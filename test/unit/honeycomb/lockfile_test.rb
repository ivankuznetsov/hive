require "test_helper"
require "hive/honeycomb/lockfile"

class HoneycombLockfileTest < Minitest::Test
  include HiveTestHelper

  def test_round_trips_sorted_entries_deterministically
    with_tmp_dir do |dir|
      path = File.join(dir, ".honeycomb.lock")
      lockfile = Hive::Honeycomb::Lockfile.new(path)
      entries = {
        "zeta" => entry("zeta", sha: "f" * 40),
        "alpha" => entry("alpha", sha: "a" * 40)
      }

      lockfile.write(entries)
      first = File.binread(path)
      loaded = lockfile.read
      lockfile.write(loaded.reverse_each.to_h)

      assert_equal %w[alpha zeta], loaded.keys
      assert_equal first, File.binread(path)
      assert_equal "a" * 40, loaded.fetch("alpha").sha
      assert_equal %w[instructions/work.md workflow.yml], loaded.fetch("alpha").files.keys
      assert_equal "permissions: workflows/.honeycomb.lock#workflows.alpha.security",
                   loaded.fetch("alpha").permissions_pointer
    end
  end

  def test_missing_lock_is_empty_but_malformed_lock_is_not
    with_tmp_dir do |dir|
      path = File.join(dir, ".honeycomb.lock")
      lockfile = Hive::Honeycomb::Lockfile.new(path)
      assert_empty lockfile.read

      File.write(path, "version: 99\n")
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.read }
    end
  end

  def test_rejects_unknown_keys_duplicate_names_and_unsafe_inventory
    with_tmp_dir do |dir|
      path = File.join(dir, ".honeycomb.lock")
      lockfile = Hive::Honeycomb::Lockfile.new(path)
      lockfile.write("demo" => entry("demo"))
      data = YAML.safe_load(File.read(path))

      data["workflows"]["demo"]["extra"] = true
      File.write(path, data.to_yaml)
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.read }

      data["workflows"]["demo"].delete("extra")
      data["workflows"]["demo"]["files"] = { "../escape" => "a" * 64 }
      File.write(path, data.to_yaml)
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.read }
    end
  end

  def test_rejects_remaining_entry_and_serialization_shapes
    with_tmp_dir do |dir|
      path = File.join(dir, ".honeycomb.lock")
      lockfile = Hive::Honeycomb::Lockfile.new(path)

      invalid_fields = {
        "version" => "not-semver",
        "tag" => 12,
        "sha" => "XYZ",
        "name" => "Bad Name"
      }
      invalid_fields.each do |field, value|
        lockfile.write("demo" => entry("demo"))
        data = YAML.safe_load(File.read(path))
        data["workflows"]["demo"][field] = value
        File.write(path, data.to_yaml)
        assert_raises(Hive::Honeycomb::LockfileError, field) { lockfile.read }
      end

      lockfile.write("demo" => entry("demo"))
      data = YAML.safe_load(File.read(path))
      data["workflows"]["demo"]["modes"]["workflow.yml"] = "120000"
      File.write(path, data.to_yaml)
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.read }

      mismatched = entry("other")
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.write("demo" => mismatched) }
      unsupported = entry("demo").with(security: { "object" => Object.new })
      assert_raises(Hive::Honeycomb::LockfileError) { lockfile.write("demo" => unsupported) }
    end
  end

  def test_wraps_lockfile_read_io_errors
    with_tmp_dir do |dir|
      path = File.join(dir, ".honeycomb.lock")
      File.write(path, "present\n")
      lockfile = Hive::Honeycomb::Lockfile.new(path)

      with_replaced_singleton_method(File, :binread, ->(_path) { raise Errno::EACCES, "denied" }) do
        assert_raises(Hive::Honeycomb::LockfileError) { lockfile.read }
      end
    end
  end

  private

  def entry(name, sha: "1" * 40)
    Hive::Honeycomb::LockEntry.new(
      source: Hive::Honeycomb::SOURCE,
      name: name,
      sha: sha,
      version: "1.0.0",
      tag: "#{name}/v1.0.0",
      selector_kind: "latest",
      selector_value: nil,
      digest: "d" * 64,
      files: { "instructions/work.md" => "b" * 64, "workflow.yml" => "a" * 64 },
      modes: { "instructions/work.md" => "100644", "workflow.yml" => "100644" },
      security: {
        "summary" => { "presets" => [ "scoped" ], "tools" => [ "Read" ], "dirs" => [],
                       "bash" => false, "yolo" => false, "shell_capable" => false, "locations" => [] },
        "findings" => []
      }
    )
  end
end
