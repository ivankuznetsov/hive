require "test_helper"
require "hive/reviewers"

class ReviewersTest < Minitest::Test
  include HiveTestHelper

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "5-review", "test-task"),
      default_branch: "main",
      pass: 1
    )
  end

  def test_dispatch_returns_agent_for_kind_agent
    with_tmp_dir do |dir|
      spec = {
        "name" => "claude-ce-code-review",
        "kind" => "agent",
        "agent" => "claude",
        "skill" => "ce-code-review",
        "output_basename" => "claude-ce-code-review",
        "prompt_template" => "reviewer_claude_ce_code_review.md.erb"
      }
      reviewer = Hive::Reviewers.dispatch(spec, make_ctx(dir))
      assert_kind_of Hive::Reviewers::Agent, reviewer
      assert_equal "claude-ce-code-review", reviewer.name
    end
  end

  def test_dispatch_defaults_to_agent_when_kind_absent
    with_tmp_dir do |dir|
      # `kind` is optional; agent is the only v1-supported kind so it's
      # the default. Keeps existing project_config.yml.erb scaffolds working
      # if a user removes the redundant `kind: agent` line.
      spec = {
        "name" => "claude-default",
        "agent" => "claude",
        "skill" => "ce-code-review",
        "output_basename" => "claude-default",
        "prompt_template" => "reviewer_claude_ce_code_review.md.erb"
      }
      reviewer = Hive::Reviewers.dispatch(spec, make_ctx(dir))
      assert_kind_of Hive::Reviewers::Agent, reviewer
    end
  end

  def test_dispatch_raises_helpfully_for_kind_linter
    # Linter reviewers are not a hive concept in v1; the helpful error
    # points the user at `review.ci.command` instead of silently
    # ignoring the request.
    with_tmp_dir do |dir|
      spec = { "name" => "rubocop", "kind" => "linter", "output_basename" => "rubocop" }
      err = assert_raises(Hive::Reviewers::UnknownKindError) do
        Hive::Reviewers.dispatch(spec, make_ctx(dir))
      end
      assert_match(/not supported in v1/, err.message)
      assert_match(/review\.ci\.command/, err.message)
      assert_equal Hive::ExitCodes::CONFIG, err.exit_code
    end
  end

  def test_dispatch_raises_for_unknown_kind
    with_tmp_dir do |dir|
      spec = { "name" => "x", "kind" => "weird", "output_basename" => "x" }
      err = assert_raises(Hive::Reviewers::UnknownKindError) do
        Hive::Reviewers.dispatch(spec, make_ctx(dir))
      end
      assert_match(/unknown reviewer kind/, err.message)
      assert_equal Hive::ExitCodes::CONFIG, err.exit_code
    end
  end

  def test_output_path_uses_output_basename_and_zero_padded_pass
    with_tmp_dir do |dir|
      ctx = Hive::Reviewers::Context.new(
        worktree_path: dir,
        task_folder: File.join(dir, "task"),
        default_branch: "main",
        pass: 3
      )
      spec = {
        "name" => "claude-ce-code-review",
        "kind" => "agent",
        "agent" => "claude",
        "skill" => "ce-code-review",
        "output_basename" => "claude-ce-code-review",
        "prompt_template" => "reviewer_claude_ce_code_review.md.erb"
      }
      reviewer = Hive::Reviewers.dispatch(spec, ctx)
      expected = File.join(dir, "task", "reviews", "claude-ce-code-review-03.md")
      assert_equal expected, reviewer.output_path
    end
  end
end
