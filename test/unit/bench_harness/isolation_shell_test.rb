# frozen_string_literal: true

require "test_helper"
require_relative "../../support/bench_isolation"

class BenchIsolationShellTest < Minitest::Test
  include BenchIsolationFixture

  def test_api_routes_forward_exactly_the_selected_nonempty_key_without_oauth
    KEYS.each do |key|
      out, err, status = shell_run({ "HB_API_KEYS" => key })

      assert_predicate status, :success?, err
      record = docker_record

      assert_equal [key], credential_names(record)
      assert_equal "decoy-#{key}", record.fetch("env").fetch(key)
      assert_equal ["#{@work}:/work"], mounts(record)
      assert_no_secrets(out + err)
      assert_hardened(record)
    end
  end

  def test_absent_or_empty_selected_key_never_substitutes_another_provider
    [nil, ""].each do |value|
      _out, err, status = shell_run({ "HB_API_KEYS" => "OPENAI_API_KEY", "OPENAI_API_KEY" => value })

      assert_predicate status, :success?, err
      assert_empty credential_names(docker_record)
    end
  end

  def test_oauth_modes_mount_only_their_file_read_only_and_forward_zero_api_keys
    { "CLAUDE" => [@claude_auth, "/tmp/.claude/.credentials.json"],
      "CODEX" => [@codex_auth, "/root/.codex/auth.json"] }.each do |harness, (auth, target)|
      out, err, status = shell_run({ "HB_API_KEYS" => "", "HB_#{harness}_AUTH" => auth })

      assert_predicate status, :success?, err
      record = docker_record

      assert_empty credential_names(record)
      assert_equal ["#{auth}:#{target}:ro", "#{@work}:/work"], mounts(record)
      assert_equal harness == "CODEX" ? "/root" : "/tmp", record.fetch("env").fetch("HOME")
      assert_includes record.fetch("argv"), harness == "CODEX" ? "seccomp=unconfined" : "no-new-privileges"
      assert_no_secrets(out + err)
    end
  end

  def test_missing_and_invalid_declarations_refuse_before_docker_without_echoing_input
    [nil, "UNKNOWN", "OPENAI_API_KEY=decoy-OPENAI_API_KEY", " OPENAI_API_KEY", "OPENAI_API_KEY ",
     "OPENAI_API_KEY\n", "OPENAI_API_KEY ANTHROPIC_API_KEY", "OPENAI_API_KEY,ANTHROPIC_API_KEY"].each do |declaration|
      assert_refusal({ "HB_API_KEYS" => declaration }, DECLARATION_ERROR)
    end
  end

  def test_incomplete_conflicting_or_nonregular_oauth_sources_refuse_before_docker
    [{ "HB_API_KEYS" => "" },
     { "HB_API_KEYS" => "", "HB_CLAUDE_AUTH" => @claude_auth, "HB_CODEX_AUTH" => @codex_auth },
     { "HB_API_KEYS" => "OPENAI_API_KEY", "HB_CLAUDE_AUTH" => @claude_auth },
     { "HB_API_KEYS" => "OPENAI_API_KEY", "HB_CODEX_AUTH" => @codex_auth },
     { "HB_API_KEYS" => "", "HB_CODEX_AUTH" => @work },
     { "HB_API_KEYS" => "", "HB_CLAUDE_AUTH" => "#{@claude_auth}.missing" }].each { |env| assert_refusal(env, AUTH_ERROR) }
  end

  def test_gate_ignores_every_generator_credential_control
    out, err, status = shell_run({ "HB_API_KEYS" => "malicious\ninput", "HB_CLAUDE_AUTH" => @claude_auth,
                                   "HB_CODEX_AUTH" => @codex_auth, "HB_ALLOW_EGRESS" => "0" }, mode: "gate")

    assert_predicate status, :success?, err
    record = docker_record

    assert_empty credential_names(record)
    assert_equal ["#{@work}:/work"], mounts(record)
    assert_includes record.fetch("argv").each_cons(2).to_a, ["--network", "none"]
    assert_no_secrets(out + err)
    assert_hardened(record)
  end

  def test_command_argument_boundaries_are_preserved
    command = ["sh", "-c", "printf '%s' 'a b; $x'", "argument with spaces"]
    _out, err, status = shell_run({ "HB_API_KEYS" => "OPENAI_API_KEY" }, command: command)

    assert_predicate status, :success?, err
    assert_equal command, docker_record.fetch("argv").last(command.length)
  end

  def test_ruby_preserves_refusal_status_but_redacts_docker_stderr_for_gen_and_gate
    [70, 125, 126, 127].each do |code|
      with_isolation_env("HB_TEST_DOCKER_EXIT" => code.to_s,
                         "HB_TEST_DOCKER_ERROR" => "decoy-OPENAI_API_KEY #{@codex_auth}") do
        %w[gen gate].each do |phase|
          error = assert_raises(HiveBench::IsolationExec::IsolationError) do
            if phase == "gen"
              HiveBench::IsolationExec.gen_exec.call(profile: profile, prompt: "x", cwd: @work)
            else
              HiveBench::IsolationExec.gate_exec.call(cmd: "true", work_dir: @work)
            end
          end
          assert_equal "runner could not establish isolation (#{phase}, exit #{code})", error.message
          assert_no_secrets(error.message)
          assert_path_exists @docker_log
        end
      end
    end
  end

  def test_wrapper_refusal_through_ruby_is_isolation_error_with_zero_docker_calls
    with_isolation_env do
      invalid = profile("claude", auth: "#{@claude_auth}.missing")
      error = assert_raises(HiveBench::IsolationExec::IsolationError) do
        HiveBench::IsolationExec.gen_exec.call(profile: invalid, prompt: "x", cwd: @work)
      end
      assert_equal "runner could not establish isolation (gen, exit 70)", error.message
      refute_path_exists @docker_log
      refute_path_exists File.join(@work, HiveBench::IsolationExec::PROMPT_FILE)
      assert_refusal({ "HB_API_KEYS" => "", "HB_CLAUDE_AUTH" => invalid.auth_path }, AUTH_ERROR)
    end
  end

  def test_sequential_planner_executor_policies_override_poison_without_changing_parent_env
    with_isolation_env("HB_API_KEYS" => "poison", "HB_CLAUDE_AUTH" => @claude_auth, "HB_CODEX_AUTH" => @codex_auth) do
      before = ENV.to_h
      candidates = [profile, profile("claude", auth: @claude_auth), profile("codex", auth: @codex_auth),
                    profile("pi", "anthropic/model"), profile("pi", "openai/model")]
      candidates.each do |candidate|
        capture_io { HiveBench::IsolationExec.gen_exec(frame: ->(p) { p }).call(profile: candidate, prompt: "plan", cwd: @work) }
        record = docker_record
        if candidate.harness == "pi"
          expected = { "openrouter" => "OPENROUTER_API_KEY", "anthropic" => "ANTHROPIC_API_KEY",
                       "openai" => "OPENAI_API_KEY" }[candidate.model.split("/").first]
        end

        assert_equal Array(expected), credential_names(record)
        auth_mounts = mounts(record).reject { |mount| mount.end_with?(":/work") }
        expected_mount = case candidate.harness
                         when "claude" then "#{@claude_auth}:/tmp/.claude/.credentials.json:ro"
                         when "codex" then "#{@codex_auth}:/root/.codex/auth.json:ro"
                         end

        assert_equal Array(expected_mount), auth_mounts
        assert_equal before, ENV.to_h
        refute_path_exists File.join(@work, HiveBench::IsolationExec::PROMPT_FILE)
      end
    end
  end

  private

  def assert_refusal(env, diagnostic)
    out, err, status = shell_run(env)

    assert_equal 70, status.exitstatus
    assert_equal diagnostic, err
    assert_empty out
    refute_path_exists @docker_log
    assert_no_secrets(err)
  end

  def assert_hardened(record)
    args = record.fetch("argv")

    ["--rm", "--read-only", "no-new-privileges"].each { |arg| assert_includes args, arg }
    [["--cpus", "8"], ["--memory", "16g"], ["--pids-limit", "4096"],
     ["--cap-drop", "ALL"], ["--tmpfs", "/tmp"]].each { |pair| assert_includes args.each_cons(2).to_a, pair }
  end
end
