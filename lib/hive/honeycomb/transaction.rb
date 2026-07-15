require "fileutils"
require "securerandom"
require "hive/atomic_file"
require "hive/git_ops"
require "hive/lock"
require "hive/honeycomb/installation"
require "hive/honeycomb/package"
require "hive/workflows/project"
require "hive/workflows/registry"

module Hive
  module Honeycomb
    TransactionResult = Data.define(:changed, :partial, :names, :commit)

    class Transaction
      JOURNAL_NAME = ".honeycomb-transaction.yml".freeze
      JOURNAL_VERSION = 1

      attr_reader :project_root, :git_ops, :hive_state_path, :workflows_dir, :lockfile, :journal_path

      def initialize(project_root:, git_ops: nil, fault: nil)
        @project_root = File.expand_path(project_root)
        @git_ops = git_ops || Hive::GitOps.new(@project_root)
        @hive_state_path = @git_ops.hive_state_path
        @workflows_dir = File.join(@hive_state_path, "workflows")
        @lockfile = Lockfile.new(File.join(@workflows_dir, ".honeycomb.lock"))
        @journal_path = File.join(@workflows_dir, JOURNAL_NAME)
        @fault = fault
      end

      def apply(installs: [], removals: [], force: false, allow_unknown_removals: false, action:)
        FileUtils.mkdir_p(workflows_dir)
        packages = Array(installs)
        removal_names = Array(removals).map(&:to_s)
        names = (packages.map { |package| package.pin.name } + removal_names).uniq.sort
        raise ResolutionError, "honeycomb transaction has no changes" if names.empty?

        result = nil
        Hive::Lock.with_commit_lock(hive_state_path) do
          recover_journal!
          lock_unreadable = false
          entries = begin
            lockfile.read
          rescue LockfileError
            raise unless allow_unknown_removals
            lock_unreadable = true
            {}
          end
          validated_partial = validate_operation!(packages, removal_names, entries, force, allow_unknown_removals)
          partial = lock_unreadable || validated_partial
          desired = entries.dup
          packages.each { |package| desired[package.pin.name] = LockEntry.from_verified(package) }
          removal_names.each { |name| desired.delete(name) }
          records = transaction_records(packages, removal_names, include_lock: !lock_unreadable)
          journal = create_journal(records, names, git_ops.hive_state_head_sha)
          commit = nil

          begin
            write_journal(journal)
            inject(:after_journal)
            backup_targets(journal)
            journal["phase"] = "backed_up"
            write_journal(journal)
            inject(:after_backup)
            install_packages(packages)
            lockfile.write(desired) unless lock_unreadable
            inject(:after_lock)
            journal["phase"] = "swapped"
            write_journal(journal)
            inject(:after_swap)

            pathspecs = git_pathspecs(records)
            git_ops.stage_hive_state_pathspecs(pathspecs)
            inject(:after_stage)
            inject(:before_commit)
            commit = git_ops.commit_hive_state_index(
              stage_name: "workflows", slug: names.one? ? names.first : "honeycombs", action: action
            )
            inject(:after_commit)
          rescue StandardError => original
            begin
              rollback_journal(journal)
              packages.each { |package| FileUtils.rm_rf(package.staging_dir) }
            rescue StandardError => rollback_error
              raise Hive::RollbackFailed,
                    "honeycomb transaction failed (#{original.class}: #{original.message}) and rollback failed " \
                    "(#{rollback_error.class}: #{rollback_error.message})"
            end
            raise original
          end
          # Once Git accepted the commit, the new filesystem/lock revision is
          # authoritative. Post-commit journal cleanup is recoverable and must
          # never restore the old files underneath the new commit.
          begin
            journal["phase"] = "committed"
            write_journal(journal)
            cleanup_journal(journal)
          rescue StandardError => e
            warn "hive: honeycomb transaction committed but journal cleanup is pending: #{e.message}"
          end
          packages.each { |package| FileUtils.rm_rf(package.staging_dir) }
          Hive::Workflows::Project.reset!
          result = TransactionResult.new(changed: commit == :committed, partial: partial, names: names, commit: commit)
        end
        result
      rescue StandardError
        packages&.each { |package| FileUtils.rm_rf(package.staging_dir) }
        raise
      end

      def recover!
        FileUtils.mkdir_p(workflows_dir)
        Hive::Lock.with_commit_lock(hive_state_path) { recover_journal! }
      end

      private

      def validate_operation!(packages, removals, entries, force, allow_unknown)
        installation = Installation.new(workflows_dir)
        partial = false
        packages.each do |package|
          name = package.pin.name
          if Hive::Workflows::Registry::WORKFLOWS.key?(name.to_sym)
            raise CollisionError, "workflow id #{name.inspect} is reserved by a built-in workflow"
          end
          ensure_same_filesystem!(package.staging_dir)
          if (entry = entries[name])
            inspection = installation.inspect(entry)
            unless inspection.clean? || force
              raise CollisionError, "managed workflow #{name.inspect} is #{inspection.state}; use --force to replace it"
            end
          else
            collisions = installation.unmanaged_collisions(name)
            if collisions.any? && !force
              raise CollisionError, "unmanaged workflow collision at #{collisions.join(', ')}; use --force to replace it"
            end
          end
        end
        removals.each do |name|
          if (entry = entries[name])
            inspection = installation.inspect(entry)
            unless inspection.clean? || force
              raise CollisionError, "managed workflow #{name.inspect} is #{inspection.state}; use --force to remove it"
            end
            partial ||= inspection.state == "missing"
          elsif allow_unknown && force && installation.canonical_managed_root?(name)
            partial = true
          else
            raise ResolutionError, "workflow #{name.inspect} is not a managed honeycomb install"
          end
        end
        partial
      end

      def ensure_same_filesystem!(path)
        return if File.stat(path).dev == File.stat(workflows_dir).dev
        raise IntegrityError, "staged honeycomb package must be on the workflows filesystem"
      end

      def transaction_records(packages, removals, include_lock: true)
        id = SecureRandom.hex(8)
        targets = []
        (packages.map { |package| package.pin.name } + removals).uniq.sort.each do |name|
          targets << record_for(name, id, targets.length)
          authored = "#{name}.yml"
          targets << record_for(authored, id, targets.length) if packages.any? { |package| package.pin.name == name }
        end
        targets << record_for(".honeycomb.lock", id, targets.length) if include_lock
        targets
      end

      def record_for(relative, id, index)
        target = File.join(workflows_dir, relative)
        {
          "target" => relative,
          "backup" => ".honeycomb-backup-#{id}/#{index}",
          "existed" => path_exists?(target)
        }
      end

      def create_journal(records, names, head)
        { "version" => JOURNAL_VERSION, "phase" => "prepared", "head" => head, "names" => names, "records" => records }
      end

      def write_journal(journal)
        Hive::AtomicFile.write(journal_path, Psych.safe_dump(journal, aliases: false, line_width: -1), mode: 0o600)
      end

      def backup_targets(journal)
        journal.fetch("records").each do |record|
          next unless record.fetch("existed")
          target = journal_target(record.fetch("target"))
          backup = journal_target(record.fetch("backup"))
          FileUtils.mkdir_p(File.dirname(backup))
          File.rename(target, backup)
        end
      end

      def install_packages(packages)
        packages.sort_by { |package| package.pin.name }.each do |package|
          target = File.join(workflows_dir, package.pin.name)
          File.rename(package.staging_dir, target)
        end
      end

      def recover_journal!
        return unless File.file?(journal_path)
        journal = read_journal
        if journal.fetch("phase") == "committed" || journal.fetch("head") != git_ops.hive_state_head_sha
          cleanup_journal(journal)
        else
          rollback_journal(journal)
        end
      end

      def read_journal
        data = Honeycomb.safe_yaml_load(File.binread(journal_path), label: "honeycomb transaction journal",
                                       error_class: LockfileError)
        unless data.is_a?(Hash) && data["version"] == JOURNAL_VERSION &&
               data["head"].is_a?(String) &&
               %w[prepared backed_up swapped committed].include?(data["phase"]) && data["records"].is_a?(Array)
          raise LockfileError, "honeycomb transaction journal is malformed"
        end
        data
      end

      def rollback_journal(journal)
        journal.fetch("records").reverse_each do |record|
          target = journal_target(record.fetch("target"))
          backup = journal_target(record.fetch("backup"))
          if path_exists?(backup)
            FileUtils.rm_rf(target)
            FileUtils.mkdir_p(File.dirname(target))
            File.rename(backup, target)
          elsif !record.fetch("existed")
            FileUtils.rm_rf(target)
          end
        end
        git_ops.reset_hive_state_paths(git_pathspecs(journal.fetch("records")))
        cleanup_journal(journal)
        Hive::Workflows::Project.reset!
      end

      def cleanup_journal(journal)
        backups = journal.fetch("records").map { |record| record.fetch("backup").split("/").first }.uniq
        backups.each { |relative| FileUtils.rm_rf(journal_target(relative)) }
        FileUtils.rm_f(journal_path)
      end

      def git_pathspecs(records)
        records.map { |record| "workflows/#{record.fetch('target')}" }.uniq.sort
      end

      def journal_target(relative)
        clean = Manifest.normalize_path(relative)
        File.join(workflows_dir, clean)
      end

      def path_exists?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end

      def inject(phase)
        @fault&.call(phase)
      end
    end
  end
end
