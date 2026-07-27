require "test_helper"
require "hive/task_meta"

class TaskMetaTest < Minitest::Test
  def test_writes_and_restores_signal_the_containing_stage_directory
    with_tmp_dir do |root|
      stage = File.join(root, ".hive-state", "stages", "9-done")
      task = File.join(stage, "finished")
      FileUtils.mkdir_p(task)
      Hive::TaskMeta.write(task, id: 7, slug: "finished", display_name: nil)
      snapshot = Hive::TaskMeta.snapshot(task)
      old_mtime = Time.now - 3_600

      File.utime(old_mtime, old_mtime, stage)
      Hive::TaskMeta.update_display_name(task, "Finished")
      assert_operator File.mtime(stage), :>, old_mtime

      File.utime(old_mtime, old_mtime, stage)
      Hive::TaskMeta.restore(task, snapshot)
      assert_operator File.mtime(stage), :>, old_mtime
    end
  end

  def test_completed_at_round_trips_in_utc_and_survives_rewrites
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(
        dir, id: 7, slug: "finished", display_name: nil,
        completed_at: "2026-07-22T12:30:00+02:00"
      )

      assert_equal "2026-07-22T10:30:00Z", Hive::TaskMeta.read(dir)[:completed_at]
      Hive::TaskMeta.update_display_name(dir, "Finished")
      Hive::TaskMeta.update_id(dir, 8)
      assert_equal "2026-07-22T10:30:00Z", Hive::TaskMeta.read(dir)[:completed_at]
    end
  end

  def test_completed_at_first_writer_wins
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 7, slug: "finished", display_name: nil)

      first = Hive::TaskMeta.write_completed_at_once(dir, Time.utc(2026, 7, 20, 8, 0, 0))
      second = Hive::TaskMeta.write_completed_at_once(dir, Time.utc(2026, 7, 22, 8, 0, 0))

      assert_equal "2026-07-20T08:00:00Z", first
      assert_equal first, second
      assert_equal first, Hive::TaskMeta.read(dir)[:completed_at]
    end
  end

  def test_completed_at_rejects_malformed_mutations
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        Hive::TaskMeta.write(
          dir, id: 7, slug: "finished", display_name: nil, completed_at: "yesterday"
        )
      end

      assert_includes error.message, "completed_at"
      refute File.exist?(File.join(dir, "meta.yml"))
    end
  end

  def test_malformed_stored_completed_at_warns_and_is_not_rewritten
    with_tmp_dir do |dir|
      path = File.join(dir, "meta.yml")
      original = "id: 7\nslug: finished\ncompleted_at: yesterday\n"
      File.write(path, original)

      metadata = nil
      _out, err = capture_io { metadata = Hive::TaskMeta.read(dir) }

      assert_nil metadata[:completed_at]
      assert_includes err, "keeping task visible"
      assert_raises(Hive::TaskMeta::InvalidMetadata) do
        Hive::TaskMeta.update_display_name(dir, "Do not rewrite")
      end
      assert_equal original, File.read(path)
    end
  end

  def test_timestamp_shaped_invalid_completed_at_warns_and_stays_visible
    with_tmp_dir do |dir|
      File.write(
        File.join(dir, "meta.yml"),
        "id: 7\nslug: finished\ncompleted_at: '2026-99-99T00:00:00Z'\n"
      )

      metadata = nil
      _out, err = capture_io { metadata = Hive::TaskMeta.read(dir) }

      assert_nil metadata[:completed_at]
      assert_includes err, "invalid completed_at"
      assert_includes err, "keeping task visible"
    end
  end

  def test_concurrent_completed_at_writers_converge_on_one_value
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 7, slug: "finished", display_name: nil)
      values = 8.times.map { |index| Time.utc(2026, 7, 20, 8, 0, index) }
      results = values.map do |value|
        Thread.new { Hive::TaskMeta.write_completed_at_once(dir, value) }
      end.map(&:value)

      assert_equal 1, results.uniq.size
      assert_equal results.first, Hive::TaskMeta.read(dir)[:completed_at]
    end
  end

  def test_read_for_admission_distinguishes_absent_metadata
    Dir.mktmpdir do |dir|
      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :absent, result.status
      assert_nil result.error
      assert_equal Hive::TaskMeta.empty, result.data
    end
  end

  def test_read_for_admission_rejects_unreadable_yaml
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.yml"), "depends_on: [unterminated\n")

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :unreadable, result.status
      assert_match(/could not parse/, result.error)
    end
  end

  def test_read_for_admission_rejects_non_mapping_yaml
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.yml"), "- depends_on: base-task\n")

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :invalid, result.status
      assert_match(/must contain a mapping/, result.error)
    end
  end

  def test_read_for_admission_rejects_invalid_dependency_shape
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.yml"), { "depends_on" => [ "base-task" ] }.to_yaml)

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :invalid, result.status
      assert_match(/depends_on/, result.error)
    end
  end

  def test_read_for_admission_rejects_duplicate_dependency_keys
    Dir.mktmpdir do |dir|
      File.write(
        File.join(dir, "meta.yml"),
        "depends_on: blocked-task\ndepends_on: completed-task\n"
      )

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :invalid, result.status
      assert_match(/duplicate depends_on/, result.error)
      assert_equal :metadata_invalid, result.reason
    end
  end

  def test_read_for_admission_rejects_duplicate_base_branch_keys
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.yml"), "base_branch: main\nbase_branch: release/next\n")

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :invalid, result.status
      assert_match(/duplicate base_branch/, result.error)
      assert_equal :metadata_invalid, result.reason
    end
  end

  def test_read_for_admission_reports_non_yaml_read_errors
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "meta.yml"))

      result = Hive::TaskMeta.read_for_admission(dir)

      assert_equal :unreadable, result.status
      assert_match(/could not read/, result.error)
      assert_equal :metadata_unreadable, result.reason
    end
  end

  def test_managed_workflow_provenance_round_trips_and_survives_updates
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(
        dir, id: 7, slug: "managed-260715-aaaa", display_name: nil, workflow: "demo",
        workflow_commit: "a" * 40, workflow_manifest_digest: "b" * 64,
        workflow_configuration_digest: "c" * 64
      )

      assert_equal "a" * 40, Hive::TaskMeta.read(dir)[:workflow_commit]
      assert_equal "b" * 64, Hive::TaskMeta.read(dir)[:workflow_manifest_digest]
      assert_equal "c" * 64, Hive::TaskMeta.read(dir)[:workflow_configuration_digest]
      Hive::TaskMeta.update_display_name(dir, "Managed")
      Hive::TaskMeta.update_id(dir, 8)
      assert_equal "a" * 40, Hive::TaskMeta.read(dir)[:workflow_commit]
      assert_equal "b" * 64, Hive::TaskMeta.read(dir)[:workflow_manifest_digest]
      assert_equal "c" * 64, Hive::TaskMeta.read(dir)[:workflow_configuration_digest]
    end
  end


  def test_configuration_digest_requires_package_provenance
    with_tmp_dir do |dir|
      assert_raises(ArgumentError) do
        Hive::TaskMeta.write(
          dir, id: 7, slug: "managed-260715-aaaa", display_name: nil,
          workflow_configuration_digest: "c" * 64
        )
      end
    end
  end

  def test_managed_workflow_provenance_must_be_written_as_a_pair
    with_tmp_dir do |dir|
      assert_raises(ArgumentError) do
        Hive::TaskMeta.write(
          dir, id: 7, slug: "managed-260715-aaaa", display_name: nil,
          workflow_commit: "a" * 40
        )
      end
    end
  end
  include HiveTestHelper

  def test_write_and_read_round_trip
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo")

      assert_equal({ id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: nil, workflow: nil },
                   Hive::TaskMeta.read(dir))
      assert File.exist?(File.join(dir, "meta.yml"))
      refute Dir.children(dir).any? { |name| name.include?(".meta.yml.tmp") }
    end
  end

  def test_rewrite_guard_uses_the_existing_ignored_task_lock_namespace
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo")
      Hive::TaskMeta.update_display_name(dir, "Updated")

      assert File.exist?(File.join(dir, ".lock.tmp.meta-guard"))
      refute File.exist?(File.join(dir, ".meta.yml.tmp.guard"))
      assert_includes Hive::GitOps::HIVE_STATE_GITIGNORE, "stages/*/*/.lock.tmp.*"
    end
  end

  def test_write_and_read_round_trip_with_dependency
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: "base-task")

      assert_equal(
        { id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: "base-task", workflow: nil },
        Hive::TaskMeta.read(dir)
      )
      assert_includes File.read(File.join(dir, "meta.yml")), "depends_on: base-task"
    end
  end

  def test_write_and_read_round_trip_with_workflow
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo", workflow: "research")

      assert_equal(
        { id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: nil, workflow: "research" },
        Hive::TaskMeta.read(dir)
      )
      assert_includes File.read(File.join(dir, "meta.yml")), "workflow: research"
    end
  end

  def test_base_branch_round_trips_and_survives_metadata_updates
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(
        dir, id: 42, slug: "fix-ui", display_name: nil,
        workflow: "async-fix", base_branch: "release/next"
      )

      assert_equal "release/next", Hive::TaskMeta.read(dir)[:base_branch]

      Hive::TaskMeta.update_display_name(dir, "Fix UI")
      Hive::TaskMeta.update_id(dir, 43)

      meta = Hive::TaskMeta.read(dir)
      assert_equal "release/next", meta[:base_branch]
      assert_equal "Fix UI", meta[:display_name]
      assert_equal 43, meta[:id]
    end
  end

  def test_read_surfaces_workflow_selector
    with_tmp_dir do |dir|
      File.write(File.join(dir, "meta.yml"), "workflow: research\n")

      assert_equal "research", Hive::TaskMeta.read(dir)[:workflow]
    end
  end

  def test_read_returns_nil_workflow_when_absent_or_blank
    with_tmp_dir do |dir|
      File.write(File.join(dir, "meta.yml"), "id: 4\n")
      assert_nil Hive::TaskMeta.read(dir)[:workflow]

      File.write(File.join(dir, "meta.yml"), "workflow: \"  \"\n")
      assert_nil Hive::TaskMeta.read(dir)[:workflow]
    end
  end

  def test_missing_or_malformed_file_returns_nil_fields
    with_tmp_dir do |dir|
      assert_equal Hive::TaskMeta.empty, Hive::TaskMeta.read(dir)

      File.write(File.join(dir, "meta.yml"), ":\n:not yaml")
      # Malformed YAML hits the warn arm of read; capture so it isn't leaked to
      # stderr (the warn itself is asserted in
      # test_malformed_yaml_warns_that_depends_on_and_workflow_were_dropped).
      result = nil
      capture_io { result = Hive::TaskMeta.read(dir) }
      assert_equal Hive::TaskMeta.empty, result

      File.write(File.join(dir, "meta.yml"), "- not\n- a hash\n")
      assert_equal Hive::TaskMeta.empty, Hive::TaskMeta.read(dir)
    end
  end

  def test_read_coerces_numeric_string_id_and_drops_unparseable_id
    with_tmp_dir do |dir|
      File.write(File.join(dir, "meta.yml"), "id: '42'\nslug: from-string-id\n")
      # A YAML-quoted numeric string id is coerced to an Integer via Integer().
      assert_equal({ id: 42, slug: "from-string-id", display_name: nil, depends_on: nil, workflow: nil },
                   Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), "id: not-a-number\nslug: bad-id\n")
      # An unparseable, non-empty id falls back to nil (ArgumentError rescue).
      assert_equal({ id: nil, slug: "bad-id", display_name: nil, depends_on: nil, workflow: nil },
                   Hive::TaskMeta.read(dir))
    end
  end

  # The narrowed rescue in `read` deliberately splits two arms: a YAML/
  # permission/encoding error WARNS (a dropped `depends_on` reads as "no
  # dependency" → blocked:false, so the daemon could dispatch a dependent
  # ahead of its prerequisite — the warn is the only signal), while a missing
  # file (ENOENT) stays SILENT (a normal, expected absence). Pin both arms so
  # a regression re-broadening to a silent `rescue StandardError; empty`
  # — which passes test_missing_or_malformed_file_returns_nil_fields (return
  # value only) — is caught.
  def test_malformed_yaml_warns_that_depends_on_and_workflow_were_dropped
    with_tmp_dir do |dir|
      File.write(File.join(dir, "meta.yml"), "depends_on: [unterminated\n")
      result = nil
      _out, err = capture_io { result = Hive::TaskMeta.read(dir) }
      assert_equal Hive::TaskMeta.empty, result
      assert_match(/depends_on, workflow, base_branch dropped; managed provenance dropped/, err,
                   "a YAML parse failure must warn that depends_on (and the " \
                   "workflow selector) were dropped")
    end
  end

  def test_missing_meta_file_arm_stays_silent
    with_tmp_dir do |dir|
      result = nil
      _out, err = capture_io { result = Hive::TaskMeta.read(dir) }
      assert_equal Hive::TaskMeta.empty, result
      assert_equal "", err,
                   "a missing meta.yml is a normal absence (ENOENT arm) and must NOT warn"
    end
  end

  def test_update_display_name_preserves_id_slug_dependency_and_workflow
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(
        dir,
        id: 7,
        slug: "keep-slug",
        display_name: nil,
        depends_on: "base-task",
        workflow: "research"
      )

      Hive::TaskMeta.update_display_name(dir, "Readable Name")

      assert_equal(
        {
          id: 7,
          slug: "keep-slug",
          display_name: "Readable Name",
          depends_on: "base-task",
          workflow: "research"
        },
        Hive::TaskMeta.read(dir)
      )
    end
  end

  def test_update_id_preserves_slug_display_name_dependency_and_workflow
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(
        dir,
        id: nil,
        slug: "keep-slug",
        display_name: "Keep Me",
        depends_on: "base-task",
        workflow: "research"
      )

      Hive::TaskMeta.update_id(dir, 42)

      assert_equal(
        { id: 42, slug: "keep-slug", display_name: "Keep Me", depends_on: "base-task", workflow: "research" },
        Hive::TaskMeta.read(dir)
      )
    end
  end

  # The id backfiller assigns an id to a task created outside `hive new`; it must
  # preserve a non-coding `workflow:` selector, not silently revert the task to
  # the project default by dropping the field on rewrite.
  def test_update_id_preserves_workflow_selector
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: nil, slug: "keep-slug", display_name: nil,
                           depends_on: nil, workflow: "research")

      Hive::TaskMeta.update_id(dir, 99)

      assert_equal "research", Hive::TaskMeta.read(dir)[:workflow],
                   "the id backfiller must not drop a non-coding workflow selector"
    end
  end

  # update_id manufactures a slug from the folder basename when the meta has
  # none — pin that surprising side effect so a refactor can't drop it silently.
  def test_update_id_falls_back_to_basename_slug_when_meta_has_no_slug
    with_tmp_dir do |parent|
      dir = File.join(parent, "derived-slug-folder")
      FileUtils.mkdir_p(dir)
      Hive::TaskMeta.write(dir, id: nil, slug: nil, display_name: nil)

      Hive::TaskMeta.update_id(dir, 5)

      meta = Hive::TaskMeta.read(dir)
      assert_equal 5, meta[:id]
      assert_equal "derived-slug-folder", meta[:slug],
                   "a missing slug must fall back to the folder basename"
    end
  end

  def test_update_helpers_refuse_to_rewrite_corrupt_metadata
    Dir.mktmpdir do |dir|
      path = File.join(dir, "meta.yml")
      original = "depends_on: [unterminated\n"
      File.write(path, original)

      assert_raises(Hive::TaskMeta::InvalidMetadata) do
        Hive::TaskMeta.update_display_name(dir, "Do Not Rewrite")
      end
      assert_raises(Hive::TaskMeta::InvalidMetadata) do
        Hive::TaskMeta.update_id(dir, 42)
      end
      assert_equal original, File.binread(path)
    end
  end
end
