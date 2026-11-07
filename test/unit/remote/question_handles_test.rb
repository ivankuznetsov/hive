require "test_helper"
require "hive/remote/question_handles"

class RemoteQuestionHandlesTest < Minitest::Test
  Task = Data.define(:id, :slug)

  def test_handles_survive_restart_retain_original_binding_and_reject_unknown_or_foreign_targets
    Dir.mktmpdir do |root|
      store = Hive::Remote::QuestionHandles.new(root: root)
      project = { "name" => "demo" }
      task = Task.new(id: 1, slug: "task")
      inventory = { "task" => { "project" => "demo", "id" => 1, "slug" => "task", "generation" => "a" * 64 },
                   "slots" => [ { "ordinal" => 1, "fingerprint" => "b" * 64, "binding" => "native-private-folder-binding", "text" => "Question?" } ] }
      slot = store.issue(project: project, task: task, inventory: inventory).first
      assert_equal slot, store.issue(project: project, task: task, inventory: inventory).first
      refute_includes JSON.generate(slot), "binding"
      record = Hive::Remote::QuestionHandles.new(root: root).resolve(handle: slot.fetch("handle"), project: project, task: task)
      assert_equal "native-private-folder-binding", record.fetch("binding")
      assert store.current!(record: record, inventory: inventory)
      changed = Marshal.load(Marshal.dump(inventory))
      changed["task"]["generation"] = "c" * 64
      assert_equal 409, assert_raises(Hive::Remote::Error) { store.current!(record: record, inventory: changed) }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve(handle: slot.fetch("handle"), project: project, task: Task.new(id: 2, slug: "other")) }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve(handle: "unknown", project: project, task: task) }.status
      assert_equal 0o600, File.stat(store.path).mode & 0o777
      assert_equal 0o700, File.stat(root).mode & 0o777
    end
  end
  def test_artifact_and_cursor_handles_bind_target_generation_and_authorized_projects
    Dir.mktmpdir do |root|
      store = Hive::Remote::QuestionHandles.new(root: root)
      project = { "name" => "demo" }
      task = Task.new(id: 1, slug: "task")
      handle = store.artifact(project: project, task: task, generation: "one", reference: "task.md")
      assert_equal handle, store.artifact(project: project, task: task, generation: "one", reference: "task.md")
      assert_equal "task.md", store.resolve_artifact(handle: handle, project: project, task: task, generation: "one")
      assert_equal 409, assert_raises(Hive::Remote::Error) { store.resolve_artifact(handle: handle, project: project, task: task, generation: "two") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve_artifact(handle: handle, project: { "name" => "private" }, task: task, generation: "one") }.status
      projects = [ [ "demo", "fingerprint" ] ]
      cursor = store.cursor(projects: projects, snapshot: "snapshot", offset: 10)
      assert_equal 10, store.resolve_cursor(handle: cursor, projects: projects, snapshot: "snapshot")
      assert_equal 409, assert_raises(Hive::Remote::Error) { store.resolve_cursor(handle: cursor, projects: projects, snapshot: "changed") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve_cursor(handle: cursor, projects: [], snapshot: "snapshot") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve(handle: cursor, project: project, task: task) }.status
    end
  end

  def test_evicted_handles_remain_known_stale_only_for_their_original_scope
    Dir.mktmpdir do |root|
      store = Hive::Remote::QuestionHandles.new(root: root, max_handles: 2)
      projects = [ [ "demo", "fingerprint" ] ]
      expired = store.cursor(projects: projects, snapshot: "one", offset: 1)
      5.times { |offset| store.cursor(projects: projects, snapshot: "two", offset: offset) }
      assert_equal 2, JSON.parse(File.read(store.path)).fetch("handles").length
      store = Hive::Remote::QuestionHandles.new(root: root)
      assert_equal 409, assert_raises(Hive::Remote::Error) { store.resolve_cursor(handle: expired, projects: projects, snapshot: "one") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve_cursor(handle: expired, projects: [], snapshot: "one") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve_cursor(handle: "0" * 64, projects: projects, snapshot: "one") }.status
    end
  end

  def test_byte_pressure_evicts_records_while_preserving_stale_artifact_identity
    Dir.mktmpdir do |root|
      store = Hive::Remote::QuestionHandles.new(root: root)
      project = { "name" => "demo" }
      task = Task.new(id: 1, slug: "task")
      oversized = "x" * Hive::Remote::QuestionHandles::MAX_REGISTRY_BYTES
      handle = store.artifact(project: project, task: task, generation: "one", reference: oversized)
      assert_operator File.size(store.path), :<=, Hive::Remote::QuestionHandles::MAX_REGISTRY_BYTES
      assert_equal 409, assert_raises(Hive::Remote::Error) { store.resolve_artifact(handle: handle, project: project, task: task, generation: "one") }.status
      assert_equal 404, assert_raises(Hive::Remote::Error) { store.resolve_artifact(handle: handle, project: { "name" => "other" }, task: task, generation: "one") }.status
    end
  end

  def test_registry_fails_closed_on_corruption_future_versions_and_exposed_permissions
    Dir.mktmpdir do |root|
      store = Hive::Remote::QuestionHandles.new(root: root)
      store.cursor(projects: [], snapshot: "one", offset: 1)
      File.write(store.path, "not JSON")
      assert_raises(Hive::ConfigError) { store.cursor(projects: [], snapshot: "two", offset: 2) }
      File.write(store.path, JSON.generate({ "schema_version" => 2, "handles" => {} }))
      error = assert_raises(Hive::ConfigError) { store.cursor(projects: [], snapshot: "two", offset: 2) }
      assert_includes error.message, "upgrade"
      File.write(store.path, JSON.generate({ "schema_version" => 1, "handles" => [] }))
      assert_raises(Hive::ConfigError) { store.cursor(projects: [], snapshot: "two", offset: 2) }
      File.chmod(0o644, store.path)
      assert_raises(Hive::ConfigError) { store.cursor(projects: [], snapshot: "two", offset: 2) }
    end
  end

  def test_handle_directory_and_lock_refuse_symlinks
    Dir.mktmpdir do |root|
      owned = File.join(root, "owned")
      FileUtils.mkdir_p(owned)
      link = File.join(root, "link")
      File.symlink(owned, link)
      assert_raises(Hive::ConfigError) do
        Hive::Remote::QuestionHandles.new(root: link).cursor(projects: [], snapshot: "one", offset: 1)
      end
      target = File.join(root, "lock-target")
      File.write(target, "")
      File.symlink(target, File.join(owned, ".read-handles.lock"))
      assert_raises(Hive::ConfigError) do
        Hive::Remote::QuestionHandles.new(root: owned).cursor(projects: [], snapshot: "one", offset: 1)
      end
    end
  end
end
