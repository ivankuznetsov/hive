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
      assert_raises(KeyError) do
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
