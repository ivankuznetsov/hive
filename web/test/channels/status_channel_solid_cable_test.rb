require "test_helper"
require "active_record/tasks/database_tasks"
require "support/status_channel_stream_lifecycle_contract"

class StatusChannelSolidCableTest < ActiveSupport::TestCase
  include ActionCableStreamLifecycleContract
  self.use_transactional_tests = false

  setup do
    @solid_cable_directory = Dir.mktmpdir("hive-status-channel-solid-cable")
    @solid_cable_database = File.join(@solid_cable_directory, "cable.sqlite3")
    template = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "cable")
    configuration = template.configuration_hash.merge(database: @solid_cable_database)
    @solid_cable_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test",
      "cable",
      configuration
    )
    @solid_cable_listener_threads = solid_cable_listener_threads

    SolidCable::Record.establish_connection(@solid_cable_config)
    pool = SolidCable::Record.connection_pool
    pool.with_connection do |connection|
      migration_verbose = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      begin
        with_replaced_singleton_method(
          ActiveRecord::Tasks::DatabaseTasks,
          :migration_connection_pool,
          -> { pool }
        ) do
          with_replaced_singleton_method(
            ActiveRecord::Tasks::DatabaseTasks,
            :migration_connection,
            -> { connection }
          ) do
            load Rails.root.join("db/cable_schema.rb")
          end
        end
      ensure
        ActiveRecord::Migration.verbose = migration_verbose
      end
    end
  end

  teardown do
    begin
      if SolidCable::Record.connected? && SolidCable::Message.table_exists?
        SolidCable::Message.delete_all
        assert_equal 0, SolidCable::Message.count
      end
    ensure
      begin
        SolidCable::Record.connection_pool.disconnect! if SolidCable::Record.connected?
      ensure
        begin
          SolidCable::Record.remove_connection
        ensure
          FileUtils.remove_entry(@solid_cable_directory) if File.exist?(@solid_cable_directory)
        end
      end
    end

    leaked_threads = solid_cable_listener_threads - @solid_cable_listener_threads
    assert_empty leaked_threads, "Solid Cable listener threads must be joined after every contract case"
  end

  private

  def stream_lifecycle_channel_class
    StatusChannel
  end

  def build_stream_lifecycle_environment
    assert_equal @solid_cable_database, SolidCable::Record.connection_db_config.database
    assert SolidCable::Message.table_exists?, "isolated Solid Cable schema must be loaded before the contract"
    super
  end

  def stream_lifecycle_adapter_name
    "solid_cable"
  end

  def stream_lifecycle_pending_entries(channel)
    channel.instance_variable_get(:@status_stream_attempts).to_a
  end

  def solid_cable_listener_threads
    Thread.list.select { |thread| thread.alive? && thread.name == "solid_cable_listener" }
  end
end
