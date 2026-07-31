require "test_helper"
require "fileutils"
require "tmpdir"
require "hive/modules/migration/qualification_target_inventory"

class ModulesMigrationQualificationTargetInventoryTest <
    Minitest::Test
  INVENTORY =
    Hive::Modules::Migration::QualificationTargetInventory

  def test_identity_is_root_independent_and_order_stable
    snapshots = 2.times.map do |index|
      Dir.mktmpdir("qualification-inventory-#{index}") do |root|
        File.chmod(0o700, root)
        paths =
          index.zero? ?
            [ [ "lib/hive.rb", "module Hive; end\n" ],
              [ "bin/hive", "#!/usr/bin/env ruby\n" ] ] :
            [ [ "bin/hive", "#!/usr/bin/env ruby\n" ],
              [ "lib/hive.rb", "module Hive; end\n" ] ]
        paths.each do |relative, bytes|
          path = File.join(root, relative)
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          File.binwrite(path, bytes)
          File.chmod(
            relative == "bin/hive" ? 0o700 : 0o600,
            path
          )
        end
        INVENTORY.new.call(root)
      end
    end

    assert_equal snapshots.fetch(0).digest,
                 snapshots.fetch(1).digest
    assert_equal snapshots.fetch(0).entries,
                 snapshots.fetch(1).entries
    assert_equal 2, snapshots.fetch(0).file_count
    assert snapshots.fetch(0).frozen?
    assert snapshots.fetch(0).entries.frozen?
  end

  def test_detects_add_delete_content_and_mode_changes
    Dir.mktmpdir("qualification-inventory-drift") do |root|
      File.chmod(0o700, root)
      file = File.join(root, "candidate.rb")
      File.binwrite(file, "one\n")
      File.chmod(0o600, file)
      subject = INVENTORY.new
      baseline = subject.call(root).digest

      File.binwrite(file, "two\n")
      refute_equal baseline, subject.call(root).digest
      File.binwrite(file, "one\n")
      File.chmod(0o700, file)
      refute_equal baseline, subject.call(root).digest
      File.chmod(0o600, file)
      extra = File.join(root, "extra")
      File.binwrite(extra, "extra\n")
      File.chmod(0o600, extra)
      refute_equal baseline, subject.call(root).digest
      File.unlink(extra)
      assert_equal baseline, subject.call(root).digest
      File.unlink(file)
      refute_equal baseline, subject.call(root).digest
    end
  end

  def test_rejects_symlink_hardlink_fifo_and_bounds
    mutations = {
      symlink: lambda do |root|
        File.symlink("/dev/null", File.join(root, "entry"))
      end,
      hardlink: lambda do |root|
        source = File.join(root, "source")
        File.binwrite(source, "bytes")
        File.chmod(0o600, source)
        File.link(source, File.join(root, "entry"))
      end,
      fifo: lambda do |root|
        File.mkfifo(File.join(root, "entry"), 0o600)
      end
    }
    mutations.each do |name, mutation|
      Dir.mktmpdir("qualification-inventory-#{name}") do |root|
        File.chmod(0o700, root)
        mutation.call(root)
        assert_raises(
          Hive::ConfigError,
          "expected #{name} to fail"
        ) do
          INVENTORY.new.call(root)
        end
      end
    end

    Dir.mktmpdir("qualification-inventory-bounds") do |root|
      File.chmod(0o700, root)
      2.times do |index|
        path = File.join(root, "file-#{index}")
        File.binwrite(path, "x")
        File.chmod(0o600, path)
      end
      assert_raises(Hive::ConfigError) do
        INVENTORY.new(max_entries: 1).call(root)
      end
      assert_raises(Hive::ConfigError) do
        INVENTORY.new(max_total_bytes: 1).call(root)
      end
    end
  end
end
