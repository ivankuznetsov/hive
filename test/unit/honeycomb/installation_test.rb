require "test_helper"
require "digest"
require "hive/honeycomb/installation"

class HoneycombInstallationTest < Minitest::Test
  include HiveTestHelper

  def test_classifies_clean_modified_missing_extra_and_type_changed_installs
    with_tmp_dir do |workflows|
      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "workflow.yml"), "descriptor\n")
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "instructions", "work.md"), "work\n")
      entry = entry_for(root)
      installation = Hive::Honeycomb::Installation.new(workflows)

      assert_equal "clean", installation.inspect(entry).state

      File.write(File.join(root, "workflow.yml"), "changed\n")
      assert_equal "dirty", installation.inspect(entry).state
      File.write(File.join(root, "workflow.yml"), "descriptor\n")

      FileUtils.rm_f(File.join(root, "instructions", "work.md"))
      assert_equal [ "instructions/work.md" ], installation.inspect(entry).missing
      File.write(File.join(root, "instructions", "work.md"), "work\n")

      File.write(File.join(root, "extra.txt"), "extra\n")
      assert_equal "extra_file", installation.inspect(entry).state
      FileUtils.rm_f(File.join(root, "extra.txt"))

      FileUtils.rm_f(File.join(root, "workflow.yml"))
      FileUtils.mkdir_p(File.join(root, "workflow.yml"))
      assert_equal [ "workflow.yml" ], installation.inspect(entry).type_changed

      FileUtils.rm_rf(root)
      File.symlink(dir = File.join(workflows, "outside"), root)
      FileUtils.mkdir_p(dir)
      assert_equal [ "." ], installation.inspect(entry).type_changed
    end
  end

  def test_classifies_absent_and_unmanaged_collisions
    with_tmp_dir do |workflows|
      installation = Hive::Honeycomb::Installation.new(workflows)
      entry = Hive::Honeycomb::LockEntry.new(**entry_values("demo", {}))
      assert_equal "missing", installation.inspect(entry).state

      File.write(File.join(workflows, "demo.yml"), "authored\n")
      FileUtils.mkdir_p(File.join(workflows, "demo"))
      assert_equal [ File.join(workflows, "demo.yml"), File.join(workflows, "demo") ],
                   installation.unmanaged_collisions("demo")
    end
  end

  def test_classifies_special_ancestor_and_extra_special_paths
    with_tmp_dir do |workflows|
      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      File.symlink("outside", File.join(root, "link"))
      entry = Hive::Honeycomb::LockEntry.new(**entry_values("demo", { "link/child.md" => "a" * 64 }))

      inspection = Hive::Honeycomb::Installation.new(workflows).inspect(entry)

      assert_equal "dirty", inspection.state
      assert_equal [ "link/child.md" ], inspection.type_changed
    end
  end

  def test_disk_inventory_tolerates_directory_disappearance
    with_tmp_dir do |workflows|
      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      installation = Hive::Honeycomb::Installation.new(workflows)
      original = Dir.method(:children)
      Dir.define_singleton_method(:children) do |path|
        raise Errno::ENOENT, path if path == root
        original.call(path)
      end

      assert_equal [ [], [] ], installation.send(:disk_inventory, root)
    ensure
      Dir.define_singleton_method(:children, original) if original
    end
  end

  private

  def entry_for(root)
    files = %w[workflow.yml instructions/work.md].to_h do |path|
      [ path, Digest::SHA256.file(File.join(root, path)).hexdigest ]
    end
    Hive::Honeycomb::LockEntry.new(**entry_values("demo", files))
  end

  def entry_values(name, files)
    {
      source: Hive::Honeycomb::SOURCE, name: name, sha: "1" * 40, version: "1.0.0",
      tag: "demo/v1.0.0", selector_kind: "latest", selector_value: nil, digest: "d" * 64,
      files: files, modes: files.keys.to_h { |path| [ path, "100644" ] },
      security: { "summary" => {}, "findings" => [] }
    }
  end
end
