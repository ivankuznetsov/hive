# frozen_string_literal: true

require "yaml"

module HiveBench
  # Renders a benchmark CANDIDATE (which agent/model drives each REAL hive stage)
  # into a hive `.hive-state/config.yml`. v2's unit of comparison is a model
  # configuration run through ACTUAL hive — not a reimplemented prompt.
  #
  # The brainstorm is seeded frozen (same requirements for every candidate), so
  # plan/execute/review are the live stages. Only claude takes a model flag in
  # hive (`claude.model`, and it must be the CLI id e.g. `claude-opus-4-8`, not
  # hive's short `opus-4.8`); codex runs its subscription model and pi its
  # provider model, so their `claude_model` is nil and simply omitted.
  #
  # Hive specifics baked in from the Stage A/B bring-up:
  #   - mode: headless         (no tmux in the container)
  #   - default_branch: main   (the target clone's local main is reset to the
  #                             task's base_commit and origin is removed, so the
  #                             execute worktree branches off base_commit)
  #   - worktree_root under /work so the worktree persists on the host mount
  #   - review bounded (max_passes + wall clock) so it runs unattended; ci.command
  #     is the corpus gate's test command (nil/omitted when the task is uncurated)
  module HiveConfig
    module_function

    DEFAULT_WORKTREE_ROOT = "/work/.worktrees"
    DEFAULT_BRANCH = "main"

    # candidate: responds to plan, execute, review (agent names: "claude"/"codex"/
    #   "pi"), claude_model (CLI id or nil), review_max_passes, review_wall_clock_sec,
    #   reviewers (Array), ci_command (String or nil).
    def to_h(candidate, worktree_root: DEFAULT_WORKTREE_ROOT, default_branch: DEFAULT_BRANCH)
      {
        "claude" => { "mode" => "headless", "model" => candidate.claude_model }.compact,
        "default_branch" => default_branch,
        "worktree_root" => worktree_root,
        "plan" => { "agent" => candidate.plan },
        "execute" => { "agent" => candidate.execute },
        # Without this, hive's built-in default (claude) would open the PR even
        # for open-model candidates — keep every stage on the candidate's agents.
        "open_pr" => { "agent" => candidate.review },
        "review" => review_config(candidate)
      }
    end

    # PROD review STRUCTURE on the CANDIDATE'S OWN MODELS (maintainer decision
    # 2026-07-09, final form): the reviewer set is one <agent>-ce-code-review
    # per DISTINCT agent in the candidate, plus pr-review-toolkit whenever
    # claude is among them. Single-model candidates review themselves (codex ->
    # codex-CE; opus -> claude-CE + toolkit); the opus+codex mixed candidate
    # derives the full prod tri-set — because prod hive IS a claude+codex shop.
    # grok uses the embedded-CE template (no native skill port yet).
    # One bench deviation stands: github_publish disabled (bench-local origin
    # + gh shim). Explicit reviewers on the Candidate override the derived set.
    CE_TEMPLATE_BY_AGENT = {
      "codex" => "reviewer_codex_ce_code_review.md.erb",
      "grok" => "reviewer_grok_ce_code_review.md.erb"
    }.freeze

    def review_config(candidate)
      {
        "agent" => candidate.review,
        "ci" => { "command" => candidate.ci_command, "max_attempts" => 3, "agent" => candidate.review },
        "triage" => { "enabled" => true, "agent" => candidate.review, "bias" => "courageous" },
        "fix" => { "agent" => candidate.review, "auto_commit" => { "sign_policy" => "inherit" } },
        "browser_test" => { "enabled" => false },
        "github_publish" => { "enabled" => false },
        "max_passes" => candidate.review_max_passes,
        "max_wall_clock_sec" => candidate.review_wall_clock_sec,
        "reviewers" => reviewers_for(candidate)
      }
    end

    def reviewers_for(candidate)
      explicit = Array(candidate.reviewers)
      return explicit unless explicit.empty?

      agents = [candidate.plan, candidate.execute, candidate.review].uniq
      set = agents.map do |agent|
        { "name" => "#{agent}-ce-code-review", "kind" => "agent", "agent" => agent,
          "skill" => "ce-code-review", "output_basename" => "#{agent}-ce-code-review",
          "prompt_template" => CE_TEMPLATE_BY_AGENT.fetch(agent, "reviewer_claude_ce_code_review.md.erb"),
          "budget_usd" => 50, "timeout_sec" => 7200 }
      end
      if agents.include?("claude")
        set << { "name" => "pr-review-toolkit", "kind" => "agent", "agent" => "claude",
                 "skill" => "pr-review-toolkit:review-pr", "output_basename" => "pr-review-toolkit",
                 "prompt_template" => "reviewer_pr_review_toolkit.md.erb",
                 "budget_usd" => 50, "timeout_sec" => 7200 }
      end
      set
    end

    def to_yaml(candidate, **)
      YAML.dump(to_h(candidate, **))
    end
  end
end
