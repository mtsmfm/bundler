# frozen_string_literal: true

module Bundler
  class RubygemsIntegration
    if defined?(Gem::Ext::Builder::CHDIR_MONITOR)
      EXT_LOCK = Gem::Ext::Builder::CHDIR_MONITOR
    else
      require "monitor"

      EXT_LOCK = Monitor.new
    end

    def self.version
      @version ||= Gem::Version.new(Gem::VERSION)
    end

    def self.provides?(req_str)
      Gem::Requirement.new(req_str).satisfied_by?(version)
    end

    def initialize
      @replaced_methods = {}
      backport_ext_builder_monitor
    end

    def version
      self.class.version
    end

    def provides?(req_str)
      self.class.provides?(req_str)
    end

    def build_args
      Gem::Command.build_args
    end

    def build_args=(args)
      Gem::Command.build_args = args
    end

    def load_path_insert_index
      Gem.load_path_insert_index
    end

    def loaded_specs(name)
      Gem.loaded_specs[name]
    end

    def mark_loaded(spec)
      if spec.respond_to?(:activated=)
        current = Gem.loaded_specs[spec.name]
        current.activated = false if current
        spec.activated = true
      end
      Gem.loaded_specs[spec.name] = spec
    end

    def validate(spec)
      Bundler.ui.silence { spec.validate(false) }
    rescue Gem::InvalidSpecificationException => e
      error_message = "The gemspec at #{spec.loaded_from} is not valid. Please fix this gemspec.\n" \
        "The validation error was '#{e.message}'\n"
      raise Gem::InvalidSpecificationException.new(error_message)
    rescue Errno::ENOENT
      nil
    end

    def set_installed_by_version(spec, installed_by_version = Gem::VERSION)
      return unless spec.respond_to?(:installed_by_version=)
      spec.installed_by_version = Gem::Version.create(installed_by_version)
    end

    def spec_missing_extensions?(spec, default = true)
      return spec.missing_extensions? if spec.respond_to?(:missing_extensions?)

      return false if spec_default_gem?(spec)
      return false if spec.extensions.empty?

      default
    end

    def spec_default_gem?(spec)
      spec.respond_to?(:default_gem?) && spec.default_gem?
    end

    def spec_matches_for_glob(spec, glob)
      return spec.matches_for_glob(glob) if spec.respond_to?(:matches_for_glob)

      spec.load_paths.map do |lp|
        Dir["#{lp}/#{glob}#{suffix_pattern}"]
      end.flatten(1)
    end

    def spec_extension_dir(spec)
      return unless spec.respond_to?(:extension_dir)
      spec.extension_dir
    end

    def stub_set_spec(stub, spec)
      stub.instance_variable_set(:@spec, spec)
    end

    def path(obj)
      obj.to_s
    end

    def platforms
      return [Gem::Platform::RUBY] if Bundler.settings[:force_ruby_platform]
      Gem.platforms
    end

    def configuration
      require_relative "psyched_yaml"
      Gem.configuration
    rescue Gem::SystemExitException, LoadError => e
      Bundler.ui.error "#{e.class}: #{e.message}"
      Bundler.ui.trace e
      raise
    rescue YamlLibrarySyntaxError => e
      raise YamlSyntaxError.new(e, "Your RubyGems configuration, which is " \
        "usually located in ~/.gemrc, contains invalid YAML syntax.")
    end

    def ruby_engine
      Gem.ruby_engine
    end

    def read_binary(path)
      Gem.read_binary(path)
    end

    def inflate(obj)
      if defined?(Gem::Util)
        Gem::Util.inflate(obj)
      else
        Gem.inflate(obj)
      end
    end

    def sources=(val)
      # Gem.configuration creates a new Gem::ConfigFile, which by default will read ~/.gemrc
      # If that file exists, its settings (including sources) will overwrite the values we
      # are about to set here. In order to avoid that, we force memoizing the config file now.
      configuration

      Gem.sources = val
    end

    def sources
      Gem.sources
    end

    def gem_dir
      Gem.dir
    end

    def gem_bindir
      Gem.bindir
    end

    def user_home
      Gem.user_home
    end

    def gem_path
      Gem.path
    end

    def reset
      Gem::Specification.reset
    end

    def post_reset_hooks
      Gem.post_reset_hooks
    end

    def suffix_pattern
      Gem.suffix_pattern
    end

    def gem_cache
      gem_path.map {|p| File.expand_path("cache", p) }
    end

    def spec_cache_dirs
      @spec_cache_dirs ||= begin
        dirs = gem_path.map {|dir| File.join(dir, "specifications") }
        dirs << Gem.spec_cache_dir if Gem.respond_to?(:spec_cache_dir) # Not in RubyGems 2.0.3 or earlier
        dirs.uniq.select {|dir| File.directory? dir }
      end
    end

    def marshal_spec_dir
      Gem::MARSHAL_SPEC_DIR
    end

    def config_map
      Gem::ConfigMap
    end

    def clear_paths
      Gem.clear_paths
    end

    def bin_path(gem, bin, ver)
      Gem.bin_path(gem, bin, ver)
    end

    def preserve_paths
      # this is a no-op outside of RubyGems 1.8
      yield
    end

    def loaded_gem_paths
      # RubyGems 2.2+ can put binary extension into dedicated folders,
      # therefore use RubyGems facilities to obtain their load paths.
      if Gem::Specification.method_defined? :full_require_paths
        loaded_gem_paths = Gem.loaded_specs.map {|_, s| s.full_require_paths }
        loaded_gem_paths.flatten
      else
        $LOAD_PATH.select do |p|
          Bundler.rubygems.gem_path.any? {|gp| p =~ /^#{Regexp.escape(gp)}/ }
        end
      end
    end

    def load_plugins
      Gem.load_plugins if Gem.respond_to?(:load_plugins)
    end

    def load_plugin_files(files)
      Gem.load_plugin_files(files) if Gem.respond_to?(:load_plugin_files)
    end

    def ui=(obj)
      Gem::DefaultUserInteraction.ui = obj
    end

    def ext_lock
      EXT_LOCK
    end

    def fetch_prerelease_specs
      fetch_specs(false, true)
    rescue Gem::RemoteFetcher::FetchError
      {} # if we can't download them, there aren't any
    end

    def with_build_args(args)
      ext_lock.synchronize do
        old_args = build_args
        begin
          self.build_args = args
          yield
        ensure
          self.build_args = old_args
        end
      end
    end

    def spec_from_gem(path, policy = nil)
      require "rubygems/security"
      require_relative "psyched_yaml"
      gem_from_path(path, security_policies[policy]).spec
    rescue Gem::Package::FormatError
      raise GemspecError, "Could not read gem at #{path}. It may be corrupted."
    rescue Exception, Gem::Exception, Gem::Security::Exception => e # rubocop:disable Lint/RescueException
      if e.is_a?(Gem::Security::Exception) ||
          e.message =~ /unknown trust policy|unsigned gem/i ||
          e.message =~ /couldn't verify (meta)?data signature/i
        raise SecurityError,
          "The gem #{File.basename(path, ".gem")} can't be installed because " \
          "the security policy didn't allow it, with the message: #{e.message}"
      else
        raise e
      end
    end

    def build_gem(gem_dir, spec)
      build(spec)
    end

    def security_policy_keys
      %w[High Medium Low AlmostNo No].map {|level| "#{level}Security" }
    end

    def security_policies
      @security_policies ||= begin
        require "rubygems/security"
        Gem::Security::Policies
      rescue LoadError, NameError
        {}
      end
    end

    def reverse_rubygems_kernel_mixin
      # Disable rubygems' gem activation system
      kernel = (class << ::Kernel; self; end)
      [kernel, ::Kernel].each do |k|
        if k.private_method_defined?(:gem_original_require)
          redefine_method(k, :require, k.instance_method(:gem_original_require))
        end
      end
    end

    # RubyGems-generated binstubs call Kernel#gem
    def binstubs_call_gem?
      !provides?(">= 2.5.2")
    end

    # only 2.5.2+ has all of the stub methods we want to use, and since this
    # is a performance optimization _only_,
    # we'll restrict ourselves to the most
    # recent RG versions instead of all versions that have stubs
    def stubs_provide_full_functionality?
      provides?(">= 2.5.2")
    end

    def has_bundler_version_finder?
      provides?(">= 2.7.0")
    end

    def replace_gem(specs, specs_by_name)
      reverse_rubygems_kernel_mixin

      executables = nil

      kernel = (class << ::Kernel; self; end)
      [kernel, ::Kernel].each do |kernel_class|
        redefine_method(kernel_class, :gem) do |dep, *reqs|
          executables ||= specs.map(&:executables).flatten if ::Bundler.rubygems.binstubs_call_gem?
          if executables && executables.include?(File.basename(caller.first.split(":").first))
            break
          end

          reqs.pop if reqs.last.is_a?(Hash)

          unless dep.respond_to?(:name) && dep.respond_to?(:requirement)
            dep = Gem::Dependency.new(dep, reqs)
          end

          if spec = specs_by_name[dep.name]
            return true if dep.matches_spec?(spec)
          end

          message = if spec.nil?
            "#{dep.name} is not part of the bundle." \
            " Add it to your #{Bundler.default_gemfile.basename}."
          else
            "can't activate #{dep}, already activated #{spec.full_name}. " \
            "Make sure all dependencies are added to Gemfile."
          end

          e = Gem::LoadError.new(message)
          e.name = dep.name
          if e.respond_to?(:requirement=)
            e.requirement = dep.requirement
          elsif e.respond_to?(:version_requirement=)
            e.version_requirement = dep.requirement
          end
          raise e
        end

        # backwards compatibility shim, see https://github.com/bundler/bundler/issues/5102
        kernel_class.send(:public, :gem) if Bundler.feature_flag.setup_makes_kernel_gem_public?
      end
    end

    # Used to make bin stubs that are not created by bundler work
    # under bundler. The new Gem.bin_path only considers gems in
    # +specs+
    def replace_bin_path(specs_by_name)
      gem_class = (class << Gem; self; end)

      redefine_method(gem_class, :find_spec_for_exe) do |gem_name, *args|
        exec_name = args.first
        raise ArgumentError, "you must supply exec_name" unless exec_name

        spec_with_name = specs_by_name[gem_name]
        matching_specs_by_exec_name = specs_by_name.values.select {|s| s.executables.include?(exec_name) }
        spec = matching_specs_by_exec_name.delete(spec_with_name)

        unless spec || !matching_specs_by_exec_name.empty?
          message = "can't find executable #{exec_name} for gem #{gem_name}"
          if spec_with_name.nil?
            message += ". #{gem_name} is not currently included in the bundle, " \
                       "perhaps you meant to add it to your #{Bundler.default_gemfile.basename}?"
          end
          raise Gem::Exception, message
        end

        unless spec
          spec = matching_specs_by_exec_name.shift
          warn \
            "Bundler is using a binstub that was created for a different gem (#{spec.name}).\n" \
            "You should run `bundle binstub #{gem_name}` " \
            "to work around a system/bundle conflict."
        end

        unless matching_specs_by_exec_name.empty?
          conflicting_names = matching_specs_by_exec_name.map(&:name).join(", ")
          warn \
            "The `#{exec_name}` executable in the `#{spec.name}` gem is being loaded, but it's also present in other gems (#{conflicting_names}).\n" \
            "If you meant to run the executable for another gem, make sure you use a project specific binstub (`bundle binstub <gem_name>`).\n" \
            "If you plan to use multiple conflicting executables, generate binstubs for them and disambiguate their names."
        end

        spec
      end

      redefine_method(gem_class, :activate_bin_path) do |name, *args|
        exec_name = args.first
        return ENV["BUNDLE_BIN_PATH"] if exec_name == "bundle"

        # Copy of Rubygems activate_bin_path impl
        requirement = args.last
        spec = find_spec_for_exe name, exec_name, [requirement]

        gem_bin = File.join(spec.full_gem_path, spec.bindir, exec_name)
        gem_from_path_bin = File.join(File.dirname(spec.loaded_from), spec.bindir, exec_name)
        File.exist?(gem_bin) ? gem_bin : gem_from_path_bin
      end

      redefine_method(gem_class, :bin_path) do |name, *args|
        exec_name = args.first
        return ENV["BUNDLE_BIN_PATH"] if exec_name == "bundle"

        spec = find_spec_for_exe(name, *args)
        exec_name ||= spec.default_executable

        gem_bin = File.join(spec.full_gem_path, spec.bindir, exec_name)
        gem_from_path_bin = File.join(File.dirname(spec.loaded_from), spec.bindir, exec_name)
        File.exist?(gem_bin) ? gem_bin : gem_from_path_bin
      end
    end

    # Because Bundler has a static view of what specs are available,
    # we don't #refresh, so stub it out.
    def replace_refresh
      gem_class = (class << Gem; self; end)
      redefine_method(gem_class, :refresh) {}
    end

    # Replace or hook into RubyGems to provide a bundlerized view
    # of the world.
    def replace_entrypoints(specs)
      specs_by_name = specs.reduce({}) do |h, s|
        h[s.name] = s
        h
      end

      Bundler.rubygems.default_stubs.each do |stub|
        default_spec = stub.to_spec
        default_spec_name = default_spec.name
        next if specs_by_name.key?(default_spec_name)

        specs << default_spec
        specs_by_name[default_spec_name] = default_spec
      end

      replace_gem(specs, specs_by_name)
      stub_rubygems(specs)
      replace_bin_path(specs_by_name)
      replace_refresh

      Gem.clear_paths
    end

    # This backports the correct segment generation code from RubyGems 1.4+
    # by monkeypatching it into the method in RubyGems 1.3.6 and 1.3.7.
    def backport_segment_generation
      redefine_method(Gem::Version, :segments) do
        @segments ||= @version.scan(/[0-9]+|[a-z]+/i).map do |s|
          /^\d+$/ =~ s ? s.to_i : s
        end
      end
    end

    # This backport fixes the marshaling of @segments.
    def backport_yaml_initialize
      redefine_method(Gem::Version, :yaml_initialize) do |_, map|
        @version = map["version"]
        @segments = nil
        @hash = nil
      end
    end

    # This backports base_dir which replaces installation path
    # RubyGems 1.8+
    def backport_base_dir
      redefine_method(Gem::Specification, :base_dir) do
        return Gem.dir unless loaded_from
        File.dirname File.dirname loaded_from
      end
    end

    def backport_cache_file
      redefine_method(Gem::Specification, :cache_dir) do
        @cache_dir ||= File.join base_dir, "cache"
      end

      redefine_method(Gem::Specification, :cache_file) do
        @cache_file ||= File.join cache_dir, "#{full_name}.gem"
      end
    end

    def backport_spec_file
      redefine_method(Gem::Specification, :spec_dir) do
        @spec_dir ||= File.join base_dir, "specifications"
      end

      redefine_method(Gem::Specification, :spec_file) do
        @spec_file ||= File.join spec_dir, "#{full_name}.gemspec"
      end
    end

    def undo_replacements
      @replaced_methods.each do |(sym, klass), method|
        redefine_method(klass, sym, method)
      end
      if Binding.public_method_defined?(:source_location)
        post_reset_hooks.reject! {|proc| proc.binding.source_location[0] == __FILE__ }
      else
        post_reset_hooks.reject! {|proc| proc.binding.eval("__FILE__") == __FILE__ }
      end
      @replaced_methods.clear
    end

    def redefine_method(klass, method, unbound_method = nil, &block)
      visibility = method_visibility(klass, method)
      begin
        if (instance_method = klass.instance_method(method)) && method != :initialize
          # doing this to ensure we also get private methods
          klass.send(:remove_method, method)
        end
      rescue NameError
        # method isn't defined
        nil
      end
      @replaced_methods[[method, klass]] = instance_method
      if unbound_method
        klass.send(:define_method, method, unbound_method)
        klass.send(visibility, method)
      elsif block
        klass.send(:define_method, method, &block)
        klass.send(visibility, method)
      end
    end

    def method_visibility(klass, method)
      if klass.private_method_defined?(method)
        :private
      elsif klass.protected_method_defined?(method)
        :protected
      else
        :public
      end
    end

    def stub_rubygems(specs)
      Gem::Specification.all = specs

      Gem.post_reset do
        Gem::Specification.all = specs
      end

      redefine_method((class << Gem; self; end), :finish_resolve) do |*|
        []
      end
    end

    def fetch_specs(source, remote, name)
      path = source + "#{name}.#{Gem.marshal_version}.gz"
      fetcher = gem_remote_fetcher
      fetcher.headers = { "X-Gemfile-Source" => remote.original_uri.to_s } if remote.original_uri
      string = fetcher.fetch_path(path)
      Bundler.load_marshal(string)
    rescue Gem::RemoteFetcher::FetchError => e
      # it's okay for prerelease to fail
      raise e unless name == "prerelease_specs"
    end

    def fetch_all_remote_specs(remote)
      source = remote.uri.is_a?(URI) ? remote.uri : URI.parse(source.to_s)

      specs = fetch_specs(source, remote, "specs")
      pres = fetch_specs(source, remote, "prerelease_specs") || []

      specs.concat(pres)
    end

    def download_gem(spec, uri, path)
      uri = Bundler.settings.mirror_for(uri)
      fetcher = gem_remote_fetcher
      fetcher.headers = { "X-Gemfile-Source" => spec.remote.original_uri.to_s } if spec.remote.original_uri
      Bundler::Retry.new("download gem from #{uri}").attempts do
        fetcher.download(spec, uri, path)
      end
    end

    def gem_remote_fetcher
      require "resolv"
      proxy = configuration[:http_proxy]
      dns = Resolv::DNS.new
      Bundler::GemRemoteFetcher.new(proxy, dns)
    end

    def gem_from_path(path, policy = nil)
      require "rubygems/package"
      p = Gem::Package.new(path)
      p.security_policy = policy if policy
      p
    end

    def build(spec, skip_validation = false)
      require "rubygems/package"
      Gem::Package.build(spec, skip_validation)
    end

    def repository_subdirectories
      Gem::REPOSITORY_SUBDIRECTORIES
    end

    def install_with_build_args(args)
      yield
    end

    def path_separator
      Gem.path_separator
    end

    def all_specs
      require_relative "remote_specification"
      Gem::Specification.stubs.map do |stub|
        StubSpecification.from_stub(stub)
      end
    end

    def backport_ext_builder_monitor
      # So we can avoid requiring "rubygems/ext" in its entirety
      Gem.module_eval <<-RB, __FILE__, __LINE__ + 1
        module Ext
        end
      RB

      require "rubygems/ext/builder"

      Gem::Ext::Builder.class_eval do
        unless const_defined?(:CHDIR_MONITOR)
          const_set(:CHDIR_MONITOR, EXT_LOCK)
        end

        remove_const(:CHDIR_MUTEX) if const_defined?(:CHDIR_MUTEX)
        const_set(:CHDIR_MUTEX, const_get(:CHDIR_MONITOR))
      end
    end

    if Gem::Specification.respond_to?(:stubs_for)
      def find_name(name)
        Gem::Specification.stubs_for(name).map(&:to_spec)
      end
    else
      def find_name(name)
        Gem::Specification.stubs.find_all do |spec|
          spec.name == name
        end.map(&:to_spec)
      end
    end

    if Gem::Specification.respond_to?(:default_stubs)
      def default_stubs
        Gem::Specification.default_stubs("*.gemspec")
      end
    else
      def default_stubs
        Gem::Specification.send(:default_stubs, "*.gemspec")
      end
    end

    def use_gemdeps(gemfile)
      ENV["BUNDLE_GEMFILE"] ||= File.expand_path(gemfile)
      require_relative "gemdeps"
      runtime = Bundler.setup
      Bundler.ui = nil
      activated_spec_names = runtime.requested_specs.map(&:to_spec).sort_by(&:name)
      [Gemdeps.new(runtime), activated_spec_names]
    end
  end

  def self.rubygems
    @rubygems ||= RubygemsIntegration.new
  end
end
