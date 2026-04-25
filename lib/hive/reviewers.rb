require "hive/reviewers/base"
require "hive/reviewers/agent"

module Hive
  # Reviewer adapters for the 5-review stage.
  #
  # v1 supports a single reviewer kind: agent-based reviewers that spawn
  # an LLM CLI (claude / codex / pi) with a rendered prompt invoking a
  # CE skill on the worktree's diff. Tool-specific linters (rubocop,
  # brakeman, etc.) are NOT a hive concept — they belong in the
  # project's CI command, which the 5-review runner invokes via U7's
  # CI-fix loop (`review.ci.command`). Hardcoding linter knowledge in
  # hive would couple the orchestrator to one ecosystem (Ruby/Rails);
  # the per-project `bin/ci` pattern keeps hive ecosystem-agnostic.
  module Reviewers
    class UnknownKindError < Hive::Error
      def exit_code
        Hive::ExitCodes::CONFIG
      end
    end

    # Build a reviewer adapter from a config spec + per-spawn context.
    # The `kind` field is optional and defaults to "agent" (the only
    # supported kind in v1). If a config explicitly sets `kind: linter`,
    # raise a helpful error pointing the user at `review.ci.command`
    # rather than silently ignoring the request.
    def self.dispatch(spec, ctx)
      kind = (spec["kind"] || "agent").to_s
      case kind
      when "agent"
        Agent.new(spec, ctx)
      when "linter"
        raise UnknownKindError, <<~MSG.strip
          reviewer kind "linter" is not supported in v1.
          Tool-specific linters (rubocop, brakeman, golangci-lint, etc.) belong
          in your project's CI command — set `review.ci.command` to your linter
          driver (e.g., `bin/ci`) and let the 5-review CI-fix phase surface and
          repair its findings. The reviewer set is for CE-skill-based agent
          reviewers only (claude /ce-code-review, codex /ce-code-review,
          pr-review-toolkit).
        MSG
      else
        raise UnknownKindError,
              "unknown reviewer kind: #{kind.inspect} (expected 'agent')"
      end
    end
  end
end
