require "test_helper"
require "hive/patrol/agent_launch"

class PatrolAgentLaunchTest < Minitest::Test
  def test_claude_patrol_launch_disables_customizations_and_reserves_initial_context
    profile = Struct.new(:name, :initial_context_tokens) do
      def require_cli_capability!(name)
        raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

        [ "--safe-mode", "--disable-slash-commands" ]
      end
    end.new(:claude, 8_000)

    launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, prompt: "review this", role: :review)

    assert_equal [ "--safe-mode", "--disable-slash-commands" ], launch.fetch(:cli_flags)
    assert_equal 8_011, launch.fetch(:minimum_tokens)
    assert_equal 4, launch.fetch(:max_turns)
  end

  def test_non_claude_patrol_launch_reserves_prompt_without_claude_flags
    profile = Struct.new(:name, :initial_context_tokens).new(:codex, 0)

    launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, prompt: "é", role: :fix)

    assert_empty launch.fetch(:cli_flags)
    assert_equal 2, launch.fetch(:minimum_tokens)
    assert_nil launch.fetch(:max_turns)
  end

  def test_claude_patrol_launch_uses_project_model_without_an_exact_route
    profile = Struct.new(:name, :initial_context_tokens) do
      def require_cli_capability!(_name)
        [ "--disable-slash-commands" ]
      end
    end.new(:claude, 0)
    cfg = {
      "claude" => {
        "model" => "claude-opus-4-8",
        "effort" => "high"
      }
    }

    launch = Hive::Patrol::AgentLaunch.prepare(
      profile: profile,
      prompt: "review this",
      role: :review,
      cfg: cfg,
      routing_arguments: nil
    )

    assert_equal [
      "--disable-slash-commands",
      "--model", "claude-opus-4-8",
      "--effort", "high"
    ], launch.fetch(:cli_flags)
    refute launch.key?(:routing_arguments)
  end

  def test_exact_route_replaces_legacy_claude_model_flags
    profile = Struct.new(:name, :initial_context_tokens) do
      def require_cli_capability!(_name)
        [ "--disable-slash-commands" ]
      end
    end.new(:claude, 0)
    route = Object.new
    cfg = { "claude" => { "model" => "claude-opus-4-8" } }

    launch = Hive::Patrol::AgentLaunch.prepare(
      profile: profile,
      prompt: "review this",
      role: :review,
      cfg: cfg,
      routing_arguments: route
    )

    assert_equal [ "--disable-slash-commands" ], launch.fetch(:cli_flags)
    refute launch.key?(:routing_arguments)
  end
end
