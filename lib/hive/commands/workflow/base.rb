require "json"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/workflow_package/managed_store"

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

        def hive_state_path
          @hive_state_path ||= begin
            configured = Hive::Config.load(@project_root).fetch("hive_state_path")
            File.expand_path(configured, @project_root)
          end
        end

        def emit(payload, human_lines:)
          if @json
            @stdout.puts JSON.generate(payload)
          else
            Array(human_lines).each { |line| @stdout.puts line }
          end
          payload
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
