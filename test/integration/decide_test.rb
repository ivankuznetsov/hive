require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/decide"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/status"
require "hive/daemon/policy"
require "hive/cli"

class DecideTest < Minitest::Test
  include HiveTestHelper

  SLUG_PATTERN = "editorial-probe-*".freeze

  def test_latest_record_ignores_malformed_audit_lines
    with_tmp_dir do |dir|
      path = File.join(dir, "approval.md")
      File.write(path, <<~TEXT)
        <!-- HIVE_DECISION_V1 {not-json} -->
        <!-- HIVE_DECISION_V1 {"decision_id":"valid","outcome":"approve"} -->
      TEXT

      assert_equal "valid", Hive::Commands::Decide.latest_record(path).fetch("decision_id")
      assert_nil Hive::Commands::Decide.latest_record(File.join(dir, "missing.md"))
    end
  end

  def test_restore_files_removes_a_path_created_after_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "created.md")
      File.write(path, "created")

      Hive::Commands::Decide.new("task", "approve", from: "approval").send(
        :restore_files, dir,
        { "created.md" => { existed: false, body: nil } }
      )

      refute File.exist?(path)
    end
  end

  def test_error_kinds_and_argument_guards_are_typed
    command = Hive::Commands::Decide.new("task", "approve", from: "approval")
    cases = [
      [ Hive::WrongStage.new("wrong"), "wrong_stage" ],
      [
        Hive::AmbiguousSlug.new("ambiguous", slug: "task", candidates: []),
        "ambiguous_slug"
      ],
      [ Hive::InvalidTaskPath.new("bad"), "invalid_task_path" ],
      [ Hive::ConcurrentRunError.new("busy"), "concurrent_run" ],
      [ Hive::ConfigError.new("config"), "config" ],
      [ Hive::GitError.new("git"), "git" ],
      [ Hive::InternalError.new("internal"), "internal" ],
      [ RuntimeError.new("other"), "error" ]
    ]
    cases.each do |error, kind|
      assert_equal kind, command.envelope_error_kind(error)
    end

    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Decide.new(
        "task", "approve", from: "", decision_id: "a" * 16, note: "ok"
      ).send(:validate_arguments!)
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Decide.new(
        "task", "", from: "approval", decision_id: "a" * 16
      ).send(:validate_arguments!)
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Decide.new(
        "task", "approve", from: "approval", decision_id: "a" * 16, note: 123
      )
                            .send(:validate_arguments!)
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Decide.new("task", "approve", from: "approval")
                            .send(:validate_arguments!)
    end
  end

  def test_entering_human_stage_waits_without_dispatch_and_surfaces_outcomes
    with_editorial_task do |_dir, approval, slug|
      task = Hive::Task.new(approval)
      marker = Hive::Markers.current(task.state_file)
      action = Hive::TaskAction.for(task, marker)

      assert_equal :waiting, marker.name
      assert_match(/\A[0-9a-f]{16}\z/, marker.attrs.fetch("decision_id"))
      assert_equal "needs_input", action.key
      assert_nil action.command
      assert_equal %w[approve reject], action.allowed_outcomes.map { |entry| entry.fetch("name") }
      assert_equal :skip, Hive::Daemon::Policy.decide(
        action: action.key, stage: "3-approval", workflow: "editorial",
        command: action.command, state_file_mtime: File.mtime(task.state_file),
        last_dispatched_state_file_mtime: nil, now: Time.now
      )

      out, = capture_io { Hive::Commands::Run.new(slug, json: true).call }
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("ok")
      assert_equal "waiting", payload.fetch("marker")
      assert_equal "human_decision_required", payload.dig("next_action", "reason")
      assert_includes payload.dig("next_action", "decide_with"),
                      "--decision-id #{marker.attrs.fetch('decision_id')}"
      assert_equal %w[approve reject], payload.fetch("allowed_outcomes").map { |entry| entry.fetch("name") }
      assert_schema_valid("hive-run", payload)
    end
  end

  def test_approve_records_publish_ready_artifact_and_completes_idempotently
    with_editorial_task do |dir, approval, slug|
      out, = capture_io do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(approval),
          note: "Ready for the editor", json: true
        ).call
      end
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert_equal true, payload.fetch("applied")
      assert_equal true, payload.fetch("completed")
      assert_equal "draft.md", payload.fetch("artifact")
      assert_equal "3-approval", payload.fetch("current_stage")
      assert_schema_valid("hive-decide", payload)

      task = Hive::Task.new(approval)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      record = Hive::Commands::Decide.latest_record(task.state_file)
      assert_equal "approve", record.fetch("outcome")
      assert_equal "Ready for the editor", record.fetch("note")
      assert_equal "draft.md", record.fetch("artifact")
      assert_equal "publish_ready", record.fetch("artifact_status")
      assert_equal "approval", record.fetch("from")
      assert File.file?(File.join(approval, "draft.md"))
      refute Dir.exist?(File.join(dir, ".hive-state", "stages", "4-publish"))

      retry_out, = capture_io do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: record.fetch("decision_id"),
          note: "Ready for the editor", json: true
        ).call
      end
      retry_payload = JSON.parse(retry_out)
      assert_equal false, retry_payload.fetch("applied")
      assert_equal true, retry_payload.fetch("noop")
      assert_equal record.fetch("decision_id"), retry_payload.fetch("decision_id")

      assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "reject", from: "approval", decision_id: record.fetch("decision_id")
        ).call
      end
    end
  end

  def test_approve_requires_non_empty_artifact_without_mutation
    with_editorial_task do |_dir, approval, slug|
      draft = File.join(approval, "draft.md")
      File.write(draft, "")
      before = File.binread(File.join(approval, "approval.md"))

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(approval)
        ).call
      end

      assert_includes error.message, "non-empty artifact"
      assert_equal before, File.binread(File.join(approval, "approval.md"))
      assert_equal :waiting, Hive::Markers.current(File.join(approval, "approval.md")).name
      assert File.directory?(approval)
    end
  end

  def test_approve_refuses_an_artifact_symlink_outside_the_task
    with_editorial_task do |_dir, approval, slug|
      with_tmp_dir do |outside|
        external = File.join(outside, "external-draft.md")
        File.write(external, "# External bytes\n")
        draft = File.join(approval, "draft.md")
        File.delete(draft)
        File.symlink(external, draft)

        error = assert_raises(Hive::WrongStage) do
          Hive::Commands::Decide.new(
            slug, "approve", from: "approval", decision_id: decision_id_for(approval)
          ).call
        end

        assert_includes error.message, "non-empty artifact"
        assert_equal "# External bytes\n", File.read(external)
        assert File.symlink?(draft)
        assert_equal :waiting, Hive::Markers.current(File.join(approval, "approval.md")).name
        assert_nil Hive::Commands::Decide.latest_record(File.join(approval, "approval.md"))
      end
    end
  end

  def test_concurrent_identical_completion_returns_one_apply_and_one_noop
    with_editorial_task do |_dir, approval, slug|
      decision_id = decision_id_for(approval)
      ready = Queue.new
      release = Queue.new
      commands = 2.times.map do
        command = Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id
        )
        original = command.method(:complete!)
        command.define_singleton_method(:complete!) do |*args|
          ready << true
          release.pop
          original.call(*args)
        end
        command
      end
      threads = commands.map do |command|
        Thread.new do
          begin
            command.send(:do_call)
          rescue StandardError => e
            e
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      results = threads.map(&:value)

      assert results.none?(Exception), results.inspect
      assert_equal 1, results.count { |payload| payload.fetch("applied") }
      assert_equal 1, results.count { |payload| payload.fetch("noop") }
      assert_equal 1, File.read(File.join(approval, "approval.md")).scan(
        Hive::Commands::Decide::RECORD_RE
      ).size
    end
  end

  def test_self_target_outcome_records_and_mints_a_fresh_decision
    with_registered_workflow(revision_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, agent_skill_preflight: false).call }
          project = File.basename(dir)
          capture_io do
            Hive::Commands::New.new(
              project, "review this", workflow: "revision", slug_override: "revision-task"
            ).call!
          end
          folder = File.join(dir, ".hive-state", "stages", "1-approval", "revision-task")
          old_id = decision_id_for(folder)
          out, = capture_io do
            Hive::Commands::Decide.new(
              "revision-task", "revise", from: "approval",
              decision_id: old_id, json: true
            ).call
          end
          payload = JSON.parse(out)
          marker = Hive::Markers.current(File.join(folder, "approval.md"))

          assert_equal true, payload.fetch("applied")
          assert_equal false, payload.fetch("completed")
          assert_equal "1-approval", payload.fetch("current_stage")
          assert_equal "needs_input", payload.dig("next_action", "kind")
          assert_equal :waiting, marker.name
          refute_equal old_id, marker.attrs.fetch("decision_id")
          assert_equal old_id, Hive::Commands::Decide.latest_record(
            File.join(folder, "approval.md")
          ).fetch("decision_id")
          assert_schema_valid("hive-decide", payload)

          retry_payload = Hive::Commands::Decide.new(
            "revision-task", "revise", from: "approval",
            decision_id: old_id
          ).send(:do_call)
          assert_equal false, retry_payload.fetch("applied")
          assert_equal true, retry_payload.fetch("noop")
        end
      end
    end
  end

  def test_invalid_waiting_identity_and_non_human_from_are_rejected
    with_editorial_task do |_dir, approval, slug|
      Hive::Markers.set(File.join(approval, "approval.md"), :waiting)
      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: "a" * 16
        ).send(:do_call)
      end
      assert_includes error.message, "decision observation is stale"

      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "draft", decision_id: "a" * 16
        ).send(:do_call)
      end
      assert_includes error.message, "not a human stage"
    end
  end

  def test_decision_from_a_moved_task_without_a_record_is_stale
    with_editorial_task do |dir, approval, slug|
      draft = File.join(dir, ".hive-state", "stages", "2-draft", slug)
      FileUtils.mkdir_p(File.dirname(draft))
      File.rename(approval, draft)

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(draft)
        ).send(:do_call)
      end
      assert_includes error.message, "--from expected 3-approval"
    end
  end

  def test_approve_rolls_back_decision_file_when_commit_fails
    with_editorial_task do |_dir, approval, slug|
      state = File.join(approval, "approval.md")
      before = File.binread(state)
      fake_ops = Object.new
      fake_ops.define_singleton_method(:hive_commit) { |**| raise Hive::GitError, "commit failed" }
      fake_ops.define_singleton_method(:run_git!) { |*| raise Hive::GitError, "restage failed" }

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_root) { fake_ops }) do
        error = assert_raises(Hive::GitError) do
          Hive::Commands::Decide.new(
            slug, "approve", from: "approval", decision_id: decision_id_for(approval)
          ).send(:do_call)
        end
        assert_includes error.message, "commit failed"
      end

      assert_equal before, File.binread(state)
      assert_nil Hive::Commands::Decide.latest_record(state)
      assert_equal :waiting, Hive::Markers.current(state).name
    end
  end

  def test_reject_rolls_back_both_state_files_when_move_fails
    with_editorial_task do |dir, approval, slug|
      approval_before = File.binread(File.join(approval, "approval.md"))
      draft_before = File.binread(File.join(approval, "draft.md"))
      destination = File.join(dir, ".hive-state", "stages", "2-draft", slug)

      replacement = lambda do |_target, **kwargs|
        fake = Object.new
        fake.define_singleton_method(:call) do
          kwargs.fetch(:observation_guard).call(Hive::Task.new(approval))
          FileUtils.mkdir_p(File.dirname(destination))
          File.rename(approval, destination)
          raise Hive::GitError, "move failed"
        end
        fake
      end
      with_replaced_singleton_method(Hive::Commands::Approve, :new, replacement) do
        error = assert_raises(Hive::GitError) do
          Hive::Commands::Decide.new(
            slug, "reject", from: "approval", decision_id: decision_id_for(approval)
          ).send(:do_call)
        end
        assert_includes error.message, "move failed"
      end

      assert_equal approval_before, File.binread(File.join(destination, "approval.md"))
      assert_equal draft_before, File.binread(File.join(destination, "draft.md"))
      assert_nil Hive::Commands::Decide.latest_record(File.join(destination, "approval.md"))
    end
  end

  def test_stale_decision_identity_is_rejected_under_lock
    with_editorial_task do |_dir, approval, _slug|
      task = Hive::Task.new(approval)
      stage = task.workflow.stage_named("approval")

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new("unused", "approve", from: "approval")
                              .send(:validate_current_decision!, task, stage, "rotated")
      end
      assert_includes error.message, "decision observation is stale"
    end
  end

  def test_plain_success_reports_decision_and_current_stage
    with_editorial_task do |_dir, approval, slug|
      out, = capture_io do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(approval)
        ).call
      end

      assert_includes out, "hive: decided #{slug} approval=approve"
      assert_includes out, "current_stage: 3-approval"
    end
  end

  def test_reject_records_decision_returns_to_draft_and_retries_as_noop
    with_editorial_task do |dir, approval, slug|
      observed_id = decision_id_for(approval)
      out, = capture_io do
        Hive::CLI.start(
          [
            "decide", slug, "reject", "--from", "3-approval",
            "--decision-id", observed_id, "--note", "Strengthen the lead", "--json"
          ]
        )
      end
      payload = JSON.parse(out)
      draft = File.join(dir, ".hive-state", "stages", "2-draft", slug)

      assert_equal true, payload.fetch("applied")
      assert_equal false, payload.fetch("completed")
      assert_equal "2-draft", payload.fetch("current_stage")
      assert File.directory?(draft)
      refute File.exist?(approval)
      assert_equal :waiting, Hive::Markers.current(File.join(draft, "draft.md")).name
      record = Hive::Commands::Decide.latest_record(File.join(draft, "approval.md"))
      assert_equal "reject", record.fetch("outcome")
      assert_equal "Strengthen the lead", record.fetch("note")
      assert_equal "draft", record.fetch("to")

      retry_out, = capture_io do
        Hive::Commands::Decide.new(
          slug, "reject", from: "approval", decision_id: observed_id,
          note: "Strengthen the lead", json: true
        ).call
      end
      retry_payload = JSON.parse(retry_out)
      assert_equal true, retry_payload.fetch("noop")
      assert_equal false, retry_payload.fetch("applied")
      assert_equal "2-draft", retry_payload.fetch("current_stage")

      assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: observed_id
        ).call
      end
    end
  end

  def test_marker_only_artifact_is_not_publish_ready
    with_editorial_task do |_dir, approval, slug|
      draft = File.join(approval, "draft.md")
      File.write(draft, "<!-- COMPLETE -->\n<!-- WAITING decision_id=aaaaaaaaaaaaaaaa -->\n")

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(approval)
        ).call
      end

      assert_includes error.message, "non-empty artifact"
      assert_equal :waiting, Hive::Markers.current(File.join(approval, "approval.md")).name
    end
  end

  def test_artifact_is_rechecked_under_the_decision_lock
    with_editorial_task do |_dir, approval, slug|
      draft = File.join(approval, "draft.md")
      command = Hive::Commands::Decide.new(
        slug, "approve", from: "approval", decision_id: decision_id_for(approval)
      )
      original = command.method(:validate_current_decision!)
      command.define_singleton_method(:validate_current_decision!) do |task, stage, decision_id|
        original.call(task, stage, decision_id)
        File.write(draft, "")
      end

      assert_raises(Hive::WrongStage) { command.call }
      assert_equal :waiting, Hive::Markers.current(File.join(approval, "approval.md")).name
      assert_nil Hive::Commands::Decide.latest_record(File.join(approval, "approval.md"))
    end
  end

  def test_decision_from_an_earlier_visit_is_rejected_after_reentry
    with_editorial_task do |_dir, approval, slug|
      old_id = decision_id_for(approval)
      Hive::Markers.set(
        File.join(approval, "approval.md"), :waiting, "decision_id" => "b" * 16
      )

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: old_id
        ).call
      end

      assert_includes error.message, "decision observation is stale"
      assert_equal "b" * 16, decision_id_for(approval)
    end
  end

  def test_completed_human_stage_run_reports_completion_without_outcomes
    with_editorial_task do |_dir, approval, slug|
      capture_io do
        Hive::Commands::Decide.new(
          slug, "approve", from: "approval", decision_id: decision_id_for(approval)
        ).call
      end

      out, = capture_io { Hive::Commands::Run.new(slug, json: true).call }
      payload = JSON.parse(out)
      assert_equal "complete", payload.fetch("marker")
      assert_equal "human_stage_complete", payload.dig("next_action", "reason")
      refute payload.key?("allowed_outcomes")
      refute payload.dig("next_action").key?("allowed_outcomes")
      refute payload.dig("next_action").key?("decide_with")
    end
  end

  def test_status_and_operational_status_expose_human_outcomes
    with_editorial_task do |_dir, _approval, slug|
      status_out, = capture_io { Hive::Commands::Status.new(json: true).call }
      row = JSON.parse(status_out).fetch("projects").flat_map { |project| project.fetch("tasks") }
                     .find { |task| task.fetch("slug") == slug }
      assert_equal "needs_input", row.fetch("action")
      assert_nil row.fetch("suggested_command")
      assert_equal %w[approve reject], row.fetch("outcomes").map { |entry| entry.fetch("name") }
      assert_schema_valid("hive-status", JSON.parse(status_out))

      operational_out, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
      operational = JSON.parse(operational_out)
      projected = operational.fetch("tasks").find { |task| task.dig("identity", "slug") == slug }
      assert_equal "waiting_on_you", projected.fetch("state")
      assert_equal %w[approve reject], projected.dig("position", "allowed_outcomes").map { |entry| entry.fetch("name") }
      assert_nil projected.fetch("action")
      assert_schema_valid("hive-operational-status", operational)
    end
  end

  private

  def decision_id_for(folder)
    Hive::Markers.current(File.join(folder, "approval.md")).attrs.fetch("decision_id")
  end

  def editorial_workflow
    Hive::Workflow.new(
      id: :editorial,
      stages: [
        Hive::Workflow::Stage.new(name: "research", index: 1, state_file: "research.md", kind: :agent, skill: "/research"),
        Hive::Workflow::Stage.new(name: "draft", index: 2, state_file: "draft.md", kind: :agent, skill: "/draft"),
        Hive::Workflow::Stage.new(
          name: "approval", index: 3, state_file: "approval.md", kind: :human, input: "draft.md",
          outcomes: {
            "approve" => Hive::Workflow::Outcome.new(name: "approve", complete: true, artifact: "draft.md"),
            "reject" => Hive::Workflow::Outcome.new(name: "reject", to: "draft")
          }.freeze
        )
      ]
    )
  end

  def revision_workflow
    Hive::Workflow.new(
      id: :revision,
      stages: [
        Hive::Workflow::Stage.new(
          name: "approval", index: 1, state_file: "approval.md", kind: :human,
          outcomes: {
            "revise" => Hive::Workflow::Outcome.new(name: "revise", to: "approval")
          }.freeze
        )
      ]
    )
  end

  def with_editorial_task
    descriptor = editorial_workflow
    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, agent_skill_preflight: false).call }
          project = File.basename(dir)
          capture_io { Hive::Commands::New.new(project, "editorial probe", workflow: "editorial").call }
          research = Dir[File.join(dir, ".hive-state", "stages", "1-research", SLUG_PATTERN)].fetch(0)
          slug = File.basename(research)
          Hive::Markers.set(File.join(research, "research.md"), :complete)
          capture_io { Hive::Commands::Approve.new(slug, from: "research").call }
          draft = File.join(dir, ".hive-state", "stages", "2-draft", slug)
          File.write(File.join(draft, "draft.md"), "# Draft\n\nPublishable copy.\n")
          Hive::Markers.set(File.join(draft, "draft.md"), :complete)
          capture_io { Hive::Commands::Approve.new(slug, from: "draft").call }
          approval = File.join(dir, ".hive-state", "stages", "3-approval", slug)

          yield dir, approval, slug
        end
      end
    end
  end

  def assert_schema_valid(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} payload errors: #{errors.map { |error| error['error'] }.inspect}"
  end
end
