# frozen_string_literal: true

require "test_helper"
require_relative "../../support/bench_isolation"

class BenchIsolationPolicyTest < Minitest::Test
  include BenchIsolationFixture

  IE = HiveBench::IsolationExec
  POLICY_ERROR = "gen credentials require a supported Pi provider prefix or a configured Claude/Codex OAuth file"

  def test_each_pi_provider_declares_only_its_key_and_removes_oauth_paths
    { "openrouter" => "OPENROUTER_API_KEY", "anthropic" => "ANTHROPIC_API_KEY", "openai" => "OPENAI_API_KEY" }.each do |provider, key|
      candidate = profile("pi", "#{provider}/vendor/model:high")
      before = candidate.model.dup

      assert_equal({ "HB_ALLOW_EGRESS" => "1", "HB_API_KEYS" => key,
                     "HB_CLAUDE_AUTH" => nil, "HB_CODEX_AUTH" => nil }, IE.gen_env(candidate))
      assert_equal before, candidate.model
      assert_predicate candidate, :frozen?
    end
  end

  def test_oauth_profiles_declare_empty_keys_and_only_their_configured_file
    { "claude" => @claude_auth, "codex" => @codex_auth }.each do |harness, auth|
      env = IE.gen_env(profile(harness, auth: auth))

      assert_equal "", env.fetch("HB_API_KEYS")
      assert_equal auth, env.fetch("HB_#{harness.upcase}_AUTH")
      assert_nil env.fetch(harness == "claude" ? "HB_CODEX_AUTH" : "HB_CLAUDE_AUTH")
    end
  end

  def test_unknown_policy_refuses_before_spawning_and_cleans_the_prompt
    candidates = [ profile("unknown"), profile("pi", "unknown/model"), profile("pi", "openrouter/"),
                  profile("pi", "minimax-3"), profile("pi", "qwen-2.6-coder"),
                  profile("claude"), profile("codex", auth: "") ]
    candidates.each do |candidate|
      error = assert_raises(IE::IsolationError) do
        IE.gen_exec(script: @spawn_script).call(profile: candidate, prompt: "x", cwd: @work)
      end
      assert_equal POLICY_ERROR, error.message
      refute_path_exists @spawn_log
      refute_path_exists File.join(@work, IE::PROMPT_FILE)
      refute_path_exists @docker_log
    end
  end

  def test_every_slate_pi_route_is_either_explicit_openrouter_or_refused
    seen = []
    HiveBench::Slate.pi_open_models.each do |candidate|
      seen << candidate.id
      if candidate.model.start_with?("openrouter/")
        assert_equal "OPENROUTER_API_KEY", IE.gen_env(candidate).fetch("HB_API_KEYS")
      else
        error = assert_raises(IE::IsolationError) do
          IE.gen_exec(script: @spawn_script).call(profile: candidate, prompt: "x", cwd: @work)
        end
        assert_equal POLICY_ERROR, error.message
        refute_path_exists @spawn_log
        refute_path_exists @docker_log
      end
    end

    assert_equal %w[pi@kimi-k2.7 pi@minimax-3 pi@qwen-2.6-coder pi@glm-5.2], seen
  end

  def test_spawn_environment_removes_inherited_oauth_paths_without_mutating_parent
    script = File.join(@isolation_dir, "environment.sh")
    File.write(script, <<~'BASH')
      printf '%s\n' "${HB_API_KEYS-unset}" "${HB_CLAUDE_AUTH-unset}" "${HB_CODEX_AUTH-unset}" > "$HB_TEST_DOCKER_LOG"
    BASH
    with_isolation_env("HB_API_KEYS" => "poison", "HB_CLAUDE_AUTH" => @claude_auth, "HB_CODEX_AUTH" => @codex_auth) do
      before = ENV.to_h
      [ profile, profile("claude", auth: @claude_auth), profile("codex", auth: @codex_auth) ].each do |candidate|
        capture_io { IE.gen_exec(script: script).call(profile: candidate, prompt: "x", cwd: @work) }
        expected = IE.gen_env(candidate)

        assert_equal [ expected.fetch("HB_API_KEYS"), expected["HB_CLAUDE_AUTH"] || "unset",
                      expected["HB_CODEX_AUTH"] || "unset" ], File.readlines(@docker_log, chomp: true)
        assert_equal before, ENV.to_h
      end
    end
  end
end
