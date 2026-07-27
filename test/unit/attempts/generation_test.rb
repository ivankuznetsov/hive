require "test_helper"
require "hive/attempts/generation"

class AttemptsGenerationTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:id, :slug, :state_file, :stage_index, :stage_name, keyword_init: true)

  ProjectTask = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root,
    keyword_init: true
  )

  FolderTask = Struct.new(:folder, :state_file, keyword_init: true)

  def test_stable_task_id_stage_and_artifact_identity_form_generation
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "body\n<!-- WAITING -->\n")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 3, stage_name: "plan")

      first = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      second = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      next_stage = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "4-execute")

      assert_equal first.task_generation, second.task_generation
      assert_equal first.task_generation, first.ownership_generation
      assert_equal 0, first.task_input_epoch
      refute_equal first.task_generation, next_stage.task_generation
      assert_equal "id:42", first.task_locator
      assert_match(/\A[0-9a-f]{64}\z/, first.progress_token)
    end
  end


  def test_explicit_input_epoch_is_numeric_and_does_not_replace_ownership_generation
    task = FakeTask.new(id: 42, slug: "task-one", state_file: "/missing")
    generation = Hive::Attempts::Generation.resolve(
      task: task, project: "demo", intended_stage: "4-execute",
      ownership_generation: "opaque-owner", task_input_epoch: 9
    )

    assert_equal "opaque-owner", generation.task_generation
    assert_equal "opaque-owner", generation.ownership_generation
    assert_equal 9, generation.task_input_epoch
  end

  def test_legacy_locator_and_progress_change_are_deterministic
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "one")
      task = FakeTask.new(id: nil, slug: "legacy-task", state_file: state_file,
                          stage_index: 1, stage_name: "inbox")
      one = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")
      File.write(state_file, "two")
      two = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")

      assert_equal "project:demo/slug:legacy-task", one.task_locator
      refute_equal one.progress_token, two.progress_token
      refute_equal one.task_generation, two.task_generation
    end
  end

  def test_missing_and_unreadable_artifacts_have_stable_tokens
    with_tmp_dir do |dir|
      task = FakeTask.new(id: 1, slug: "missing", state_file: File.join(dir, "missing"))
      missing = Hive::Attempts::Generation.artifact_token(task)
      assert_match(/\A[0-9a-f]{64}\z/, missing)

      File.write(task.state_file, "body")
      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        unreadable = Hive::Attempts::Generation.artifact_token(task)
        assert_match(/\A[0-9a-f]{64}\z/, unreadable)
        refute_equal missing, unreadable
      end
    end
  end

  def test_dependency_admission_change_advances_generation
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "unchanged")
      task = ProjectTask.new(
        id: 42, slug: "dependent", state_file: state_file,
        stage_index: 4, stage_name: "execute", project_root: dir
      )
      fingerprint = "wait"
      resolver = ->(_task) { fingerprint }

      with_replaced_singleton_method(Hive::DependencySnapshot, :admission_fingerprint, resolver) do
        waiting = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )
        same_wait = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )
        fingerprint = "clear"
        clear = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )

        assert_equal waiting.task_generation, same_wait.task_generation
        refute_equal waiting.progress_token, clear.progress_token
        refute_equal waiting.task_generation, clear.task_generation
      end
    end
  end

  def test_downstream_attempt_uses_current_journal_task_generation
    with_tmp_dir do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "pr.md")
      File.write(state_file, "body")
      record = Hive::TaskJournal::Envelope.authoritative(
        {
          event_type: "implementation_identity_captured",
          task: { "id" => "42", "slug" => "task-one" }, workflow: "coding",
          stage: "4-execute", attempt_id: "attempt-1", task_generation: 7,
          ownership_generation: "owner-7", commit_generation: 0,
          reason: "execute_identity_captured", evidence: [], provenance: {}, payload: {}
        }
      )
      File.write(
        File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME),
        "#{JSON.generate(record)}\n"
      )
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      create_running_attempt(
        store,
        attempt_id: "attempt-1", task_id: "42", project: "demo", task_slug: "task-one",
        intended_stage: "4-execute", task_generation: "owner-7",
        ownership_generation: "owner-7", task_input_epoch: 7,
        progress_token: "progress-attempt-1", provider: "codex"
      )
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")

      generation = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "5-open-pr", attempt_store: store
      )

      assert_equal 7, generation.task_input_epoch
    end
  end

  def test_downstream_generation_rejects_malformed_or_unbound_journal
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "body")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")
      journal = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))

      File.write(journal, "not-json\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::Attempts::Generation.current_task_input_epoch(task, attempt_store: store)
      end

      record = Hive::TaskJournal::Envelope.authoritative(
        {
          event_type: "implementation_identity_captured",
          task: { "id" => "42", "slug" => "task-one" }, workflow: "coding",
          stage: "4-execute", attempt_id: "missing-attempt", task_generation: 7,
          ownership_generation: "owner-7", commit_generation: 0,
          reason: "execute_identity_captured", evidence: [], provenance: {}, payload: {}
        }
      )
      File.write(journal, "#{JSON.generate(record)}\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::Attempts::Generation.current_task_input_epoch(task, attempt_store: store)
      end
    end
  end

  def test_downstream_generation_propagates_journal_read_failure
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "body")
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "{}\n")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")

      with_replaced_singleton_method(File, :readlines, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
        assert_raises(Errno::EACCES) do
          Hive::Attempts::Generation.current_task_input_epoch(task)
        end
      end
    end
  end

  def test_current_input_epoch_uses_task_folder_and_rejects_empty_journal
    with_tmp_dir do |dir|
      nested_state = File.join(dir, "elsewhere", "pr.md")
      task = FolderTask.new(folder: dir, state_file: nested_state)
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "")

      error = assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::Attempts::Generation.current_task_input_epoch(task)
      end

      assert_match(/exists but is empty/, error.message)
    end
  end

  def test_current_input_epoch_builds_default_read_only_attempt_store
    with_tmp_dir do |dir|
      task = FolderTask.new(folder: dir, state_file: File.join(dir, "pr.md"))
      attempt_root = File.join(dir, "attempts")
      store = Hive::Attempts::Store.new(root: attempt_root)
      create_running_attempt(
        store,
        attempt_id: "attempt-3", task_id: "42", project: "demo", task_slug: "task",
        intended_stage: "4-execute", task_generation: "owner-3",
        ownership_generation: "owner-3", task_input_epoch: 3,
        progress_token: "progress-attempt-3", provider: "codex"
      )
      record = Hive::TaskJournal::Envelope.authoritative(
        {
          event_type: "generation_advanced", task: { "id" => "42", "slug" => "task" },
          workflow: "coding", stage: "4-execute", attempt_id: "attempt-3", task_generation: 3,
          ownership_generation: "owner-3", commit_generation: 0, reason: "input_changed",
          evidence: [], provenance: {}, payload: {}
        }
      )
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "#{JSON.generate(record)}\n")

      with_env("HIVE_ATTEMPT_STORE_ROOT" => attempt_root) do
        assert_equal 3, Hive::Attempts::Generation.current_task_input_epoch(task)
      end
    end
  end

  private

  def create_running_attempt(store, **attributes)
    now = Time.now.utc
    claim_capability = "c" * 64
    launching = store.create_launching(
      **attributes,
      request_id: "request-#{attributes.fetch(:attempt_id)}",
      predecessor_attempt_id: nil,
      worker_argv: [ "hive", "run", attributes.fetch(:task_slug) ],
      claim_capability_digest: Hive::Attempts::Capability.digest(claim_capability),
      starting_revision: nil,
      retry_charge: 0,
      inherited_outputs: [],
      launch_timeout_sec: 30,
      now: now
    )
    claimed = store.claim(
      launching, owner: current_owner, claim_capability: claim_capability,
      first_heartbeat_timeout_sec: 30, now: now
    )
    store.first_heartbeat(claimed, stale_sec: 30, now: now)
  end

  def current_owner
    {
      "pid" => Process.pid,
      "start_fingerprint" => "start",
      "session_id" => Process.getsid(0),
      "process_group_id" => Process.getpgrp
    }
  end
end
