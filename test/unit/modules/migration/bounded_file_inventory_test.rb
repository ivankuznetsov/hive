require "test_helper"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"

class ModulesMigrationBoundedFileInventoryTest < Minitest::Test
  include HiveTestHelper

  PATTERN = /\A[0-9a-f]{4}\.json\z/

  def test_pages_in_lexicographic_order_independent_of_directory_order
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      directory.prepare!
      %w[0003.json 0001.json 0004.json 0002.json].each do |name|
        directory.atomic_write(name, name)
      end
      inventory = inventory_for(directory)

      first = inventory.page(limit: 2)
      assert_equal %w[0001.json 0002.json], first.names
      assert_match(/\Ainventory-v1\./, first.next_cursor)

      restarted = inventory_for(
        Hive::ManagedDirectory.new(root: root, label: "inventory")
      )
      second = restarted.page(limit: 2, cursor: first.next_cursor)
      assert_equal %w[0003.json 0004.json], second.names
      assert_nil second.next_cursor
    end
  end

  def test_cursor_freezes_a_high_water_mark_and_detects_earlier_changes
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      %w[0001.json 0003.json].each do |name|
        directory.atomic_write(name, name)
      end
      inventory = inventory_for(directory)
      first = inventory.page(limit: 1)

      directory.atomic_write("0004.json", "later")
      second = inventory.page(limit: 1, cursor: first.next_cursor)
      assert_equal [ "0003.json" ], second.names
      assert_nil second.next_cursor

      directory.atomic_write("0002.json", "inside snapshot")
      assert_raises(Hive::ConfigError) do
        inventory.page(limit: 1, cursor: first.next_cursor)
      end
    end

    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      %w[0001.json 0003.json].each do |name|
        directory.atomic_write(name, name)
      end
      inventory = inventory_for(directory)
      first = inventory.page(limit: 1)

      File.unlink(File.join(root, "0001.json"))
      directory.atomic_write("0002.json", "replacement")
      assert_raises(Hive::ConfigError) do
        inventory.page(limit: 1, cursor: first.next_cursor)
      end
    end
  end

  def test_rejects_foreign_or_malformed_cursors_and_invalid_limits
    with_tmp_dir do |root|
      first_root = File.join(root, "first")
      second_root = File.join(root, "second")
      first_directory = Hive::ManagedDirectory.new(
        root: first_root, anchor: root, label: "inventory"
      )
      second_directory = Hive::ManagedDirectory.new(
        root: second_root, anchor: root, label: "inventory"
      )
      %w[0001.json 0002.json].each do |name|
        first_directory.atomic_write(name, name)
        second_directory.atomic_write(name, name)
      end
      cursor = inventory_for(first_directory).page(limit: 1).next_cursor

      assert_raises(Hive::ConfigError) do
        inventory_for(second_directory).page(limit: 1, cursor: cursor)
      end
      assert_raises(Hive::ConfigError) do
        inventory_for(first_directory).page(limit: 1, cursor: "inventory-v1.bad")
      end
      assert_raises(Hive::ConfigError) do
        inventory_for(first_directory).page(limit: 0)
      end
    end
  end

  def test_rejects_unexpected_names_and_excess_before_returning_a_page
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      directory.atomic_write("unexpected", "bad")
      assert_raises(Hive::ConfigError) do
        inventory_for(directory).page(limit: 1)
      end
    end

    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      %w[0001.json 0002.json 0003.json].each do |name|
        directory.atomic_write(name, name)
      end
      assert_raises(Hive::ConfigError) do
        inventory_for(directory, max_entries: 2).snapshot
      end
    end
  end

  def test_rejects_malformed_inventory_configuration
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "inventory")
      error = assert_raises(Hive::ConfigError) do
        inventory_for(directory, max_entries: Object.new)
      end
      assert_equal "inventory is malformed", error.message
    end
  end

  private

  def inventory_for(directory, max_entries: 8)
    Hive::Modules::Migration::BoundedFileInventory.new(
      directory: directory,
      relative: ".",
      filename_pattern: PATTERN,
      max_entries: max_entries,
      cursor_prefix: "inventory-v1",
      malformed_message: "inventory is malformed",
      overflow_message: "inventory is too large"
    )
  end
end
