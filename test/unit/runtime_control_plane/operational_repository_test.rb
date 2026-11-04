require "test_helper"
require "hive/runtime_control_plane"

class RuntimeOperationalRepositoryTest < Minitest::Test
  include HiveTestHelper

  def test_snapshot_encoding_precedes_sql_and_projection_stays_bound
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      repository = Hive::RuntimeControlPlane::OperationalRepository.new(database: database)
      snapshot = { "phase" => "complete", "tick_sequence" => 7, "daemon" => { "pid" => 42 } }
      projection = { "tick_sequence" => 7, "daemon" => { "pid" => 42 } }
      acquired = false
      original_transaction = database.method(:transaction)
      database.define_singleton_method(:transaction) do |**options, &block|
        original_transaction.call(**options) do |db|
          acquired = true
          block.call(db)
        ensure
          acquired = false
        end
      end
      codec = Hive::RuntimeControlPlane::Codec
      original_encoder = codec.method(:dump_json)
      testcase = self
      encoder = lambda do |document|
        testcase.refute acquired, "snapshot preparation must precede lock acquisition" if document.key?("snapshot")
        original_encoder.call(document)
      end
      with_replaced_singleton_method(codec, :dump_json, encoder) do
        repository.publish(snapshot, status_projection: projection)
      end
      assert_equal snapshot, repository.snapshot
      assert_equal projection, repository.status_projection
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        repository.publish(snapshot, status_projection: projection.merge("tick_sequence" => 8))
      end
      assert_equal projection, repository.status_projection
    ensure
      database&.disconnect
    end
  end
end
