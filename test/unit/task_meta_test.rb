require "test_helper"
require "hive/task_meta"

class TaskMetaTest < Minitest::Test
  include HiveTestHelper

  def test_write_and_read_round_trip
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo")

      assert_equal({ id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: nil }, Hive::TaskMeta.read(dir))
      assert File.exist?(File.join(dir, "meta.yml"))
      refute Dir.children(dir).any? { |name| name.include?(".meta.yml.tmp") }
    end
  end

  def test_write_and_read_round_trip_with_dependency
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: "base-task")

      assert_equal(
        { id: 42, slug: "add-foo", display_name: "Add Foo", depends_on: "base-task" },
        Hive::TaskMeta.read(dir)
      )
      assert_includes File.read(File.join(dir, "meta.yml")), "depends_on: base-task"
    end
  end

  def test_missing_or_malformed_file_returns_nil_fields
    with_tmp_dir do |dir|
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), ":\n:not yaml")
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), "- not\n- a hash\n")
      assert_equal({ id: nil, slug: nil, display_name: nil, depends_on: nil }, Hive::TaskMeta.read(dir))
    end
  end

  def test_read_coerces_numeric_string_id_and_drops_unparseable_id
    with_tmp_dir do |dir|
      File.write(File.join(dir, "meta.yml"), "id: '42'\nslug: from-string-id\n")
      # A YAML-quoted numeric string id is coerced to an Integer via Integer().
      assert_equal({ id: 42, slug: "from-string-id", display_name: nil, depends_on: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), "id: not-a-number\nslug: bad-id\n")
      # An unparseable, non-empty id falls back to nil (ArgumentError rescue).
      assert_equal({ id: nil, slug: "bad-id", display_name: nil, depends_on: nil }, Hive::TaskMeta.read(dir))
    end
  end

  def test_update_display_name_preserves_id_slug_and_dependency
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 7, slug: "keep-slug", display_name: nil, depends_on: "base-task")

      Hive::TaskMeta.update_display_name(dir, "Readable Name")

      assert_equal(
        { id: 7, slug: "keep-slug", display_name: "Readable Name", depends_on: "base-task" },
        Hive::TaskMeta.read(dir)
      )
    end
  end
end
