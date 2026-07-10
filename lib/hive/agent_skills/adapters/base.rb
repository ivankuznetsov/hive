require "digest"
require "fileutils"

require "hive/agent_skills/inspector"
require "hive/atomic_file"

module Hive
  module AgentSkills
    module Adapters
      Operation = Data.define(
        :id, :agent, :package_id, :capabilities, :kind, :argv, :files,
        :depends_on, :preconditions, :metadata
      ) do
        def to_h
          {
            "id" => id,
            "agent" => agent,
            "package" => package_id,
            "capabilities" => capabilities,
            "kind" => kind,
            "argv" => argv,
            "files" => files,
            "depends_on" => depends_on,
            "preconditions" => preconditions
          }
        end
      end

      AdapterPlan = Data.define(:agent, :operations, :conflicts)
      Outcome = Data.define(:operation_id, :agent, :package_id, :status, :message, :exit_status, :changed_files) do
        def to_h
          {
            "operation_id" => operation_id,
            "agent" => agent,
            "package" => package_id,
            "status" => status,
            "message" => message,
            "exit_status" => exit_status,
            "changed_files" => changed_files
          }
        end
      end

      class Base
        ACTIONABLE_HEALTH = %w[missing stale].freeze
        EXECUTION_TIMEOUT_SEC = 120

        attr_reader :agent

        def initialize(config:, project_root:, manifest: Manifest.load,
                       runner: CommandRunner.new, environment: ENV)
          @config = config
          @project_root = File.expand_path(project_root)
          @manifest = manifest
          @runner = runner
          @environment = environment
          @agent = self.class::AGENT
        end

        def plan(inspections)
          rows = inspections.select do |row|
            row.agent == agent && row.managed && ACTIONABLE_HEALTH.include?(row.health)
          end
          groups = rows.group_by(&:package_id)
          conflicts = []
          operations = []

          ordered_package_ids(groups.keys).each do |package_id|
            package_rows = groups.fetch(package_id)
            package = @manifest.package(package_id)
            native_spec = package.native_for(agent)
            package_conflicts = ownership_conflicts(native_spec, package_rows)
            conflicts.concat(package_conflicts)
            next unless package_conflicts.empty?

            package_operations = operations_for_package(package, native_spec, package_rows)
            operations.concat(package_operations)
            operations.concat(alias_operations(package_rows, depends_on: package_operations.last&.id))
          end

          operations = add_prerequisite_dependencies(operations)
          AdapterPlan.new(agent: agent, operations: operations.freeze, conflicts: conflicts.freeze)
        end

        def execute(operation)
          return failed(operation, "operation belongs to #{operation.agent}, not #{agent}") unless operation.agent == agent
          precondition_error = validate_preconditions(operation)
          return failed(operation, precondition_error) if precondition_error
          return execute_alias(operation) if operation.kind == "alias_write"

          before = before_command(operation)
          result = @runner.call(operation.argv, env: runner_environment, timeout: EXECUTION_TIMEOUT_SEC)
          return command_failed(operation, result, before) unless result.success?

          after_error = after_command(operation, before)
          return failed(operation, after_error, exit_status: result.exit_status) if after_error

          Outcome.new(
            operation_id: operation.id,
            agent: agent,
            package_id: operation.package_id,
            status: "succeeded",
            message: "completed #{operation.kind}",
            exit_status: result.exit_status,
            changed_files: operation.files
          )
        rescue StandardError => e
          failed(operation, "#{e.class}: #{e.message}")
        end

        protected

        def operations_for_package(_package, _native_spec, _rows)
          raise NotImplementedError
        end

        def ownership_conflicts(_native_spec, _rows)
          []
        end

        def operation(package:, rows:, kind:, argv:, files:, depends_on: [], metadata: {}, preconditions: {})
          id = "#{agent}:#{package.id}:#{kind}"
          Operation.new(
            id: id.freeze,
            agent: agent.freeze,
            package_id: package.id.freeze,
            capabilities: rows.map(&:capability_id).compact.uniq.sort.freeze,
            kind: kind.freeze,
            argv: argv.map { |arg| arg.to_s.freeze }.freeze,
            files: files.map { |path| path.to_s.freeze }.freeze,
            depends_on: depends_on.compact.map(&:freeze).freeze,
            preconditions: deep_freeze(preconditions.dup),
            metadata: deep_freeze(metadata.dup)
          ).freeze
        end

        def config_root(native_spec)
          configured = @environment[native_spec.config_home].to_s
          return File.expand_path(configured) unless configured.empty?
          home = @environment["HOME"] || Dir.home
          case native_spec.provider
          when "claude" then File.join(home, ".claude")
          when "codex" then File.join(home, ".codex")
          when "pi" then File.join(home, ".pi", "agent")
          end
        end

        def package_state(rows)
          rows.first.native
        end

        def runner_environment
          %w[HOME PATH CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR].each_with_object({}) do |key, out|
            out[key] = @environment[key] if @environment.key?(key)
          end
        end

        def file_snapshot(path)
          if File.file?(path)
            content = File.binread(path)
            {
              "exists" => true,
              "digest" => Digest::SHA256.hexdigest(content),
              "mode" => File.stat(path).mode & 0o777,
              "content" => content
            }
          else
            { "exists" => false, "digest" => nil, "mode" => nil, "content" => "" }
          end
        end

        def public_snapshot(snapshot)
          snapshot.reject { |key, _| key == "content" }
        end

        def alias_operations(rows, depends_on:)
          rows.filter_map do |row|
            contract = @manifest.capability(row.capability_id).agent(agent)
            next unless contract.alias_spec
            path = File.join(@project_root, contract.alias_spec.path)
            if File.file?(path)
              next if File.read(path) == Manifest.alias_content(contract.alias_spec)
              next
            end

            package = @manifest.package(row.package_id)
            snapshot = file_snapshot(path)
            operation(
              package: package,
              rows: [ row ],
              kind: "alias_write",
              argv: [],
              files: [ path ],
              depends_on: [ depends_on ],
              preconditions: { "file" => public_snapshot(snapshot) },
              metadata: {
                "path" => path,
                "content" => Manifest.alias_content(contract.alias_spec),
                "snapshot" => snapshot
              }
            )
          end
        end

        def validate_preconditions(operation)
          return nil unless operation.kind == "alias_write"
          path = operation.metadata.fetch("path")
          expected = operation.metadata.fetch("snapshot")
          current = file_snapshot(path)
          return nil if current["exists"] == expected["exists"] && current["digest"] == expected["digest"]

          "#{path} changed since preview"
        end

        def execute_alias(operation)
          path = operation.metadata.fetch("path")
          snapshot = operation.metadata.fetch("snapshot")
          if File.file?(path) && File.read(path) != snapshot.fetch("content") && !snapshot.fetch("exists")
            return failed(operation, "user-owned alias #{path} appeared after preview")
          end
          mode = snapshot["mode"] || 0o644
          Hive::AtomicFile.write(path, operation.metadata.fetch("content"), mode: mode)
          Outcome.new(
            operation_id: operation.id,
            agent: agent,
            package_id: operation.package_id,
            status: "succeeded",
            message: "wrote Hive-owned alias #{path}",
            exit_status: 0,
            changed_files: [ path ].freeze
          )
        end

        def before_command(_operation)
          nil
        end

        def after_command(_operation, _before)
          nil
        end

        def command_failed(operation, result, before)
          rollback_failed_command(operation, before)
          message = if result.timed_out
            "#{operation.kind} timed out"
          elsif !result.error.to_s.empty?
            "#{operation.kind} failed: #{result.error}"
          else
            detail = result.stderr.to_s.lines.first.to_s.strip
            detail = "exit #{result.exit_status}" if detail.empty?
            "#{operation.kind} failed: #{detail}"
          end
          failed(operation, message, exit_status: result.exit_status)
        end

        def rollback_failed_command(_operation, _before)
          nil
        end

        def failed(operation, message, exit_status: nil)
          Outcome.new(
            operation_id: operation.id,
            agent: agent,
            package_id: operation.package_id,
            status: "failed",
            message: message,
            exit_status: exit_status,
            changed_files: [].freeze
          )
        end

        def ordered_package_ids(ids)
          visited = {}
          order = []
          visit = lambda do |id|
            return if visited[id]
            visited[id] = true
            package = @manifest.package(id)
            package.prerequisites.each { |dependency| visit.call(dependency) if ids.include?(dependency) }
            order << id
          end
          ids.each { |id| visit.call(id) }
          order
        end

        def add_prerequisite_dependencies(operations)
          final_by_package = operations.group_by(&:package_id).transform_values(&:last)
          operations.map do |operation|
            dependencies = @manifest.package(operation.package_id).prerequisites.filter_map do |package_id|
              final_by_package[package_id]&.id
            end
            next operation if dependencies.empty?

            Operation.new(
              id: operation.id,
              agent: operation.agent,
              package_id: operation.package_id,
              capabilities: operation.capabilities,
              kind: operation.kind,
              argv: operation.argv,
              files: operation.files,
              depends_on: (dependencies + operation.depends_on).uniq.freeze,
              preconditions: operation.preconditions,
              metadata: operation.metadata
            ).freeze
          end.freeze
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, item| key.freeze; deep_freeze(item) }
          when Array
            value.each { |item| deep_freeze(item) }
          else
            value.freeze
          end
          value.freeze
        end
      end
    end
  end
end
