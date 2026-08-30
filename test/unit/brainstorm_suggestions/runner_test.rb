require "test_helper"
require "hive/agent_profiles"
require "hive/brainstorm_suggestions/runner"

class HiveBrainstormSuggestionsRunnerTest < Minitest::Test
  Bundle = Struct.new(:manifest) do
    def materialize(root)
      path = File.join(root, "bundle")
      FileUtils.mkdir_p(path, mode: 0o700)
      File.write(File.join(path, "context.md"), "repository evidence", mode: "w", perm: 0o400)
      File.chmod(0o400, File.join(path, "context.md"))
      path
    end

    def render_context = "repository evidence"
    def question = { "text" => "Which adapter?" }
  end

  def bundle
    Bundle.new({ "entries" => [ { "source" => "repository" } ] })
  end

  def test_only_profiles_with_explicit_data_only_capability_are_supported
    assert Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(:claude))
    %i[codex pi grok opencode].each do |name|
      refute Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(name)), name
    end
  end

  def test_runner_uses_toolless_bubblewrap_launch_and_always_removes_runtime
    runtime = nil
    executor = lambda do |launch|
      runtime = launch.runtime_root
      assert File.directory?(runtime)
      assert_equal "/usr/bin/bwrap", launch.argv.first
      tools_index = launch.argv.index("--tools")
      assert_equal "", launch.argv.fetch(tools_index + 1)
      refute launch.argv.any? { |value| value.include?(Dir.pwd) }
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: JSON.generate("structured_output" => {
          "disposition" => "suggestion", "text" => "Use the adapter.",
          "rationale" => "It matches the evidence.", "provenance" => [ "repository" ]
        }),
        exit_code: 0, timed_out: false
      )
    end
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:claude), executor: executor,
      bwrap_path: "/usr/bin/bwrap", executable_resolver: ->(*) { "/bin/true" }
    )

    result = runner.call(bundle: bundle)

    assert_equal "fresh", result.fetch("state")
    refute File.exist?(runtime)
  end

  def test_unsupported_route_is_unavailable_and_never_executes
    executed = false
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:codex), executor: ->(*) { executed = true },
      bwrap_path: "/usr/bin/bwrap"
    )

    result = runner.call(bundle: bundle)

    assert_equal "unavailable", result.fetch("state")
    assert_equal false, executed
  end

  def test_failure_timeout_and_spawn_error_remove_runtime_without_raw_output
    outcomes = [
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: "provider secret body", exit_code: 2, timed_out: false
      ),
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: "partial secret body", exit_code: nil, timed_out: true
      ),
      Errno::ENOENT.new("provider secret path")
    ]

    outcomes.each do |outcome|
      runtime = nil
      executor = lambda do |launch|
        runtime = launch.runtime_root
        raise outcome if outcome.is_a?(Exception)

        outcome
      end
      runner = Hive::BrainstormSuggestions::Runner.new(
        profile: Hive::AgentProfiles.lookup(:claude), executor: executor,
        bwrap_path: "/usr/bin/bwrap", executable_resolver: ->(*) { "/bin/true" }
      )

      result = runner.call(bundle: bundle)
      assert_equal "failed", result.fetch("state")
      refute_includes result.fetch("safe_reason"), "secret"
      refute File.exist?(runtime)
    end
  end
end
