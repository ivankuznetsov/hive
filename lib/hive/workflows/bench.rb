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
      LEGACY_DESCRIPTOR_PATH = "workflows/bench.yml".freeze
      LEGACY_INSTRUCTIONS_PATH = "workflows/bench".freeze
      LEGACY_ARCHIVE_DESCRIPTOR_PATH = "workflows/bench.legacy.yml.disabled".freeze
      LEGACY_ARCHIVE_INSTRUCTIONS_PATH = "workflows/bench.legacy".freeze
      LEGACY_STAGE_SIGNATURES = [
        [ "inbox", 1, "task.md", :inert, nil, nil ],
        [ "extract", 2, "extract.md", :agent, "extract", "extract.md" ],
        [ "generate", 3, "generate.md", :agent, "generate", "generate.md" ],
        [ "judge", 4, "judge.md", :agent, "judge", "judge.md" ],
        [ "publish", 5, "publish.md", :agent, "publish", "publish.md" ],
        [ "done", 6, "task.md", :inert, "done", nil ]
      ].map(&:freeze).freeze
      LEGACY_NIL_STAGE_FIELDS = %i[
        skill permissions status_mode budget_usd timeout_sec capability agent
        model effort input reviewers council deliverable
      ].freeze

      def self.instruction(name)
        File.join(INSTRUCTIONS_DIR, "#{name}.md").freeze
      end

      # v0.4.2 promoted hive-bench's project-authored descriptor to a built-in.
      # Recognize only that descriptor's exact semantic shape so existing
      # campaigns keep using their local instructions until an explicit re-init
      # migrates them. A modified/custom `bench.yml` still hits the normal
      # built-in collision guard instead of being silently shadowed.
      def self.legacy_project_descriptor?(descriptor, source_path:)
        return false unless descriptor.id.to_sym == :bench
        return false if source_path.nil?
        return false unless File.basename(source_path) == "bench.yml"

        instruction_dir = File.join(File.dirname(source_path), "bench")
        signatures = descriptor.stages.map do |stage|
          expected_instruction = LEGACY_STAGE_SIGNATURES.fetch(stage.index - 1, []).last
          instruction_name = expected_instruction if stage.instruction == File.join(instruction_dir, expected_instruction.to_s)
          [ stage.name, stage.index, stage.state_file, stage.kind,
            stage.advance_verb&.name, instruction_name ]
        end
        return false unless signatures == LEGACY_STAGE_SIGNATURES

        descriptor.stages.all? do |stage|
          LEGACY_NIL_STAGE_FIELDS.all? { |field| stage.public_send(field).nil? }
        end
      end

      # A bench task must remain runnable after installation without requiring a
      # separate hive-bench checkout. Snapshot the packaged harness into the
      # project's durable hive/state branch so every campaign uses the runtime
      # version selected when the workflow was initialized.
      def self.install_runtime!(ops)
        destination = File.join(ops.hive_state_path, RUNTIME_STATE_DIR)
        staging = "#{destination}.tmp-#{Process.pid}"
        backup = "#{destination}.previous-#{Process.pid}-#{SecureRandom.hex(4)}"
        FileUtils.rm_rf(staging)
        FileUtils.mkdir_p(staging)
        FileUtils.cp_r(File.join(RUNTIME_DIR, "."), staging)

        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          migration_pathspecs = archive_legacy_project_workflow!(ops)
          pathspecs = [ RUNTIME_STATE_DIR, *migration_pathspecs ]
          runtime_backed_up = false
          runtime_installed = false
          begin
            if File.exist?(destination) || File.symlink?(destination)
              FileUtils.mv(destination, backup)
              runtime_backed_up = true
            end
            FileUtils.mv(staging, destination)
            runtime_installed = true
            ops.hive_commit(
              stage_name: "config",
              slug: "bench-runtime",
              action: "install",
              pathspecs: pathspecs
            )
          rescue StandardError
            rollback_failed_install!(ops, destination: destination, backup: backup,
                                     migration_pathspecs: migration_pathspecs, pathspecs: pathspecs,
                                     runtime_backed_up: runtime_backed_up,
                                     runtime_installed: runtime_installed)
            raise
          end
          FileUtils.rm_rf(backup)
        end
        destination
      ensure
        FileUtils.rm_rf(staging) if staging
      end

      def self.archive_legacy_project_workflow!(ops)
        descriptor_path = File.join(ops.hive_state_path, LEGACY_DESCRIPTOR_PATH)
        return [] unless File.file?(descriptor_path)

        require "hive/workflows/descriptor_parser"
        descriptor = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
        return [] unless legacy_project_descriptor?(descriptor, source_path: descriptor_path)

        instruction_path = File.join(ops.hive_state_path, LEGACY_INSTRUCTIONS_PATH)
        archived_descriptor = File.join(ops.hive_state_path, LEGACY_ARCHIVE_DESCRIPTOR_PATH)
        archived_instructions = File.join(ops.hive_state_path, LEGACY_ARCHIVE_INSTRUCTIONS_PATH)
        [ archived_descriptor, archived_instructions ].each do |path|
          next unless File.exist?(path) || File.symlink?(path)

          raise Hive::ConfigError,
                "cannot migrate legacy bench workflow: archive target already exists at #{path}"
        end

        FileUtils.mv(descriptor_path, archived_descriptor)
        begin
          FileUtils.cp_r(instruction_path, archived_instructions)
        rescue StandardError
          errors = []
          rollback_step(errors) { FileUtils.rm_rf(archived_instructions) }
          rollback_step(errors) { FileUtils.mv(archived_descriptor, descriptor_path) }
          warn "hive: failed to restore legacy bench descriptor: #{errors.join('; ')}" unless errors.empty?
          raise
        end
        [
          LEGACY_DESCRIPTOR_PATH,
          LEGACY_ARCHIVE_DESCRIPTOR_PATH,
          LEGACY_ARCHIVE_INSTRUCTIONS_PATH
        ]
      end

      def self.rollback_failed_install!(ops, destination:, backup:, migration_pathspecs:, pathspecs:,
                                        runtime_backed_up:, runtime_installed:)
        errors = []
        rollback_step(errors) { FileUtils.rm_rf(destination) } if runtime_installed
        if runtime_backed_up && (File.exist?(backup) || File.symlink?(backup))
          rollback_step(errors) { FileUtils.mv(backup, destination) }
        end
        if migration_pathspecs.any?
          rollback_step(errors) do
            FileUtils.mv(
              File.join(ops.hive_state_path, LEGACY_ARCHIVE_DESCRIPTOR_PATH),
              File.join(ops.hive_state_path, LEGACY_DESCRIPTOR_PATH)
            )
          end
          rollback_step(errors) do
            FileUtils.rm_rf(File.join(ops.hive_state_path, LEGACY_ARCHIVE_INSTRUCTIONS_PATH))
          end
        end
        rollback_step(errors) do
          ops.run_git!("-C", ops.hive_state_path, "reset", "-q", "--", *pathspecs)
        end
        return if errors.empty?

        warn "hive: failed to fully roll back bench runtime installation: #{errors.join('; ')}"
      end

      def self.rollback_step(errors)
        yield
      rescue StandardError => e
        errors << "#{e.class}: #{e.message}"
      end

      DESCRIPTOR = Hive::Workflow.new(
        id: :bench,
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
