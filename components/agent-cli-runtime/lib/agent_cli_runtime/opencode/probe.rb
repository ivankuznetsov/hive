require "json"

module AgentCliRuntime
  module OpenCode
    module Probe
      REQUIRED_RUN_FLAGS = %w[
        --model --variant --format --dir --pure --auto
      ].freeze
      MODEL_INVENTORY_TIMEOUT_SECONDS = 30
      SAFE_ENVIRONMENT_KEYS = %w[
        HOME LANG LC_ALL LOGNAME PATH SHELL SSL_CERT_DIR SSL_CERT_FILE
        TMPDIR USER
      ].freeze
      ANSI_PATTERN = /\e\[[0-?]*[ -\/]*[@-~]/
      private_constant :SAFE_ENVIRONMENT_KEYS, :ANSI_PATTERN

      module_function

      def call(request, env: ENV)
        call!(request, env:)
      rescue Error => e
        profile = Profiles.resolve(request.profile)
        executable = request.executable || profile.bin(env:)
        RouteProbeResult.new(
          provider: profile.name,
          ready: false,
          installed: profile.binary_installed?(env:, executable:),
          executable: executable,
          version: nil,
          minimum_version: profile.min_version,
          auth_configuration: AuthConfiguration.new(status: :not_checked),
          route: request.route,
          route_available: false,
          available_variants: [],
          capability_evidence: [
            CapabilityEvidence.new(
              capability: error_capability(e), supported: false,
              provider: profile.name,
              launcher_identity: profile.launcher_identity,
              diagnostic: Redactor.diagnostic(e)
            )
          ],
          diagnostic: Redactor.diagnostic(e)
        )
      end

      def call!(request, env: ENV)
        unless request.is_a?(ProbeRequest)
          raise ArgumentError,
                "request must be an AgentCliRuntime::ProbeRequest"
        end

        profile = Profiles.resolve(request.profile)
        unless profile.name == :opencode
          raise ArgumentError,
                "route-aware ProbeRequest currently requires profile :opencode"
        end
        installed = profile.binary_installed?(env:, executable: request.executable)
        unless installed
          raise BinaryUnavailable,
                "opencode binary not runnable: " \
                "#{request.executable || profile.bin(env:)}"
        end

        child_env = child_environment(profile, request, env:)
        version = profile.check_version!(
          env: child_env, executable: request.executable
        )
        evidence = [
          evidence(profile, :installation),
          evidence(profile, :version, [ version ])
        ]

        run_help = capture!(
          profile, child_env, "run", "--help", executable: request.executable
        )
        missing = REQUIRED_RUN_FLAGS.reject { |flag| advertised?(run_help, flag) }
        unless missing.empty?
          raise UnsupportedCapability,
                "OpenCode run is missing required capability #{missing.join(', ')}"
        end
        evidence.concat(REQUIRED_RUN_FLAGS.map do |flag|
          evidence(profile, capability_for(flag), [ flag ])
        end)

        export_help = capture!(
          profile, child_env, "export", "--help", executable: request.executable
        )
        unless advertised?(export_help, "--sanitize")
          raise UnsupportedCapability,
                "OpenCode export is missing required --sanitize capability"
        end
        evidence << evidence(profile, :sanitized_export, [ "--sanitize" ])

        auth_output = capture!(
          profile, child_env, "auth", "list", executable: request.executable
        )
        configured_key = request.credential_environment_keys.find do |key|
          !env[key].to_s.empty?
        end
        auth_from_inventory =
          normalized_output(auth_output).match?(
            /(?:\A|[^A-Za-z0-9_.-])#{Regexp.escape(request.route.provider)}(?:\z|[^A-Za-z0-9_.-])/
          )
        unless configured_key || request.credential_file_staged ||
               auth_from_inventory
          raise AuthenticationError,
                "OpenCode authentication source is missing for requested provider"
        end
        auth = AuthConfiguration.new(
          status: :configured,
          source:
            configured_key ? "selected environment" :
              (request.credential_file_staged ? "staged auth file" :
               "local auth inventory")
        )
        evidence << evidence(profile, :auth_configuration)

        configured_variants = request.configured_variants
        inventory_variants = if configured_variants.nil?
          models_output = capture!(
            profile, child_env, "models", request.route.provider, "--verbose",
            executable: request.executable,
            timeout_sec: MODEL_INVENTORY_TIMEOUT_SECONDS
          )
          variants_for(models_output, request.route.to_s)
        end
        if configured_variants.nil? && inventory_variants.nil?
          raise RouteUnavailable,
                "requested OpenCode route is unavailable in the local model inventory"
        end
        variants = [ *inventory_variants, *configured_variants ].uniq.sort.freeze
        if request.variant && !variants.include?(request.variant)
          raise RouteUnavailable,
                "requested OpenCode variant is unavailable for the exact route"
        end
        evidence << evidence(profile, :model_route, [ request.route.to_s ])
        if inventory_variants.nil?
          evidence << evidence(
            profile, :configured_model_route, [ request.route.to_s ]
          )
        end
        evidence << evidence(profile, :model_variant, [ request.variant ]) if
          request.variant

        RouteProbeResult.new(
          provider: profile.name,
          ready: true,
          installed: true,
          executable: request.executable || profile.bin(env: child_env),
          version: version,
          minimum_version: profile.min_version,
          auth_configuration: auth,
          route: request.route,
          route_available: true,
          available_variants: variants,
          capability_evidence: evidence,
          diagnostic: nil
        )
      rescue UnknownProvider
        raise
      rescue Error
        raise
      rescue StandardError => e
        raise ProbeError, Redactor.diagnostic(e)
      end

      def child_environment(profile, request, env:)
        selected = (ENV.keys | env.keys).to_h { |key| [ key, nil ] }
        env.each do |key, value|
          if SAFE_ENVIRONMENT_KEYS.include?(key) || key.start_with?("LC_") ||
             key.start_with?("MISE_")
            selected[key] = value.to_s
          end
        end
        %w[
          BUNDLE_BIN_PATH BUNDLE_GEMFILE GEM_HOME GEM_PATH RUBYLIB RUBYOPT
        ].each { |key| selected[key] = nil }
        profile.env_bin_override_keys.each do |key|
          selected[key] = env[key].to_s unless env[key].to_s.empty?
        end
        request.credential_environment_keys.each do |key|
          selected[key] = env[key].to_s unless env[key].to_s.empty?
        end
        selected.merge(request.environment).freeze
      end
      private_class_method :child_environment

      def capture!(profile, environment, *arguments, executable: nil,
                   timeout_sec: nil)
        options = { env: environment, executable: executable }
        options[:timeout_sec] = timeout_sec if timeout_sec
        out, err, status = profile.capture_local(*arguments, **options)
        unless status.success?
          diagnostic = normalized_output("#{err}\n#{out}")
          raise ConfigurationError,
                diagnostic.empty? ?
                  "OpenCode local inspection command failed" : diagnostic
        end
        "#{out}\n#{err}"
      rescue Errno::ENOENT, Errno::EACCES, Timeout::Error => e
        raise BinaryUnavailable,
              "OpenCode local inspection command could not run (#{e.class.name.split('::').last})"
      end
      private_class_method :capture!

      def advertised?(help, flag)
        help.match?(/(?:\A|[\s,])#{Regexp.escape(flag)}(?:[\s,=\[]|$)/)
      end
      private_class_method :advertised?

      def variants_for(output, route)
        text = normalized_output(output)
        lines = text.lines
        index = lines.index { |line| line.strip == route }
        return nil unless index

        suffix = lines.drop(index + 1).join
        object = first_json_object(suffix)
        return [] unless object

        parsed = JSON.parse(object)
        variants = parsed["variants"]
        variants.is_a?(Hash) ? variants.keys.sort.freeze : [].freeze
      rescue JSON::ParserError
        raise ConfigurationError,
              "OpenCode local model inventory is malformed"
      end
      private_class_method :variants_for

      def first_json_object(text)
        start = text.index("{")
        return nil unless start

        depth = 0
        quoted = false
        escaped = false
        text.each_char.with_index do |character, index|
          next if index < start

          if quoted
            if escaped
              escaped = false
            elsif character == "\\"
              escaped = true
            elsif character == '"'
              quoted = false
            end
            next
          end
          if character == '"'
            quoted = true
          elsif character == "{"
            depth += 1
          elsif character == "}"
            depth -= 1
            return text[start..index] if depth.zero?
          end
        end
        nil
      end
      private_class_method :first_json_object

      def normalized_output(value)
        value.to_s.gsub(ANSI_PATTERN, "").strip
      end
      private_class_method :normalized_output

      def evidence(profile, capability, arguments = [])
        CapabilityEvidence.new(
          capability: capability,
          supported: true,
          provider: profile.name,
          launcher_identity: profile.launcher_identity,
          arguments: arguments.compact
        )
      end
      private_class_method :evidence

      def capability_for(flag)
        {
          "--model" => :model,
          "--variant" => :model_variant,
          "--format" => :json_events,
          "--dir" => :working_directory,
          "--pure" => :pure,
          "--auto" => :permission_enforcement
        }.fetch(flag)
      end
      private_class_method :capability_for

      def error_capability(error)
        case error
        when AuthenticationError then :auth_configuration
        when RouteUnavailable then :model_route
        when UnsupportedCapability then :cli_capability
        when BinaryUnavailable then :installation
        else :probe
        end
      end
      private_class_method :error_capability
    end
  end
end
