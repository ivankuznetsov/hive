require "fileutils"
require "json"
require "time"
require "hive/limit_fallback"

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
      # triage, the fix agent, the CI-fix agent, and the auto-rebase
      # conflict-resolution agent when `hive run` rebases a task in the
      # review stage (Hive::Rebase, phase "rebase").
      #
      # A fallback is attempted only under the shared Hive::LimitFallback
      # rules: the option is enabled and maps the primary profile to a
      # different profile; the primary failed with a classified provider
      # limit (generic failures, auth/preflight errors, and refused models
      # never fall back); the explicit reset hint is absent or at least
      # `min_wait_sec` away; and the durable attempt is not under explicit
      # provider-account routing.
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
        CONFIG_PATH = %w[review limit_fallback].freeze
        RECEIPT_BASENAME = "limit-fallback".freeze
        DEFAULT_MIN_WAIT_SEC = Hive::LimitFallback::DEFAULT_MIN_WAIT_SEC
        THREAD_KEY = :hive_review_limit_fallback_failures
        LIMIT_DETAIL_MAX = Hive::LimitFallback::LIMIT_DETAIL_MAX

        # One approved substitution. `phase` is the review phase whose marker
        # would carry a failed attempt ("reviewers", "triage", "fix", "ci";
        # "rebase" for the pre-stage conflict agent, which writes no marker);
        # `role` is the display name (a reviewer's name, or the phase).
        Decision = Hive::LimitFallback::Decision

        module_function

        # The validated settings hash when the option is enabled, else nil.
        def settings(cfg)
          Hive::LimitFallback.settings(cfg, CONFIG_PATH)
        end

        # Fallback profile name configured for `primary`, or nil.
        def configured_fallback(cfg, primary)
          Hive::LimitFallback.configured_fallback(cfg, CONFIG_PATH, primary)
        end

        # Decide whether a review role whose primary agent `primary` just
        # failed may be retried on its configured fallback profile. Returns a
        # Decision or nil.
        def decide(cfg, phase:, primary:, limit_text:, error_message:, role: phase, now: Time.now.utc)
          Hive::LimitFallback.decide(
            cfg, path: CONFIG_PATH, phase: phase, primary: primary, role: role,
            limit_text: limit_text, error_message: error_message, now: now,
            log: method(:log)
          )
        end

        # Receipt outcome for a finished substitute run: "used" when it
        # succeeded, "limited" when it also hit a limit, else "failed".
        def outcome(ok:, limit_text:, error_message:)
          Hive::LimitFallback.outcome(ok: ok, limit_text: limit_text, error_message: error_message)
        end

        def min_wait_sec(opts)
          Hive::LimitFallback.min_wait_sec(opts)
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
