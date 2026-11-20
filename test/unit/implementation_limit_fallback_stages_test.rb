require "test_helper"
require "json"
require "hive/implementation_limit_fallback"
require "hive/stages/artifacts"
require "hive/stages/finalize"
require "hive/task"

# implementation.limit_fallback at the config-driven launch seams: the
# finalize agent and the artifacts inference / reviewer roles (the producer
# reports the fallback as unsupported).
class ImplementationLimitFallbackStagesTest < Minitest::Test
  include HiveTestHelper

  LONG_LIMIT = "You've hit your usage limit. Upgrade to Pro or try again at Nov 23rd.".freeze
  LIMIT_MESSAGE = "limits reached for codex: You've hit your usage limit.".freeze
  LIMITED = { status: :error, error_reason: "limits_reached", limit_text: LONG_LIMIT,
              error_message: LIMIT_MESSAGE, retry_at: "2026-11-20T11:00:00Z" }.freeze
  PR_URL = "https://github.com/acme/app/pull/9".freeze
  FinalizeTask = Struct.new(:folder, :state_file, :slug, :project_root, keyword_init: true)

  def enabled_cfg(agents: { "codex" => "grok" }, enabled: true, extra: {})
    {
      "implementation" => {
        "limit_fallback" => { "enabled" => enabled, "min_wait_sec" => 3600, "agents" => agents }
      }
    }.merge(extra)
  end

  def reset_hint(at)
    "You've hit your usage limit. Try again at #{at.utc.strftime('%b %-d, %Y %-I:%M %p')} UTC."
  end

  # --- 8-finalize -----------------------------------------------------------

  def test_finalize_limit_falls_back_and_the_substitute_completes_the_stage
    with_finalize_task do |task|
      calls = []
      result = nil
      _out, err = capture_io do
        result = with_finalize_spawns(task, calls, [ :limited, :complete ]) do
          Hive::Stages::Finalize.run!(task, enabled_cfg(extra: { "finalize" => { "model" => "gpt-5.6-sol" } }))
        end
      end

      assert_equal({ commit: "pr_finalized", status: :complete }, result)
      assert_equal %w[codex grok], calls.map { |call| call.fetch(:profile).name.to_s }
      assert_equal "grok", calls.last.fetch(:limit_fallback).fallback
      assert_match(/finalize: codex hit a usage\/credit limit .*fallback grok used/, err)
    end
  end

  def test_finalize_limit_is_unchanged_when_disabled
    with_finalize_task do |task|
      calls = []
      result = with_finalize_spawns(task, calls, [ :limited ]) do
        Hive::Stages::Finalize.run!(task, enabled_cfg(enabled: false))
      end

      assert_equal({ commit: nil, status: :error }, result)
      assert_equal 1, calls.length
      attrs = Hive::Markers.current(task.state_file).attrs
      assert_equal "limits_reached", attrs.fetch("reason")
      assert_nil attrs["fallback_agent"]
    end
  end

  def test_finalize_republishes_the_primary_limit_when_the_fallback_does_not_run_or_fails
    {
      [ :limited, :limited ] => "limited",
      [ :limited, :crashed ] => "failed",
      [ :soon ] => "waiting"
    }.each do |responses, outcome|
      with_finalize_task do |task|
        calls = []
        result = nil
        capture_io do
          result = with_finalize_spawns(task, calls, responses) do
            Hive::Stages::Finalize.run!(task, enabled_cfg)
          end
        end

        assert_equal({ commit: nil, status: :error }, result, outcome)
        attrs = Hive::Markers.current(task.state_file).attrs
        assert_equal [ "limits_reached", "codex", "grok", outcome ],
                     attrs.values_at("reason", "provider", "fallback_agent", "fallback_outcome"), outcome
      end
    end

    with_finalize_task do |task|
      calls = []
      with_replaced_singleton_method(Hive::ImplementationLimitFallback, :record!, ->(**) { false }) do
        with_finalize_spawns(task, calls, [ :limited ]) { Hive::Stages::Finalize.run!(task, enabled_cfg) }
      end
      assert_equal 1, calls.length
      assert_equal "failed", Hive::Markers.current(task.state_file).attrs.fetch("fallback_outcome")
    end
  end

  def test_finalize_substitute_tampering_is_terminal
    with_finalize_task do |task|
      calls = []
      result = nil
      capture_io do
        result = with_finalize_spawns(task, calls, [ :limited, :tamper ]) do
          Hive::Stages::Finalize.run!(task, enabled_cfg)
        end
      end

      assert_equal({ commit: "finalize_tampered", status: :error }, result)
      assert_equal 2, calls.length
    end
  end

  def test_finalize_substitute_launch_withholds_the_primary_model
    with_finalize_task do |task|
      captured = []
      spawn = ->(_task, **kwargs) { captured << kwargs; { status: :error } }
      plan = Hive::ImplementationLimitFallback::Plan.new(
        stage: "finalize", role: "finalize", primary: "codex", fallback: "grok", state: "substitute",
        retry_after: nil, limit_detail: "limit", identity: nil
      )
      cfg = { "finalize" => { "agent" => "codex", "model" => "gpt-5.6-sol" } }
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        Hive::Stages::Finalize.spawn_finalize_agent(
          task, cfg, "prompt", Hive::AgentProfiles.lookup("grok"), task.folder, limit_fallback: plan
        )
        Hive::Stages::Finalize.spawn_finalize_agent(
          task, cfg, "prompt", Hive::AgentProfiles.lookup("codex"), task.folder
        )
      end

      assert_equal "finalize-fallback-grok", captured.first.fetch(:log_label)
      refute captured.first.key?(:model)
      assert_equal "gpt-5.6-sol", captured.last.fetch(:model)
    end
  end

  # --- 7-artifacts ----------------------------------------------------------

  def test_artifacts_inference_limit_falls_back_on_the_fallback_profile
    with_artifacts_task do |task, identity|
      calls = []
      cfg = enabled_cfg(extra: { "artifacts" => { "agent" => "codex", "model" => "gpt-5.6-sol" } })
      result = nil
      _out, err = capture_io do
        result = with_role_spawns(calls, [ LIMITED, inference_output ]) do
          Hive::Stages::Artifacts.run_role!(role: "inference", task: task, cfg: cfg, prompt: "infer",
                                            identity: identity)
        end
      end

      assert_equal %w[codex grok], calls.map { |call| call.fetch(:profile).name.to_s }
      assert_match(/\Aartifacts-inference-.*-fallback-grok\z/, calls.last.fetch(:log_label))
      refute calls.last.key?(:model), "the primary's artifacts.model never reaches the fallback"
      assert_equal "grok", result.dig(:actor, "agent")
      assert_equal "provider-default", result.dig(:actor, "model")
      assert_match(/artifacts inference: codex hit a usage\/credit limit .*fallback grok used/, err)
    end
  end

  def test_artifacts_fallback_runs_the_stage_model_when_artifacts_agent_names_it
    with_artifacts_task do |task, identity|
      calls = []
      cfg = enabled_cfg(extra: {
        "artifacts" => {
          "agent" => "grok", "model" => "grok-4.7",
          "evidence" => { "reviewer" => { "agent" => "codex", "permissions" => "read-only" } }
        }
      })
      result = nil
      capture_io do
        result = with_role_spawns(calls, [ LIMITED, inference_output ]) do
          Hive::Stages::Artifacts.run_role!(role: "reviewer", task: task, cfg: cfg, prompt: "review",
                                            identity: identity)
        end
      end

      assert_equal "grok-4.7", calls.last.fetch(:model)
      assert_equal %w[grok grok-4.7], result.fetch(:actor).values_at("agent", "model")
    end
  end

  def test_artifacts_role_limit_stands_when_the_fallback_is_off_waits_or_fails
    cases = {
      [ enabled_cfg(enabled: false), [ LIMITED ] ] => nil,
      [ enabled_cfg, [ LIMITED.merge(limit_text: reset_hint(Time.now.utc + 600)) ] ] => "waiting",
      [ enabled_cfg, [ LIMITED, LIMITED ] ] => "limited",
      [ enabled_cfg, [ LIMITED, { status: :error, error_message: "grok crashed" } ] ] => "failed"
    }
    cases.each do |(cfg, responses), outcome|
      with_artifacts_task do |task, identity|
        calls = []
        error = nil
        capture_io do
          error = assert_raises(Hive::Stages::Artifacts::RoleAgentError) do
            with_role_spawns(calls, responses) do
              Hive::Stages::Artifacts.run_role!(
                role: "inference", task: task, cfg: cfg.merge("artifacts" => { "agent" => "codex" }),
                prompt: "infer", identity: identity
              )
            end
          end
        end

        assert_equal "codex", error.profile.name.to_s
        assert_same_value outcome, error.fallback_attrs[:fallback_outcome]
        Hive::Stages::Artifacts.publish_role_agent_error!(task, error)
        attrs = Hive::Markers.current(task.state_file).attrs
        assert_equal [ "limits_reached", outcome ], attrs.values_at("reason", "fallback_outcome")
      end
    end

    with_artifacts_task do |task, identity|
      calls = []
      error = with_replaced_singleton_method(Hive::ImplementationLimitFallback, :record!, ->(**) { false }) do
        with_role_spawns(calls, [ LIMITED ]) do
          assert_raises(Hive::Stages::Artifacts::RoleAgentError) do
            Hive::Stages::Artifacts.run_role!(
              role: "inference", task: task, cfg: enabled_cfg.merge("artifacts" => { "agent" => "codex" }),
              prompt: "infer", identity: identity
            )
          end
        end
      end
      assert_equal "failed", error.fallback_attrs.fetch(:fallback_outcome)
      assert_equal 1, calls.length
    end
  end

  def test_artifacts_producer_limit_reports_the_fallback_as_unsupported
    [ [ enabled_cfg, "unsupported" ], [ enabled_cfg(agents: { "claude" => "grok" }), nil ] ].each do |cfg, outcome|
      with_artifacts_task do |task, identity|
        calls = []
        error = nil
        capture_io do
          error = assert_raises(Hive::Stages::Artifacts::RoleAgentError) do
            with_role_spawns(calls, [ LIMITED ]) do
              Hive::Stages::Artifacts.run_role!(
                role: "producer", task: task,
                cfg: cfg.merge("artifacts" => { "evidence" => { "producer" => { "agent" => "codex" } } }),
                prompt: "produce", identity: identity,
                writable_root: File.join(task.folder, "evidence")
              )
            end
          end
        end

        assert_equal 1, calls.length
        assert_same_value outcome, error.fallback_attrs[:fallback_outcome]
      end
    end
  end

  private

  def assert_same_value(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def inference_output
    { status: :ok, final_message: '{"claims":[],"exclusions":[]}', final_message_truncated: false }
  end

  def with_artifacts_task
    Dir.mktmpdir("hive-artifacts-fallback") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-261120-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      File.write(task.state_file, "# Artifacts\n")
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      with_replaced_singleton_method(Hive::Artifacts::OutcomeEvidence::Identity, :new, ->(**) { resolver }) do
        yield task, identity
      end
    end
  end

  def with_role_spawns(calls, responses)
    queue = responses.dup
    spawn = lambda do |_task, agent_custody:, **kwargs|
      calls << kwargs
      response = queue.shift
      agent_custody.call { response.dup }
    end
    with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) { yield }
  end

  def with_finalize_task
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p([ folder, worktree ])
      task = FinalizeTask.new(folder: folder, state_file: File.join(folder, "pr.md"),
                              slug: "fallback-task", project_root: root)
      File.write(File.join(folder, "plan.md"), "# plan\n")
      File.write(File.join(folder, "worktree.yml"), { "path" => worktree, "branch" => task.slug }.to_yaml)
      File.write(task.state_file, pr_body("<!-- COMPLETE pr_url=#{PR_URL} is_draft=true -->"))
      yield task
    end
  end

  def pr_body(marker)
    "---\npr_url: #{PR_URL}\npr_number: 9\n---\n\n## Summary\n\n#{marker}\n"
  end

  # Responses: :limited (the primary's Agent wrote limits_reached), :soon (a
  # limit resetting within min_wait_sec), :complete (the agent finalized),
  # :crashed (a non-limit failure), :tamper (a protected-file write).
  def with_finalize_spawns(task, calls, responses, &block)
    queue = responses.dup
    test = self
    spawn = lambda do |spawned, _cfg, _prompt, profile, _worktree, agent_custody:, **kwargs|
      calls << kwargs.merge(profile: profile)
      agent_custody.call { test.send(:finalize_response, spawned, queue.shift, profile) }
    end
    clean = Hive::Gh::ScanResult.new(hits: [], fetch_failed: false, fetch_error: nil)
    stubs = [
      [ Hive::Stages::Finalize, :validate_pr_reference!, ->(*) { [ PR_URL, nil ] } ],
      [ Hive::Gh, :scan_pr_for_secrets, ->(**) { clean } ],
      [ Hive::Stages::Finalize, :pr_already_merged?, ->(*) { false } ],
      [ Hive::Gh, :ensure_authenticated!, ->(*) { } ],
      [ Hive::Stages::Finalize, :verify_state!, ->(*) { nil } ],
      [ Hive::Stages::Finalize, :refresh_pr_identity!, ->(*) { nil } ],
      [ Hive::Stages::Finalize, :render_prompt, ->(*) { "prompt" } ],
      [ Hive::Stages::Base, :stage_profile, ->(*, **) { Hive::AgentProfiles.lookup("codex") } ],
      [ Hive::Stages::Finalize, :spawn_finalize_agent, spawn ],
      [ Hive::Stages::Finalize, :mark_pr_ready, ->(*) { nil } ],
      [ Hive::Stages::Finalize, :write_summary, ->(*) { true } ]
    ]
    with_stubs(stubs, &block)
  end

  def finalize_response(task, response, profile)
    case response
    when :limited, :soon
      text = response == :soon ? reset_hint(Time.now.utc + 600) : LONG_LIMIT
      Hive::Markers.set(task.state_file, :error, reason: "limits_reached",
                                                 message: "limits reached for #{profile.name}: #{text}")
      LIMITED.merge(limit_text: text, error_message: "limits reached for #{profile.name}: #{text}")
    when :complete
      File.write(task.state_file, pr_body("<!-- COMPLETE pr_url=#{PR_URL} is_draft=false -->"))
      { status: :complete }
    when :crashed
      Hive::Markers.set(task.state_file, :error, reason: "exit_code", exit_code: 1)
      { status: :error, error_message: "exit_code=1" }
    when :tamper
      File.write(File.join(task.folder, "plan.md"), "# rewritten\n")
      { status: :ok }
    end
  end

  def with_stubs(stubs, &block)
    return yield if stubs.empty?

    receiver, name, replacement = stubs.first
    with_replaced_singleton_method(receiver, name, replacement) { with_stubs(stubs.drop(1), &block) }
  end
end
