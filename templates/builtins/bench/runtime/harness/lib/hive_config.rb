# frozen_string_literal: true

require "yaml"

module HiveBench
  # Renders a benchmark CANDIDATE (which agent/model drives each REAL hive stage)
  # into a hive `.hive-state/config.yml`. v2's unit of comparison is a model
  # configuration run through ACTUAL hive — not a reimplemented prompt.
  #
  # The brainstorm is seeded frozen (same requirements for every candidate), so
  # plan/execute/review are the live stages. Candidate identities are declared
  # through Hive's provider-neutral `models:` map; Hive's Agent CLI runtime is
  # solely responsible for compiling provider-native model and effort flags.
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
    PARALLEL_ATTEMPT_STARTUP_TIMEOUT_SEC = 300
    OPENCODE_PLUGIN = "/opt/compound-engineering"
    OPENCODE_OX_ALPHA_MODEL = {
      "name" => "Ox Alpha",
      "family" => "alpha",
      "release_date" => "2026-08-20",
      "attachment" => true,
      "reasoning" => true,
      "temperature" => true,
      "tool_call" => true,
      "cost" => { "input" => 0, "output" => 0 },
      "limit" => { "context" => 1_048_576, "output" => 131_072 },
      "modalities" => { "input" => %w[text image], "output" => ["text"] },
      "status" => "active",
      "variants" => { "high" => { "reasoning" => { "effort" => "high" } } }
    }.freeze
    # OpenCode enforces scoped permissions while Pi relies on the surrounding
    # benchmark container. Give both harnesses the same coding capability: the
    # disposable container + provider-only network remain the security
    # boundary, while OpenCode may run the repository diagnostics and tests a
    # coding benchmark requires. Without Bash the model can edit blindly, which
    # measures a capability handicap rather than the harness.
    OPENCODE_PERMISSIONS = {
      "preset" => "scoped", "tools" => [ "Read", "Write", "Edit", "Bash(*)" ]
    }.freeze

    # candidate: responds to plan, execute, review (agent names: "claude"/"codex"/
    #   "pi"), claude_model (CLI id or nil), review_max_passes, review_wall_clock_sec,
    #   reviewers (Array), ci_command (String or nil).
    def to_h(candidate, worktree_root: DEFAULT_WORKTREE_ROOT, default_branch: DEFAULT_BRANCH)
      config = {
        "claude" => { "mode" => "headless", "model" => candidate.claude_model,
                      "effort" => candidate.claude_effort }.compact,
        "default_branch" => default_branch,
        "worktree_root" => worktree_root,
        # A full parallel campaign can put the host under swap pressure while
        # detached Hive workers boot. Keep the launch claim bounded, but do not
        # expire it at the production-oriented 30-second default before the
        # worker can claim its already-admitted attempt.
        "attempt_launch_timeout_sec" => PARALLEL_ATTEMPT_STARTUP_TIMEOUT_SEC,
        "attempt_first_heartbeat_timeout_sec" => PARALLEL_ATTEMPT_STARTUP_TIMEOUT_SEC,
        "plan_review" => { "enabled" => false },
        "plan" => { "agent" => candidate.plan },
        "execute" => { "agent" => candidate.execute },
        # Without this, hive's built-in default (claude) would open the PR even
        # for open-model candidates — keep every stage on the candidate's agents.
        "open_pr" => { "agent" => candidate.review },
        "review" => review_config(candidate)
      }
      if uses?(candidate, "opencode")
        config["permissions"] = OPENCODE_PERMISSIONS
        config["agents"] = {
          "opencode" => {
            "config" => {
              "provider" => {
                "openrouter" => {
                  "models" => { "stealth/ox-alpha" => OPENCODE_OX_ALPHA_MODEL }
                }
              }
            },
            "credential_env" => ["OPENROUTER_API_KEY"],
            "plugins" => [OPENCODE_PLUGIN],
            "isolation" => "hermetic"
          }
        }
      end

      models = {}
      add_route(models, "plan", route_for(candidate, candidate.plan, "plan"))
      add_route(models, "execute", route_for(candidate, candidate.execute, "execute"))

      # `review` is a coarse parent for calls that can use different providers,
      # especially mixed reviewer panels. Route the candidate-owned calls
      # exactly so its model cannot leak into a Grok/Claude/Codex peer reviewer.
      review_route = route_for(candidate, candidate.review, "review")
      add_route(models, "open_pr", review_route)
      %w[review_ci review_triage review_fix].each { |stage| add_route(models, stage, review_route) }
      add_route(models, "review_reviewers", shared_reviewer_route(config.dig("review", "reviewers")))
      config["models"] = models unless models.empty?
      config
    end

    def add_route(models, stage, route)
      models[stage] = route.dup unless route.empty?
    end

    def route_for(candidate, agent, stage)
      case agent
      when "claude"
        { "model" => candidate.claude_model, "effort" => candidate.claude_effort }.compact
      when "codex"
        {
          "model" => candidate.codex_models&.fetch(stage, nil) || candidate.codex_model,
          "effort" => candidate.codex_efforts&.fetch(stage, nil) || candidate.codex_effort
        }.compact
      when "pi"
        { "model" => candidate.pi_models&.fetch(stage, nil) }.compact
      when "opencode"
        {
          "model" => candidate.opencode_models&.fetch(stage, nil),
          "effort" => candidate.opencode_effort
        }.compact
      when "grok"
        { "model" => candidate.grok_model, "effort" => candidate.grok_effort }.compact
      else
        {}
      end
    end

    def uses?(candidate, agent)
      stage_agents = [candidate.plan, candidate.execute, candidate.review]
      reviewer_agents = Array(candidate.reviewers).filter_map do |reviewer|
        reviewer.is_a?(Hash) ? (reviewer["agent"] || reviewer[:agent]) : nil
      end
      (stage_agents + reviewer_agents).include?(agent)
    end

    # Hive's built-in reviewer identity is one routing key for the whole panel.
    # Route a field only when doing so preserves every reviewer's declaration;
    # the other field then comes from each reviewer spec and Agent CLI Runtime
    # renders both for that provider. `inherit` is a no-flag activation value.
    def shared_reviewer_route(reviewers)
      specs = Array(reviewers).select { |reviewer| reviewer.is_a?(Hash) && reviewer["kind"] != "linter" }
      return {} if specs.empty?

      efforts = specs.map { |reviewer| reviewer["effort"] }
      return { "effort" => efforts.first } if efforts.all? && efforts.uniq.one?

      models = specs.map { |reviewer| reviewer["model"] }
      return { "model" => models.first } if models.all? && models.uniq.one?
      return { "effort" => "inherit" } if efforts.none? && models.any?

      {}
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
        "fix" => {
          "agent" => candidate.review,
          "auto_commit" => {
            "sign_policy" => "inherit",
            # Benchmark targets are disposable isolated clones and several
            # corpus tasks legitimately span schemas/, examples/, packaging,
            # and other repo-specific paths outside Hive's conservative
            # production review allowlist. Keep symlink and secret-content
            # safety checks, but let CleanExit preserve the candidate's full
            # implementation when a tool-only harness cannot run git commit.
            "scope_check" => { "enabled" => false }
          }
        },
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
          "budget_usd" => 50, "timeout_sec" => 7200 }.merge(route_for(candidate, agent, "review"))
      end
      if agents.include?("claude")
        set << { "name" => "pr-review-toolkit", "kind" => "agent", "agent" => "claude",
                 "skill" => "pr-review-toolkit:review-pr", "output_basename" => "pr-review-toolkit",
                 "prompt_template" => "reviewer_pr_review_toolkit.md.erb",
                 "budget_usd" => 50, "timeout_sec" => 7200 }
               .merge(route_for(candidate, "claude", "review"))
      end
      set
    end

    def to_yaml(candidate, **)
      YAML.dump(to_h(candidate, **))
    end
  end
end
