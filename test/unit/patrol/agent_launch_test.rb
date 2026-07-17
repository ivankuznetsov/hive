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
    assert_equal 3, launch.fetch(:max_turns)
  end

  def test_non_claude_patrol_launch_reserves_prompt_without_claude_flags
    profile = Struct.new(:name, :initial_context_tokens).new(:codex, 0)

    launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, prompt: "é", role: :fix)

    assert_empty launch.fetch(:cli_flags)
    assert_equal 2, launch.fetch(:minimum_tokens)
    assert_nil launch.fetch(:max_turns)
  end
end
