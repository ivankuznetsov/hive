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

  private

  def recovery_entries(parent)
    return [] unless File.directory?(parent)
    Dir.children(parent).grep(/\A(?:#{Regexp.escape(Publisher::STAGE_PREFIX)}|#{Regexp.escape(Publisher::BACKUP_PREFIX)})/)
  end
end
