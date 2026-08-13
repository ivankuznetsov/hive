require "fileutils"
require "json"
require "tmpdir"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/module_package/workflow_compatibility"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/mutation_lock"
require "hive/workflow_package/task_migrator"

module Hive
  module Commands
    class Workflow
      class ConsentRequired < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class OwnershipError < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class UpdateRequired < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class Base
        def initialize(project_root:, json:, stdout:, stdin: $stdin, yes: false, committer: nil)
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @stdin = stdin
          @yes = yes
          @committer = committer
        end

        def call
          call!
        rescue Hive::Error, SystemCallError, IOError => e
          if @json
            @stdout.puts JSON.generate(error_payload(e))
          else
            warn "hive workflow: #{e.message}"
          end
          exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
        end

        private

        def store
          @store ||= Hive::WorkflowPackage::ManagedStore.new(hive_state_path)
        end

        def project_config
          @project_config ||= Hive::Config.load(@project_root)
        end

        def hive_state_path
          @hive_state_path ||= File.expand_path(
            project_config.fetch("hive_state_path"), @project_root
          )
        end

        def admit_runtime!(workflow, package_root, configuration: nil)
          workflow_compatibility.admit_runtime!(
            workflow, package_root, configuration: configuration
          )
        end

        def workflow_compatibility
          @workflow_compatibility ||= Hive::ModulePackage::WorkflowCompatibility.new(
            store: store, project_config: project_config
          )
        end

        def emit(payload, human_lines:)
          if @json
            @stdout.puts JSON.generate(payload)
          else
            Array(human_lines).each { |line| @stdout.puts line }
          end
          payload
        end

        def optional_input_disclosure(inputs)
          Array(inputs).map do |input|
            binding = input["binding"] || "unbound"
            availability = input["available"] ? "available; value: [redacted]" : "unavailable"
            "optional input: #{input.fetch('name')}; binding: #{binding}; " \
              "authorized slots: #{Array(input.fetch('authorized_slots')).join(', ')}; #{availability}"
          end
        end

        def confirmed?(prompt)
          return true if @yes
          unless interactive?
            raise ConsentRequired, "confirmation required; pass --yes in JSON or non-interactive mode"
          end

          @stdout.print "#{prompt} [y/N] "
          answer = @stdin.gets.to_s.strip.downcase
          %w[y yes].include?(answer)
        end

        def interactive?
          !@json && @stdin.respond_to?(:tty?) && @stdin.tty?
        end

        def commit_state(name, action)
          relative = File.join("workflows", name)
          if @committer
            @committer.call(action, name, relative)
            return
          end

          ops = Hive::GitOps.new(@project_root)
          Hive::Lock.with_commit_lock(hive_state_path) do
            ops.hive_commit(
              stage_name: "workflows", slug: name, action: action,
              pathspecs: [ relative ]
            )
          end
        end

        def migrate_managed_tasks!(name)
          prepared = prepare_managed_tasks!(name)
          result = nil
          Hive::WorkflowPackage::MutationLock.with_lock(store.workflows_dir) do
            result = commit_prepared_task_migration!(prepared, name, action: "migrated", commit_empty: false)
          end
          prepared.cleanup(result)
        rescue StandardError => error
          raise error if error.is_a?(Hive::UnsupportedProjectConfigError)

          raise Hive::Error,
                "managed workflow #{name.inspect} retained task migration failed " \
                "(#{error.class}: #{error.message}); finish any live task, then run hive migrate"
        ensure
          prepared&.close
        end

        def activate_with_task_migration!(candidate:, configuration:, expected_current:, action:)
          name = candidate.resolution.name
          workflow_compatibility.stage!(candidate: candidate, configuration: configuration)
          prepared = begin
            prepare_managed_tasks!(
              name,
              target_selection: {
                "source_commit" => candidate.resolution.source_commit,
                "manifest_digest" => candidate.resolution.manifest_digest,
                "configuration_digest" => configuration.digest
              }
            )
          rescue StandardError => error
            cleanup_after_failed_activation(name, error)
          end

          migration = nil
          workflow_compatibility.activate!(
            candidate: candidate,
            configuration: configuration,
            expected_current: expected_current,
            commit: lambda do
              migration = commit_prepared_task_migration!(
                prepared, name, action: action, commit_empty: true
              )
            end,
            admit: false
          )
          migration
        ensure
          prepared&.close
        end

        def prepare_managed_tasks!(name, target_selection: nil)
          Hive::WorkflowPackage::TaskMigrator.new(
            hive_state_path,
            store: store,
            cfg: project_config,
            workflow: name,
            target_selection: target_selection
          ).prepare
        end

        def commit_prepared_task_migration!(prepared, name, action:, commit_empty:)
          result = nil
          Hive::Lock.with_commit_lock(hive_state_path) do
            result = prepared.apply do |preview|
              next if preview.task_count.zero? && !commit_empty

              pathspecs = preview.pathspecs + [ File.join("workflows", name) ]
              if @committer
                @committer.call(action, name, pathspecs)
              else
                detail = if preview.task_count.positive?
                  "#{action} and migrated #{preview.task_count} task#{preview.task_count == 1 ? '' : 's'}"
                else
                  action
                end
                Hive::GitOps.new(@project_root).hive_commit(
                  stage_name: "workflows", slug: name,
                  action: detail,
                  pathspecs: pathspecs
                )
              end
            end
          end
          result
        end

        def cleanup_after_failed_activation(name, original_error)
          store.cleanup_unreferenced(name)
        rescue StandardError => cleanup_error
          warn "hive workflow: activation failed with #{original_error.class}: #{original_error.message}; " \
               "candidate cleanup also failed with #{cleanup_error.class}: #{cleanup_error.message}"
        ensure
          raise original_error
        end

        def post_commit_step(warnings, label)
          yield
        rescue StandardError => e
          message = "#{label} failed (#{e.class}: #{e.message}); the workflow selection change already succeeded"
          warnings << message
          warn "hive workflow: #{message}"
          nil
        end

        def warning_lines(warnings)
          warnings.map { |warning| "warning: #{warning}" }
        end

        def error_payload(error)
          Hive::Schemas::ErrorEnvelope.build(
            schema: envelope_schema,
            error: error,
            error_kind: error_kind(error)
          )
        end

        def error_kind(error)
          case error
          when ConsentRequired then "consent_required"
          when OwnershipError then "ownership"
          when UpdateRequired then "update_required"
          when Hive::ConcurrentRunError then "concurrent_run"
          when Hive::GitError then "git"
          when Hive::ConfigError then "config"
          when Hive::WorkflowPackage::RegistryError then "registry"
          else "error"
          end
        end
      end
    end
  end
end
