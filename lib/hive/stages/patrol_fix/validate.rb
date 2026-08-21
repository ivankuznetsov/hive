require "digest"
require "time"
require "hive/patrol/validator"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/runner"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/validation_receipt"
require "hive/patrol_fix/worktree_receipt"

module Hive
  module Stages
    module PatrolFix
      module Validate
        module_function

        def run!(task, cfg = {}, command_runner: nil, worktree_root: nil)
          manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
          store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
          existing = current(store, manifest, "validation", "validate")
          return complete(existing) if existing
          fix = current(store, manifest, "fix", "fix") || raise(Hive::StageError, "validate requires a current fix receipt")
          custody = Hive::PatrolFix::WorktreeReceipt.new(
            task_folder: task.folder, project_root: task.project_root, slug: task.slug,
            worktree_root: worktree_root
          )
          owner = custody.read
          custody.validate!(owner)
          expected_head = fix.dig("payload", "head_revision")
          actual_head = git_head(owner.fetch("worktree"))
          raise Hive::StageError, "fix worktree HEAD changed before validation" unless actual_head == expected_head
          raise Hive::StageError, "fix worktree is dirty before validation" unless git_status(owner.fetch("worktree")).empty?
          commands = selected_commands(manifest, fix, cfg || {})
          runner = command_runner || lambda { |path, rows| default_validator(cfg || {}).validate_selected(path, rows) }
          result = runner.call(owner.fetch("worktree"), commands)
          final_head = git_head(owner.fetch("worktree"))
          raise Hive::StageError, "validation changed the worktree HEAD" unless final_head == expected_head
          raise Hive::StageError, "validation changed the worktree bytes" unless git_status(owner.fetch("worktree")).empty?
          payload = Hive::PatrolFix::ValidationReceipt.build(
            worktree_head: expected_head, results: Array(result.fetch("commands"))
          )
          receipt = store.append!(build_receipt(manifest, payload))
          complete(receipt)
        end

        # Validation runs the operator's own commands, so it needs both
        # deadlines: the wall-clock cap and the idle-output cap that kills a
        # silent run before it burns the whole budget.
        def default_validator(cfg)
          Hive::Patrol::Validator.new(
            timeout_sec: cfg.dig("timeout_sec", "patrol") ||
              Hive::Patrol::Validator::DEFAULT_TIMEOUT_SEC,
            idle_timeout_sec: cfg.dig("timeout_sec", "patrol_idle")
          )
        end

        def selected_commands(manifest, fix, cfg)
          rows = []
          engines = manifest.fetch("sources").map { |source| source.fetch("engine") }.uniq
          if engines.include?("ordinary_patrol")
            append_configured(rows, "ordinary", cfg.dig("patrol", "commands"))
          end
          if engines.include?("architecture_patrol")
            append_configured(rows, "architecture", cfg.dig("refactor_patrol", "commands"))
          end
          Array(fix.dig("payload", "validation_commands")).each do |command|
            rows << { "identity" => "agent:#{command.fetch('identity')}",
                      "command" => command.fetch("command"), "provenance" => "agent" }
          end
          rows.uniq { |row| [ row.fetch("identity"), row.fetch("command") ] }
        end

        def append_configured(rows, prefix, commands)
          Hive::Patrol::Validator.configured_names(commands).each do |name|
            rows << { "identity" => "#{prefix}:#{name}",
                      "command" => commands[name] || commands[name.to_sym], "provenance" => "controller" }
          end
        end
        private_class_method :append_configured

        def build_receipt(manifest, payload)
          digest = Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(payload))
          { "schema" => Hive::PatrolFix::ReceiptStore::SCHEMA, "schema_version" => 1,
            "receipt_id" => "validation-#{digest[0, 24]}", "kind" => "validation", "stage" => "validate",
            "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"),
            "recorded_at" => Time.now.utc.iso8601, "payload" => payload }
        end
        private_class_method :build_receipt

        def git_head(path)
          result = Hive::AgentGitGate.read(path, :head_oid)
          raise Hive::StageError, "validation worktree HEAD is unavailable" unless result.success?
          result.stdout.strip
        end
        private_class_method :git_head
        def git_status(path)
          result = Hive::AgentGitGate.read(path, :status)
          raise Hive::StageError, "validation worktree status is unavailable" unless result.success?
          result.stdout
        end
        private_class_method :git_status
        def current(store, manifest, kind, stage)
          store.read_all.find { |r| r["kind"] == kind && r["stage"] == stage && r["task"] == manifest["task"] && r["evidence_revision"] == manifest["evidence_revision"] }
        end
        private_class_method :current
        def complete(receipt) = { status: :complete, commit: "patrol-fix validation collected", receipt: receipt }
        private_class_method :complete
      end
    end
  end
end

Hive::PatrolFix::Runner.register("validate", Hive::Stages::PatrolFix::Validate.method(:run!))
