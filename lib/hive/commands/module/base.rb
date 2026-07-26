require "digest"
require "json"
require "time"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/module_package/workflow_compatibility"
require "hive/modules/inspector"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/managed_store"

module Hive
  module Commands
    class Module
      class ConsentRequired < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class OwnershipError < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class Base
        def initialize(project_root:, json:, stdout:, stdin: $stdin, yes: false, dry_run: false,
                       receipt: nil, store: nil, committer: nil, inspector: nil)
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @stdin = stdin
          @yes = yes
          @dry_run = dry_run
          @receipt = receipt
          @store = store
          @committer = committer
          @inspector = inspector
        end

        def call
          call!
        rescue Hive::Error, SystemCallError, IOError => e
          if @json
            @stdout.puts JSON.generate(error_payload(e))
          else
            warn "hive module: #{e.message}"
          end
          exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
        end

        private

        def store
          @store ||= Hive::ModulePackage::ManagedStore.new(hive_state_path)
        end

        def workflow_store
          @workflow_store ||= Hive::WorkflowPackage::ManagedStore.new(hive_state_path)
        end

        def workflow_compatibility
          @workflow_compatibility ||= Hive::ModulePackage::WorkflowCompatibility.new(
            store: workflow_store, project_config: project_config
          )
        end

        def inspector
          @inspector ||= Hive::Modules::Inspector.new(
            store: store, workflow_store: workflow_store,
            project_config: project_config,
            project_id: registered_project_identity.fetch("project_id")
          )
        end

        def project_config
          @project_config ||= Hive::Config.load(@project_root)
        end

        def hive_state_path
          @hive_state_path ||= File.expand_path(project_config.fetch("hive_state_path"), @project_root)
        end

        def registered_project_identity
          root = File.realpath(@project_root)
          entry = Hive::Config.registered_projects.find do |candidate|
            File.realpath(candidate.fetch("path")) == root
          rescue SystemCallError
            false
          end
          unless entry
            raise Hive::ConfigError, "module inspection requires a registered project identity"
          end
          entry
        end

        def emit(payload, human_lines:)
          if @json
            @stdout.puts JSON.generate(payload)
          else
            Array(human_lines).each { |line| @stdout.puts line }
          end
          payload
        end

        def confirm_mutation!(prompt)
          return true if @yes
          unless interactive?
            raise ConsentRequired, "confirmation required; pass --yes with the reviewed preview receipt"
          end
          @stdout.print "#{prompt} [y/N] "
          answer = @stdin.gets.to_s.strip.downcase
          raise ConsentRequired, "module change cancelled; no project state changed" unless %w[y yes].include?(answer)
          true
        end

        def require_noninteractive_receipt!
          return unless @json || !interactive?
          raise ConsentRequired, "exact preview receipt required; run with --dry-run first" if @receipt.to_s.empty?
        end

        def interactive? = !@json && @stdin.respond_to?(:tty?) && @stdin.tty?

        def commit_state(name, action)
          if @committer
            @committer.call(action, name, File.join("modules", name))
            return
          end
          ops = Hive::GitOps.new(@project_root)
          Hive::Lock.with_commit_lock(hive_state_path) do
            ops.hive_commit(
              stage_name: "modules", slug: name, action: action,
              pathspecs: [ File.join("modules", name) ]
            )
          end
        end

        def commit_workflow_state(name, action)
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

        def lifecycle_payload(operation:, status:, name:, preview: nil, selection: nil)
          {
            "schema" => "hive-module-lifecycle",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-lifecycle"),
            "ok" => true, "operation" => operation, "status" => status, "name" => name,
            "preview_receipt" => preview&.receipt,
            "candidate" => preview&.data&.fetch("candidate", nil),
            "configuration_digest" => preview&.configuration&.digest,
            "diff" => preview&.diff&.to_h,
            "proposed" => preview && preview_proposal(preview),
            "selection" => selection
          }
        end

        def preview_proposal(preview)
          configuration = preview.configuration
          settings = configuration.contract.fetch("settings").map do |spec|
            name = spec.fetch("name")
            secret = spec.fetch("type") == "secret" || spec["secret"] == true
            {
              "name" => name, "type" => spec.fetch("type"), "required" => spec.fetch("required"),
              "secret" => secret, "value" => secret ? nil : configuration.settings[name],
              "binding" => secret ? configuration.settings[name] : nil
            }
          end
          hooks = configuration.contract.fetch("hooks").map do |hook|
            hook.merge("enabled" => configuration.hooks.fetch(hook.fetch("id")))
          end
          {
            "settings" => settings, "hooks" => hooks, "grants" => configuration.grants,
            "permission_digest" => configuration.data.fetch("permission_digest")
          }
        end

        def state_preview(operation, current, issued_at: Time.now.utc)
          issued_at = Time.at(issued_at.to_i, in: "UTC")
          data = {
            "schema_version" => 1, "operation" => operation,
            "issued_at" => issued_at.utc.iso8601(6),
            "expires_at" => (issued_at.utc + Hive::ModulePackage::Preview::TTL_SECONDS).iso8601(6),
            "current" => current
          }
          digest = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(data))
          { data: data, digest: digest, receipt: "#{issued_at.to_i}.#{digest}" }
        end

        def verify_state_receipt!(operation, current, now: Time.now.utc)
          issued_at, digest = Hive::ModulePackage::Preview.receipt_parts(@receipt)
          preview = state_preview(operation, current, issued_at: issued_at)
          raise Hive::ConfigError, "module state preview receipt does not match" unless secure_equal?(preview.fetch(:digest), digest)
          if now.utc > Time.iso8601(preview.dig(:data, "expires_at"))
            raise Hive::ConfigError, "module state preview receipt expired; preview again"
          end
          preview
        end

        def secure_equal?(left, right)
          left.bytesize == right.bytesize && left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
        end

        def error_payload(error)
          Hive::Schemas::ErrorEnvelope.build(
            schema: envelope_schema, error: error, error_kind: error_kind(error)
          )
        end

        def error_kind(error)
          case error
          when ConsentRequired then "consent_required"
          when OwnershipError then "ownership"
          when Hive::ConcurrentRunError then "concurrent_run"
          when Hive::ModulePackage::CatalogError then "catalog"
          when Hive::ConfigError then "config"
          when Hive::GitError then "git"
          else "error"
          end
        end

        def envelope_schema = "hive-module-lifecycle"
      end
    end
  end
end
