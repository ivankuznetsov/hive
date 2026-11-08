require "test_helper"
require "hive/config"
require "hive/markers"
require "hive/stages/brainstorm"
require "hive/task"

class BrainstormRuntimeTest < Minitest::Test
  include HiveTestHelper

  def test_run_routes_default_claude_brainstorm_through_headless_claude_launch
    with_brainstorm_task do |task|
      captured = nil
      claude = lambda do |_task, cfg, **kwargs|
        captured = [ cfg, kwargs ]
        { status: :error, error_message: "stub" }
      end
      headless = ->(*) { flunk "a Claude brainstorm must not take the non-Claude path" }

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude_with_failure_marker!, claude) do
        with_replaced_singleton_method(Hive::Stages::Brainstorm, :run_headless!, headless) do
          Hive::Stages::Brainstorm.run!(task, brainstorm_cfg.merge("claude" => { "mode" => "tmux" }))
        end
      end

      assert_equal "tmux", captured.fetch(0).dig("claude", "mode"),
                   "the retired claude.mode key is ignored, not rewritten"
      assert_equal :claude, captured.fetch(1).fetch(:profile).name
      assert_equal :state_file_marker, captured.fetch(1).fetch(:status_mode)
      refute captured.fetch(1).key?(:session_name)
    end
  end

  def test_run_routes_non_claude_brainstorm_agent_through_run_headless
    with_brainstorm_task do |task|
      captured = nil
      headless = lambda do |_task, _cfg, profile:|
        captured = profile
        { commit: "error", status: :error }
      end

      with_replaced_singleton_method(Hive::Stages::Brainstorm, :run_headless!, headless) do
        Hive::Stages::Brainstorm.run!(task, brainstorm_cfg.merge("brainstorm" => { "agent" => "codex" }))
      end

      assert_equal :codex, captured.name
    end
  end

  def test_action_for_preserves_unknown_marker_name
    assert_equal "none", Hive::Stages::Brainstorm.action_for(:none)
    assert_equal "paused", Hive::Stages::Brainstorm.action_for(:paused)
  end

  def test_headless_failed_spawn_without_artifact_becomes_typed_brainstorm_error
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |_task, **_kwargs|
        {
          status: :error,
          failure_origin: "budget_exhausted",
          failure_details: {
            provider: "claude",
            subtype: "error_max_budget_usd",
            configured_cap_usd: 1.0,
            observed_cost_usd: 1.047936,
            diagnostic: "Reached maximum budget ($1)",
            remedy: "raise_stage_budget"
          },
          error_message: "agent exhausted its per-run budget"
        }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "budget_exhausted", marker.attrs.fetch("reason")
        assert_equal "raise_stage_budget", marker.attrs.fetch("remedy")
      end
    end
  end

  def test_claude_failed_spawn_without_artifact_becomes_typed_brainstorm_error
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:claude)
      spawn = ->(_task, _cfg, **_kwargs) { { status: :error, error_message: "claude session died" } }

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude_with_failure_marker!, spawn) do
        result = Hive::Stages::Brainstorm.run_claude!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_agent_failed", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "claude session died"
      end
    end
  end

  def test_invalid_waiting_artifact_cannot_complete_brainstorm
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |spawned_task, **_kwargs|
        File.write(spawned_task.state_file, "not a brainstorm\n<!-- WAITING -->\n")
        { status: :waiting }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_artifact_invalid", marker.attrs.fetch("reason")
      end
    end
  end

  def test_changed_valid_artifact_wins_over_trailing_spawn_failure
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |spawned_task, **_kwargs|
        File.write(
          spawned_task.state_file,
          "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
        )
        { status: :error, failure_origin: "budget_exhausted" }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        assert_equal({ commit: "round_waiting", status: :waiting }, result)
        assert_equal :waiting, Hive::Markers.current(task.state_file).name
      end
    end
  end

  def test_unchanged_preexisting_artifact_does_not_hide_failed_spawn
    with_brainstorm_task do |task|
      File.write(
        task.state_file,
        "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
      )
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = ->(_task, **_kwargs) { { status: :error, error_message: "preflight failed" } }

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_agent_failed", marker.attrs.fetch("reason")
      end
    end
  end

  private

  def brainstorm_cfg
    {
      "budget_usd" => { "brainstorm" => 1.0 },
      "timeout_sec" => { "brainstorm" => 30 }
    }
  end

  def with_brainstorm_task
    with_tmp_dir do |root|
      folder = File.join(
        root, ".hive-state", "stages", "2-brainstorm",
        "brainstorm-test-260725-abcd"
      )
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "idea.md"), "Build a reliable system.\n")
      yield Hive::Task.new(folder)
    end
  end
end
