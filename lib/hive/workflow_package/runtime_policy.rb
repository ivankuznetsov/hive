require "fileutils"
require "json"
require "rbconfig"
require "shellwords"
require "hive/atomic_file"
require "hive/agent_profiles"
require "hive/workflow_package/canonical_json"

module Hive
  module WorkflowPackage
    class RuntimePolicy
      REQUIRED_CAPABILITIES = %i[
        tools directories commands domains settings_isolation mcp_isolation environment_isolation
      ].freeze
      SUPPORTED_TOOLS = %w[
        Read LS Grep Glob Write Edit MultiEdit NotebookEdit Bash WebFetch
      ].freeze
      ALWAYS_DENIED_TOOLS = %w[WebSearch Task Skill EnterPlanMode ExitPlanMode AskUserQuestion].freeze
      SAFE_ENV_KEYS = %w[HOME LANG LC_ALL TMPDIR].freeze
      COMMAND_META = /[|<>`\n\r]|\$\(|\$\{|\*\*(?!\z)/
      DOMAIN = /\A(?:\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i

      Policy = Data.define(
        :permission_mode, :allowed_tools, :disallowed_tools, :directories,
        :commands, :domains, :executables, :environment,
        :settings_path, :mcp_config_path, :policy_path, :cli_flags
      )

      def self.compile(permissions, task_folder:, profile:, policy_dir:)
        new(permissions, task_folder: task_folder, profile: profile, policy_dir: policy_dir).compile
      end

      # Admission mirrors every descriptor-selected runner, not just the
      # default stage profile. This catches a council reviewer or revise actor
      # that selects a runner unable to enforce the package policy before the
      # generation is activated (and the same compile runs again at spawn).
      def self.admit_workflow!(workflow, permissions, task_folder:, policy_dir:)
        actor_names = workflow.stages.flat_map do |stage|
          next [] unless [ :agent, :council ].include?(stage.kind)

          names = [ stage.agent || :claude ]
          if stage.kind == :council
            names.concat(stage.reviewers.map { |reviewer| reviewer.agent || :claude })
            names << (stage.council.revise.agent || :claude) if stage.council&.revise
          end
          names
        end
        actor_names.map(&:to_sym).uniq.each_with_index do |name, index|
          compile(
            permissions, task_folder: task_folder,
            profile: Hive::AgentProfiles.lookup(name),
            policy_dir: File.join(policy_dir, "actor-#{index}-#{name}")
          )
        end
        true
      end

      def initialize(permissions, task_folder:, profile:, policy_dir:)
        @permissions = stringify_hash(permissions)
        @task_folder = File.realpath(task_folder)
        @profile = profile
        @policy_dir = File.expand_path(policy_dir)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::ConfigError, "managed runtime task folder is unavailable (#{e.class.name.split('::').last})"
      end

      def compile
        validate_profile!
        tools = normalize_array("tools")
        denied = normalize_array("deny")
        validate_tools!(tools, denied)
        commands = normalize_array("commands")
        domains = normalize_array("domains").map(&:downcase)
        validate_commands!(tools, commands)
        validate_domains!(tools, domains)
        validate_credentials!
        directories = resolve_directories
        executables = resolve_executables(commands)
        environment = sanitized_environment(executables)
        disallowed = ((SUPPORTED_TOOLS - tools) + ALWAYS_DENIED_TOOLS + denied).uniq.sort

        FileUtils.mkdir_p(@policy_dir, mode: 0o700)
        policy_path = File.join(@policy_dir, "policy.json")
        settings_path = File.join(@policy_dir, "settings.json")
        mcp_path = File.join(@policy_dir, "mcp.json")
        write_json(policy_path, {
          "allowed_tools" => tools,
          "directories" => directories,
          "commands" => commands,
          "domains" => domains,
          "executables" => executables
        })
        hook_file = File.expand_path("../scripts/workflow_policy_hook.rb", __dir__)
        hook_command = Shellwords.join(
          [ RbConfig.ruby, "-r#{hook_file}", "-e", "Hive::Scripts::WorkflowPolicyHook.run(ARGV.fetch(0))", policy_path ]
        )
        settings = {
          "permissions" => {
            "defaultMode" => "dontAsk",
            "allow" => tools,
            "deny" => disallowed,
            "additionalDirectories" => directories.drop(1)
          },
          "hooks" => {
            "PreToolUse" => [ { "hooks" => [ { "type" => "command", "command" => hook_command } ] } ]
          }
        }
        if tools.include?("Bash")
          settings["sandbox"] = {
            "enabled" => true,
            "failIfUnavailable" => true,
            "autoAllowBashIfSandboxed" => true,
            "excludedCommands" => [],
            "allowUnsandboxedCommands" => false,
            "filesystem" => { "allowWrite" => directories },
            "network" => { "allowedDomains" => domains, "deniedDomains" => [] }
          }
        end
        write_json(settings_path, settings)
        write_json(mcp_path, {})

        Policy.new(
          permission_mode: "dontAsk",
          allowed_tools: tools.freeze,
          disallowed_tools: disallowed.freeze,
          directories: directories.freeze,
          commands: commands.freeze,
          domains: domains.freeze,
          executables: executables.freeze,
          environment: environment.freeze,
          settings_path: settings_path.freeze,
          mcp_config_path: mcp_path.freeze,
          policy_path: policy_path.freeze,
          cli_flags: [ "--settings", settings_path, "--setting-sources", "",
                       "--mcp-config", mcp_path, "--strict-mcp-config" ].freeze
        ).freeze
      end

      private

      def validate_profile!
        capabilities = @profile.respond_to?(:policy_capabilities) ? @profile.policy_capabilities : []
        missing = REQUIRED_CAPABILITIES - capabilities
        return if @profile.name == :claude && missing.empty?

        raise Hive::ConfigError,
              "runner #{@profile.name.inspect} cannot enforce managed workflow policy" \
              "#{missing.empty? ? '' : " (missing: #{missing.join(', ')})"}"
      end

      def validate_tools!(tools, denied)
        unknown = (tools + denied) - (SUPPORTED_TOOLS + ALWAYS_DENIED_TOOLS)
        raise Hive::ConfigError, "managed policy declares unsupported tools" unless unknown.empty?

        overlap = tools & denied
        raise Hive::ConfigError, "managed policy tools and deny lists overlap" unless overlap.empty?
        raise Hive::ConfigError, "managed policy must allow at least one tool" if tools.empty?
        forbidden = tools & ALWAYS_DENIED_TOOLS
        raise Hive::ConfigError, "managed policy cannot allow inherited or interactive tools" unless forbidden.empty?
      end

      def validate_commands!(tools, commands)
        if tools.include?("Bash") && commands.empty?
          raise Hive::ConfigError, "managed Bash access requires declared commands"
        end
        if commands.any? && !tools.include?("Bash")
          raise Hive::ConfigError, "managed command declarations require the Bash tool"
        end
        commands.each do |command|
          if command.match?(COMMAND_META) || command.strip.empty?
            raise Hive::ConfigError, "managed command declarations must be exact or end in a single * wildcard"
          end
          tokens = Shellwords.shellsplit(command)
          wildcard = tokens.last == "*"
          tokens.pop if wildcard
          if tokens.empty? || tokens.any? { |token| token.include?("*") }
            raise Hive::ConfigError, "managed command declarations must use a literal executable and arguments"
          end
        rescue ArgumentError
          raise Hive::ConfigError, "managed command declaration has invalid shell quoting"
        end
      end

      def validate_domains!(tools, domains)
        raise Hive::ConfigError, "managed domains require WebFetch or declared Bash commands" if domains.any? && !(tools.include?("WebFetch") || tools.include?("Bash"))
        raise Hive::ConfigError, "managed WebFetch access requires declared domains" if tools.include?("WebFetch") && domains.empty?
        raise Hive::ConfigError, "managed policy contains an invalid domain" unless domains.all? { |domain| DOMAIN.match?(domain) }
      end

      def validate_credentials!
        credentials = normalize_array("credentials")
        return if credentials.empty?

        raise Hive::ConfigError, "managed credential injection is not supported by this Hive runtime"
      end

      def resolve_directories
        [ @task_folder ] + normalize_array("directories").map do |entry|
          if entry.start_with?("/") || entry.split(/[\\\/]/).include?("..") || entry.include?("\0")
            raise Hive::ConfigError, "managed directory declarations must be relative task paths"
          end
          resolved = File.expand_path(entry, @task_folder)
          effective = begin
            File.realpath(resolved)
          rescue Errno::ENOENT, Errno::EACCES
            resolved
          end
          unless effective == @task_folder || effective.start_with?(@task_folder + File::SEPARATOR)
            raise Hive::ConfigError, "managed directory declaration escapes the task folder"
          end
          effective
        end.uniq
      end

      def resolve_executables(commands)
        commands.each_with_object({}) do |command, out|
          executable = Shellwords.shellsplit(command).first
          next if out.key?(executable)

          resolved = find_executable(executable)
          raise Hive::ConfigError, "declared executable #{executable.inspect} is unavailable" unless resolved
          if resolved == @task_folder || resolved.start_with?(@task_folder + File::SEPARATOR)
            raise Hive::ConfigError, "declared executable resolves inside the task-controlled directory"
          end
          out[executable] = resolved
        end.sort.to_h
      end

      def find_executable(name)
        return File.realpath(name) if name.include?(File::SEPARATOR) && File.file?(name) && File.executable?(name)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |dir|
          next if dir.empty?

          candidate = File.join(dir, name)
          File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end.first
      end

      def sanitized_environment(executables)
        values = SAFE_ENV_KEYS.each_with_object({}) do |key, out|
          value = ENV[key]
          out[key] = value if value && !value.empty?
        end
        roots = executables.values.map { |path| File.dirname(path) }
        roots.concat(%w[/usr/local/bin /usr/bin /bin].select { |path| File.directory?(path) })
        values["PATH"] = roots.uniq.join(File::PATH_SEPARATOR)
        values["HIVE_MANAGED_POLICY"] = "1"
        values
      end

      def normalize_array(key)
        value = @permissions.fetch(key, [])
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
          raise Hive::ConfigError, "managed permissions.#{key} must be an array of non-empty strings"
        end
        value.map(&:strip).uniq.sort
      end

      def stringify_hash(value)
        raise Hive::ConfigError, "managed permissions must be a map" unless value.is_a?(Hash)

        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def write_json(path, data)
        Hive::AtomicFile.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(data), mode: 0o600)
      end
    end
  end
end
