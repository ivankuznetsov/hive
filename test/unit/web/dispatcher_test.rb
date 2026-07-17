require "test_helper"
require "json"
require "hive/web/dispatcher"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/workflow"
require "hive/workflows/project"
require "hive/brainstorm_parser"
require "hive/daemon/dispatch_request_queue"

# Unit coverage for the web Dispatcher's gate logic: reject must derive the
# task's *prior* gate from its current stage (not hardcode 2-brainstorm), and
# intervene must write the operator's message into brainstorm.md via the bot's
# answer writer so the daemon picks it up — instead of dropping it into a file
# nothing consumes.
class WebDispatcherTest < Minitest::Test
  include HiveTestHelper

  def seed_task_at(dir, stage)
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::New.new(project, "dispatcher probe").call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    slug = File.basename(inbox)
    dest = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.mv(inbox, dest)
    [ project, slug, dest ]
  end

  # The web "Repair daemon" button enqueues `hive daemon install --force` under
  # the __global__ maintenance sentinel; the daemon consumer special-cases that
  # project instead of dropping it as unknown_project. Only the consumer half is
  # covered elsewhere — assert the PRODUCER's sentinel/argv so the two can't
  # drift apart (a wrong sentinel or argv would be caught by neither suite).
  def test_repair_daemon_enqueues_global_maintenance_install_force
    with_tmp_global_config do
      request_id = Hive::Web::Dispatcher.new.repair_daemon
      refute_nil request_id, "repair_daemon must return the enqueued request id"

      files = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "**", "*#{request_id}*")]
              .select { |f| File.file?(f) }
      refute_empty files, "repair_daemon must enqueue a dispatch request"
      payload = JSON.parse(File.read(files.first))
      assert_equal Hive::Daemon::DispatchRequestQueue::GLOBAL_MAINTENANCE_PROJECT,
                   payload["project"], "repair must ride the __global__ sentinel"
      assert_equal %w[hive daemon install --force], payload["argv"]
      assert_equal "web_daemon_repair", payload["trigger"]
    end
  end

  def test_repair_daemon_maps_queue_rejection_to_typed_error
    with_tmp_global_config do
      original = Hive::Bot::DispatchRequestWriter.method(:write!)
      Hive::Bot::DispatchRequestWriter.define_singleton_method(:write!) do |**|
        raise ArgumentError, "argv not allowlisted"
      end
      error = assert_raises(Hive::Error) { Hive::Web::Dispatcher.new.repair_daemon }
      assert_match(/daemon install --force/, error.message,
                   "a write-time rejection must surface CLI guidance, not run repair from a worker")
    ensure
      Hive::Bot::DispatchRequestWriter.define_singleton_method(:write!, original) if original
    end
  end

  def test_recover_queues_one_generation_fenced_coordinator_request
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug, dest = seed_task_at(dir, "6-review")
        File.write(File.join(dest, "task.md"),
                   "# t\n\n<!-- REVIEW_ERROR phase=triage reason=merge_conflict pass=1 -->\n")

        request_id = Hive::Web::Dispatcher.new.recover(
          slug: slug, project: project, stage: "6-review",
          marker: "review_error",
          attrs: { "phase" => "triage", "reason" => "merge_conflict", "pass" => "1" },
          retry_projection: retry_projection(7)
        )

        requests = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "**", "*#{request_id}*")]
        payload = requests.filter_map { |f| JSON.parse(File.read(f)) if File.file?(f) }.first
        assert_equal %w[hive retry manual], payload.fetch("argv").first(3)
        assert_equal "7", payload.fetch("argv")[payload.fetch("argv").index("--generation") + 1]
        assert_equal 7, payload.fetch("task_generation")
        refute_includes payload.fetch("argv"), "markers"
      end
    end
  end

  def test_recover_propagates_request_write_failure_without_sequence_sidecar
    with_tmp_global_config do
      original = Hive::Bot::DispatchRequestWriter.method(:write!)
      Hive::Bot::DispatchRequestWriter.define_singleton_method(:write!) do |**|
        raise Errno::ENOSPC, "no space left on device"
      end

      assert_raises(Errno::ENOSPC) do
        Hive::Web::Dispatcher.new.recover(
          slug: "stuck-260612-bbbb", project: "p", stage: "6-review",
          marker: "review_error",
          attrs: { "phase" => "triage", "reason" => "merge_conflict", "pass" => "1" },
          retry_projection: retry_projection(2)
        )
      end

      leftovers = Dir[File.join(Hive::Paths.state_home, "**", "*.sequence*")]
      assert_empty leftovers,
                   "a failed request write must not orphan its .sequence sidecar - "                    "nothing in the daemon ever cleans one whose request id never lands"
    ensure
      Hive::Bot::DispatchRequestWriter.define_singleton_method(:write!, original) if original
    end
  end

  def test_recover_refuses_a_row_without_retry_projection
    with_tmp_global_config do
      error = assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.recover(
          slug: "fine-260612-cccc", project: "p", stage: "6-review", marker: "none"
        )
      end
      assert_match(/retry state changed or is unavailable/, error.message)
    end
  end

  def test_recover_refuses_abandoned_projection
    with_tmp_global_config do
      error = assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.recover(
          slug: "s", project: "p", stage: "6-review",
          marker: "review_error", attrs: { "phase" => "fix", "reason" => "fix_tampered" },
          retry_projection: retry_projection(3, state: "abandoned")
        )
      end
      assert_match(/re-arm/, error.message)
    end
  end

  # Web recover threads the row's workflow so a non-coding task retries via the
  # universal `hive run --stage` instead of falling to a coding retry verb (or
  # an invalid `hive run --from`). All other recover tests use coding rows.
  def test_recover_uses_hive_run_for_a_generic_workflow_row
    with_tmp_global_config do
      request_id = Hive::Web::Dispatcher.new.recover(
        slug: "generic-260620-aaaa", project: "p", stage: "2-gather",
        marker: "error", attrs: {}, workflow: "research", retry_projection: retry_projection(5)
      )

      contents = Dir[File.join(Hive::Paths.state_home, "**", "*#{request_id}*")]
                 .select { |f| File.file?(f) }
                 .map { |f| File.read(f) }.join("\n")

      assert_includes contents, "retry"
      assert_includes contents, "--generation"
      refute_includes contents, "markers"
    end
  end

  def test_answer_questions_requires_an_awaiting_brainstorm
    Dir.mktmpdir("no-brainstorm") do |dir|
      error = assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.answer_questions(folder: dir, answers: { "1" => "x" })
      end
      assert_match(/awaits a brainstorm/, error.message,
                   "answers against a folder with no brainstorm.md must refuse, not 500")
    end
  end

  def test_new_idea_lands_in_the_inbox
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)

        capture_io { Hive::Web::Dispatcher.new.new_idea(project: project, text: "from the web composer") }

        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, inbox.size, "the composer's idea must land as a 1-inbox task"
        assert_includes File.read(File.join(inbox.first, "idea.md")), "from the web composer"
      end
    end
  end

  # Seed a task pinned to a scaffolded CUSTOM workflow (inbox -> work -> done),
  # returning [project, slug]. The descriptor lives only in the project's
  # overlay, so the dispatcher must load it before resolving the task.
  def seed_custom_task(dir, workflow_id)
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::Workflow.new!(workflow_id, project_root: dir) }
    capture_io { Hive::Commands::New.new(project, "custom dispatcher probe", workflow: workflow_id).call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    [ project, File.basename(inbox) ]
  end

  # The in-process drop/approve overlay-registration path must work on a
  # CUSTOM-workflow stage dir, not just coding stages — a regression in
  # per-project overlay loading on a generic stage would otherwise slip the
  # dispatcher unit suite (it's only indirectly covered by the CLI-driven e2e).
  def test_drop_removes_a_custom_workflow_task
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug = seed_custom_task(dir, "flow")
        Hive::Workflows::Project.reset! # fresh process: no overlay pre-loaded

        capture_io do
          Hive::Web::Dispatcher.new.drop(slug: slug, project: project, from: "1-inbox")
        end

        assert_empty Dir[File.join(dir, ".hive-state", "stages", "*", slug)],
                     "drop must remove a custom-workflow task by loading its project overlay"
      end
    end
  ensure
    Hive::Workflows::Project.reset!
  end

  def test_approve_advances_a_custom_workflow_task
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug = seed_custom_task(dir, "flow")
        Hive::Workflows::Project.reset!

        capture_io do
          Hive::Web::Dispatcher.new.approve(slug: slug, project: project, from: "1-inbox")
        end

        assert File.directory?(File.join(dir, ".hive-state", "stages", "2-work", slug)),
               "approve must advance a custom-workflow task from 1-inbox to its 2-work stage"
        refute File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox", slug)),
               "the source stage folder must not survive an advance"
      end
    end
  ensure
    Hive::Workflows::Project.reset!
  end

  def test_drop_hard_deletes_the_task_folder
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug, dest = seed_task_at(dir, "2-brainstorm")

        capture_io do
          Hive::Web::Dispatcher.new.drop(slug: slug, project: project, from: "2-brainstorm")
        end

        refute File.directory?(dest), "drop must remove the stage folder outright (Shift+X parity)"
        assert_empty Dir[File.join(dir, ".hive-state", "stages", "*", slug)],
                     "the slug must not survive in any stage - drop is a delete, not a move"
      end
    end
  end

  def test_drop_scoped_to_a_stale_stage_refuses_instead_of_deleting
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug, dest = seed_task_at(dir, "3-plan")

        assert_raises(Hive::WrongStage) do
          capture_io { Hive::Web::Dispatcher.new.drop(slug: slug, project: project, from: "1-inbox") }
        end
        assert File.directory?(dest), "a stage-mismatched drop must not delete the task"
      end
    end
  end

  def test_reject_sends_task_back_to_immediately_prior_gate
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug, = seed_task_at(dir, "6-review")

        capture_io do
          Hive::Web::Dispatcher.new.reject(slug: slug, project: project, from: "6-review")
        end

        assert File.directory?(File.join(dir, ".hive-state", "stages", "5-open-pr", slug)),
               "reject from 6-review must land in the prior gate 5-open-pr, not 2-brainstorm"
        refute File.directory?(File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)),
               "reject must NOT force a late-stage task all the way back to brainstorm"
      end
    end
  end

  def test_answer_questions_writes_each_numbered_answer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _project, _slug, folder = seed_task_at(dir, "2-brainstorm")
        brainstorm = File.join(folder, "brainstorm.md")
        File.write(brainstorm, "### Q1. Scope?

### A1.

### Q2. Acceptance?

### A2.

")

        result = Hive::Web::Dispatcher.new.answer_questions(
          folder: folder,
          answers: { "2" => "Green tests", "1" => "Header only", "3" => "  " }
        )

        assert_equal [ 1, 2 ], result[:answered], "both non-blank answers must be recorded, blanks skipped"
        parsed = Hive::BrainstormParser.parse(brainstorm)
        assert_equal "Header only", parsed.find { |q| q.n == 1 }.answer.to_s.strip
        assert_equal "Green tests", parsed.find { |q| q.n == 2 }.answer.to_s.strip
      end
    end
  end

  def test_answer_questions_rejects_a_no_longer_open_question
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _project, _slug, folder = seed_task_at(dir, "2-brainstorm")
        File.write(File.join(folder, "brainstorm.md"),
                   "### Q1. Scope?

### A1.
Already answered

### Q2. Acceptance?

### A2.

")

        err = assert_raises(Hive::Error) do
          Hive::Web::Dispatcher.new.answer_questions(folder: folder, answers: { "1" => "again" })
        end

        assert_match(/no longer open/, err.message,
                     "a stale form submit must be told to reload, not silently overwrite")
      end
    end
  end

  def test_intervene_writes_answer_into_brainstorm_file
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _project, _slug, folder = seed_task_at(dir, "2-brainstorm")
        brainstorm = File.join(folder, "brainstorm.md")
        File.write(brainstorm, "### Q1. What is the goal?\n\n### A1.\n\n")

        result = Hive::Web::Dispatcher.new.intervene(folder: folder, message: "Ship the box")

        assert_equal 1, result[:question_n]
        parsed = Hive::BrainstormParser.parse(brainstorm)
        assert_equal "Ship the box", parsed.first.answer.to_s.strip,
                     "intervene must record the operator's message as the answer"
      end
    end
  end

  def test_intervene_without_brainstorm_file_raises_clear_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _project, _slug, folder = seed_task_at(dir, "4-execute")

        error = assert_raises(Hive::Error) do
          Hive::Web::Dispatcher.new.intervene(folder: folder, message: "steer")
        end
        assert_match(/awaits a brainstorm answer/, error.message)
      end
    end
  end

  def test_intervene_requires_a_message
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _project, _slug, folder = seed_task_at(dir, "2-brainstorm")

        assert_raises(Hive::Error) do
          Hive::Web::Dispatcher.new.intervene(folder: folder, message: "   ")
        end
      end
    end
  end

  def test_dispatch_maps_known_action_to_stage_verb
    with_tmp_global_config do
      result = Hive::Web::Dispatcher.new.dispatch(
        slug: "demo-task", project: "demo", action: "ready_for_review", stage: "5-open-pr"
      )

      assert_equal [ "hive", "review", "demo-task", "--project", "demo", "--from", "5-open-pr" ], result[:argv],
                   "ready_for_review must map to the `review` verb (a STAGE_VERB_BY_ACTION typo would fail here)"
    end
  end

  def test_dispatch_surfaces_queue_grammar_rejections_as_typed_errors
    with_tmp_global_config do
      # "x" passes the route constraint upstream of nothing here — but the
      # QUEUE's slug grammar requires two characters, so the writer raises
      # ArgumentError; the operator must get a typed 422, not a 500.
      error = assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.dispatch(slug: "x", project: "p", action: "ready_to_plan")
      end
      assert_match(/cannot queue this dispatch/, error.message)
    end
  end

  def test_dispatch_rejects_an_unknown_action
    with_tmp_global_config do
      dispatcher = Hive::Web::Dispatcher.new

      # An unknown action must NOT be passed through as a literal hive verb
      # (which would enqueue a bad request); it raises so the app maps it to a
      # 422 rather than a queued bad verb or an opaque 500.
      assert_raises(Hive::Error) do
        dispatcher.dispatch(slug: "demo-task", project: "demo", action: "totally-bogus")
      end
    end
  end

  def test_assert_dispatchable_raises_for_unknown_action
    with_tmp_global_config do
      dispatcher = Hive::Web::Dispatcher.new

      assert dispatcher.assert_dispatchable!("ready_to_plan").nil?,
             "a known action passes the guard without raising"
      error = assert_raises(Hive::Error) { dispatcher.assert_dispatchable!("nope") }
      assert_match(/unknown dispatch action/, error.message)
    end
  end

  def test_dispatch_maps_each_gate_action_distinctly
    with_tmp_global_config do
      dispatcher = Hive::Web::Dispatcher.new

      plan = dispatcher.dispatch(slug: "demo-task", project: "demo", action: "ready_to_plan")
      develop = dispatcher.dispatch(slug: "demo-task", project: "demo", action: "ready_to_develop")

      assert_equal "plan", plan[:argv][1], "ready_to_plan must map to `plan`"
      assert_equal "develop", develop[:argv][1], "ready_to_develop must map to `develop`"
    end
  end

  def test_dispatch_rejects_ready_to_advance_because_approve_is_not_queue_routable
    with_tmp_global_config do
      # `ready_to_advance`'s verb is `hive approve`, which the daemon queue
      # allowlist excludes (approve is spawned in-process). The web drives
      # generic advance through the in-process `#approve` method, so the
      # queue `dispatch` must NOT silently accept it.
      assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.dispatch(
          slug: "generic-task", project: "demo", action: "ready_to_advance", stage: "2-gather"
        )
      end
    end
  end

  def test_dispatch_maps_generic_ready_to_run_to_run_with_stage
    with_tmp_global_config do
      # `hive run` has no --from — the web dispatcher must scope it with
      # --stage, not build an invalid `hive run --from`.
      result = Hive::Web::Dispatcher.new.dispatch(
        slug: "generic-task", project: "demo", action: "ready_to_run", stage: "1-intake"
      )

      assert_equal [ "hive", "run", "generic-task", "--project", "demo", "--stage", "1-intake" ],
                   result[:argv]
    end
  end

  private

  def retry_projection(generation, state: "cooldown")
    {
      "state" => state,
      "retry_count" => 1,
      "key" => { "generation" => generation }
    }
  end
end
