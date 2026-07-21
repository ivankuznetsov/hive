require "test_helper"

require "hive/agent_skills/canonical_skill"
require "hive/agent_skills/directory_publisher"

class AgentSkillsDirectoryPublisherTest < Minitest::Test
  include HiveTestHelper

  Publisher = Hive::AgentSkills::DirectoryPublisher

  def projection(hive_version: Hive::VERSION)
    Hive::AgentSkills::CanonicalSkill.new(hive_version: hive_version).render("claude")
  end

  def publisher(home, rendered: projection, failure_hook: nil)
    Publisher.new(
      root: File.join(home, ".claude"),
      trusted_root: home,
      projection: rendered,
      failure_hook: failure_hook
    )
  end

  def publish(publisher)
    report = publisher.report
    publisher.publish(expected_snapshot: report.snapshot)
  end

  def test_fresh_publish_is_complete_private_and_idempotently_healthy
    with_tmp_dir do |home|
      target = publisher(home)
      assert_equal "absent", target.report.state

      result = publish(target)

      assert_equal "healthy", result.state
      assert_empty result.issues
      assert_equal projection.files.keys.sort, result.files.keys.sort
      projection.files.each_key do |relative|
        assert_equal 0o600, File.stat(File.join(target.destination, relative)).mode & 0o777
      end
      assert_equal 0o700, File.stat(target.destination).mode & 0o777
      assert_equal "healthy", target.report.state
    end
  end

  def test_intact_stale_projection_is_replaced_as_one_directory
    with_tmp_dir do |home|
      old = publisher(home, rendered: projection(hive_version: "0.0.1"))
      publish(old)
      current = publisher(home)

      assert_equal "stale", current.report.state
      before_inode = File.stat(current.destination).ino
      result = current.publish(expected_snapshot: current.report.snapshot)

      assert_equal "healthy", result.state
      refute_equal before_inode, File.stat(current.destination).ino
      assert_empty recovery_entries(current.parent)
    end
  end

  def test_modified_or_incomplete_managed_content_is_never_overwritten
    with_tmp_dir do |home|
      target = publisher(home)
      publish(target)
      skill_path = File.join(target.destination, "SKILL.md")
      File.open(skill_path, "a") { |file| file.write("user change\n") }

      report = target.report
      assert_equal "foreign", report.state
      assert_match(/modified/, report.issues.first.last)
      assert_raises(Publisher::ForeignContent) do
        target.publish(expected_snapshot: report.snapshot)
      end
      assert_includes File.read(skill_path), "user change"

      File.delete(File.join(target.destination, "references", "recovery.md"))
      assert_equal "foreign", target.report.state
    end
  end

  def test_declared_external_metadata_cannot_mask_projection_or_foreign_files
    with_tmp_dir do |home|
      target = publisher(home)
      publish(target)
      metadata = File.join(target.destination, "_meta.json")
      File.write(metadata, "{}\n", mode: "w", perm: 0o600)

      assert_equal "foreign", target.report.state
      allowed = target.report(allowed_extra_files: [ "_meta.json" ])
      assert_equal "healthy", allowed.state
      refute allowed.files.key?("_meta.json")

      %w[SKILL.md .hive-skill.json].each do |canonical_path|
        report = target.report(allowed_extra_files: [ canonical_path ])
        assert_equal "unsafe", report.state
        assert_match(/invalid allowed projection metadata/, report.issues.first.last)
      end

      File.write(File.join(target.destination, "PRIVATE.md"), "keep\n", mode: "w", perm: 0o600)
      assert_equal "foreign", target.report(allowed_extra_files: [ "_meta.json" ]).state
    end
  end

  def test_symlink_and_group_writable_roots_are_rejected_read_only
    with_tmp_dir do |home|
      outside = File.join(home, "outside")
      Dir.mkdir(outside, 0o700)
      File.symlink(outside, File.join(home, ".claude"))
      report = publisher(home).report
      assert_equal "unsafe", report.state
      assert_match(/symlink/, report.issues.first.last)
    end

    with_tmp_dir do |home|
      root = File.join(home, ".claude")
      Dir.mkdir(root, 0o700)
      File.chmod(0o770, root)
      report = publisher(home).report
      assert_equal "unsafe", report.state
      assert_match(/group\/world-writable/, report.issues.first.last)
    end
  end

  def test_parent_lock_must_be_private_regular_and_not_redirected
    [ :symlink, :hardlink, :public_mode ].each do |variant|
      with_tmp_dir do |home|
        target = publisher(home)
        FileUtils.mkdir_p(target.parent, mode: 0o700)
        outside = File.join(home, "outside-lock")
        File.write(outside, "preserve\n")
        File.chmod(0o600, outside)
        lock = File.join(target.parent, Publisher::LOCK_NAME)
        case variant
        when :symlink then File.symlink(outside, lock)
        when :hardlink then File.link(outside, lock)
        when :public_mode
          File.write(lock, "")
          File.chmod(0o644, lock)
        end
        preview = target.report

        assert_raises(Publisher::UnsafePath, variant.to_s) do
          target.publish(expected_snapshot: preview.snapshot)
        end
        assert_equal "preserve\n", File.read(outside)
        refute File.exist?(target.destination)
      end
    end
  end

  def test_concurrent_foreign_destination_and_symlink_swap_are_preserved
    [ :directory, :symlink ].each do |replacement|
      with_tmp_dir do |home|
        target = nil
        hook = lambda do |phase, current|
          next unless phase == :after_stage
          if replacement == :directory
            Dir.mkdir(current.destination, 0o700)
            File.write(File.join(current.destination, "PRIVATE.md"), "keep\n", mode: "w", perm: 0o600)
          else
            outside = File.join(home, "outside")
            Dir.mkdir(outside, 0o700)
            File.write(File.join(outside, "PRIVATE.md"), "keep\n", mode: "w", perm: 0o600)
            File.symlink(outside, current.destination)
          end
        end
        target = publisher(home, failure_hook: hook)
        preview = target.report

        assert_raises(Publisher::Changed) do
          target.publish(expected_snapshot: preview.snapshot)
        end
        assert_equal "keep\n", File.read(File.join(target.destination, "PRIVATE.md"))
        assert_empty recovery_entries(target.parent)
      end
    end
  end

  def test_orphan_stage_and_backup_are_reported_as_conflicts
    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.parent, mode: 0o700)
      stage = File.join(target.parent, "#{Publisher::STAGE_PREFIX}claude-crash")
      backup = File.join(target.parent, "#{Publisher::BACKUP_PREFIX}claude-crash")
      Dir.mkdir(stage, 0o700)
      Dir.mkdir(backup, 0o700)

      report = target.report
      assert_equal "absent", report.state
      assert_equal "conflicting", report.issues.first.first
      assert_includes report.issues.first.last, stage
      assert_includes report.issues.first.last, backup
      assert_raises(Publisher::ForeignContent) do
        target.publish(expected_snapshot: report.snapshot)
      end
    end
  end

  def test_failures_before_commit_restore_the_old_complete_projection
    phases = %i[
      after_stage before_backup_rename after_backup_rename before_stage_rename
      after_stage_rename before_parent_fsync after_parent_fsync before_backup_cleanup
    ]
    phases.each do |failure_phase|
      with_tmp_dir do |home|
        publish(publisher(home, rendered: projection(hive_version: "0.0.1")))
        hook = ->(phase, _) { raise "crash at #{phase}" if phase == failure_phase }
        target = publisher(home, failure_hook: hook)
        preview = target.report
        assert_equal "stale", preview.state

        error = assert_raises(RuntimeError) do
          target.publish(expected_snapshot: preview.snapshot)
        end
        assert_includes error.message, failure_phase.to_s
        assert_equal "stale", publisher(home).report.state, failure_phase.to_s
        assert_empty recovery_entries(target.parent), failure_phase.to_s
      end
    end
  end

  def test_failures_after_old_cleanup_leave_the_new_complete_projection
    %i[after_backup_cleanup before_final_fsync after_final_fsync].each do |failure_phase|
      with_tmp_dir do |home|
        publish(publisher(home, rendered: projection(hive_version: "0.0.1")))
        hook = ->(phase, _) { raise "crash at #{phase}" if phase == failure_phase }
        target = publisher(home, failure_hook: hook)

        assert_raises(RuntimeError) do
          target.publish(expected_snapshot: target.report.snapshot)
        end
        assert_equal "healthy", publisher(home).report.state, failure_phase.to_s
        assert_empty recovery_entries(target.parent), failure_phase.to_s
      end
    end
  end

  def test_fresh_install_failure_never_leaves_a_partial_destination
    %i[after_stage before_stage_rename after_stage_rename after_parent_fsync].each do |failure_phase|
      with_tmp_dir do |home|
        hook = ->(phase, _) { raise "crash at #{phase}" if phase == failure_phase }
        target = publisher(home, failure_hook: hook)

        assert_raises(RuntimeError) do
          target.publish(expected_snapshot: target.report.snapshot)
        end
        assert_equal "absent", publisher(home).report.state, failure_phase.to_s
        assert_empty recovery_entries(target.parent), failure_phase.to_s
      end
    end
  end

  def test_destination_must_remain_below_trusted_root
    with_tmp_dir do |home|
      error = assert_raises(Publisher::UnsafePath) do
        Publisher.new(
          root: File.join(File.dirname(home), "foreign-root"),
          trusted_root: home,
          projection: projection
        )
      end

      assert_match(/beneath the trusted user root/, error.message)
    end
  end

  def test_invalid_manifest_json_is_foreign_content
    with_tmp_dir do |home|
      target = publisher(home)
      publish(target)
      File.write(File.join(target.destination, Publisher::MANIFEST_NAME), "{")

      report = target.report

      assert_equal "foreign", report.state
      assert_match(/invalid JSON/, report.issues.first.last)
    end
  end

  def test_publish_rejects_a_final_report_that_does_not_verify
    with_tmp_dir do |home|
      target = publisher(home)
      preview = target.report
      original_report = target.method(:report)
      healthy_reports = 0
      target.define_singleton_method(:report) do |**kwargs|
        result = original_report.call(**kwargs)
        if result.state == "healthy"
          healthy_reports += 1
          return result.with(state: "stale", issues: [ [ "stale", "verification drift" ] ].freeze) if healthy_reports == 3
        end
        result
      end

      error = assert_raises(Publisher::Error) do
        target.publish(expected_snapshot: preview.snapshot)
      end

      assert_match(/did not verify: verification drift/, error.message)
      assert_equal "healthy", publisher(home).report.state
    end
  end

  def test_redirected_and_unavailable_trusted_roots_are_unsafe
    with_tmp_dir do |home|
      target = publisher(home)
      original_realpath = File.method(:realpath)
      with_singleton_method(File, :realpath, ->(path) { path == home ? "#{home}-redirected" : original_realpath.call(path) }) do
        report = target.report
        assert_equal "unsafe", report.state
        assert_match(/redirected/, report.issues.first.last)
      end
    end

    Dir.mktmpdir("hive-missing-trusted-root") do |dir|
      trusted = File.join(dir, "missing")
      target = Publisher.new(
        root: File.join(trusted, ".claude"), trusted_root: trusted, projection: projection
      )

      report = target.report
      assert_equal "unsafe", report.state
      assert_match(/trusted user root .* unavailable/, report.issues.first.last)
    end
  end

  def test_missing_directory_component_is_rejected
    with_tmp_dir do |home|
      target = publisher(home)

      error = assert_raises(Publisher::UnsafePath) do
        target.send(:validate_directory!, File.join(home, "missing"))
      end

      assert_match(/path component .* unavailable/, error.message)
    end
  end

  def test_parent_creation_detects_identity_change_and_accepts_eexist_race
    with_tmp_dir do |home|
      target = publisher(home)
      original_identity = target.method(:identity)
      home_calls = 0
      target.define_singleton_method(:identity) do |path|
        value = original_identity.call(path)
        if path == home
          home_calls += 1
          value = value.merge("ino" => value.fetch("ino") + 1).freeze if home_calls == 2
        end
        value
      end

      error = assert_raises(Publisher::Changed) { target.send(:ensure_parent_directories!) }
      assert_match(/changed while creating/, error.message)
    end

    with_tmp_dir do |home|
      target = publisher(home)
      raced_path = File.join(home, ".claude")
      original_mkdir = Dir.method(:mkdir)
      raced = false
      mkdir = lambda do |path, mode = 0o777|
        if path == raced_path && !raced
          raced = true
          original_mkdir.call(path, mode)
          raise Errno::EEXIST, path
        end
        original_mkdir.call(path, mode)
      end

      with_singleton_method(Dir, :mkdir, mkdir) { target.send(:ensure_parent_directories!) }

      assert raced
      assert File.directory?(target.parent)
    end
  end

  def test_parent_lock_timeout_is_a_changed_destination
    with_tmp_dir do |home|
      target = publisher(home)
      target.send(:ensure_parent_directories!)
      lock_path = File.join(target.parent, Publisher::LOCK_NAME)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |holder|
        assert holder.flock(File::LOCK_EX | File::LOCK_NB)
        clock_calls = 0
        clock = lambda do |*|
          clock_calls += 1
          clock_calls == 1 ? 0.0 : Publisher::LOCK_TIMEOUT_SEC + 1.0
        end

        error = with_singleton_method(Process, :clock_gettime, clock) do
          assert_raises(Publisher::Changed) do
            target.send(:with_parent_lock, lock_path) { flunk "lock unexpectedly acquired" }
          end
        end
        assert_match(/timed out waiting/, error.message)
      end
    end


    with_tmp_dir do |home|
      target = publisher(home)
      target.send(:ensure_parent_directories!)
      lock_path = File.join(target.parent, Publisher::LOCK_NAME)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |holder|
        assert holder.flock(File::LOCK_EX | File::LOCK_NB)
        target.define_singleton_method(:sleep) { |_| holder.flock(File::LOCK_UN) }
        yielded = false

        target.send(:with_parent_lock, lock_path) { yielded = true }

        assert yielded
      end
    end
  end

  def test_staging_rejects_cross_filesystem_and_parent_identity_races
    with_tmp_dir do |home|
      target = publisher(home)
      target.send(:ensure_parent_directories!)
      stage = File.join(target.parent, "#{Publisher::STAGE_PREFIX}cross-device")
      original_stat = File.method(:stat)
      parent_dev = original_stat.call(target.parent).dev
      fake_stat = Struct.new(:dev).new(parent_dev + 1)

      with_singleton_method(File, :stat, ->(path) { path == stage ? fake_stat : original_stat.call(path) }) do
        error = assert_raises(Publisher::UnsafePath) { target.send(:create_stage!, stage) }
        assert_match(/destination filesystem/, error.message)
      end
      FileUtils.remove_entry_secure(stage) if File.exist?(stage)
    end

    with_tmp_dir do |home|
      target = publisher(home)
      target.send(:ensure_parent_directories!)
      stage = File.join(target.parent, "#{Publisher::STAGE_PREFIX}parent-race")
      original_identity = target.method(:identity)
      parent_calls = 0
      target.define_singleton_method(:identity) do |path|
        value = original_identity.call(path)
        if path == parent
          parent_calls += 1
          value = value.merge("ino" => value.fetch("ino") + 1).freeze if parent_calls == 2
        end
        value
      end

      error = assert_raises(Publisher::Changed) { target.send(:create_stage!, stage) }
      assert_match(/parent changed while staging/, error.message)
      FileUtils.remove_entry_secure(stage) if File.exist?(stage)
    end
  end

  def test_staged_files_are_verified_byte_for_byte
    with_tmp_dir do |home|
      target = publisher(home)
      stage = File.join(home, "stage")
      FileUtils.mkdir_p(stage, mode: 0o700)
      File.write(File.join(stage, "SKILL.md"), "wrong\n", mode: "w", perm: 0o600)

      error = assert_raises(Publisher::Error) { target.send(:verify_stage!, stage) }

      assert_match(/failed byte verification/, error.message)
      assert_includes error.message, "SKILL.md"
    end
  end

  def test_rollback_preserves_a_foreign_replacement_and_wraps_rollback_failure
    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.destination, mode: 0o700)
      private_file = File.join(target.destination, "PRIVATE.md")
      File.write(private_file, "keep\n", mode: "w", perm: 0o600)

      target.send(
        :rollback!, stage: File.join(target.parent, "stage"), backup: File.join(target.parent, "backup"),
        old_moved: false, new_installed: true, staged_identity: {}.freeze
      )

      assert_equal "keep\n", File.read(private_file)
    end

    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.parent, mode: 0o700)
      target.define_singleton_method(:fsync_directory) { |_| raise Errno::EIO, "forced fsync failure" }

      error = assert_raises(Publisher::Error) do
        target.send(
          :rollback!, stage: File.join(target.parent, "stage"), backup: File.join(target.parent, "backup"),
          old_moved: false, new_installed: false, staged_identity: nil
        )
      end
      assert_match(/rollback could not complete: Errno::EIO/, error.message)
    end
  end

  def test_exchange_revalidates_backup_and_published_tree
    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.parent, mode: 0o700)
      stage = File.join(target.parent, "stage")
      backup = File.join(target.parent, "backup")
      Dir.mkdir(stage, 0o700)
      Dir.mkdir(backup, 0o700)
      prior_identity = target.send(:identity, backup)

      error = assert_raises(Publisher::Changed) do
        target.send(
          :assert_parent_and_exchange_state!, stage: stage, backup: backup, old_moved: true,
          expected_snapshot: target.report.snapshot, prior_identity: prior_identity,
          prior_tree_digest: "different"
        )
      end
      assert_match(/backup changed/, error.message)
    end

    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.parent, mode: 0o700)

      error = assert_raises(Publisher::Changed) do
        target.send(:assert_published_tree!, backup: File.join(target.parent, "backup"), old_moved: false)
      end
      assert_match(/published Hive skill tree changed/, error.message)
    end
  end

  def test_tree_walk_rejects_special_entries
    with_tmp_dir do |home|
      target = publisher(home)
      root = File.join(home, "tree")
      Dir.mkdir(root, 0o700)
      entry = File.join(root, "special")
      File.write(entry, "placeholder", mode: "w", perm: 0o600)
      fake_stat = Object.new
      fake_stat.define_singleton_method(:symlink?) { false }
      fake_stat.define_singleton_method(:uid) { Process.euid }
      fake_stat.define_singleton_method(:mode) { 0o600 }
      fake_stat.define_singleton_method(:directory?) { false }
      fake_stat.define_singleton_method(:file?) { false }
      original_lstat = File.method(:lstat)

      with_singleton_method(File, :lstat, ->(path) { path == entry ? fake_stat : original_lstat.call(path) }) do
        error = assert_raises(Publisher::UnsafePath) { target.send(:tree_files, root) }
        assert_match(/not a regular file or directory/, error.message)
      end
    end
  end

  def test_unsafe_report_uses_minimal_snapshot_when_full_snapshot_fails
    with_tmp_dir do |home|
      target = publisher(home)
      target.define_singleton_method(:validate_existing_components!) do
        raise Publisher::UnsafePath, "forced unsafe path"
      end
      target.define_singleton_method(:snapshot_for) { |*| raise Errno::EACCES, "forced snapshot failure" }

      report = target.report

      assert_equal "unsafe", report.state
      assert_nil report.snapshot.fetch("tree_digest")
      assert_empty report.snapshot.fetch("path_identities")
    end
  end

  def test_orphan_inspection_errors_are_reported_as_unsafe
    with_tmp_dir do |home|
      target = publisher(home)
      FileUtils.mkdir_p(target.parent, mode: 0o700)
      original_children = Dir.method(:children)

      with_singleton_method(
        Dir, :children,
        ->(path) { path == target.parent ? raise(Errno::EACCES, path) : original_children.call(path) }
      ) do
        error = assert_raises(Publisher::UnsafePath) { target.send(:orphan_paths) }
        assert_match(/could not inspect skill publish recovery state/, error.message)
      end
    end
  end

  private

  def with_singleton_method(object, name, replacement)
    singleton = object.singleton_class
    original = singleton.instance_method(name)
    singleton.define_method(name, replacement)
    yield
  ensure
    singleton.define_method(name, original) if singleton && original
  end

  def recovery_entries(parent)
    return [] unless File.directory?(parent)
    Dir.children(parent).grep(/\A(?:#{Regexp.escape(Publisher::STAGE_PREFIX)}|#{Regexp.escape(Publisher::BACKUP_PREFIX)})/)
  end
end
