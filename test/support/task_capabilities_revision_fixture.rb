require "hive/task_capabilities/revision"
require "hive/task_counter"

module TaskCapabilitiesRevisionFixture
  def with_revision(command: "ruby -e 'puts 42'", settings: {}, selections: [])
    with_tmp_dir do |dir|
      prepare_test_runtime_project(dir)
      code = File.join(dir, "code")
      FileUtils.mkdir_p(code)
      system("git", "init", "-q", code, exception: true)
      File.write(File.join(code, "README"), "example")
      system("git", "-C", code, "add", ".", exception: true)
      system("git", "-C", code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "initial", exception: true)
      folder = File.join(dir, ".hive-state/stages/3-plan/revision-task")
      task_id = Hive::TaskCounter.next_or_nil
      Hive::TaskMeta.write(folder, id: task_id, slug: "revision-task", display_name: nil)
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["review"]["ci"]["command"] = command
      yield_cfg = settings.delete(:configure)
      cfg["task_capabilities"].merge!(settings)
      yield_cfg&.call(cfg, dir)
      task = Struct.new(:folder, :project_root, :id, :slug, :workflow, :stage_name, :stage_index, :worktree_path, :state_file).new(
        folder, dir, task_id, "revision-task", Hive::Workflows::Coding::DESCRIPTOR, "plan", 3, code, File.join(folder, "task.md"))
      resolution = Hive::TaskCapabilities::Resolver.new(workflow: task.workflow, cfg: cfg, project_root: dir).resolve(
        task_identity: Hive::TaskMeta.stable_identity(Hive::TaskMeta.read(folder)), selections: selections)
      store = Hive::TaskCapabilities::Store.new(folder)
      Hive::TaskMeta.rewrite(folder, task_capabilities: resolution.plan.adoption)
      store.activate(resolution.plan, expected_version: nil, approvals: resolution.approvals)
      service = Hive::TaskCapabilities::Revision.new(task: task)
      attempts = Hive::Attempts::Repository.new(database: Hive::TaskCounter.database, root: File.join(dir, "attempt-payloads"))
      with_replaced_singleton_method(Hive::Attempts::Repository, :open_default, ->(**) { attempts }) do
        yield service, task, store, cfg
      end
    end
  end

  def expectation(service)
    service.show.fetch("expected").transform_keys(&:to_sym)
  end
end
