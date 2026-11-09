require "fileutils"
require "json"
require "time"
require "hive/agent_limit"
require "hive/attempts/context"

module Hive
  module Stages
    module Review
      # Opt-in substitution of a 6-review role's agent when its primary
      # provider hits a classified usage/credit limit.
      #
      # Configured by `review.limit_fallback`:
      #
      #   review:
      #     limit_fallback:
      #       enabled: true
      #       min_wait_sec: 3600
      #       agents:
      #         codex: claude
      #
      # The `agents` map is keyed by the PRIMARY agent profile and names the
      # substitute profile. It applies to every review role that launches an
      # agent: each reviewer (by its `agent`, or `codex` for `codex_review`),
      # triage, the fix agent, and the CI-fix agent.
      #
      # A fallback is attempted only when every condition holds:
      #   - the option is enabled and maps the primary profile to a different
      #     profile;
      #   - the primary run failed with a classified provider limit (the same
      #     signal that produces `reason=limits_reached`); generic failures,
      #     auth/preflight errors, and refused models never fall back;
      #   - the provider's explicit reset hint is absent, or is at least
      #     `min_wait_sec` away (a short wall is better waited out);
      #   - the durable attempt is not under explicit provider-account
      #     routing, whose router already owns adapter selection.
      #
      # A substitute is tried at most once per role invocation. If it fails
      # (limit or otherwise) the caller keeps the primary's limit result, so
      # the stage writes the same `limits_reached` marker it writes today,
      # annotated with `primary_agent` / `fallback_agent` /
      # `fallback_outcome`.
      #
      # Every attempted substitution is appended to
      # `reviews/limit-fallback-NN.jsonl` (JSON lines; not matched by the
      # `*-NN.md` reviewer-file glob) and echoed as a `[hive.review]` log
      # line naming the role, primary, fallback, and the limit.
      module LimitFallback
        RECEIPT_BASENAME = "limit-fallback".freeze
        DEFAULT_MIN_WAIT_SEC = 3600
        THREAD_KEY = :hive_review_limit_fallback_failures
        LIMIT_DETAIL_MAX = 200

        # One approved substitution. `phase` is the review phase whose marker
        # would carry a failed attempt ("reviewers", "triage", "fix", "ci");
        # `role` is the display name (a reviewer's name, or the phase).
        # `retry_after` is the provider's explicit reset estimate (ISO-8601),
        # or nil when the provider gave none.
        Decision = Data.define(:phase, :role, :primary, :fallback, :retry_after, :limit_detail)

        module_function

        # The validated settings hash when the option is enabled, else nil.
        def settings(cfg)
          raw = cfg.is_a?(Hash) ? cfg.dig("review", "limit_fallback") : nil
          return nil unless raw.is_a?(Hash) && raw["enabled"] == true

          raw
        end

        # Fallback profile name configured for `primary`, or nil.
        def configured_fallback(cfg, primary)
          opts = settings(cfg)
          return nil unless opts && primary

          agents = opts["agents"]
          return nil unless agents.is_a?(Hash)

          fallback = agents[primary.to_s]
          fallback = fallback.to_s.strip
          return nil if fallback.empty? || fallback == primary.to_s

          fallback
        end

        def limited?(limit_text:, error_message:)
          !limit_text.to_s.empty? || Hive::AgentLimit.from_limit?(error_message.to_s)
        end

        # Decide whether a review role whose primary agent `primary` just
        # failed may be retried on its configured fallback profile. Returns a
        # Decision or nil. Every refusal after a classified limit on an
        # enabled config is logged so an operator can see why no substitute
        # ran.
        def decide(cfg, phase:, primary:, limit_text:, error_message:, role: phase, now: Time.now.utc)
          opts = settings(cfg)
          return nil unless opts
          return nil unless limited?(limit_text: limit_text, error_message: error_message)

          text = limit_text.to_s.empty? ? error_message.to_s : limit_text.to_s
          primary = primary.to_s
          fallback = configured_fallback(cfg, primary)
          unless fallback
            log("#{role}: #{primary.inspect} hit a usage/credit limit; no fallback agent configured " \
                "for it in review.limit_fallback.agents")
            return nil
          end
          if Hive::Attempts::Context.current&.explicit_routing?
            log("#{role}: #{primary} hit a usage/credit limit; fallback to #{fallback} skipped " \
                "because this attempt uses explicit provider routing")
            return nil
          end

          explicit = Hive::AgentLimit.explicit_retry_after(text, now: now)
          min_wait = min_wait_sec(opts)
          if explicit && (explicit - now) < min_wait
            log("#{role}: #{primary} hit a usage/credit limit resetting at #{explicit.iso8601} " \
                "(< min_wait_sec=#{min_wait}); waiting for reset instead of falling back to #{fallback}")
            return nil
          end

          Decision.new(
            phase: phase.to_s, role: role.to_s, primary: primary, fallback: fallback,
            retry_after: explicit&.iso8601,
            limit_detail: Hive::AgentLimit.first_useful_line(text)[0, LIMIT_DETAIL_MAX]
          )
        end

        def min_wait_sec(opts)
          value = opts["min_wait_sec"]
          value.is_a?(Integer) && value >= 0 ? value : DEFAULT_MIN_WAIT_SEC
        end

        def receipt_path(task_folder, pass)
          File.join(task_folder, "reviews", "#{RECEIPT_BASENAME}-#{format('%02d', pass)}.jsonl")
        end

        # Append one durable receipt line and a log line for an attempted
        # substitution. `outcome` is "used" (the substitute's result
        # replaced the primary's), "limited" (the substitute also hit a
        # limit), or "failed" (the substitute failed for another reason).
        # A failed outcome is remembered for the current review run so the
        # resulting limits_reached marker can name the attempt.
        def record!(task_folder:, pass:, decision:, outcome:, output: nil, error: nil)
          entry = {
            "recorded_at" => Time.now.utc.iso8601,
            "pass" => pass,
            "phase" => decision.phase,
            "role" => decision.role,
            "primary" => decision.primary,
            "fallback" => decision.fallback,
            "outcome" => outcome.to_s,
            "limit" => decision.limit_detail,
            "retry_after" => decision.retry_after,
            "output" => output,
            "error" => error && error.to_s[0, LIMIT_DETAIL_MAX]
          }.compact
          log("#{decision.role}: #{decision.primary} hit a usage/credit limit " \
              "(#{decision.limit_detail}; retry_after=#{decision.retry_after || 'unknown'}); " \
              "fallback #{decision.fallback} #{outcome}#{" -> #{output}" if output}")
          remember_failure(decision, outcome) unless outcome.to_s == "used"
          path = receipt_path(task_folder, pass)
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, "a") { |file| file.write("#{JSON.generate(entry)}\n") }
          entry
        rescue SystemCallError => e
          # The log line above already carries the audit facts; a lost
          # receipt line must not turn a successful substitution into an
          # infra failure.
          warn "[hive.review] could not record limit fallback receipt: #{e.class}: #{e.message}"
          entry
        end

        def reset_run!
          Thread.current[THREAD_KEY] = {}
        end

        # Marker attrs naming a failed substitution for `phase` in this run.
        def marker_attrs(phase)
          failure = (Thread.current[THREAD_KEY] || {})[phase.to_s]
          return {} unless failure

          {
            primary_agent: failure.fetch(:primary),
            fallback_agent: failure.fetch(:fallback),
            fallback_outcome: failure.fetch(:outcome)
          }
        end

        def remember_failure(decision, outcome)
          failures = (Thread.current[THREAD_KEY] ||= {})
          failures[decision.phase] = {
            primary: decision.primary, fallback: decision.fallback, outcome: outcome.to_s
          }
        end

        # --- reviewers ---------------------------------------------------

        # Profile a reviewer spec launches when it is not routed.
        def reviewer_primary(spec)
          return "codex" if spec["kind"].to_s == "codex_review"

          spec["agent"]&.to_s
        end

        def reviewer_output_basename(spec, fallback)
          "#{spec.fetch('output_basename')}-fallback-#{fallback}"
        end

        def reviewer_output_path(ctx, spec, fallback)
          File.join(
            ctx.task_folder, "reviews",
            "#{reviewer_output_basename(spec, fallback)}-#{format('%02d', ctx.pass)}.md"
          )
        end

        # A substitute reviewer spec: always an `agent` reviewer on the
        # fallback profile, with its own name and output file so the review
        # history shows which agent reviewed. The primary's model/effort pins
        # are dropped because they name the primary provider's models.
        def reviewer_spec(spec, decision, templates:)
          primary_template = templates[decision.primary]
          template = spec["prompt_template"]
          if spec["kind"].to_s == "codex_review" || template.nil? || template == primary_template
            template = templates.fetch(decision.fallback, template || templates.fetch("codex"))
          end
          spec.reject { |key, _| %w[model effort kind agent].include?(key) }.merge(
            "kind" => "agent",
            "agent" => decision.fallback,
            "name" => "#{spec.fetch('name')}-fallback-#{decision.fallback}",
            "output_basename" => reviewer_output_basename(spec, decision.fallback),
            "skill" => spec["skill"] || "ce-code-review",
            "prompt_template" => template
          )
        end

        # Config handed to a substitute launch: provider-neutral `models:`
        # routes were authored for the primary provider, so they are
        # withheld and the fallback profile's own default model applies.
        def fallback_cfg(cfg)
          return cfg unless cfg.is_a?(Hash) && cfg.key?("models")

          cfg.reject { |key, _| key == "models" }
        end

        def log(message)
          warn "[hive.review] limit fallback: #{message}"
        end
      end
    end
  end
end
