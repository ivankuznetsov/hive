require "test_helper"
require "hive/modules/migration/bounded_directory_entries"

class ModulesMigrationBoundedDirectoryEntriesTest < Minitest::Test
  include HiveTestHelper

  ENTRIES =
    Hive::Modules::Migration::BoundedDirectoryEntries

  def test_sorts_only_after_the_streaming_limit_is_proven
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      %w[zeta alpha].each do |name|
        path = File.join(root, name)
        File.binwrite(path, name)
        File.chmod(0o600, path)
      end

      assert_equal %w[alpha zeta],
                   ENTRIES.names(root, limit: 2)
      error = assert_raises(Hive::ConfigError) do
        ENTRIES.names(root, limit: 1)
      end
      assert_equal "bounded directory inventory is malformed",
                   error.message
    end
  end

  def test_rejects_an_unsafe_directory_before_enumeration
    with_tmp_dir do |root|
      File.chmod(0o777, root)

      assert_raises(Hive::ConfigError) do
        ENTRIES.names(root, limit: 1)
      end
    end
  end
end
