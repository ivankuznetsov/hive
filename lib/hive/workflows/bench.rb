require "fileutils"
require "securerandom"
require "hive/lock"
require "hive/workflow"

module Hive
  module Workflows
    module Bench
      INSTRUCTIONS_DIR = File.expand_path("../../../templates/builtins/bench", __dir__).freeze
      RUNTIME_DIR = File.join(INSTRUCTIONS_DIR, "runtime").freeze
      RUNTIME_STATE_DIR = "bench-runtime".freeze
      def self.instruction(name)
        File.join(INSTRUCTIONS_DIR, "#{name}.md").freeze
      end

      # A bench task must remain runnable after installation without requiring a
      # separate hive-bench checkout. Snapshot the packaged harness into the
      # project's durable hive/state branch so every campaign uses the runtime
      # version selected when the workflow was initialized.
      def self.install_runtime!(ops, additional_pathspecs: [], before_commit: nil, rollback: nil)
        destination = File.join(ops.hive_state_path, RUNTIME_STATE_DIR)
        staging = "#{destination}.tmp-#{Process.pid}"
        backup = "#{destination}.previous-#{Process.pid}-#{SecureRandom.hex(4)}"
        FileUtils.rm_rf(staging)
        FileUtils.mkdir_p(staging)
        FileUtils.cp_r(File.join(RUNTIME_DIR, "."), staging)

        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          pathspecs = [ RUNTIME_STATE_DIR ]
          runtime_backed_up = false
          runtime_installed = false
          commit_finished = false
          head_before = nil
          transaction_started = false
          begin
            ensure_clean_hive_state_index!(ops)
            head_before = hive_state_head(ops)
            transaction_started = true
            if path_present?(destination)
              Thread.handle_interrupt(Interrupt => :never) do
                FileUtils.mv(destination, backup)
                runtime_backed_up = true
              end
            end
            Thread.handle_interrupt(Interrupt => :never) do
              FileUtils.mv(staging, destination)
              runtime_installed = true
            end
            before_commit&.call
            pathspecs = [ *pathspecs, *resolve_additional_pathspecs(additional_pathspecs) ].uniq
            Thread.handle_interrupt(Interrupt => :never) do
              ops.hive_commit(
                stage_name: "config",
                slug: "bench-runtime",
                action: "install",
                pathspecs: pathspecs
              )
              commit_finished = true
            end
          rescue StandardError, Interrupt => error
            Thread.handle_interrupt(Interrupt => :never) do
              pathspecs = [ *pathspecs, *resolve_additional_pathspecs(additional_pathspecs) ].uniq
              if !transaction_started
                # Preconditions failed before any installation mutation.
              elsif commit_finished || commit_landed?(ops, head_before)
                errors = []
                rollback_step(errors) { remove_path!(backup) }
                warn_rollback_errors(errors)
              else
                runtime_backed_up ||= path_present?(backup)
                runtime_installed ||= !path_present?(staging) && path_present?(destination)
                errors = rollback_failed_install!(
                  ops,
                  destination: destination,
                  backup: backup,
                  pathspecs: pathspecs,
                  runtime_backed_up: runtime_backed_up,
                  runtime_installed: runtime_installed,
                  warn_on_failure: false
                )
                rollback_step(errors) { rollback&.call }
                warn_rollback_errors(errors)
              end
            end
            raise error
          end
          remove_path!(backup)
        end
        destination
      ensure
        FileUtils.rm_rf(staging) if staging
      end

      def self.rollback_failed_install!(ops, destination:, backup:, pathspecs:,
                                        runtime_backed_up:, runtime_installed:, warn_on_failure: true)
        errors = []
        # Reset FIRST: a failed commit may have staged every path below. Leaving
        # those entries live while restoring the filesystem lets a concurrent
        # bare commit sweep a partial installation into unrelated history.
        rollback_step(errors) do
          ops.run_git!("-C", ops.hive_state_path, "reset", "-q", "--", *pathspecs)
        end

        rollback_step(errors) { remove_path!(destination) } if runtime_installed
        if runtime_backed_up
          if !path_present?(destination) && path_present?(backup)
            rollback_step(errors) { FileUtils.mv(backup, destination) }
          elsif path_present?(destination) && path_present?(backup)
            errors << "previous bench runtime retained at #{backup} because #{destination} could not be removed"
          elsif !path_present?(backup)
            errors << "previous bench runtime backup is missing at #{backup}"
          end
        end
        warn_rollback_errors(errors) if warn_on_failure
        errors
      end

      def self.warn_rollback_errors(errors)
        return if errors.empty?

        warn "hive: failed to fully roll back bench runtime installation: #{errors.join('; ')}"
      end

      def self.ensure_clean_hive_state_index!(ops)
        staged = ops.run_git!("-C", ops.hive_state_path, "diff", "--cached", "--name-only", "--")
        return if staged.strip.empty?

        raise Hive::ConfigError,
              "cannot install bench runtime while hive-state has staged changes: " \
              "#{staged.lines.map(&:strip).join(', ')}"
      end

      def self.hive_state_head(ops)
        ops.run_git!("-C", ops.hive_state_path, "rev-parse", "HEAD").strip
      end

      def self.commit_landed?(ops, head_before)
        return false unless head_before

        hive_state_head(ops) != head_before
      rescue StandardError => e
        warn "hive: could not determine whether bench runtime installation committed " \
             "(#{e.class}: #{e.message}); preserving installed files for manual inspection"
        true
      end

      def self.resolve_additional_pathspecs(value)
        Array(value.respond_to?(:call) ? value.call : value)
      end

      def self.remove_path!(path)
        return unless path_present?(path)

        FileUtils.rm_r(path)
        raise IOError, "path still exists after removal: #{path}" if path_present?(path)
      end

      def self.path_present?(path)
        File.exist?(path) || File.symlink?(path)
      end

      def self.rollback_step(errors)
        yield
      rescue StandardError, Interrupt => e
        errors << "#{e.class}: #{e.message}"
      end

      DESCRIPTOR = Hive::Workflow.new(
        id: :bench,
        archive_visibility_retention_days: 3,
        stages: [
          Hive::Workflow::Stage.new(
            name: "inbox",
            index: 1,
            state_file: "task.md",
            kind: :inert
          ),
          Hive::Workflow::Stage.new(
            name: "extract",
            index: 2,
            state_file: "extract.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "extract"),
            kind: :agent,
            instruction: instruction("extract"),
            agent: "codex",
            timeout_sec: 3600,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "generate",
            index: 3,
            state_file: "generate.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "generate"),
            kind: :agent,
            instruction: instruction("generate"),
            agent: "codex",
            timeout_sec: 604_800,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "judge",
            index: 4,
            state_file: "judge.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "judge"),
            kind: :agent,
            instruction: instruction("judge"),
            agent: "codex",
            timeout_sec: 604_800,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "publish",
            index: 5,
            state_file: "publish.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "publish"),
            kind: :agent,
            instruction: instruction("publish"),
            agent: "codex",
            timeout_sec: 3600,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "done",
            index: 6,
            state_file: "task.md",
            kind: :inert
          )
        ]
      )
    end
  end
end
