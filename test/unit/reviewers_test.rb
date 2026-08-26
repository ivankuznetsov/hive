require "test_helper"
require "hive/reviewers"

class ReviewersTest < Minitest::Test
  include HiveTestHelper

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "6-review", "test-task"),
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

  def test_explicit_route_translates_native_codex_review_to_admitted_agent
    with_tmp_dir do |dir|
      spec = {
        "name" => "native",
        "kind" => "codex_review",
        "agent" => "codex",
        "output_basename" => "native",
        "prompt_template" => "reviewer_codex_native_review.md.erb"
      }
      context = Object.new
      context.define_singleton_method(:explicit_routing?) { true }
      context.define_singleton_method(:adapter) { "grok" }

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        reviewer = Hive::Reviewers.dispatch(spec, make_ctx(dir))

        assert_instance_of Hive::Reviewers::Agent, reviewer
        assert_equal "grok", reviewer.spec.fetch("agent")
        assert_equal "ce-code-review", reviewer.spec.fetch("skill")
        assert_equal "reviewer_grok_ce_code_review.md.erb",
                     reviewer.spec.fetch("prompt_template")
      end

      assert_equal "codex_review", spec.fetch("kind"), "dispatch must not mutate frozen config"
    end
  end

  def test_legacy_route_keeps_native_codex_review_adapter
    with_tmp_dir do |dir|
      spec = {
        "name" => "native",
        "kind" => "codex_review",
        "agent" => "codex",
        "output_basename" => "native",
        "prompt_template" => "reviewer_codex_native_review.md.erb"
      }

      assert_instance_of Hive::AgentSupport.for(:codex)::Reviewer,
                         Hive::Reviewers.dispatch(spec, make_ctx(dir))
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

  def test_base_reviewer_run_must_be_implemented_by_subclasses
    with_tmp_dir do |dir|
      spec = { "name" => "base", "output_basename" => "base" }
      reviewer = Hive::Reviewers::Base.new(spec, make_ctx(dir))

      error = assert_raises(NotImplementedError) { reviewer.run! }
      assert_match(/Hive::Reviewers::Base must implement #run!/, error.message)
    end
  end

  # ── Context alias coverage ─────────────────────────────────────────────

  # The canonical home of the per-spawn Context Data type is
  # Hive::Stages::Review::Context (the 6-review stage owns the type
  # because triage / ci_fix / browser_test / fix_guardrail all consume
  # it, none of which are reviewers). The legacy
  # Hive::Reviewers::Context alias must keep pointing at the same class
  # so external callers and the existing Reviewers::Agent adapter keep
  # working.
  def test_reviewers_context_is_alias_of_stages_review_context
    require "hive/stages/review/context"
    assert_equal Hive::Stages::Review::Context, Hive::Reviewers::Context,
                 "Reviewers::Context must alias Stages::Review::Context"
  end

  def test_constructing_via_either_name_yields_same_data_class_instance
    require "hive/stages/review/context"
    canonical = Hive::Stages::Review::Context.new(
      worktree_path: "/wt", task_folder: "/tf", default_branch: "main", pass: 1
    )
    via_alias = Hive::Reviewers::Context.new(
      worktree_path: "/wt", task_folder: "/tf", default_branch: "main", pass: 1
    )
    assert_equal canonical.class, via_alias.class,
                 "instances built via either name share the same Data class"
    assert_equal canonical, via_alias,
                 "Data equality holds across the alias because the classes are identical"
  end
end
