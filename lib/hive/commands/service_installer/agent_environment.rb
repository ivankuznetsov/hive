require "agent_cli_runtime"

module Hive
  module Commands
    module ServiceInstaller
      # Discover launch dependencies without evaluating shell startup files or
      # copying credentials and unrelated shell environment into service files.
      class AgentEnvironment
        INTERPRETERS = %w[node bun python3].freeze

        def initialize(environment)
          @environment = environment
        end

        def paths
          commands = profiles.map { |profile| profile.bin(env: @environment) } + INTERPRETERS
          selected = commands.filter_map { |command| resolve(command) }.map { |path| File.dirname(path) }
          # Keep shell precedence and preserve symlink/shim paths rather than
          # resolving them to a version that a future tool upgrade removes.
          (search_paths & selected).concat(selected - search_paths).uniq
        end

        def overrides
          profiles.flat_map(&:env_bin_override_keys).uniq.each_with_object({}) do |key, result|
            value = @environment[key].to_s
            next if value.empty?

            resolved = resolve(value)
            unless resolved
              raise Hive::ConfigError, "#{key} must resolve to an executable on the installation PATH"
            end
            result[key] = resolved
          end
        end

        private

        def profiles
          AgentCliRuntime::Profiles.names.map { |name| AgentCliRuntime::Profiles.fetch(name) }
        end

        def search_paths
          @environment.fetch("PATH", "").split(File::PATH_SEPARATOR).select { |path| absolute_path?(path) }.uniq
        end

        def absolute_path?(path)
          path.start_with?("/") && !path.match?(/[[:cntrl:]:]/)
        end

        def resolve(command)
          return nil if command.match?(/[[:cntrl:]:]/)

          if command.include?(File::SEPARATOR)
            return command if absolute_path?(command) && executable?(command)
          else
            directory = search_paths.find { |path| executable?(File.join(path, command)) }
            return File.join(directory, command) if directory
          end
          nil
        end

        def executable?(path)
          File.file?(path) && File.executable?(path)
        end
      end
    end
  end
end
