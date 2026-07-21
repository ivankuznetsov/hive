require "digest"
require "fileutils"
require "json"
require "securerandom"

module Hive
  module AgentSkills
    # Verifies and atomically publishes one complete Hive-owned skill
    # projection below an agent's user config root. It never follows symlinks,
    # never treats a modified tree as managed, and swaps whole directories so a
    # resolver cannot observe files from two skill versions.
    class DirectoryPublisher
      MANIFEST_NAME = ".hive-skill.json"
      LOCK_NAME = ".hive-skill.lock"
      STAGE_PREFIX = ".hive-skill-stage-"
      BACKUP_PREFIX = ".hive-skill-backup-"
      LOCK_TIMEOUT_SEC = 10
      SAFE_RELATIVE = %r{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9._/-]+\z}

      class Error < Hive::ConfigError; end
      class UnsafePath < Error; end
      class Changed < Error; end
      class ForeignContent < Error; end

      Report = Data.define(:state, :destination, :manifest, :files, :snapshot, :issues)

      attr_reader :root, :destination, :parent, :projection

      def initialize(root:, trusted_root:, projection:, failure_hook: nil)
        @root = File.expand_path(root)
        @trusted_root = File.expand_path(trusted_root)
        @projection = projection
        @failure_hook = failure_hook
        relative = projection.destination_relative.to_s
        raise UnsafePath, "unsafe bundled skill destination #{relative.inspect}" unless safe_relative?(relative)

        @destination = File.expand_path(relative, @root)
        @parent = File.dirname(@destination)
        unless contained?(@destination, @root) && contained?(@root, @trusted_root)
          raise UnsafePath, "bundled skill destination must remain beneath the trusted user root"
        end
      end

      # Read-only state used by doctor, preview, and execution revalidation.
      # External distributors may declare their own metadata files, but never
      # mask a canonical projection file from integrity verification.
      def report(ignore_orphans: [], allowed_extra_files: [])
        validate_existing_components!
        allowed_extra_files = validate_allowed_extra_files!(allowed_extra_files)
        orphans = orphan_paths - ignore_orphans
        unless File.exist?(destination)
          snapshot = snapshot_for("absent", {}, orphans)
          issues = [ [ "missing", "Hive operating skill is not installed at #{destination}" ] ]
          issues.unshift(orphan_issue(orphans)) unless orphans.empty?
          return Report.new(
            state: "absent", destination: destination, manifest: nil, files: {}.freeze,
            snapshot: snapshot, issues: issues.freeze
          ).freeze
        end

        validate_directory!(destination)
        files = tree_files(destination, allowed_extra_files: allowed_extra_files)
        manifest_path = File.join(destination, MANIFEST_NAME)
        unless files.key?(MANIFEST_NAME)
          return foreign_report(files, nil, orphans, "destination has no Hive projection manifest")
        end

        manifest = parse_manifest(files.fetch(MANIFEST_NAME).fetch("content"))
        identity_error = manifest_identity_error(manifest)
        return foreign_report(files, manifest, orphans, identity_error) if identity_error

        integrity_error = manifest_integrity_error(manifest, files)
        return foreign_report(files, manifest, orphans, integrity_error) if integrity_error

        exact = projection.files.all? do |path, content|
          files[path] && files.fetch(path).fetch("digest") == ::Digest::SHA256.hexdigest(content)
        end && files.keys.sort == projection.files.keys.sort
        state = exact ? "healthy" : "stale"
        issues = []
        unless exact
          issues << [ "stale", "managed Hive operating skill does not match canonical #{projection.skill_version}" ]
        end
        issues.unshift(orphan_issue(orphans)) unless orphans.empty?
        snapshot = snapshot_for(state, files, orphans)
        Report.new(
          state: state, destination: destination, manifest: public_manifest(manifest),
          files: public_files(files), snapshot: snapshot, issues: issues.freeze
        ).freeze
      rescue JSON::ParserError => e
        files ||= {}
        foreign_report(files, nil, orphan_paths, "projection manifest is invalid JSON: #{e.message}")
      rescue UnsafePath => e
        snapshot = snapshot_for("unsafe", {}, []) rescue minimal_snapshot("unsafe")
        Report.new(
          state: "unsafe", destination: destination, manifest: nil, files: {}.freeze,
          snapshot: snapshot,
          issues: [ [ "conflicting", e.message ] ].freeze
        ).freeze
      end

      # Publish only when the previewed tree and all previewed path identities
      # are still current. All writes happen in a private sibling directory;
      # the destination changes via rename only.
      def publish(expected_snapshot:)
        unless %w[absent stale].include?(expected_snapshot["state"]) && Array(expected_snapshot["orphans"]).empty?
          raise ForeignContent,
                "Hive will publish only an absent or intact stale managed skill, not #{expected_snapshot['state'].inspect}"
        end
        assert_snapshot!(expected_snapshot)
        ensure_parent_directories!
        lock_path = File.join(parent, LOCK_NAME)
        with_parent_lock(lock_path) do
          assert_snapshot!(expected_snapshot, allow_created_ancestors: true)
          stage = File.join(parent, "#{STAGE_PREFIX}#{projection.platform}-#{SecureRandom.hex(8)}")
          backup = File.join(parent, "#{BACKUP_PREFIX}#{projection.platform}-#{SecureRandom.hex(8)}")
          old_moved = false
          new_installed = false
          committed = false
          staged_identity = nil
          prior_identity = nil
          prior_tree_digest = nil
          begin
            create_stage!(stage)
            staged_identity = identity(stage)
            trigger(:after_stage)
            assert_snapshot!(expected_snapshot, allow_created_ancestors: true, ignore_orphans: [ stage ])

            if File.exist?(destination)
              trigger(:before_backup_rename)
              assert_snapshot!(expected_snapshot, allow_created_ancestors: true, ignore_orphans: [ stage ])
              prior_identity = identity(destination)
              prior_tree_digest = tree_digest_at(destination)
              File.rename(destination, backup)
              old_moved = true
              trigger(:after_backup_rename)
            end

            trigger(:before_stage_rename)
            assert_parent_and_exchange_state!(
              stage: stage, backup: backup, old_moved: old_moved,
              expected_snapshot: expected_snapshot,
              prior_identity: prior_identity,
              prior_tree_digest: prior_tree_digest
            )
            File.rename(stage, destination)
            new_installed = true
            trigger(:after_stage_rename)
            assert_published_tree!(backup: backup, old_moved: old_moved)
            trigger(:before_parent_fsync)
            assert_published_tree!(backup: backup, old_moved: old_moved)
            fsync_directory(parent)
            trigger(:after_parent_fsync)
            committed = true

            if old_moved
              trigger(:before_backup_cleanup)
              assert_published_tree!(backup: backup, old_moved: true)
              FileUtils.remove_entry_secure(backup)
              old_moved = false
              trigger(:after_backup_cleanup)
              trigger(:before_final_fsync)
              fsync_directory(parent)
              trigger(:after_final_fsync)
            end
          rescue StandardError
            rollback!(stage: stage, backup: backup, old_moved: old_moved,
                      new_installed: new_installed,
                      staged_identity: staged_identity) unless committed && !old_moved
            raise
          ensure
            FileUtils.remove_entry_secure(stage) if File.exist?(stage)
          end
        end

        final = report
        unless final.state == "healthy" && final.issues.empty?
          raise Error, "published Hive operating skill did not verify: #{final.issues.map(&:last).join('; ')}"
        end
        final
      end

      private

      def safe_relative?(path)
        SAFE_RELATIVE.match?(path) && !path.split("/").include?(".")
      end

      def contained?(path, root)
        path == root || path.start_with?(root + File::SEPARATOR)
      end

      def validate_existing_components!
        validate_trusted_root!
        paths_between(@trusted_root, destination).each do |path|
          break unless File.exist?(path) || File.symlink?(path)

          validate_directory!(path)
        end
      end

      def validate_trusted_root!
        stat = File.lstat(@trusted_root)
        raise UnsafePath, "trusted user root #{@trusted_root} must not be a symlink" if stat.symlink?
        raise UnsafePath, "trusted user root #{@trusted_root} is not a directory" unless stat.directory?
        validate_owner_mode!(stat, @trusted_root)
        real = File.realpath(@trusted_root)
        unless real == @trusted_root
          raise UnsafePath, "trusted user root #{@trusted_root} is redirected to #{real}"
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise UnsafePath, "trusted user root #{@trusted_root} is unavailable: #{e.message}"
      end

      def validate_directory!(path)
        stat = File.lstat(path)
        raise UnsafePath, "skill path component #{path} must not be a symlink" if stat.symlink?
        raise UnsafePath, "skill path component #{path} is not a directory" unless stat.directory?
        validate_owner_mode!(stat, path)
        stat
      rescue Errno::ENOENT, Errno::EACCES => e
        raise UnsafePath, "skill path component #{path} is unavailable: #{e.message}"
      end

      def validate_owner_mode!(stat, path)
        raise UnsafePath, "skill path component #{path} is not owned by uid #{Process.euid}" unless stat.uid == Process.euid
        return if (stat.mode & 0o022).zero?

        raise UnsafePath, "skill path component #{path} is group/world-writable"
      end

      def ensure_parent_directories!
        validate_trusted_root!
        paths_between(@trusted_root, parent).each do |path|
          if File.exist?(path) || File.symlink?(path)
            validate_directory!(path)
            next
          end

          parent_path = File.dirname(path)
          before = identity(parent_path)
          Dir.mkdir(path, 0o700)
          validate_directory!(path)
          unless identity(parent_path) == before
            raise Changed, "skill path parent #{parent_path} changed while creating #{path}"
          end
        rescue Errno::EEXIST
          validate_directory!(path)
        end
      end

      def paths_between(base, target)
        raise UnsafePath, "#{target} is outside trusted root #{base}" unless contained?(target, base)
        relative = target.delete_prefix(base).delete_prefix(File::SEPARATOR)
        return [] if relative.empty?

        relative.split(File::SEPARATOR).each_with_object([]) do |component, paths|
          current = paths.empty? ? File.join(base, component) : File.join(paths.last, component)
          paths << current
        end
      end

      def with_parent_lock(path)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o600) do |lock|
          validate_owner_mode!(lock.stat, path)
          raise UnsafePath, "skill publish lock #{path} is not a regular file" unless lock.stat.file?
          unless (lock.stat.mode & 0o777) == 0o600 && lock.stat.nlink == 1
            raise UnsafePath, "skill publish lock #{path} must be owner-private and singly linked"
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_TIMEOUT_SEC
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise Changed, "timed out waiting for Hive skill publish lock #{path}"
            end
            sleep 0.05
          end
          validate_directory!(parent)
          yield
        end
      rescue Errno::ELOOP, Errno::EACCES => e
        raise UnsafePath, "skill publish lock #{path} is unsafe: #{e.message}"
      end

      def create_stage!(stage)
        parent_identity = identity(parent)
        Dir.mkdir(stage, 0o700)
        validate_directory!(stage)
        unless File.stat(stage).dev == File.stat(parent).dev
          raise UnsafePath, "skill stage must be on the destination filesystem"
        end
        unless identity(parent) == parent_identity
          raise Changed, "skill destination parent changed while staging"
        end

        projection.files.each do |relative, content|
          raise UnsafePath, "unsafe projection file #{relative.inspect}" unless safe_relative?(relative)
          path = File.join(stage, relative)
          ensure_stage_subdirectories!(stage, File.dirname(path))
          flags = File::WRONLY | File::CREAT | File::EXCL
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          File.open(path, flags, 0o600) do |file|
            file.write(content)
            file.flush
            file.fsync
          end
        end
        fsync_tree(stage)
        verify_stage!(stage)
      end

      def ensure_stage_subdirectories!(stage, target)
        return if target == stage
        relative = target.delete_prefix(stage).delete_prefix(File::SEPARATOR)
        cursor = stage
        relative.split(File::SEPARATOR).each do |component|
          cursor = File.join(cursor, component)
          Dir.mkdir(cursor, 0o700) unless File.exist?(cursor)
          validate_directory!(cursor)
        end
      end

      def verify_stage!(stage)
        files = tree_files(stage)
        exact = files.keys.sort == projection.files.keys.sort && projection.files.all? do |path, content|
          files.fetch(path).fetch("digest") == ::Digest::SHA256.hexdigest(content)
        end
        unless exact
          changed = (files.keys | projection.files.keys).select do |path|
            files[path].nil? || projection.files[path].nil? ||
              files.fetch(path).fetch("digest") != ::Digest::SHA256.hexdigest(projection.files.fetch(path))
          end
          raise Error, "staged Hive operating skill failed byte verification: #{changed.sort.join(', ')}"
        end
      end

      def rollback!(stage:, backup:, old_moved:, new_installed:, staged_identity:)
        discard = "#{stage}-rollback"
        if new_installed && File.exist?(destination)
          if same_identity?(identity(destination), staged_identity)
            File.rename(destination, discard)
          else
            fsync_directory(parent)
            return
          end
        end
        if old_moved && File.exist?(backup)
          File.rename(backup, destination)
        end
        FileUtils.remove_entry_secure(discard) if File.exist?(discard)
        FileUtils.remove_entry_secure(stage) if File.exist?(stage)
        fsync_directory(parent)
      rescue StandardError => e
        raise Error, "skill publish failed and rollback could not complete: #{e.class}: #{e.message}"
      end

      def assert_parent_and_exchange_state!(stage:, backup:, old_moved:, expected_snapshot:,
                                            prior_identity:, prior_tree_digest:)
        validate_directory!(parent)
        validate_directory!(stage)
        if old_moved
          raise Changed, "Hive skill backup disappeared during publish" unless File.directory?(backup) && !File.symlink?(backup)
          raise Changed, "Hive skill destination reappeared during publish" if File.exist?(destination) || File.symlink?(destination)
          unless same_identity?(identity(backup), prior_identity) && tree_digest_at(backup) == prior_tree_digest
            raise Changed, "Hive skill backup changed during publish"
          end
        else
          assert_snapshot!(expected_snapshot, allow_created_ancestors: true, ignore_orphans: [ stage ])
        end
      end

      def assert_published_tree!(backup:, old_moved:)
        ignored = old_moved ? [ backup ] : []
        current = report(ignore_orphans: ignored)
        unless current.state == "healthy" && current.issues.empty?
          raise Changed, "published Hive skill tree changed during directory exchange"
        end
      end

      def same_identity?(left, right)
        return false unless left && right
        %w[dev ino uid mode type].all? { |field| left[field] == right[field] }
      end

      def tree_digest_at(path)
        ::Digest::SHA256.hexdigest(JSON.generate(public_files(tree_files(path))))
      end

      def assert_snapshot!(expected, allow_created_ancestors: false, ignore_orphans: [])
        current = report(ignore_orphans: ignore_orphans).snapshot
        fields = %w[state destination manifest_digest tree_digest orphans]
        mismatch = fields.any? { |field| current[field] != expected[field] }
        expected.fetch("path_identities", []).each do |entry|
          now = identity(entry.fetch("path")) rescue nil
          mismatch ||= now != entry
        end
        unless allow_created_ancestors
          mismatch ||= current.fetch("path_identities") != expected.fetch("path_identities")
        end
        raise Changed, "Hive operating skill destination changed since preview" if mismatch
      end

      def foreign_report(files, manifest, orphans, message)
        issues = [ [ "conflicting", "Hive will not replace #{destination}: #{message}" ] ]
        issues.unshift(orphan_issue(orphans)) unless orphans.empty?
        Report.new(
          state: "foreign", destination: destination, manifest: public_manifest(manifest),
          files: public_files(files), snapshot: snapshot_for("foreign", files, orphans),
          issues: issues.freeze
        ).freeze
      end

      def parse_manifest(content)
        document = JSON.parse(content)
        raise JSON::ParserError, "root must be an object" unless document.is_a?(Hash)
        document
      end

      def manifest_identity_error(manifest)
        required = %w[schema schema_version owner platform invocation skill_version canonical_digest hive_version files]
        return "projection manifest fields are not recognized" unless manifest.keys.sort == required.sort
        return "projection manifest is not Hive-owned" unless manifest["schema"] == "hive-managed-skill-projection" && manifest["owner"] == "hive"
        return "projection manifest schema version is unsupported" unless manifest["schema_version"] == 1
        return "projection platform does not match #{projection.platform}" unless manifest["platform"] == projection.platform
        return "projection invocation does not match #{projection.invocation}" unless manifest["invocation"] == projection.invocation
        return "projection manifest file table is invalid" unless manifest["files"].is_a?(Hash)
        nil
      end

      def manifest_integrity_error(manifest, files)
        declared = manifest.fetch("files")
        return "projection manifest declares unsafe files" unless declared.all? do |path, digest|
          path.is_a?(String) && safe_relative?(path) && path != MANIFEST_NAME &&
            digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
        end
        actual_paths = files.keys - [ MANIFEST_NAME ]
        return "projection contains missing or foreign files" unless actual_paths.sort == declared.keys.sort

        declared.each do |path, digest|
          return "projection file #{path} was modified" unless files.fetch(path).fetch("digest") == digest
        end
        nil
      end

      def tree_files(root_path, allowed_extra_files: [])
        files = {}
        walk = lambda do |directory, prefix|
          Dir.children(directory).sort.each do |name|
            path = File.join(directory, name)
            relative = prefix.empty? ? name : File.join(prefix, name)
            stat = File.lstat(path)
            raise UnsafePath, "projection entry #{path} must not be a symlink" if stat.symlink?
            validate_owner_mode!(stat, path)
            if stat.directory?
              walk.call(path, relative)
            elsif stat.file?
              next if allowed_extra_files.include?(relative)

              content = File.binread(path)
              files[relative] = {
                "digest" => ::Digest::SHA256.hexdigest(content),
                "mode" => stat.mode & 0o777,
                "content" => content
              }.freeze
            else
              raise UnsafePath, "projection entry #{path} is not a regular file or directory"
            end
          end
        end
        walk.call(root_path, "")
        files.freeze
      end

      def validate_allowed_extra_files!(paths)
        files = Array(paths).map(&:to_s).uniq.freeze
        invalid = files.reject do |path|
          safe_relative?(path) && path != MANIFEST_NAME && !projection.files.key?(path)
        end
        raise UnsafePath, "invalid allowed projection metadata: #{invalid.join(', ')}" unless invalid.empty?

        files
      end

      def public_files(files)
        files.keys.sort.to_h do |path|
          data = files.fetch(path)
          [ path, { "digest" => data.fetch("digest"), "mode" => data.fetch("mode") }.freeze ]
        end.freeze
      end

      def public_manifest(manifest)
        manifest&.dup&.freeze
      end

      def snapshot_for(state, files, orphans)
        public = public_files(files)
        {
          "state" => state,
          "destination" => destination,
          "manifest_digest" => files.dig(MANIFEST_NAME, "digest"),
          "tree_digest" => ::Digest::SHA256.hexdigest(JSON.generate(public)),
          "orphans" => orphans.freeze,
          "path_identities" => existing_path_identities.freeze
        }.freeze
      end

      def minimal_snapshot(state)
        {
          "state" => state, "destination" => destination, "manifest_digest" => nil,
          "tree_digest" => nil, "orphans" => [], "path_identities" => []
        }.freeze
      end

      def existing_path_identities
        ([ @trusted_root ] + paths_between(@trusted_root, destination)).filter_map do |path|
          next unless File.exist?(path) || File.symlink?(path)
          identity(path)
        end
      end

      def identity(path)
        stat = File.lstat(path)
        {
          "path" => path,
          "dev" => stat.dev,
          "ino" => stat.ino,
          "uid" => stat.uid,
          "mode" => stat.mode & 0o777,
          "type" => stat.ftype
        }.freeze
      end

      def orphan_paths
        return [] unless File.directory?(parent) && !File.symlink?(parent)
        Dir.children(parent).grep(/\A(?:#{Regexp.escape(STAGE_PREFIX)}|#{Regexp.escape(BACKUP_PREFIX)})/).sort.map do |name|
          File.join(parent, name)
        end.freeze
      rescue SystemCallError => e
        raise UnsafePath, "could not inspect skill publish recovery state: #{e.message}"
      end

      def orphan_issue(paths)
        [ "conflicting", "orphan Hive skill publish state requires review: #{paths.join(', ')}" ]
      end

      def fsync_tree(root_path)
        directories = [ root_path ]
        Dir.glob(File.join(root_path, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          directories << path if File.directory?(path) && !File.symlink?(path)
        end
        directories.reverse_each { |directory| fsync_directory(directory) }
      end

      def fsync_directory(path)
        File.open(path, File::RDONLY) { |directory| directory.fsync }
      end

      def trigger(phase)
        @failure_hook&.call(phase, self)
      end
    end
  end
end
