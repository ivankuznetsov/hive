require "hive/reviewers/base"
require "hive/reviewers/synthetic_task"
require "hive/reviewers/agent"
require "hive/agent_support"

module Hive
  # Reviewer adapters for the 6-review stage.
  #
  # Two reviewer kinds ship today:
  #
  # - "agent" (default): spawns an LLM CLI (claude / codex / pi / grok) with a
  #   rendered prompt invoking a CE skill on the worktree's diff; the
  #   agent writes the findings file itself (Hive::Reviewers::Agent).
  # - "codex_review": runs codex's native, single-pass `codex review`
  #   subcommand and captures its stdout into the findings file
  #   (Hive::AgentSupport::Codex::Reviewer). This is the patrol-default reviewer —
  #   one cheap tuned pass instead of the multi-persona ce-code-review
  #   fan-out — and needs no CE `skill`.
  #
  # Tool-specific linters (rubocop, brakeman, etc.) are NOT a hive
  # concept — they belong in the project's CI command, which the 6-review
  # runner invokes via U7's CI-fix loop (`review.ci.command`). Hardcoding
  # linter knowledge in hive would couple the orchestrator to one
  # ecosystem (Ruby/Rails); the per-project `bin/ci` pattern keeps hive
  # ecosystem-agnostic.
  module Reviewers
    ROUTED_REVIEW_TEMPLATES = {
      "claude" => "reviewer_claude_ce_code_review.md.erb",
      "codex" => "reviewer_codex_ce_code_review.md.erb",
      "grok" => "reviewer_grok_ce_code_review.md.erb",
      "pi" => "reviewer_codex_ce_code_review.md.erb"
    }.freeze

    # Default attempt budget for a reviewer adapter (Hive::Reviewers::Agent).
    # A reviewer spec can override via the optional `max_attempts` field;
    # `1` disables retry (single attempt). Backoff between failed attempts
    # is exponential (1s, 2s, 4s, 8s, 8s, …) capped at REVIEWER_BACKOFF_CAP_SEC
    # so a high max_attempts doesn't accidentally introduce minute-scale waits.
    DEFAULT_REVIEWER_MAX_ATTEMPTS = 2
    REVIEWER_BACKOFF_CAP_SEC = 8

    # Capped exponential backoff (1s, 2s, 4s, 8s, 8s, …) for the Nth failed
    # attempt. Single source of truth shared by the reviewer adapters
    # (Hive::Reviewers::Agent, AgentSupport::Codex::Reviewer) and the 6-review triage retry
    # (Hive::Stages::Review#triage_retry_backoff); each caller keeps its own
    # thin wrapper as a test-stub seam but delegates the formula here.
    def self.backoff_seconds_for(failed_attempt)
      [ 2**(failed_attempt - 1), REVIEWER_BACKOFF_CAP_SEC ].min
    end

    class UnknownKindError < Hive::Error
      def exit_code
        Hive::ExitCodes::CONFIG
      end
    end

    # Build a reviewer adapter from a config spec + per-spawn context.
    # The `kind` field is optional and defaults to "agent". A
    # `kind: codex_review` spec selects the native-`codex review` adapter.
    # If a config explicitly sets `kind: linter`, raise a helpful error
    # pointing the user at `review.ci.command` rather than silently
    # ignoring the request.
    #
    # `cfg:` (optional, default nil) flows the merged project config to
    # the adapter so `agents.<name>.<key>` overrides reach the
    # AgentProfile lookup. Pre-cfg callers continue to work; the lookup
    # falls back to the registry-stored profile when cfg is nil.
    def self.dispatch(spec, ctx, cfg: nil)
      spec = admitted_route_spec(spec)
      kind = (spec["kind"] || "agent").to_s
      case kind
      when "agent"
        Agent.new(spec, ctx, cfg: cfg)
      when "codex_review"
        Hive::AgentSupport.for(:codex)::Reviewer.new(spec, ctx, cfg: cfg)
      when "linter"
        raise UnknownKindError, <<~MSG.strip
          reviewer kind "linter" is not supported in v1.
          Tool-specific linters (rubocop, brakeman, golangci-lint, etc.) belong
          in your project's CI command — set `review.ci.command` to your linter
          driver (e.g., `bin/ci`) and let the 6-review CI-fix phase surface and
          repair its findings. The reviewer set is for CE-skill-based agent
          reviewers only (claude /ce-code-review, codex /ce-code-review,
          pr-review-toolkit).
        MSG
      else
        raise UnknownKindError,
              "unknown reviewer kind: #{kind.inspect} (expected 'agent' or 'codex_review')"
      end
    end

    # Native `codex review` is deliberately a direct subprocess adapter. It
    # predates durable provider routing, so it has no account launch-binding
    # seam, trusted evidence channel, or provider-neutral failure handoff.
    # Inside an explicitly routed durable attempt, translate that one native
    # reviewer into the normal agent adapter. Stages::Base then supplies the
    # already-admitted account, adapter, model, effort, and evidence pipe just
    # like every other provider-backed invocation in the enclosing attempt.
    def self.admitted_route_spec(spec)
      context = Hive::Attempts::Context.current
      return spec unless context&.explicit_routing?
      return spec unless (spec["kind"] || "agent").to_s == "codex_review"

      adapter = context.adapter.to_s
      spec.merge(
        "kind" => "agent",
        "agent" => adapter,
        "skill" => "ce-code-review",
        "prompt_template" => ROUTED_REVIEW_TEMPLATES.fetch(
          adapter,
          "reviewer_codex_ce_code_review.md.erb"
        )
      ).freeze
    end
    private_class_method :admitted_route_spec
  end
end
