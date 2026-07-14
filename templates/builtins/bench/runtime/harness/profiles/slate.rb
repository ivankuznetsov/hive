# frozen_string_literal: true

require "lib/profile"

module HiveBench
  # The v1 benchmark slate: 6 cells = harness@model. hive pins a model for
  # claude only, so each cell here bakes its own model flag into the headless
  # argv (`claude --model`, `codex -m`, `pi --model`). Min versions match hive's
  # AgentProfile floors; auth paths match hive's logged-in? checks.
  #
  # Open-model feasibility (the origin's flagged risk) is RESOLVED: `pi --model
  # <pattern>` exists and "supports provider/id and optional :<thinking>", so the
  # four open models run on Pi. The exact provider/id pattern per model depends
  # on Pi's configured providers (OpenRouter) — recorded here as the `model`
  # field; a smoke run (U8) confirms each pattern resolves to a live model.
  module Slate
    module_function

    CLAUDE_AUTH = "~/.claude/.credentials.json"
    CODEX_AUTH = "~/.codex/auth.json"
    PI_AUTH = "~/.pi/agent/auth.json"

    def profiles
      [claude_opus47, claude_opus, codex_gpt, *pi_open_models].freeze
    end

    def by_id(id)
      profiles.find { |p| p.id == id }
    end

    # Planner/executor pairs for pipeline mode: the planner authors the plan, the
    # executor implements it. `id` is the agent_id recorded in results.json.
    Pair = Data.define(:id, :planner, :executor)

    def pipelines
      [*self_plan_pipelines, *cross_pipelines].freeze
    end

    # Self-plan pipelines (X plans + X executes) = each agent's FULL capability —
    # the meaningful "fresh X" run, vs the frozen-plan executor (which only tests
    # executing someone else's already-refined plan).
    def self_plan_pipelines
      {
        "codex-selfplan" => "codex@gpt-5.5-xhigh",
        "opus-4.8-selfplan" => "claude@opus-4.8",
        "kimi-selfplan" => "pi@kimi-k2.7",
        "glm-selfplan" => "pi@glm-5.2"
      }.map { |id, agent| Pair.new(id: id, planner: by_id(agent), executor: by_id(agent)) }
    end

    # Cross pipelines: planner-A hands its plan to executor-B.
    def cross_pipelines
      [
        Pair.new(id: "glm-5.2->kimi-k2.7", planner: by_id("pi@glm-5.2"), executor: by_id("pi@kimi-k2.7")),
        Pair.new(id: "opus-4.8->codex", planner: by_id("claude@opus-4.8"), executor: by_id("codex@gpt-5.5-xhigh"))
      ]
    end

    def pipeline_by_id(id)
      pipelines.find { |p| p.id == id }
    end

    # The recorded incumbent: scored from claude-opus-4.7's RAW execute output
    # (reused — see lib/reuse.rb), never run fresh (we don't ship the 4.7 CLI).
    # headless_argv is unused for a reused cell but kept for shape/preflight.
    def claude_opus47
      Profile.new(
        id: "claude@opus-4.7", harness: "claude", model: "claude-opus-4-7", bin: "claude",
        min_version: "2.1.118", auth_path: CLAUDE_AUTH,
        headless_argv: lambda do |prompt:|
          ["claude", "-p", "--model", "claude-opus-4-7", "--dangerously-skip-permissions", prompt]
        end
      )
    end

    def claude_opus
      Profile.new(
        id: "claude@opus-4.8", harness: "claude", model: "claude-opus-4-8", bin: "claude",
        min_version: "2.1.118", auth_path: CLAUDE_AUTH,
        headless_argv: lambda do |prompt:|
          ["claude", "-p", "--model", "claude-opus-4-8", "--dangerously-skip-permissions", prompt]
        end
      )
    end

    def codex_gpt
      # "gpt-5.5 xhigh" = model gpt-5.5 at reasoning effort xhigh. codex pins the
      # model with -m and the effort via a -c config override.
      Profile.new(
        id: "codex@gpt-5.5-xhigh", harness: "codex", model: "gpt-5.5", bin: "codex",
        min_version: "0.125.0", auth_path: CODEX_AUTH,
        headless_argv: lambda do |prompt:|
          ["codex", "exec", "-m", "gpt-5.5", "-c", 'model_reasoning_effort="xhigh"',
           "--dangerously-bypass-approvals-and-sandbox", prompt]
        end
      )
    end

    # Each open model is `pi --model <pattern> -p`. Patterns are pi provider/id
    # forms; adjust to match the local Pi provider config if a smoke run reports
    # an unresolved pattern. The bench runs these via OpenRouter (OPENROUTER_API_KEY
    # passed into the runner), so the pattern is the `openrouter/<id>` form Pi
    # resolves. glm-5.2 is verified live (U8 smoke: provider=openrouter,
    # model=z-ai/glm-5.2); the other three still need their own smoke before a
    # run pins them (left as bare labels until verified).
    PI_MODELS = {
      "kimi-k2.7" => "openrouter/moonshotai/kimi-k2.7-code",
      "minimax-3" => "minimax-3",
      "qwen-2.6-coder" => "qwen-2.6-coder",
      "glm-5.2" => "openrouter/z-ai/glm-5.2"
    }.freeze

    # NOTE: the production gen path (IsolationExec#agent_command) builds pi's
    # invocation from `model` directly so it can add the runner-specific flags
    # (--mode json, --no-session, --offline, timeout) and read the plan from a
    # /work file — it does NOT call this `headless_argv`. The lambda stays as the
    # documented host-equivalent invocation and is what preflight/tests exercise.
    def pi_open_models
      PI_MODELS.map do |label, pattern|
        Profile.new(
          id: "pi@#{label}", harness: "pi", model: pattern, bin: "pi",
          min_version: "0.70.2", auth_path: PI_AUTH,
          headless_argv: lambda do |prompt:|
            ["pi", "-p", "--model", pattern, prompt]
          end
        )
      end
    end
  end
end
