require "test_helper"
require "hive/recovery/migration"

class RecoveryMigrationTest < Minitest::Test
  def test_loading_explicit_migration_does_not_load_the_legacy_decoder
    script = <<~RUBY
      $LOAD_PATH.unshift #{File.expand_path("../../../lib", __dir__).inspect}
      require "hive/recovery/migration"
      abort "legacy decoder loaded" if $LOADED_FEATURES.any? { |path| path.end_with?("runtime_control_plane/legacy_import.rb") }
    RUBY
    assert system(RbConfig.ruby, "-e", script)
  end

  def test_attempt_layout_state_machine_is_deleted
    refute Hive::Recovery::Migration.const_defined?(:CHECKPOINT_SCHEMA)
    refute Hive::Recovery::Migration.respond_to?(:ensure!)
  end

  def test_inventory_is_the_only_lazy_legacy_decoder_entrypoint
    calls = 0
    importer = Object.new
    importer.define_singleton_method(:call) { calls += 1; :inventory }
    factory = ->(**) { importer }
    original = nil
    require "hive/runtime_control_plane/legacy_import"
    original = Hive::RuntimeControlPlane::LegacyImport.method(:new)
    Hive::RuntimeControlPlane::LegacyImport.define_singleton_method(:new, factory)

    assert_equal :inventory, Hive::Recovery::Migration.inventory_runtime(state_home: "/state", data_home: "/data")
    assert_equal 1, calls
  ensure
    Hive::RuntimeControlPlane::LegacyImport.define_singleton_method(:new, original) if original
  end
end
