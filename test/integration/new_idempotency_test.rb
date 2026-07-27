require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/workflow"
require "hive/task_meta"

class NewIdempotencyTest < Minitest::Test
  include HiveTestHelper

  def test_error_kind_maps_config_concurrency_and_internal_failures
    command = Hive::Commands::New.new("project", "task", idempotency_key: "key", json: true)
    cases = [
      [ Hive::ConfigError.new("config"), "config" ],
      [ Hive::Commands::New::ProjectConfigUnreadable.new("config"), "config" ],
      [ Hive::Commands::New::UnregisteredProjectWorkflow.new("config"), "config" ],
      [ Hive::ConcurrentRunError.new("busy"), "concurrent_run" ],
      [ Hive::InternalError.new("internal"), "internal" ],
      [ RuntimeError.new("other"), "error" ]
    ]

    cases.each do |error, kind|
      assert_equal kind, command.envelope_error_kind(error)
    end
  end

  def test_retry_returns_original_task_after_it_moves
    with_initialized_project do |project_root, project|
      first = create_json(
        project, "draft launch post", key: "workflow-creator:editorial:v1", slug: "editorial-task"
      )
      assert_equal true, first.fetch("created")
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "editorial-task")
      Hive::Commands::Approve.new(
        folder, to: "2-brainstorm", from: "1-inbox", force: true, quiet: true
      ).call

      retry_payload = create_json(
        project, "draft launch post", key: "workflow-creator:editorial:v1", slug: "editorial-task"
      )

      assert_equal false, retry_payload.fetch("created")
      assert_equal "editorial-task", retry_payload.fetch("slug")
      assert_equal "2-brainstorm", retry_payload.fetch("current_stage")
      assert_equal 1, idempotent_tasks(project_root).size
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new"))))
      assert_empty schemer.validate(retry_payload).to_a
    end
  end

  def test_reusing_key_for_different_input_is_rejected_without_a_second_task
    with_initialized_project do |project_root, project|
      create_json(project, "first request", key: "creator:stable", slug: "first-task")

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        Hive::Commands::New.new(
          project, "different request", slug_override: "second-task",
          idempotency_key: "creator:stable", json: true
        ).call!
      end

      assert_includes error.message, "different input or workflow"
      assert_equal 1, idempotent_tasks(project_root).size

      out, err, status = with_captured_exit do
        Hive::Commands::New.new(
          project, "different request", slug_override: "second-task",
          idempotency_key: "creator:stable", json: true
        ).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      assert_equal "usage", payload.fetch("error_kind")
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new"))))
      assert_empty schemer.validate(payload).to_a
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_invalid_idempotency_keys_are_rejected
    with_initialized_project do |_project_root, project|
      [ "", " ", "x" * 513 ].each do |key|
        error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
          Hive::Commands::New.new(
            project, "task", slug_override: "invalid-key-task",
            idempotency_key: key, json: true
          ).call!
        end
        assert_includes error.message, "idempotency key must be"
      end
    end
  end

  def test_attachment_content_participates_in_the_fingerprint
    with_initialized_project do |project_root, project|
      with_tmp_dir do |dir|
        source = File.join(dir, "source.png")
        File.binwrite(source, "png-bytes")

        payload = create_json_with(
          project, "task with image", key: "creator:attachment", slug: "attachment-task",
          attachments: [ [ source, "source.png" ] ]
        )
        metadata = Hive::TaskMeta.read(payload.fetch("task_folder"))

        assert_equal true, payload.fetch("created")
        assert_match(/\A[0-9a-f]{64}\z/, metadata.fetch(:input_fingerprint))
        assert_equal "png-bytes",
                     File.binread(File.join(project_root, ".hive-state", "stages", "1-inbox",
                                            "attachment-task", "assets", "source.png"))
      end
    end
  end

  def test_idempotent_attachment_fingerprint_and_task_use_one_byte_snapshot
    with_initialized_project do |project_root, project|
      with_tmp_dir do |dir|
        source = File.join(dir, "source.png")
        File.binwrite(source, "original-bytes")
        command = Hive::Commands::New.new(
          project, "task with raced image", slug_override: "raced-attachment-task",
          idempotency_key: "creator:raced-attachment", json: true,
          attachments: [ [ source, "source.png" ] ]
        )
        original_lookup = command.method(:find_idempotent_task!)
        command.define_singleton_method(:find_idempotent_task!) do |*args|
          File.binwrite(source, "changed-after-fingerprint")
          original_lookup.call(*args)
        end

        out, = capture_io { command.call! }
        payload = JSON.parse(out)
        captured = File.join(payload.fetch("task_folder"), "assets", "source.png")

        assert_equal "original-bytes", File.binread(captured)

        File.binwrite(source, "original-bytes")
        retry_payload = create_json_with(
          project, "task with raced image", key: "creator:raced-attachment",
          slug: "raced-attachment-task", attachments: [ [ source, "source.png" ] ]
        )
        assert_equal false, retry_payload.fetch("created")
        assert_equal 1, idempotent_tasks(project_root).size
      end
    end
  end

  def test_commit_failure_removes_the_uncommitted_task
    with_initialized_project do |project_root, project|
      fake_ops = Object.new
      runner = method(:run!)
      hive_state = File.join(project_root, ".hive-state")
      fake_ops.define_singleton_method(:hive_commit) do |**|
        runner.call("git", "-C", hive_state, "add", "--",
                    "stages/1-inbox/failed-task")
        raise Hive::GitError, "commit failed"
      end
      fake_ops.define_singleton_method(:run_git!) do |*args|
        runner.call("git", *args)
      end

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_root) { fake_ops }) do
        error = assert_raises(Hive::GitError) do
          Hive::Commands::New.new(
            project, "will fail", slug_override: "failed-task",
            idempotency_key: "creator:commit-failure", json: true
          ).call!
        end
        assert_includes error.message, "commit failed"
      end

      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "failed-task")
      )
      assert_empty run!("git", "-C", File.join(project_root, ".hive-state"),
                        "diff", "--cached", "--name-only")
    end
  end

  def test_interrupted_commit_removes_the_uncommitted_task
    with_initialized_project do |project_root, project|
      fake_ops = Object.new
      runner = method(:run!)
      hive_state = File.join(project_root, ".hive-state")
      fake_ops.define_singleton_method(:hive_commit) do |**|
        runner.call("git", "-C", hive_state, "add", "--",
                    "stages/1-inbox/interrupted-task")
        raise Interrupt, "stop"
      end
      fake_ops.define_singleton_method(:run_git!) { |*args| runner.call("git", *args) }

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_root) { fake_ops }) do
        assert_raises(Interrupt) do
          Hive::Commands::New.new(
            project, "will stop", slug_override: "interrupted-task",
            idempotency_key: "creator:interrupted", json: true
          ).call!
        end
      end

      refute Dir.exist?(
        File.join(hive_state, "stages", "1-inbox", "interrupted-task")
      )
      assert_empty run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
    end
  end

  def test_non_idempotent_commit_failure_also_clears_staged_state
    with_initialized_project do |project_root, project|
      fake_ops = Object.new
      runner = method(:run!)
      hive_state = File.join(project_root, ".hive-state")
      fake_ops.define_singleton_method(:hive_commit) do |**|
        runner.call("git", "-C", hive_state, "add", "--",
                    "stages/1-inbox/failed-legacy-task")
        raise Hive::GitError, "commit failed"
      end
      fake_ops.define_singleton_method(:run_git!) { |*args| runner.call("git", *args) }

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_root) { fake_ops }) do
        assert_raises(Hive::GitError) do
          Hive::Commands::New.new(
            project, "will fail", slug_override: "failed-legacy-task"
          ).call!
        end
      end

      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "failed-legacy-task")
      )
      assert_empty run!("git", "-C", File.join(project_root, ".hive-state"),
                        "diff", "--cached", "--name-only")
    end
  end

  def test_owner_authored_workflow_content_participates_in_fingerprint
    with_initialized_project do |project_root, project|
      create_authored_workflow(project_root, "editorial")
      create_json_with(
        project, "same request", key: "creator:authored-content", slug: "first-authored",
        workflow: "editorial"
      )
      File.write(
        File.join(project_root, ".hive-state", "workflows", "editorial", "work.md"),
        "Changed owner instructions.\n"
      )
      Hive::Workflows::Project.reset!

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        Hive::Commands::New.new(
          project, "same request", slug_override: "second-authored",
          workflow: "editorial", idempotency_key: "creator:authored-content", json: true
        ).call!
      end

      assert_includes error.message, "different input or workflow"
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_owner_authored_workflow_change_during_creation_aborts_candidate
    with_initialized_project do |project_root, project|
      create_authored_workflow(project_root, "editorial")
      instruction = File.join(
        project_root, ".hive-state", "workflows", "editorial", "work.md"
      )
      command = Hive::Commands::New.new(
        project, "same request", slug_override: "raced-authored",
        workflow: "editorial", idempotency_key: "creator:authored-race", json: true
      )
      original_lookup = command.method(:find_idempotent_task!)
      command.define_singleton_method(:find_idempotent_task!) do |*args|
        File.write(instruction, "Changed during task creation.\n")
        original_lookup.call(*args)
      end

      error = assert_raises(Hive::ConcurrentRunError) { command.call! }

      assert_includes error.message, "owner-authored workflow changed"
      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "raced-authored")
      )
      assert_empty idempotent_tasks(project_root)
    end
  end

  def test_unreadable_task_metadata_fails_idempotency_closed
    with_initialized_project do |project_root, project|
      capture_io do
        Hive::Commands::New.new(
          project, "legacy task", slug_override: "legacy-task"
        ).call!
      end
      meta = File.join(
        project_root, ".hive-state", "stages", "1-inbox", "legacy-task", "meta.yml"
      )
      File.write(meta, "id: [\n")

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        Hive::Commands::New.new(
          project, "new task", slug_override: "must-not-exist",
          idempotency_key: "creator:fail-closed", json: true
        ).call!
      end

      assert_includes error.message, "cannot prove idempotency"
      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "must-not-exist")
      )
    end
  end

  def test_post_ownership_eexist_cleans_the_candidate
    with_initialized_project do |project_root, project|
      replacement = lambda do |*|
        raise Errno::EEXIST, "metadata collision"
      end

      with_replaced_singleton_method(Hive::TaskMeta, :write, replacement) do
        assert_raises(Errno::EEXIST) do
          Hive::Commands::New.new(
            project, "candidate", slug_override: "owned-candidate",
            idempotency_key: "creator:owned-candidate", json: true
          ).call!
        end
      end

      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "owned-candidate")
      )
    end
  end

  def test_idempotent_candidate_is_created_with_workflow_then_commit_locks_held
    with_initialized_project do |project_root, project|
      command = Hive::Commands::New.new(
        project, "same task", slug_override: "locked-task",
        idempotency_key: "creator:race", json: true
      )
      original = command.method(:create_task_candidate!)
      observe_lock = method(:other_process_lock_state)
      command.define_singleton_method(:create_task_candidate!) do |*args, **kwargs|
        commit_lock = File.join(project_root, ".hive-state", ".commit-lock")
        workflow_lock = File.join(
          project_root, ".hive-state", "workflows", ".mutation.lock"
        )
        raise "candidate creation ran outside workflow mutation lock" unless
          observe_lock.call(workflow_lock) == "blocked"
        raise "candidate creation ran outside commit lock" unless
          observe_lock.call(commit_lock) == "blocked"

        original.call(*args, **kwargs)
      end

      out, = capture_io { command.call! }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("created")
      assert Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "locked-task")
      )
    end
  end

  def test_same_slug_with_a_different_key_never_reuses_or_removes_the_first_task
    with_initialized_project do |project_root, project|
      first = create_json(
        project, "first task", key: "creator:first", slug: "shared-slug"
      )

      error = assert_raises(Hive::Commands::New::SlugCollisionError) do
        Hive::Commands::New.new(
          project, "second task", slug_override: "shared-slug",
          idempotency_key: "creator:second", json: true
        ).call!
      end

      assert_includes error.message, "slug collision"
      assert_includes File.read(File.join(first.fetch("task_folder"), "idea.md")), "first task"
      metadata = Hive::TaskMeta.read(first.fetch("task_folder"))
      assert_equal "creator:first", metadata.fetch(:idempotency_key)
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_multiple_tasks_with_the_same_key_fail_closed
    with_initialized_project do |project_root, project|
      %w[first second].each do |slug|
        capture_io do
          Hive::Commands::New.new(
            project, "#{slug} task", slug_override: "#{slug}-task"
          ).call!
        end
        folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "#{slug}-task")
        Hive::TaskMeta.rewrite(
          folder, idempotency_key: "creator:duplicate", input_fingerprint: "fingerprint"
        )
      end

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        Hive::Commands::New.new(
          project, "third task", slug_override: "third-task",
          idempotency_key: "creator:duplicate", json: true
        ).call!
      end
      assert_includes error.message, "multiple tasks"
      assert_equal 2, idempotent_tasks(project_root).size
    end
  end

  def test_plain_retry_reports_existing_task_and_next_command
    with_initialized_project do |_project_root, project|
      create_json(project, "plain retry", key: "creator:plain", slug: "plain-task")

      out, = capture_io do
        Hive::Commands::New.new(
          project, "plain retry", slug_override: "ignored-task",
          idempotency_key: "creator:plain"
        ).call!
      end

      assert_includes out, "idempotent task already exists"
      assert_includes out, "next: hive brainstorm"
    end
  end

  def test_legacy_creation_does_not_write_idempotency_metadata
    with_initialized_project do |project_root, project|
      capture_io { Hive::Commands::New.new(project, "ordinary task", slug_override: "ordinary-task").call! }
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "ordinary-task")
      metadata = File.read(File.join(folder, "meta.yml"))

      refute_includes metadata, "idempotency_key"
      refute_includes metadata, "input_fingerprint"
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io do
          Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call
        end
        yield project_root, File.basename(project_root)
      end
    end
  end

  def create_json(project, text, key:, slug:)
    create_json_with(project, text, key: key, slug: slug)
  end

  def create_json_with(project, text, key:, slug:, attachments: [], workflow: nil)
    out, err = capture_io do
      Hive::Commands::New.new(
        project, text, slug_override: slug, idempotency_key: key, json: true,
        attachments: attachments, workflow: workflow
      ).call!
    end
    assert_empty err
    JSON.parse(out)
  end

  def create_authored_workflow(project_root, id)
    Hive::Commands::Workflow.new!(
      id, project_root: project_root, stdout: StringIO.new
    )
  end

  def idempotent_tasks(project_root)
    Dir.glob(File.join(project_root, ".hive-state", "stages", "*", "*", "meta.yml")).select do |path|
      Hive::TaskMeta.read(File.dirname(path))[:idempotency_key]
    end
  end

  def other_process_lock_state(path)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      acquired = File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      writer.write(acquired ? "acquired" : "blocked")
      writer.close
      exit! 0
    end
    writer.close
    state = reader.read
    Process.wait(pid)
    reader.close
    state
  end
end
