require "test_helper"
require "hive/task_meta"

class TaskMetaTest < Minitest::Test
  include HiveTestHelper

  def test_write_and_read_round_trip
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 42, slug: "add-foo", display_name: "Add Foo")

      assert_equal({ id: 42, slug: "add-foo", display_name: "Add Foo" }, Hive::TaskMeta.read(dir))
      assert File.exist?(File.join(dir, "meta.yml"))
      refute Dir.children(dir).any? { |name| name.include?(".meta.yml.tmp") }
    end
  end

  def test_missing_or_malformed_file_returns_nil_fields
    with_tmp_dir do |dir|
      assert_equal({ id: nil, slug: nil, display_name: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), ":\n:not yaml")
      assert_equal({ id: nil, slug: nil, display_name: nil }, Hive::TaskMeta.read(dir))

      File.write(File.join(dir, "meta.yml"), "- not\n- a hash\n")
      assert_equal({ id: nil, slug: nil, display_name: nil }, Hive::TaskMeta.read(dir))
    end
  end

  def test_update_display_name_preserves_id_and_slug
    with_tmp_dir do |dir|
      Hive::TaskMeta.write(dir, id: 7, slug: "keep-slug", display_name: nil)

      Hive::TaskMeta.update_display_name(dir, "Readable Name")

      assert_equal({ id: 7, slug: "keep-slug", display_name: "Readable Name" }, Hive::TaskMeta.read(dir))
    end
  end
end
