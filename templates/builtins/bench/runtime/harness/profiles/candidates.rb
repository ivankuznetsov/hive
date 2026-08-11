# frozen_string_literal: true

module HiveBench
  # v2 slate: a CANDIDATE is a hive model configuration (which agent+model drives
  # each stage), run through REAL hive. Replaces the v1 Profile/Pair slate that fed
  # the reimplemented pipeline. `model_version` is what the leaderboard records;
  # Model fields describe provider-neutral stage identities. HiveConfig renders
  # them into Hive's native `models:` map; the shared Agent CLI runtime owns all
  # provider-specific flag compilation.
  # Review fields feed the prod-default review config (hive_config.rb).
  module Candidates
    module_function

    Candidate = Data.define(:id, :plan, :execute, :review, :claude_model, :claude_effort, :pi_models,
                            :codex_effort, :codex_model, :codex_models, :codex_efforts,
                            :grok_model, :grok_effort, :model_version,
                            :review_max_passes, :review_wall_clock_sec, :reviewers, :ci_command)

    # pi --model patterns verified against the local pi + OpenRouter (2026-07-03).
    GLM = "openrouter/z-ai/glm-5.2"
    KIMI = "openrouter/moonshotai/kimi-k2.7-code"
    FABLE = "claude-fable-5"
    OPUS = "opus"
    SOL = "gpt-5.6-sol"
    TERRA = "gpt-5.6-terra"

    def all
      [all_opus, all_codex, opus_plan_codex_exec,
       all_glm, all_kimi, glm_plan_kimi_exec,
       all_codex_xhigh, opus_plan_codex_exec_xhigh, all_grok,
       all_codex_sol_xhigh, sol_plan_terra_exec_sol_review,
       fable_plan_grok_exec_sol_review, sol_plan_grok_exec_sol_review,
       sol_plan_terra_exec_grok_review, sol_plan_exec_high_grok_review,
       opus_plan_sol_exec_sol_opus_review, fable_plan_sol_exec_sol_opus_review].freeze
    end

    def by_id(id)
      all.find { |c| c.id == id }
    end

    def base(id, plan:, execute:, review:, model_version:, claude_model: nil, claude_effort: nil,
             pi_models: nil, codex_effort: nil, codex_model: nil, codex_models: nil,
             codex_efforts: nil, grok_model: nil, grok_effort: nil, reviewers: [])
      Candidate.new(id: id, plan: plan, execute: execute, review: review,
                    claude_model: claude_model, claude_effort: claude_effort, pi_models: pi_models,
                    codex_effort: codex_effort, codex_model: codex_model,
                    codex_models: codex_models, codex_efforts: codex_efforts,
                    grok_model: grok_model, grok_effort: grok_effort,
                    model_version: model_version,
                    review_max_passes: 2, review_wall_clock_sec: 7200,
                    reviewers: reviewers, ci_command: nil)
    end

    def sole_codex_ce_reviewer
      [{ "name" => "codex-ce-code-review", "kind" => "agent", "agent" => "codex",
         "model" => SOL, "effort" => "xhigh",
         "skill" => "ce-code-review", "output_basename" => "codex-ce-code-review",
         "prompt_template" => "reviewer_codex_ce_code_review.md.erb",
         "budget_usd" => 50, "timeout_sec" => 7200 }]
    end

    def sole_grok_ce_reviewer
      [{ "name" => "grok-ce-code-review", "kind" => "agent", "agent" => "grok",
         "model" => "grok-4.5", "effort" => "xhigh",
         "skill" => "ce-code-review", "output_basename" => "grok-ce-code-review",
         "prompt_template" => "reviewer_grok_ce_code_review.md.erb",
         "budget_usd" => 50, "timeout_sec" => 7200 }]
    end

    def sol_grok_ce_reviewers
      sole_codex_ce_reviewer + sole_grok_ce_reviewer
    end

    def sol_opus_ce_reviewers
      [
        { "name" => "sol-ce-code-review", "kind" => "agent", "agent" => "codex",
          "model" => SOL, "effort" => "xhigh", "skill" => "ce-code-review",
          "output_basename" => "sol-ce-code-review",
          "prompt_template" => "reviewer_codex_ce_code_review.md.erb",
          "budget_usd" => 50, "timeout_sec" => 7200 },
        { "name" => "opus-5-ce-code-review", "kind" => "agent", "agent" => "claude",
          "model" => OPUS, "effort" => "xhigh", "skill" => "ce-code-review",
          "output_basename" => "opus-5-ce-code-review",
          "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
          "budget_usd" => 50, "timeout_sec" => 7200 }
      ]
    end

    def all_opus
      base("all-opus-4.8", plan: "claude", execute: "claude", review: "claude",
                           claude_model: "claude-opus-4-8", model_version: "claude-opus-4-8")
    end

    def all_codex
      base("all-codex", plan: "codex", execute: "codex", review: "codex",
                        model_version: "gpt-5.5")
    end

    def opus_plan_codex_exec
      base("opus-plan->codex-exec", plan: "claude", execute: "codex", review: "claude",
                                    claude_model: "claude-opus-4-8", model_version: "opus-plan/codex-exec")
    end

    def all_glm
      base("all-glm-5.2", plan: "pi", execute: "pi", review: "pi",
                          pi_models: { "plan" => GLM, "execute" => GLM, "review" => GLM },
                          model_version: "glm-5.2")
    end

    def all_kimi
      # The CODE variant, deliberately — kimi-k2.7 base is a different model.
      base("all-kimi-k2.7-code", plan: "pi", execute: "pi", review: "pi",
                                 pi_models: { "plan" => KIMI, "execute" => KIMI, "review" => KIMI },
                                 model_version: "kimi-k2.7-code")
    end

    # "glm with kimi": glm plans (and reviews), kimi implements — the open-model
    # mirror of opus-plan->codex-exec.
    def glm_plan_kimi_exec
      base("glm-plan->kimi-exec", plan: "pi", execute: "pi", review: "pi",
                                  pi_models: { "plan" => GLM, "execute" => KIMI, "review" => GLM },
                                  model_version: "glm-plan/kimi-exec")
    end

    # xhigh variants (maintainer decision 2026-07-08): the default-effort codex
    # cells reasoned at ~15% of output — these re-run every codex-touched
    # candidate with model_reasoning_effort=xhigh through Hive's native stage
    # routing.
    def all_codex_xhigh
      base("all-codex-xhigh", plan: "codex", execute: "codex", review: "codex",
                              codex_effort: "xhigh", model_version: "gpt-5.5-xhigh")
    end

    def opus_plan_codex_exec_xhigh
      base("opus-plan->codex-exec-xhigh", plan: "claude", execute: "codex", review: "claude",
                                          claude_model: "claude-opus-4-8", codex_effort: "xhigh",
                                          model_version: "opus-plan/codex-exec-xhigh")
    end

    # gpt-5.6-sol at xhigh (maintainer request 2026-07-09): the 5.6 generation
    # joins the board alongside gpt-5.5. Needs codex >= 0.144
    # (hive-bench-runner:sol image).
    def all_codex_sol_xhigh
      base("all-codex-5.6-sol-xhigh", plan: "codex", execute: "codex", review: "codex",
                                      codex_model: SOL, codex_effort: "xhigh",
                                      model_version: "gpt-5.6-sol-xhigh")
    end

    # xAI grok (maintainer request 2026-07-09): grok-4.5 at xhigh — grok's
    # effort scale has a literal xhigh, so the pin is like-for-like with the
    # codex xhigh candidates. Hive passes both controls through its native stage
    # router and shared Agent CLI runtime. Grok reports no token usage — cost
    # columns stay empty by design.
    def all_grok
      base("all-grok-4.5", plan: "grok", execute: "grok", review: "grok",
                           grok_model: "grok-4.5", grok_effort: "xhigh",
                           model_version: "grok-4.5-xhigh")
    end

    # Follow-up workflow comparison (maintainer decision 2026-07-13): keep the
    # candidate review stage controlled with one Sol xhigh /ce-code-review
    # reviewer while varying planner and executor. The stage-specific Codex
    # pins are required for the Sol-plan/Terra-execute cell because both stages
    # use the same `codex` Hive agent profile.
    def sol_plan_terra_exec_sol_review
      base("sol-plan->terra-exec-sol-review", plan: "codex", execute: "codex", review: "codex",
                                              codex_models: { "plan" => SOL, "execute" => TERRA, "review" => SOL },
                                              codex_efforts: { "plan" => "xhigh", "execute" => "xhigh", "review" => "xhigh" },
                                              reviewers: sole_codex_ce_reviewer,
                                              model_version: "sol-xhigh-plan/terra-xhigh-exec/sol-xhigh-review")
    end

    def fable_plan_grok_exec_sol_review
      base("fable-plan->grok-exec-sol-review", plan: "claude", execute: "grok", review: "codex",
                                               claude_model: FABLE, claude_effort: "high",
                                               codex_models: { "review" => SOL },
                                               codex_efforts: { "review" => "xhigh" },
                                               grok_model: "grok-4.5", grok_effort: "xhigh",
                                               reviewers: sole_codex_ce_reviewer,
                                               model_version: "fable-5-high-plan/grok-4.5-xhigh-exec/sol-xhigh-review")
    end

    def sol_plan_grok_exec_sol_review
      base("sol-plan->grok-exec-sol-review", plan: "codex", execute: "grok", review: "codex",
                                             codex_models: { "plan" => SOL, "review" => SOL },
                                             codex_efforts: { "plan" => "xhigh", "review" => "xhigh" },
                                             grok_model: "grok-4.5", grok_effort: "xhigh",
                                             reviewers: sole_codex_ce_reviewer,
                                             model_version: "sol-xhigh-plan/grok-4.5-xhigh-exec/sol-xhigh-review")
    end

    # Review-family follow-up: keep the established Sol-plan/Terra-execute
    # workflow, but hand open-pr, triage, fixes, and the sole CE review to Grok.
    def sol_plan_terra_exec_grok_review
      base("sol-plan->terra-exec-grok-review", plan: "codex", execute: "codex", review: "grok",
                                               codex_models: { "plan" => SOL, "execute" => TERRA },
                                               codex_efforts: { "plan" => "xhigh", "execute" => "xhigh" },
                                               grok_model: "grok-4.5", grok_effort: "xhigh",
                                               reviewers: sole_grok_ce_reviewer,
                                               model_version: "sol-xhigh-plan/terra-xhigh-exec/grok-4.5-xhigh-review")
    end

    # Flagship production-shaped workflow: Sol plans at xhigh, implements at
    # high, and owns review/triage/fixes at xhigh with independent Sol and Grok
    # CE reviewers. The explicit panel excludes Claude/toolkit reviewers.
    def sol_plan_exec_high_grok_review
      base("sol-plan@xhigh->exec@high+grok-review",
           plan: "codex", execute: "codex", review: "codex",
           codex_models: { "plan" => SOL, "execute" => SOL, "review" => SOL },
           codex_efforts: { "plan" => "xhigh", "execute" => "high", "review" => "xhigh" },
           grok_model: "grok-4.5", grok_effort: "xhigh",
           reviewers: sol_grok_ce_reviewers,
           model_version: "sol-xhigh-plan/sol-high-exec/sol+grok-review")
    end

    # Production-shaped Sol execution with a same-panel Sol + Opus 5 review.
    # The two cells vary only the Claude planner: Opus 5 xhigh versus Fable 5
    # xhigh. Reviewer-level model pins keep the Fable planner from changing the
    # Opus reviewer identity.
    def opus_plan_sol_exec_sol_opus_review
      base("opus-5-plan@xhigh->sol-exec@high+sol-opus-review",
           plan: "claude", execute: "codex", review: "codex",
           claude_model: OPUS, claude_effort: "xhigh",
           codex_models: { "execute" => SOL, "review" => SOL },
           codex_efforts: { "execute" => "high", "review" => "xhigh" },
           reviewers: sol_opus_ce_reviewers,
           model_version: "opus-5-xhigh-plan/sol-high-exec/sol-xhigh+opus-5-xhigh-review")
    end

    def fable_plan_sol_exec_sol_opus_review
      base("fable-5-plan@xhigh->sol-exec@high+sol-opus-review",
           plan: "claude", execute: "codex", review: "codex",
           claude_model: FABLE, claude_effort: "xhigh",
           codex_models: { "execute" => SOL, "review" => SOL },
           codex_efforts: { "execute" => "high", "review" => "xhigh" },
           reviewers: sol_opus_ce_reviewers,
           model_version: "fable-5-xhigh-plan/sol-high-exec/sol-xhigh+opus-5-xhigh-review")
    end
  end
end
