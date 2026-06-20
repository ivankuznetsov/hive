require "test_helper"
require "hive/task_meta"

class TaskMetaTest < Minitest::Test
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
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), ":\n:not yaml")
      # Malformed YAML hits the warn arm of read; capture so it isn't leaked to
      # stderr (the warn itself is asserted in
      # test_malformed_yaml_warns_that_depends_on_and_workflow_were_dropped).
      result = nil
      capture_io { result = Hive::TaskMeta.read(dir) }
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }, result)

      File.write(File.join(dir, "meta.yml"), "- not\n- a hash\n")
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }, Hive::TaskMeta.read(dir))
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
      assert_match(/depends_on, workflow dropped/, err,
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

  def test_update_display_name_preserves_id_slug_and_dependency
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 7, slug: "keep-slug", display_name: nil, depends_on: "base-task")

      Hive::TaskMeta.update_display_name(dir, "Readable Name")

      assert_equal(
        { id: 7, slug: "keep-slug", display_name: "Readable Name", depends_on: "base-task", workflow: nil },
        Hive::TaskMeta.read(dir)
      )
    end
  end
end
