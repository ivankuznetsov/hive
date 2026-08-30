require "test_helper"
require "json_schemer"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/repair_projection"
require "hive/task_journal"
require "hive/task_projection/store"

class RepairProjectionCommandTest < Minitest::Test
  include HiveTestHelper

  def test_cli_repairs_one_exact_task_and_is_idempotent
    with_project_tasks(2) do |project, tasks|
      selected, untouched = tasks
      write_legacy_journal(selected)
      File.write(File.join(untouched.folder, "task-projection.json"), "untouched-snapshot\n")
      File.write(
        File.join(untouched.folder, "task-projection.checkpoint.json"),
        "untouched-checkpoint\n"
      )

      first = cli_json(
        "repair-projection", selected.slug,
        "--project", project, "--stage", "1-inbox", "--json"
      )
      second = cli_json(
        "repair-projection", selected.slug,
        "--project", project, "--stage", "1-inbox", "--json"
      )

      assert_schema_valid(first)
      assert_schema_valid(second)
      assert_equal true, first.fetch("ok")
      assert_equal "repaired", first.fetch("outcome")
      assert_equal "current", first.fetch("checkpoint_state")
      assert_equal selected.slug, first.fetch("slug")
      assert_equal project, first.fetch("project")
      assert_equal first.fetch("journal_cursor"), second.fetch("journal_cursor")
      assert_equal "untouched-snapshot\n",
                   File.binread(File.join(untouched.folder, "task-projection.json"))
      assert_equal "untouched-checkpoint\n",
                   File.binread(File.join(untouched.folder, "task-projection.checkpoint.json"))

      human, err = capture_io do
        Hive::Commands::RepairProjection.new(
          selected.slug, project: project, stage: "1-inbox"
        ).call
      end
      assert_empty err
      assert_includes human, "Repaired projection for #{project}:#{selected.slug}"
      assert_includes human, "hive status --operational --json"
    end
  end

  def test_pristine_zero_history_task_repairs_without_inventing_a_journal
    with_project_tasks(1) do |project, tasks|
      task = tasks.first

      payload = cli_json(
        "repair-projection", task.slug,
        "--project", project, "--stage", "1-inbox", "--json"
      )

      assert_schema_valid(payload)
      assert_equal true, payload.fetch("ok")
      assert_equal "repaired", payload.fetch("outcome")
      assert_equal "current", payload.fetch("checkpoint_state")
      refute File.exist?(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)),
             "zero-history repair must not invent authoritative journal history"
    end
  end

  def test_corrupt_authority_emits_a_typed_bounded_error
    with_project_tasks(2) do |project, tasks|
      _unused, corrupt = tasks

      File.write(
        File.join(corrupt.folder, Hive::TaskJournal::JOURNAL_BASENAME),
        "not-json\n"
      )
      journal_before = File.binread(
        File.join(corrupt.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      )
      corrupt_payload = command_error_payload(
        corrupt.slug, project: project, stage: "1-inbox"
      )
      assert_schema_valid(corrupt_payload)
      assert_equal "invalid_projection_authority", corrupt_payload.fetch("error_kind")
      assert_equal journal_before,
                   File.binread(File.join(corrupt.folder, Hive::TaskJournal::JOURNAL_BASENAME))
      refute File.exist?(File.join(corrupt.folder, "task-projection.json"))
    end
  end

  def test_missing_referenced_attempt_fails_without_enumerating_proof_storage
    with_project_tasks(1) do |project, tasks|
      task = tasks.first
      write_attempt_journal(task, attempt_id: "missing-attempt")
      calls = []
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch_projection_binding) do |attempt_id|
        calls << [ :fetch_projection_binding, attempt_id ]
        nil
      end
      attempt_store.define_singleton_method(:fetch) do |attempt_id|
        calls << [ :fetch, attempt_id ]
        nil
      end
      attempt_store.define_singleton_method(:scan) do
        raise "proof-root enumeration must not run"
      end

      payload = command_error_payload(
        task.slug, project: project, stage: "1-inbox", attempt_store: attempt_store
      )

      assert_schema_valid(payload)
      assert_equal "invalid_projection_authority", payload.fetch("error_kind")
      assert calls.all? { |(_method, id)| id == "missing-attempt" }
      assert_operator calls.length, :<=, 1
    end
  end

  def test_live_task_lock_and_lock_time_identity_change_fail_typed
    with_project_tasks(2) do |project, tasks|
      first, moved = tasks
      write_legacy_journal(first)

      locked_payload = nil
      Hive::Lock.with_task_lock(first.folder, "op" => "test", create: false) do
        locked_payload = command_error_payload(
          first.slug, project: project, stage: "1-inbox"
        )
      end
      assert_schema_valid(locked_payload)
      assert_equal "task_locked", locked_payload.fetch("error_kind")
      assert_equal first.slug, locked_payload.fetch("slug")

      sequence = [ first, moved ]
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { sequence.shift }
      moved_payload = command_error_payload(
        first.slug,
        project: project,
        stage: "1-inbox",
        resolver_factory: -> { resolver }
      )
      assert_schema_valid(moved_payload)
      assert_equal "invalid_task_path", moved_payload.fetch("error_kind")
      assert_includes moved_payload.fetch("message"), "identity changed"
      refute File.exist?(File.join(first.folder, "task-projection.json"))
      refute File.exist?(first.lock_file), "identity-change failure must release the task lock"
    end
  end

  def test_ambiguous_target_emits_candidates_without_touching_a_task
    candidates = [
      { project: "one", stage: "1-inbox", folder: "/tmp/one/task" },
      { project: "two", stage: "1-inbox", folder: "/tmp/two/task" }
    ]
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do
      raise Hive::AmbiguousSlug.new(
        "slug 'task' is ambiguous", slug: "task", candidates: candidates
      )
    end

    payload = command_error_payload(
      "task", resolver_factory: -> { resolver }
    )

    assert_schema_valid(payload)
    assert_equal "ambiguous_slug", payload.fetch("error_kind")
    assert_equal %w[one two], payload.fetch("candidates").map { |row| row.fetch("project") }
    refute payload.key?("task_folder")
  end

  def test_terminal_postcondition_does_not_recommend_retry
    with_project_tasks(1) do |project, tasks|
      task = tasks.first
      write_legacy_journal(task)
      projection = Hive::TaskProjection.project(records: [])
      bounded = Hive::TaskProjection::Store::BoundedRead.new(
        projection: projection,
        state: "repair_required",
        diagnostics: [ { "reason" => "checkpoint_oversized" } ],
        truncated: true,
        journal_cursor: 0
      )
      fake_store = Object.new
      fake_store.define_singleton_method(:repair!) do |marker:, **|
        Hive::TaskProjection::Store::RepairResult.new(
          projection: projection, bounded: bounded
        )
      end

      payload = nil
      with_replaced_singleton_method(
        Hive::TaskProjection::Store, :new, ->(**) { fake_store }
      ) do
        payload = command_error_payload(
          task.slug, project: project, stage: "1-inbox"
        )
      end

      assert_schema_valid(payload)
      assert_equal "projection_repair_failed", payload.fetch("error_kind")
      assert_equal true, payload.fetch("terminal")
      assert_equal "checkpoint_oversized", payload.fetch("reason")
      assert_equal "compact_projection_history", payload.dig("next_action", "kind")
      refute payload.dig("next_action").key?("command")
    end
  end

  private

  def with_project_tasks(count)
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        project = File.basename(project_root)
        count.times do |index|
          capture_io do
            Hive::Commands::New.new(project, "projection repair task #{index}").call
          end
        end
        folders = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")].sort
        folders.each do |folder|
          FileUtils.rm_f(File.join(folder, Hive::TaskProjection::Store::SNAPSHOT_BASENAME))
          FileUtils.rm_f(File.join(folder, Hive::TaskProjection::Store::CHECKPOINT_BASENAME))
        end
        yield project, folders.map { |folder| Hive::Task.new(folder) }
      end
    end
  end

  def write_legacy_journal(task)
    Hive::TaskJournal::Writer.new(task_folder: task.folder).append(
      event_type: "legacy_baseline",
      task: { "id" => task.id&.to_s, "slug" => task.slug },
      workflow: task.workflow.id,
      stage: "#{task.stage_index}-#{task.stage_name}",
      attempt_id: "legacy",
      task_generation: 0,
      ownership_generation: nil,
      commit_generation: 0,
      reason: "operator_fixture",
      evidence: [],
      provenance: { "source" => "test" },
      payload: {}
    )
  end

  def write_attempt_journal(task, attempt_id:)
    envelope = Hive::TaskJournal::Envelope.authoritative({
      event_id: "event-missing-proof",
      event_type: "activity_recorded",
      task: { "id" => task.id&.to_s, "slug" => task.slug },
      workflow: task.workflow.id,
      stage: "#{task.stage_index}-#{task.stage_name}",
      attempt_id: attempt_id,
      task_generation: 1,
      ownership_generation: "owner-1",
      commit_generation: 0,
      reason: "fixture",
      evidence: [],
      provenance: { "source" => "test" },
      payload: { "activity_kind" => "attempt_admitted", "operation_id" => "fixture-op" }
    })
    File.write(
      File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME),
      "#{JSON.generate(envelope)}\n"
    )
  end

  def cli_json(*argv)
    out, err = capture_io { Hive::CLI.start(argv) }
    assert_empty err
    JSON.parse(out)
  end

  def command_error_payload(target, **options)
    out, = capture_io do
      assert_raises(Hive::Error) do
        Hive::Commands::RepairProjection.new(target, json: true, **options).call
      end
    end
    JSON.parse(out)
  end

  def assert_schema_valid(payload)
    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-repair-projection")))
    )
    assert_empty schema.validate(payload).to_a
  end
end
