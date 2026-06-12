require "test_helper"
require "hive/web/dispatcher"
require "hive/commands/init"
require "hive/commands/new"
require "hive/brainstorm_parser"

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

  def test_recover_queues_marker_clear_then_stage_rerun_as_one_sequence
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project, slug, dest = seed_task_at(dir, "6-review")
        File.write(File.join(dest, "task.md"),
                   "# t\n\n<!-- REVIEW_ERROR phase=triage reason=triage_failed pass=1 -->\n")

        request_id = Hive::Web::Dispatcher.new.recover(
          slug: slug, project: project, stage: "6-review",
          marker: "review_error",
          attrs: { "phase" => "triage", "reason" => "triage_failed", "pass" => "1" }
        )

        requests = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "**", "*#{request_id}*")]
        assert requests.any? { |f| File.file?(f) && File.read(f).include?("markers") },
               "the FIRST queued command must be the guarded marker clear"
        first = requests.map { |f| File.read(f) if File.file?(f) }.compact.join
        assert_includes first, "pass=1", "the clear must be guarded by the most discriminating attr"

        sequence = Dir[File.join(Hive::Paths.state_home, "**", "*#{request_id}*")]
                   .select { |f| File.file?(f) && File.read(f).include?("review") }
        assert sequence.any?,
               "the stage rerun must ride the same request id so it stays invisible until the clear succeeds"
      end
    end
  end

  def test_recover_refuses_manual_only_states_with_a_readable_error
    with_tmp_global_config do
      error = assert_raises(Hive::Error) do
        Hive::Web::Dispatcher.new.recover(
          slug: "s", project: "p", stage: "6-review",
          marker: "review_error", attrs: { "phase" => "fix", "reason" => "fix_tampered" }
        )
      end
      refute_empty error.message, "the manual-only reply must reach the operator"
    end
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
end
