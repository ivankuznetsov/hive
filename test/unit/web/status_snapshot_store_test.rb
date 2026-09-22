require "test_helper"
require "hive/web/status_snapshot_store"

class StatusSnapshotStoreTest < Minitest::Test
  include HiveTestHelper

  def test_saved_page_data_round_trips_and_rejects_corrupt_or_relocated_history
    Dir.mktmpdir do |dir|
      path = File.join(dir, "status.json")
      store = Hive::Web::StatusSnapshotStore.new(path: path)
      project = { "name" => "demo", "path" => "/demo", "tasks" => [] }
      payload = { "projects" => [ project ], "project_archives" => { "demo" => project },
        "board_metadata" => { "demo" => { "workflows" => { "coding" => [ { "dir" => "9-done", "name" => "done" } ], "missing" => nil } } },
        "daemon_status" => { "running" => true } }
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        store.write(payload, last_success_at: "2026-07-25T12:00:00Z")
        assert_equal payload, store.read.fetch("payload")
        good = JSON.parse(File.read(path))
        [ payload.merge("project_archives" => []),
          payload.merge("project_archives" => { "demo" => project.merge("path" => "/old") }),
          payload.merge("project_archives" => { "demo" => project.merge("tasks" => [ nil ]) }),
          payload.merge("daemon_status" => nil),
          payload.merge("board_metadata" => { "demo" => { "workflows" => { "coding" => [ { "dir" => 9 } ] } } }) ].each do |invalid|
          File.write(path, JSON.generate(good.merge("payload" => invalid)))
          assert_nil store.read, "invalid saved page data must fall back to cold loading"
        end
      end
    end
  end
  def test_round_trip_is_private_and_scoped_to_registered_projects
    Dir.mktmpdir do |dir|
      path = File.join(dir, "status.json")
      store = Hive::Web::StatusSnapshotStore.new(path: path)
      projects = [ { "name" => "demo", "path" => "/demo" } ]
      payload = { "projects" => [ { "name" => "demo", "path" => "/demo", "tasks" => [ { "slug" => "saved-task" } ] } ] }
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
        assert_nil store.read
        store.write(payload, last_success_at: "2026-07-25T12:00:00Z")
        assert_equal payload, store.read.fetch("payload")
        assert_equal 0o600, File.stat(path).mode & 0o777
      end
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) { assert_nil store.read }
    end
  end

  def test_future_invalid_and_oversized_documents_are_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, "status.json")
      store = Hive::Web::StatusSnapshotStore.new(path: path)
      store.write({ "projects" => [] }, last_success_at: "2026-07-25T12:00:00Z")
      good = JSON.parse(File.read(path))
      [ good.merge("last_success_at" => "not a time"),
        good.merge("last_success_at" => "2999-01-01T00:00:00Z"),
        good.merge("payload" => { "projects" => [ nil ] }) ].each do |document|
        File.write(path, JSON.generate(document))
        assert_nil store.read
      end
      File.write(path, JSON.generate(good).ljust(Hive::Web::StatusSnapshotStore::MAX_BYTES + 1))
      assert_nil store.read
    end
  end

  def test_rows_from_a_different_registry_cannot_be_persisted
    Dir.mktmpdir do |dir|
      store = Hive::Web::StatusSnapshotStore.new(path: File.join(dir, "status.json"))
      registry = [ { "name" => "old", "path" => "/old" } ]
      payload = { "projects" => [ { "name" => "new", "path" => "/new", "tasks" => [] } ] }
      store.write(payload, projects: registry, last_success_at: "2026-07-25T12:00:00Z")
      assert_nil store.read
      payload = { "projects" => [ registry.first.merge("hive_state_path" => "/moved-state") ] }
      store.write(payload, projects: registry, last_success_at: "2026-07-25T12:00:00Z")
      assert_nil store.read
    end
  end

  def test_invalid_cache_is_ignored_and_failed_write_preserves_previous_snapshot
    Dir.mktmpdir do |dir|
      path = File.join(dir, "status.json")
      store = Hive::Web::StatusSnapshotStore.new(path: path)
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        [ "{", "null", JSON.generate("schema" => 99) ].each do |bytes|
          File.write(path, bytes)
          assert_nil store.read
        end
        payload = { "projects" => [] }
        store.write(payload, last_success_at: "2026-07-25T12:00:00Z")
        with_replaced_singleton_method(Hive::AtomicFile, :write, ->(*) { raise IOError, "disk unavailable" }) do
          store.write(payload.merge("generated_at" => "new"), last_success_at: "2026-07-25T12:01:00Z")
        end
        assert_equal payload, store.read.fetch("payload")
      end
    end
  end
end
