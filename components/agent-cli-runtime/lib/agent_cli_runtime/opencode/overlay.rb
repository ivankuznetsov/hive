require "fileutils"
require "json"

module AgentCliRuntime
  module OpenCode
    module Overlay
      MAX_CONFIGURATION_BYTES = 1_048_576
      SECRET_KEY_PATTERN = /(?:api[_-]?key|token|secret|password|credential)/i
      ENV_PLACEHOLDER_PATTERN = /\A\{env:[A-Z][A-Z0-9_]*\}\z/
      private_constant :SECRET_KEY_PATTERN, :ENV_PLACEHOLDER_PATTERN

      class Cleanup
        def initialize(root)
          stat = File.lstat(root)
          @root = root.freeze
          @device = stat.dev
          @inode = stat.ino
          @owner = stat.uid
          @mutex = Mutex.new
          @cleaned = false
        end

        def call
          @mutex.synchronize do
            return if @cleaned
            unless File.exist?(@root) || File.symlink?(@root)
              @cleaned = true
              return
            end

            stat = File.lstat(@root)
            if stat.symlink? || !stat.directory? || stat.dev != @device ||
               stat.ino != @inode || stat.uid != @owner
              raise UnsafePathError,
                    "refusing to clean a replaced OpenCode invocation root"
            end

            FileUtils.remove_entry_secure(@root)
            @cleaned = true
          end
        end
      end
      private_constant :Cleanup

      module_function

      def prepare!(preparation, env: ENV)
        unless preparation.is_a?(OpenCodePreparationRequest)
          raise ArgumentError,
                "request must be an AgentCliRuntime::OpenCodePreparationRequest"
        end

        profile = Profiles.resolve(preparation.request.profile)
        unless profile.name == :opencode
          raise ConfigurationError,
                "OpenCode preparation requires profile :opencode"
        end

        source_config, source_label = load_configuration(preparation)
        requested_route = resolve_route(preparation.request, source_config)
        validate_provider!(source_config, requested_route.provider)
        validate_nonsecret!(source_config)
        roots = resolve_roots(preparation)
        credential_environment_keys = provider_credential_environment_keys(
          source_config, requested_route.provider,
          preparation.credential_environment_keys
        )
        plugins = selected_plugins(source_config, preparation.plugins)
        permission = permission_rules(preparation, roots, plugins: plugins)

        root = create_root!(preparation.invocation_root)
        cleanup = Cleanup.new(root)
        begin
          paths = create_directories(root)
          pure = preparation.pure && plugins.empty?
          config = generated_configuration(
            source_config, plugins, requested_route, permission
          )
          configuration_path = File.join(paths.fetch(:source), "opencode.json")
          write_private_file(configuration_path, JSON.pretty_generate(config) + "\n")
          generated_paths = [ root, *paths.values, configuration_path ]

          staged_credential = stage_credential_file(
            preparation.credential_file,
            File.join(paths.fetch(:data), "opencode", "auth.json")
          )
          generated_paths.concat(staged_credential ? staged_credential : [])

          environment = overlay_environment(
            paths, configuration_path, pure: pure
          )
          executable =
            preparation.request.executable || profile.bin(env: env)
          probe_env = env.to_h.merge(
            "AGENT_CLI_RUNTIME_OPENCODE_BIN" => executable
          )
          probe_request = ProbeRequest.new(
            profile: profile,
            route: requested_route,
            variant: preparation.request.effort,
            environment: environment,
            credential_environment_keys: credential_environment_keys,
            credential_file_staged:
              staged_credential && credential_file_supports_provider?(
                staged_credential.last, requested_route.provider
              )
          )
          probe_result = OpenCode::Probe.call!(probe_request, env: probe_env)
          invocation = compile_invocation(
            preparation, profile, requested_route, roots,
            executable:, pure: pure,
            probe_result:
          )

          PreparedInvocation.new(
            invocation: invocation,
            environment: environment,
            credential_environment_keys: credential_environment_keys,
            invocation_root: root,
            generated_paths: generated_paths.uniq,
            configuration_path: configuration_path,
            requested_route: requested_route,
            configuration_source: source_label,
            probe_result: probe_result,
            cleanup: cleanup,
            executable: executable
          )
        rescue Exception
          cleanup.call
          raise
        end
      end

      def load_configuration(preparation)
        if preparation.configuration_path
          path = safe_source_file!(
            preparation.configuration_path, label: "OpenCode configuration"
          )
          if File.size(path) > MAX_CONFIGURATION_BYTES
            raise ConfigurationError,
                  "OpenCode configuration exceeds the bounded input size"
          end
          [ JSON.parse(File.read(path)), path ]
        elsif preparation.configuration
          [ JSON.parse(JSON.generate(preparation.configuration)), "inline" ]
        else
          raise ConfigurationError,
                "OpenCode preparation requires an explicit configuration source"
        end
      rescue JSON::ParserError
        raise ConfigurationError,
              "OpenCode configuration must be valid JSON"
      end
      private_class_method :load_configuration

      def resolve_route(request, config)
        value = request.model
        value = config["model"] if value.to_s.empty?
        if value.to_s.empty?
          raise RouteUnavailable,
                "OpenCode requires an exact provider/model route or explicit overlay default"
        end
        Route.parse(value)
      rescue ArgumentError => e
        raise RouteUnavailable, Redactor.diagnostic(e)
      end
      private_class_method :resolve_route

      def validate_provider!(config, provider)
        definitions = config["provider"]
        unless definitions.is_a?(Hash) && definitions[provider].is_a?(Hash)
          raise ConfigurationError,
                "requested OpenCode provider is absent from the selected configuration"
        end
      end
      private_class_method :validate_provider!

      def validate_nonsecret!(value, key = nil)
        case value
        when Hash
          value.each { |child_key, child| validate_nonsecret!(child, child_key) }
        when Array
          value.each { |child| validate_nonsecret!(child, key) }
        when String
          if key.to_s.match?(SECRET_KEY_PATTERN) &&
             !value.match?(ENV_PLACEHOLDER_PATTERN)
            raise ConfigurationError,
                  "OpenCode provider definitions cannot contain credential values"
          end
        end
      end
      private_class_method :validate_nonsecret!

      PROVIDER_ENVIRONMENT_KEY_ALIASES = {
        "anthropic" => %w[ANTHROPIC CLAUDE],
        "google" => %w[GOOGLE GEMINI],
        "gemini" => %w[GOOGLE GEMINI],
        "xai" => %w[XAI GROK],
        "github-copilot" => %w[COPILOT GITHUB],
        "opencode" => %w[OPENCODE]
      }.freeze
      private_constant :PROVIDER_ENVIRONMENT_KEY_ALIASES

      def provider_credential_environment_keys(config, provider, configured_keys)
        definition = config.fetch("provider").fetch(provider)
        referenced = environment_placeholders(definition)
        aliases = PROVIDER_ENVIRONMENT_KEY_ALIASES.fetch(
          provider, [ provider.upcase.gsub(/[^A-Z0-9]+/, "_") ]
        )
        configured_keys.select do |key|
          referenced.include?(key) || aliases.any? { |prefix| key.start_with?("#{prefix}_") }
        end.freeze
      end
      private_class_method :provider_credential_environment_keys

      def environment_placeholders(value)
        case value
        when Hash
          value.values.flat_map { |child| environment_placeholders(child) }
        when Array
          value.flat_map { |child| environment_placeholders(child) }
        when String
          match = /\A\{env:(?<key>[A-Z][A-Z0-9_]*)\}\z/.match(value)
          match ? [ match[:key] ] : []
        else
          []
        end.uniq
      end
      private_class_method :environment_placeholders

      def resolve_roots(preparation)
        working = safe_directory!(preparation.working_directory, label: "working directory")
        reads = preparation.additional_read_roots.map do |path|
          safe_directory!(path, label: "additional read root")
        end
        writes = preparation.additional_write_roots.map do |path|
          safe_directory!(path, label: "additional write root")
        end
        {
          working: working,
          read: reads.uniq.freeze,
          write: writes.uniq.freeze
        }.freeze
      end
      private_class_method :resolve_roots

      def permission_rules(preparation, roots, plugins: preparation.plugins)
        mode = preparation.request.permission_mode
        if mode.nil?
          policy = preparation.permission_policy
          unless policy
            raise ConfigurationError,
                  "OpenCode requires an explicit OpenCode permission policy when permission_mode is nil"
          end
          return deep_copy(policy.rules)
        end

        unless %w[read-only workspace-write].include?(mode)
          raise ConfigurationError,
                "unsupported OpenCode permission mode"
        end

        external = { "*" => "deny" }
        (roots.fetch(:read) + roots.fetch(:write)).uniq.each do |root|
          external[root] = "allow"
          external["#{root}/**"] = "allow"
        end
        common = {
          "*" => "deny",
          "read" => {
            "*" => "allow",
            "*.env" => "deny",
            "*.env.*" => "deny",
            "*.env.example" => "allow"
          },
          "glob" => "allow",
          "grep" => "allow",
          "list" => "allow",
          "lsp" => "allow",
          "skill" => plugins.empty? ? "deny" : "allow",
          "external_directory" => external
        }
        if mode == "read-only"
          return common.merge(
            "edit" => "deny", "bash" => "deny", "task" => "deny",
            "webfetch" => "deny", "websearch" => "deny",
            "question" => "deny"
          )
        end

        # OpenCode applies the last matching permission rule. Start from a
        # denial and append only the invocation's declared write roots. The
        # working directory is an implicit write root for workspace-write;
        # additional read roots remain explicitly denied unless the caller
        # also declared them writable.
        writable_roots = [ roots.fetch(:working), *roots.fetch(:write) ].uniq
        edit = { "*" => "deny" }
        allows = if preparation.edit_patterns.empty?
          writable_roots.flat_map do |root|
            edit_patterns(root, working: roots.fetch(:working))
          end
        else
          normalize_declared_edit_patterns(
            preparation.edit_patterns, writable_roots,
            working: roots.fetch(:working)
          )
        end
        allows.each do |pattern|
            edit[pattern] = "allow"
        end
        (roots.fetch(:read) - roots.fetch(:write)).each do |root|
          edit_patterns(root, working: roots.fetch(:working)).each do |pattern|
            edit[pattern] = "deny"
          end
        end
        common.merge(
          "edit" => edit, "bash" => "deny", "task" => "deny",
          "webfetch" => "deny", "websearch" => "deny",
          "question" => "deny"
        )
      end
      private_class_method :permission_rules

      def edit_patterns(root, working:)
        if root == working
          [ "**" ]
        elsif root.start_with?(working + File::SEPARATOR)
          relative = root.delete_prefix(working + File::SEPARATOR)
          [ relative, "#{relative}/**" ]
        else
          [ root, "#{root}/**" ]
        end
      end
      private_class_method :edit_patterns

      def normalize_declared_edit_patterns(patterns, writable_roots, working:)
        patterns.map do |value|
          pattern = value.sub(%r{\A//}, "/")
          unless File.absolute_path?(pattern) && !pattern.include?("\0")
            raise ConfigurationError,
                  "OpenCode edit patterns must be absolute path patterns"
          end
          literal_prefix = pattern.split(/[*?]/, 2).first.sub(%r{/+\z}, "")
          unless writable_roots.any? do |root|
            literal_prefix == root || literal_prefix.start_with?(root + File::SEPARATOR)
          end
            raise ConfigurationError,
                  "OpenCode edit pattern is outside the declared write roots"
          end
          if pattern == working
            "**"
          elsif pattern.start_with?(working + File::SEPARATOR)
            pattern.delete_prefix(working + File::SEPARATOR)
          else
            pattern
          end
        end.uniq.freeze
      end
      private_class_method :normalize_declared_edit_patterns

      def create_root!(value)
        path = File.expand_path(value)
        unless File.absolute_path?(value.to_s)
          raise UnsafePathError,
                "OpenCode invocation root must be absolute"
        end
        parent = File.realpath(File.dirname(path))
        path = File.join(parent, File.basename(path))
        if File.exist?(path) || File.symlink?(path)
          raise UnsafePathError,
                "OpenCode invocation root must not already exist"
        end
        validate_ancestors!(parent)
        Dir.mkdir(path, 0o700)
        path.freeze
      rescue Errno::EEXIST, Errno::ENOENT, Errno::EACCES => e
        raise UnsafePathError, Redactor.diagnostic(e)
      end
      private_class_method :create_root!

      def validate_ancestors!(path)
        current = File.expand_path(path)
        loop do
          stat = File.lstat(current)
          unless stat.directory? && !stat.symlink?
            raise UnsafePathError,
                  "OpenCode invocation root has an unsafe ancestor"
          end
          parent = File.dirname(current)
          break if parent == current

          current = parent
        end
      end
      private_class_method :validate_ancestors!

      def create_directories(root)
        {
          config: "config-home",
          data: "data-home",
          cache: "cache-home",
          state: "state-home",
          source: "selected-config",
          temporary: "tmp"
        }.transform_values do |relative|
          path = File.join(root, relative)
          Dir.mkdir(path, 0o700)
          path.freeze
        end.freeze
      end
      private_class_method :create_directories

      def selected_plugins(source, requested)
        values = requested.empty? ? source.fetch("plugin", []) : requested
        unless values.is_a?(Array) &&
               values.all? { |plugin| plugin.is_a?(String) && !plugin.empty? }
          raise ConfigurationError,
                "OpenCode plugin selection must be an array of non-empty strings"
        end
        values.uniq.freeze
      end
      private_class_method :selected_plugins

      def generated_configuration(source, plugins, route, permission)
        config = deep_copy(source)
        if config["agent"].is_a?(Hash)
          config["agent"].each_value do |agent|
            agent.delete("permission") if agent.is_a?(Hash)
          end
        end
        config["$schema"] ||= "https://opencode.ai/config.json"
        config["model"] = route.to_s
        config["permission"] = permission
        if plugins.empty?
          config.delete("plugin")
        else
          config["plugin"] = plugins.dup
        end
        config
      end
      private_class_method :generated_configuration

      def stage_credential_file(source, destination)
        return nil if source.nil?

        source_path = safe_source_file!(source, label: "OpenCode credential file")
        directory = File.dirname(destination)
        Dir.mkdir(directory, 0o700)
        contents = File.binread(source_path)
        write_private_file(destination, contents)
        [ directory, destination ]
      end
      private_class_method :stage_credential_file

      def credential_file_supports_provider?(path, provider)
        value = JSON.parse(File.binread(path))
        value.is_a?(Hash) && value.key?(provider)
      rescue JSON::ParserError
        false
      end
      private_class_method :credential_file_supports_provider?

      def safe_source_file!(value, label:)
        path = File.expand_path(value)
        unless File.absolute_path?(value.to_s)
          raise UnsafePathError, "#{label} must be absolute"
        end
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid
          raise UnsafePathError,
                "#{label} must be an owner-controlled regular file"
        end
        path.freeze
      rescue Errno::ENOENT, Errno::EACCES => e
        raise UnsafePathError, Redactor.diagnostic(e)
      end
      private_class_method :safe_source_file!

      def safe_directory!(value, label:)
        path = File.expand_path(value)
        unless File.absolute_path?(value.to_s)
          raise UnsafePathError, "#{label} must be absolute"
        end
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise UnsafePathError,
                "#{label} must be an owner-controlled real directory"
        end
        File.realpath(path).freeze
      rescue Errno::ENOENT, Errno::EACCES => e
        raise UnsafePathError, Redactor.diagnostic(e)
      end
      private_class_method :safe_directory!

      def write_private_file(path, contents)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(contents)
        end
        File.chmod(0o600, path)
        path
      end
      private_class_method :write_private_file

      def overlay_environment(paths, configuration_path, pure:)
        environment = {
          "XDG_CONFIG_HOME" => paths.fetch(:config),
          "XDG_DATA_HOME" => paths.fetch(:data),
          "XDG_CACHE_HOME" => paths.fetch(:cache),
          "XDG_STATE_HOME" => paths.fetch(:state),
          "TMPDIR" => paths.fetch(:temporary),
          "OPENCODE_CONFIG" => configuration_path,
          "OPENCODE_DISABLE_PROJECT_CONFIG" => "true",
          "OPENCODE_DISABLE_CLAUDE_CODE" => "true",
          "OPENCODE_DISABLE_MODELS_FETCH" => "true",
          "OPENCODE_DISABLE_AUTOUPDATE" => "true",
          "OPENCODE_PURE" => pure ? "true" : "false"
        }
        unless environment.keys.sort == OPENCODE_OVERLAY_ENVIRONMENT_KEYS.sort
          raise ConfigurationError, "OpenCode overlay environment contract drifted"
        end
        environment.freeze
      end
      private_class_method :overlay_environment

      def compile_invocation(preparation, profile, route, roots,
                             executable:, pure:, probe_result:)
        source = preparation.request
        trusted = source.trusted_cli_arguments.dup
        trusted.concat([ "--dir", roots.fetch(:working) ])
        trusted << "--pure" if pure
        request = Request.new(
          profile: profile,
          prompt: source.prompt,
          permission_mode: source.permission_mode,
          permission_arguments: [ "--auto" ],
          add_dirs: [],
          require_add_dirs: false,
          allowed_tools: nil,
          disallowed_tools: nil,
          # OpenCode has no verified per-run budget flag in the pinned
          # contract. The caller may enforce external limits, but preparation
          # must not claim that this value reached the CLI.
          max_budget_usd: nil,
          model: route.to_s,
          effort: source.effort,
          pin_model: true,
          identity_arguments: source.identity_arguments,
          capabilities: [],
          raw_cli_arguments: source.raw_cli_arguments,
          trusted_cli_arguments: trusted,
          executable: executable,
          command_prefix: source.command_prefix,
          include_output_format: source.include_output_format
        )
        compiled = Runtime.compile(request)
        CompiledInvocation.new(
          argv: compiled.argv,
          stdin_data: compiled.stdin_data,
          provider: compiled.provider,
          launcher_identity: compiled.launcher_identity,
          capability_evidence:
            compiled.capability_evidence + probe_result.capability_evidence
        )
      end
      private_class_method :compile_invocation

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :deep_copy
    end
  end
end
