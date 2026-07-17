require "fileutils"
require "securerandom"
require "tmpdir"
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
      def self.install_runtime!(ops, additional_pathspecs: [], before_commit: nil, rollback: nil)
        destination = File.join(ops.hive_state_path, RUNTIME_STATE_DIR)
        staging = "#{destination}.tmp-#{Process.pid}"
        backup = "#{destination}.previous-#{Process.pid}-#{SecureRandom.hex(4)}"
        migration = nil
        FileUtils.rm_rf(staging)
        FileUtils.mkdir_p(staging)
        FileUtils.cp_r(File.join(RUNTIME_DIR, "."), staging)

        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          migration_pathspecs = []
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
            # Defer asynchronous Ctrl-C until each filesystem mutation and the
            # state needed to reverse it have both been recorded.
            Thread.handle_interrupt(Interrupt => :never) do
              migration = archive_legacy_project_workflow!(ops)
              migration_pathspecs = migration.fetch(:pathspecs)
              pathspecs = [ RUNTIME_STATE_DIR, *migration_pathspecs,
                           *resolve_additional_pathspecs(additional_pathspecs) ].uniq
            end
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
              validate_migration_parent!(ops, migration)
              ops.hive_commit(
                stage_name: "config",
                slug: "bench-runtime",
                action: "install",
                pathspecs: pathspecs,
                after_stage: -> { validate_migration_staging!(ops, migration) }
              )
              validate_migration_parent!(ops, migration)
              commit_finished = true
            end
          rescue StandardError, Interrupt => error
            Thread.handle_interrupt(Interrupt => :never) do
              pathspecs = [ *pathspecs, *resolve_additional_pathspecs(additional_pathspecs) ].uniq
              if !transaction_started
                # Preconditions failed before any migration mutation.
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
                  migration_pathspecs: migration_pathspecs,
                  migration_root: migration&.fetch(:root, nil),
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
        migration_handle = migration&.fetch(:handle, nil)
        close_directory_handle(migration_handle)
        FileUtils.rm_rf(staging) if staging
      end

      def self.archive_legacy_project_workflow!(ops)
        workflows_path = File.join(ops.hive_state_path, "workflows")
        logical_descriptor_path = File.join(ops.hive_state_path, LEGACY_DESCRIPTOR_PATH)
        return empty_migration unless path_present?(logical_descriptor_path)

        pin = pin_workflows_directory!(ops.hive_state_path, workflows_path)
        workflows_root = pin.fetch(:root)
        descriptor_path = File.join(workflows_root, File.basename(LEGACY_DESCRIPTOR_PATH))
        validate_migration_path!(ops.hive_state_path, descriptor_path, expected: :file)

        require "hive/workflows/descriptor_parser"
        descriptor_snapshot = read_descriptor_snapshot!(descriptor_path)
        descriptor = parse_descriptor_snapshot!(descriptor_snapshot, descriptor_path)
        unless legacy_project_descriptor?(descriptor, source_path: descriptor_path)
          pin.fetch(:handle).close
          return empty_migration
        end

        instruction_path = File.join(workflows_root, File.basename(LEGACY_INSTRUCTIONS_PATH))
        validate_migration_path!(ops.hive_state_path, instruction_path, expected: :directory)
        archived_descriptor = File.join(workflows_root, File.basename(LEGACY_ARCHIVE_DESCRIPTOR_PATH))
        archived_instructions = File.join(workflows_root, File.basename(LEGACY_ARCHIVE_INSTRUCTIONS_PATH))
        archive_targets = [
          [ archived_descriptor, File.join(ops.hive_state_path, LEGACY_ARCHIVE_DESCRIPTOR_PATH) ],
          [ archived_instructions, File.join(ops.hive_state_path, LEGACY_ARCHIVE_INSTRUCTIONS_PATH) ]
        ]
        archive_targets.each do |path, display_path|
          next unless path_present?(path)

          raise Hive::ConfigError,
                "cannot migrate legacy bench workflow: archive target already exists at #{display_path}"
        end

        instruction_staging_root = Dir.mktmpdir(".bench.legacy-", workflows_root)
        instruction_staging = File.join(instruction_staging_root, "archive")
        descriptor_archived = false
        instructions_archived = false
        begin
          FileUtils.cp_r(instruction_path, instruction_staging, dereference_root: false)
          staged_stat = File.lstat(instruction_staging)
          unless staged_stat.directory? && !staged_stat.symlink?
            raise Hive::ConfigError,
                  "cannot migrate legacy bench workflow: instruction root changed during archive copy"
          end
          # Publish the private copy atomically. File.rename does not traverse a
          # raced destination symlink, and a real destination directory fails
          # instead of receiving a nested archive.
          publish_instruction_archive!(instruction_staging, archived_instructions)
          instructions_archived = true
          archive_descriptor!(descriptor_path, archived_descriptor, expected: descriptor_snapshot)
          descriptor_archived = true
        rescue StandardError, Interrupt
          errors = []
          rollback_step(errors) { restore_archived_descriptor!(archived_descriptor, descriptor_path) } if descriptor_archived
          rollback_step(errors) { remove_path!(archived_instructions) } if instructions_archived
          warn "hive: failed to restore legacy bench descriptor: #{errors.join('; ')}" unless errors.empty?
          raise
        ensure
          FileUtils.rm_rf(instruction_staging_root) if instruction_staging_root
        end
        {
          pathspecs: [
            LEGACY_DESCRIPTOR_PATH,
            LEGACY_ARCHIVE_DESCRIPTOR_PATH,
            LEGACY_ARCHIVE_INSTRUCTIONS_PATH
          ],
          handle: pin.fetch(:handle),
          root: workflows_root,
          dev: pin.fetch(:dev),
          ino: pin.fetch(:ino)
        }
      rescue StandardError, Interrupt
        close_directory_handle(pin&.fetch(:handle, nil))
        raise
      end

      def self.rollback_failed_install!(ops, destination:, backup:, migration_pathspecs:, migration_root: nil, pathspecs:,
                                        runtime_backed_up:, runtime_installed:, warn_on_failure: true)
        errors = []
        # Reset FIRST: a failed commit may have staged every path below. Leaving
        # those entries live while restoring the filesystem lets a concurrent
        # bare commit sweep a half-migration into unrelated history.
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
        if migration_pathspecs.any?
          workflows_root = migration_root || File.join(ops.hive_state_path, "workflows")
          rollback_step(errors) do
            restore_archived_descriptor!(
              File.join(workflows_root, File.basename(LEGACY_ARCHIVE_DESCRIPTOR_PATH)),
              File.join(workflows_root, File.basename(LEGACY_DESCRIPTOR_PATH))
            )
          end
          rollback_step(errors) do
            remove_path!(File.join(workflows_root, File.basename(LEGACY_ARCHIVE_INSTRUCTIONS_PATH)))
          end
        end
        warn_rollback_errors(errors) if warn_on_failure
        errors
      end

      def self.warn_rollback_errors(errors)
        return if errors.empty?

        warn "hive: failed to fully roll back bench runtime installation: #{errors.join('; ')}"
      end

      def self.empty_migration
        { pathspecs: [], handle: nil, root: nil, dev: nil, ino: nil }.freeze
      end

      def self.pin_workflows_directory!(hive_state_path, workflows_path)
        validate_migration_path!(hive_state_path, workflows_path, expected: :directory)
        expected = File.lstat(workflows_path)
        handle = Dir.open(workflows_path)
        root = pinned_directory_path(handle)
        opened = File.stat(root)
        unless opened.directory? && opened.dev == expected.dev && opened.ino == expected.ino
          raise Hive::ConfigError, "legacy bench workflows directory changed during migration"
        end

        { handle: handle, root: root, dev: opened.dev, ino: opened.ino }
      rescue StandardError, Interrupt
        close_directory_handle(handle)
        raise
      end

      def self.close_directory_handle(handle)
        handle&.close
      rescue IOError
        nil
      end

      def self.pinned_directory_path(handle)
        [ "/proc/self/fd/#{handle.fileno}", "/dev/fd/#{handle.fileno}" ].each do |candidate|
          return candidate if File.directory?(candidate)
        end

        raise Hive::ConfigError,
              "cannot safely pin the legacy bench workflows directory on this platform"
      end

      def self.validate_migration_parent!(ops, migration)
        return unless migration&.fetch(:handle, nil)

        workflows_path = File.join(ops.hive_state_path, "workflows")
        current = File.lstat(workflows_path)
        parent_matches = current.directory? && !current.symlink? &&
                         current.dev == migration.fetch(:dev) && current.ino == migration.fetch(:ino)
        raise Hive::ConfigError, "legacy bench workflows directory changed during migration" unless parent_matches

        descriptor = File.join(migration.fetch(:root), File.basename(LEGACY_DESCRIPTOR_PATH))
        return unless path_present?(descriptor)

        raise Hive::ConfigError, "legacy bench descriptor path reappeared before commit"
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
        raise Hive::ConfigError,
              "cannot validate legacy bench workflows directory during migration: #{e.class}: #{e.message}"
      end

      def self.validate_migration_staging!(ops, migration)
        return unless migration&.fetch(:handle, nil)

        validate_migration_parent!(ops, migration)
        staged_descriptor = ops.run_git!(
          "-C", ops.hive_state_path, "ls-files", "--stage", "--", LEGACY_DESCRIPTOR_PATH
        )
        return if staged_descriptor.strip.empty?

        raise Hive::ConfigError, "legacy bench descriptor reappeared in the staged migration"
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
        warn "hive: could not determine whether bench migration committed " \
             "(#{e.class}: #{e.message}); preserving migrated files for manual inspection"
        true
      end

      def self.resolve_additional_pathspecs(value)
        Array(value.respond_to?(:call) ? value.call : value)
      end

      # Copy with O_EXCL before deleting the source so a raced descriptor target
      # cannot be followed or overwritten. The caller's interrupt mask makes the
      # copy/delete pair one observable transaction for Ctrl-C.
      def self.read_descriptor_snapshot!(path)
        read_flags = File::RDONLY
        read_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, read_flags) do |descriptor|
          stat = descriptor.stat
          raise Hive::ConfigError, "legacy bench descriptor changed type during migration" unless stat.file?

          { content: descriptor.read.freeze, dev: stat.dev, ino: stat.ino, mode: stat.mode }.freeze
        end
      rescue SystemCallError, IOError => e
        raise Hive::ConfigError,
              "cannot read legacy bench descriptor safely at #{path}: #{e.class}: #{e.message}"
      end

      def self.parse_descriptor_snapshot!(snapshot, path)
        data = YAML.safe_load(snapshot.fetch(:content))
        Hive::Workflows::DescriptorParser.parse_hash(data, path: path)
      rescue Psych::Exception => e
        raise Hive::ConfigError, "workflow descriptor #{path}: is not valid YAML: #{e.message}"
      end

      def self.archive_descriptor!(source, destination, expected:)
        quarantine = "#{source}.migrating-#{Process.pid}-#{SecureRandom.hex(16)}"
        quarantined = false
        published = false
        File.rename(source, quarantine)
        quarantined = true
        validate_descriptor_snapshot!(quarantine, expected)
        write_descriptor_archive!(destination, expected)
        published = true
        validate_descriptor_snapshot!(quarantine, expected)
        File.unlink(quarantine)
        quarantined = false
        return unless path_present?(source)

        raise Hive::ConfigError, "legacy bench descriptor path reappeared during migration"
      rescue StandardError, Interrupt
        quarantined ||= quarantine && path_present?(quarantine) && !path_present?(source)
        recovery = quarantine if quarantined && path_present?(quarantine)
        recovery ||= destination if published && path_present?(destination)
        if recovery && !path_present?(source)
          File.rename(recovery, source)
          FileUtils.rm_f(destination) if published && recovery == quarantine
        elsif recovery
          warn "hive: retained legacy bench descriptor recovery copy at #{recovery} " \
               "because #{source} reappeared during migration"
        end
        raise
      end

      def self.write_descriptor_archive!(destination, expected)
        mode = expected.fetch(:mode) & 0o7777
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, mode) do |archive|
          archive.write(expected.fetch(:content))
          archive.flush
          archive.fsync
        end
      end

      def self.validate_descriptor_snapshot!(path, expected)
        read_flags = File::RDONLY
        read_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, read_flags) do |descriptor|
          stat = descriptor.stat
          unless stat.file? && stat.dev == expected.fetch(:dev) && stat.ino == expected.fetch(:ino) &&
                 descriptor.read == expected.fetch(:content)
            raise Hive::ConfigError, "legacy bench descriptor changed during migration"
          end
        end
      end

      def self.publish_instruction_archive!(source, destination)
        File.rename(source, destination)
      rescue Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR, Errno::ENOTEMPTY => e
        raise Hive::ConfigError,
              "cannot migrate legacy bench workflow: archive target appeared at #{destination} " \
              "(#{e.class}: #{e.message})"
      rescue StandardError, Interrupt
        remove_path!(destination) unless path_present?(source)
        raise
      end

      def self.restore_archived_descriptor!(source, destination)
        if path_present?(destination)
          raise Hive::ConfigError,
                "cannot restore legacy bench descriptor over path that reappeared at #{destination}; " \
                "recovery copy remains at #{source}"
        end

        File.rename(source, destination)
      end

      def self.remove_path!(path)
        return unless path_present?(path)

        FileUtils.rm_r(path)
        raise IOError, "path still exists after removal: #{path}" if path_present?(path)
      end

      def self.path_present?(path)
        File.exist?(path) || File.symlink?(path)
      end

      def self.validate_migration_path!(hive_state_path, path, expected:)
        stat = File.lstat(path)
        if stat.symlink?
          raise Hive::ConfigError,
                "cannot migrate legacy bench workflow through symlinked #{expected} at #{path}"
        end
        valid_type = expected == :directory ? stat.directory? : stat.file?
        unless valid_type
          raise Hive::ConfigError,
                "cannot migrate legacy bench workflow: expected #{expected} at #{path}"
        end

        state_root = File.realpath(hive_state_path)
        resolved = File.realpath(path)
        return if resolved.start_with?("#{state_root}#{File::SEPARATOR}")

        raise Hive::ConfigError,
              "cannot migrate legacy bench workflow outside hive state: #{path} resolves to #{resolved}"
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
        raise Hive::ConfigError,
              "cannot validate legacy bench migration path #{path}: #{e.class}: #{e.message}"
      end

      def self.rollback_step(errors)
        yield
      rescue StandardError, Interrupt => e
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
