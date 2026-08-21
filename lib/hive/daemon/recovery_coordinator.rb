require "digest"
require "json"
require "shellwords"
require "time"
require "hive/agent_limit"
require "hive/attempts/generation"
require "hive/attempts/store"
require "hive/daemon/auto_retry_safety"
require "hive/daemon/dispatch_request_queue"
require "hive/lock"
require "hive/markers"
require "hive/provider_routing/decision"
require "hive/recovery"
require "hive/recovery/retry_policy"
require "hive/task"
require "hive/task_resolver"

module Hive
  module Daemon
    # Sole producer and transition owner for ERROR / REVIEW_ERROR recovery.
    # Adapters submit an observed row; this coordinator re-resolves it under
    # the task lock, applies the shared cooldown and safety policy, then
    # persists one restartable v5 request before any marker mutation.
    class RecoveryCoordinator
      LIFECYCLE_STATES = %w[
        queued cooldown running blocked terminal unavailable
      ].freeze

      Receipt = Data.define(
        :status, :request_id, :attempt_id, :phase, :failure_origin,
        :next_eligible_at, :owner, :reason, :remediation, :retry_count,
        :provider_hint, :terminal_outcome, :terminal_at,
        :failure_fingerprint, :identical_failure_count, :escalation_tier
      ) do
        def initialize(terminal_outcome: nil, terminal_at: nil,
                       failure_fingerprint: nil, identical_failure_count: nil,
                       escalation_tier: nil, **rest)
          super(
            terminal_outcome: terminal_outcome, terminal_at: terminal_at,
            failure_fingerprint: failure_fingerprint,
            identical_failure_count: identical_failure_count,
            escalation_tier: escalation_tier, **rest
          )
        end

        def to_h
          super.transform_keys(&:to_s)
        end

        def self.from_h(value)
          attributes = members.to_h do |member|
            key = value.key?(member) ? member : member.to_s
            [ member, value[key] ]
          end
          new(**attributes)
        end

        def primary_label
          {
            "queued" => "Recovery queued",
            "cooldown" => "Retry available later",
            "running" => "Agent running",
            "blocked" => "Recovery blocked",
            "terminal" => terminal_success? ? "Completed" : "Failed",
            "unavailable" => "Current state unavailable"
          }.fetch(status)
        end

        def human_summary
          context = []
          context << "request #{request_id}" if request_id
          context << "attempt #{attempt_id}" if attempt_id
          context << "eligible #{next_eligible_at}" if status == "cooldown" && next_eligible_at
          context << terminal_outcome.to_s.tr("_", " ") if status == "terminal" && terminal_outcome
          context << "at #{terminal_at}" if status == "terminal" && terminal_at
          context << reason.to_s.tr("_", " ") if reason
          context << remediation if remediation && status != "queued"
          context.empty? ? primary_label : "#{primary_label} — #{context.join('; ')}"
        end

        private

        def terminal_success?
          %w[succeeded success completed terminal_replay].include?(
            terminal_outcome.to_s
          )
        end
      end
      SafetyObservation = Data.define(
        :marker, :marker_attrs, :state_file, :stage, :folder
      )

      class << self
        # Recovery action tokens use the same canonical observation at the
        # status edge and again under the coordinator's task lock. This makes
        # the token a real freshness guard rather than an adapter-only precheck.
        def observation_token(row)
          attrs = row_value(row, :marker_attrs)
          attrs = row_value(row, :attrs) unless attrs.is_a?(Hash)
          attrs = attrs.is_a?(Hash) ? Hive::Recovery.canonical_marker_attrs(attrs) : {}
          observed_at = row_value(row, :state_file_mtime) ||
                        row_value(row, :observation_mtime) ||
                        row_value(row, :mtime)
          observed_at = Time.parse(observed_at.to_s) unless
            observed_at.nil? || observed_at.respond_to?(:utc)
          ::Digest::SHA256.hexdigest(JSON.generate(
            "project" => row_value(row, :project),
            "slug" => row_value(row, :slug),
            "folder" => row_value(row, :folder),
            "stage" => row_value(row, :stage),
            "marker" => row_value(row, :marker),
            "marker_attrs" => attrs,
            "state_file_mtime" => observed_at&.utc&.iso8601(6),
            "task_generation" => row_value(row, :task_generation) ||
              row_value(row, :condition_task_generation),
            "attempt_id" => row_value(row, :attempt_id) ||
              row_value(row, :current_attempt)
          ))
        rescue ArgumentError, TypeError
          ::Digest::SHA256.hexdigest(JSON.generate("invalid_observation" => true))
        end

        private

        def row_value(row, key)
          return row.public_send(key) if row.respond_to?(key)
          return row[key] if row.respond_to?(:key?) && row.key?(key)
          return row[key.to_s] if row.respond_to?(:key?) && row.key?(key.to_s)
          return row[key.to_s] if row.respond_to?(:[])

          nil
        end
      end

      def initialize(state_home: Hive::Paths.state_home,
                     request_queue: Hive::Daemon::DispatchRequestQueue,
                     task_resolver: nil,
                     safety: Hive::Daemon::AutoRetrySafety.method(:safe_to_retry?),
                     generation_resolver: nil, attempt_store: nil,
                     attempt_store_factory: nil)
        @state_home = state_home
        @request_queue = request_queue
        @task_resolver = task_resolver || method(:resolve_task)
        @safety = safety.respond_to?(:call) ? safety : safety.method(:safe_to_retry?)
        @generation_resolver = generation_resolver || method(:resolve_generation)
        @attempt_store = attempt_store
        @attempt_store_factory = attempt_store_factory || lambda do
          Hive::Attempts::Store.open_default(state_home: @state_home)
        end
      end

      # The single retry ladder. Every retry in Hive is paced by this, so
      # there is one concept to reason about rather than a provider window
      # and a separate marker window that happened to disagree. Steps climb
      # and then hold; the last step is the ceiling.
      RETRY_BACKOFF_SEC = [ 5, 10, 60, 300, 900, 3600 ].freeze
      DETERMINISTIC_FAILURE_THRESHOLD = 3
      FAILURE_HISTORY_LIMIT = 64

      # A deliberate human retry is not the automatic sweep. The cooldown
      # paces Hive's own retries; gating an operator on it leaves a task idle
      # for an hour with a person standing over it. Safety checks still apply
      # to these — those are about worktree state, not pacing.
      OPERATOR_REQUESTORS = %w[action cli bot web].freeze

      def retry_delay_sec(retry_count)
        index = retry_count.to_i
        return RETRY_BACKOFF_SEC.first if index.negative?

        RETRY_BACKOFF_SEC[[ index, RETRY_BACKOFF_SEC.length - 1 ].min]
      end

      # Requests carry their own charge; a request without one is its first.
      def request_retry_delay_sec(request)
        recovery = request.respond_to?(:recovery) ? request.recovery : nil
        retry_delay_sec(recovery.is_a?(Hash) ? recovery["retry_count"].to_i : 0)
      end

      def assessment(row, now: Time.now.utc, retry_count: nil)
        retry_count = durable_retry_count(row) if retry_count.nil?
        observed_at = value(row, :state_file_mtime)
        eligible_at = observed_at && observed_at + retry_delay_sec(retry_count)
        safe, safety_reason = @safety.call(row)
        {
          due: !eligible_at.nil? && now.utc >= eligible_at,
          retry_at: eligible_at,
          safe: safe == true,
          safety_reason: safety_reason.to_s
        }
      rescue StandardError => e
        {
          due: false, retry_at: nil, safe: false,
          safety_reason: "inspection failed: #{e.class}: #{e.message}"
        }
      end

      def request(row:, requestor:, request_id: nil, observation_token: nil,
                  chat_id: nil, update_id: nil,
                  now: Time.now.utc)
        now = now.utc
        failure_origin = marker_attrs(row)["reason"].to_s
        retry_count = durable_retry_count(row)
        assessment = assessment(row, now: now, retry_count: retry_count)
        operator_request = OPERATOR_REQUESTORS.include?(requestor.to_s)
        unless assessment[:retry_at]
          return receipt(
            "unavailable", failure_origin: failure_origin, owner: "hive",
            reason: "missing_observation_time",
            remediation: "refresh status so Hive can observe the current marker generation",
            retry_count: retry_count
          )
        end
        unless assessment[:due] || operator_request
          return receipt(
            "cooldown", failure_origin: failure_origin, owner: "scheduler",
            next_eligible_at: assessment[:retry_at].utc.iso8601(6),
            reason: "shared_cooldown",
            remediation: "retry remains available after the shared cooldown, " \
                         "or immediately on an explicit operator retry",
            retry_count: retry_count, provider_hint: provider_hint(row)
          )
        end
        unless assessment[:safe]
          return receipt(
            "blocked", failure_origin: failure_origin, owner: safety_owner(assessment),
            reason: "safety_blocked", remediation: assessment[:safety_reason],
            next_eligible_at: assessment[:retry_at].utc.iso8601(6),
            retry_count: retry_count, provider_hint: provider_hint(row)
          )
        end

        task = resolve_task_for(row)
        Hive::Lock.with_task_lock(task.folder, "operation" => "recovery_admission") do
          locked_task = resolve_task_for(row)
          unless same_task_identity?(task, locked_task) &&
                 observed_task_identity_matches?(row, locked_task)
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "operator",
              reason: "task_identity_conflict",
              remediation: "refresh status; the canonical task location changed before recovery admission",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end

          current = Hive::Markers.current(locked_task.state_file)
          unless recoverable_marker?(current)
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "operator",
              reason: "generation_conflict",
              remediation: "refresh status; the failure marker changed before recovery admission",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end
          if current.attrs["marker_id"].to_s.empty?
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "operator",
              reason: "recovery_migration_required",
              remediation: "run `hive migrate` in the task project and retry from fresh status",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end

          expected_generation = observed_marker_generation(row)
          unless marker_generation(current) == expected_generation
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "operator",
              reason: "generation_conflict",
              remediation: "refresh status; the failure marker changed before recovery admission",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end
          source_receipt = source_receipt_for(
            marker: current, task: locked_task, project: value(row, :project)
          )
          if failure_origin == "provider_route_failed" && source_receipt.nil?
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "hive",
              reason: "provider_receipt_unavailable",
              remediation: "wait for the immutable provider attempt receipt and retry from fresh status",
              retry_count: retry_count
            )
          end
          locked_safe, locked_safety_reason = @safety.call(
            safety_observation(row, locked_task, current)
          )
          unless locked_safe == true
            locked_assessment = { safety_reason: locked_safety_reason.to_s }
            return receipt(
              "blocked", failure_origin: failure_origin,
              owner: safety_owner(locked_assessment),
              reason: "safety_blocked",
              remediation: locked_safety_reason.to_s,
              next_eligible_at: assessment[:retry_at].utc.iso8601(6),
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end
          if observation_token &&
             !secure_compare(
               locked_observation_token(row, locked_task, current),
               observation_token.to_s
             )
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "operator",
              reason: "stale_observation",
              remediation: "take a fresh operational snapshot and retry its action",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end

          existing = @request_queue.find_recovery(
            project: value(row, :project),
            slug: value(row, :slug),
            observed_marker_generation: expected_generation,
            state_home: @state_home
          )
          if existing
            existing = unpark_deterministic_failure(existing, now:) if operator_request
            return receipt_for_request(
              existing,
              replay: existing.recovery&.fetch("phase", nil) == "terminal",
              now: now
            )
          end

          if locked_task.id.to_s.empty?
            return receipt(
              "blocked", failure_origin: failure_origin, owner: "hive",
              reason: "missing_task_id",
              remediation: "wait for Hive to assign the task id, then retry from a fresh status snapshot",
              retry_count: retry_count, provider_hint: provider_hint(row)
            )
          end

          markerless_body = Hive::Markers.without_markers(File.binread(locked_task.state_file))
          generation = @generation_resolver.call(
            locked_task,
            project: value(row, :project),
            intended_stage: value(row, :stage),
            state_file_content: markerless_body
          )
          canonical_request_id = if source_receipt
            deterministic_request_id(
              row, locked_task, expected_generation, generation.task_generation,
              source_receipt: source_receipt
            )
          else
            request_id.to_s
          end
          if canonical_request_id.empty?
            canonical_request_id = deterministic_request_id(
              row, locked_task, expected_generation, generation.task_generation
            )
          end
          attrs = Hive::Recovery.canonical_marker_attrs(current.attrs)
          marker_id = marker_identity(current)
          next_eligible_at = assessment[:retry_at].utc.iso8601(6)
          failure_evidence = failure_evidence_for(
            row, retry_count: retry_count, marker_attrs: attrs
          )
          recovery = {
            "variant" => "marker",
            "phase" => "admitted",
            "observed_marker_generation" => expected_generation,
            "expected_marker_attrs" => attrs,
            "canonical_task_folder" => canonical_path(locked_task.folder),
            "expected_post_clear_progress_fingerprint" => generation.progress_token,
            "dispatch_generation" => generation.task_generation,
            "failure_origin" => failure_origin.empty? ? "unknown" : failure_origin,
            "next_eligible_at" => next_eligible_at,
            "owner" => "scheduler",
            "blocked_reason" => nil,
            "blocked_remediation" => nil,
            "retry_count" => retry_count + 1,
            "failure_fingerprint" => failure_evidence.fetch("fingerprint"),
            "identical_failure_count" => failure_evidence.fetch("count"),
            "failure_attempt_history" => failure_evidence.fetch("attempts"),
            "provider_hint" => provider_hint(row),
            "policy_digest" => nil,
            "source_receipt" => source_receipt,
            "admission_observation" => nil
          }
          if failure_evidence.fetch("deterministic")
            recovery.merge!(
              "blocked_reason" => "deterministic_failure",
              "blocked_remediation" =>
                "change the failing input, provider, or implementation, then use the current workflow.retry action",
              "owner" => "operator"
            )
          end
          @request_queue.write_request!(
            project: value(row, :project),
            slug: value(row, :slug),
            argv: retry_argv(row),
            requestor: requestor,
            chat_id: chat_id,
            update_id: update_id,
            trigger: "recovery",
            request_id: canonical_request_id,
            task_generation: generation.task_generation,
            predecessor_attempt_id: source_receipt&.fetch("attempt_id", nil),
            task_id: locked_task.id,
            expected_stage: value(row, :stage),
            expected_marker_name: current.name.to_s,
            expected_marker_id: marker_id,
            recovery: recovery,
            state_home: @state_home,
            now: now
          )
          @request_queue.remove_terminal_recoveries(
            project: value(row, :project),
            slug: value(row, :slug),
            expected_stage: value(row, :stage),
            except_request_id: canonical_request_id,
            state_home: @state_home
          )
          if failure_evidence.fetch("deterministic")
            persisted = @request_queue.fetch(canonical_request_id, state_home: @state_home)
            return receipt_for_request(persisted, now: now)
          end
          receipt(
            "queued", request_id: canonical_request_id, phase: "admitted",
            failure_origin: recovery.fetch("failure_origin"),
            next_eligible_at: next_eligible_at, owner: "scheduler",
            retry_count: recovery["retry_count"], provider_hint: recovery["provider_hint"]
          )
        end
      rescue Hive::ConcurrentRunError => e
        holder = e.respond_to?(:holder) ? e.holder : nil
        receipt(
          "running", attempt_id: holder && holder["attempt_id"],
          failure_origin: failure_origin, owner: "agent",
          reason: "existing_live",
          remediation: "attach to the current owner and wait for its terminal receipt",
          retry_count: retry_count, provider_hint: provider_hint(row)
        )
      rescue Hive::Error, SystemCallError, IOError => e
        receipt(
          "unavailable", failure_origin: failure_origin, owner: "hive",
          reason: "recovery_unavailable",
          remediation: "#{e.class}: #{e.message}",
          retry_count: retry_count, provider_hint: provider_hint(row)
        )
      end

      # Admit the first explicit-pool exhaustion into the ordinary recovery
      # ledger without fabricating a task marker. The immutable task
      # generation plus frozen policy digest is the idempotency identity; the
      # RecoveryCoordinator remains the owner of the retry charge and cadence.
      def request_admission_failure(request:, decision:, now: Time.now.utc)
        now = now.utc
        validate_admission_decision!(decision, expected_status: :no_route)
        project = request.project.to_s
        slug = request.slug.to_s
        task = resolve_admission_task(project: project, slug: slug)

        Hive::Lock.with_task_lock(task.folder, "operation" => "recovery_admission_failure") do
          locked_task = resolve_admission_task(project: project, slug: slug)
          unless same_task_identity?(task, locked_task) &&
                 admission_request_identity_matches?(request, locked_task)
            return receipt(
              "blocked", failure_origin: decision.reason, owner: "operator",
              reason: "task_identity_conflict",
              remediation: "refresh status; the canonical task changed before recovery admission"
            )
          end

          marker = Hive::Markers.current(locked_task.state_file)
          if recoverable_marker?(marker)
            return receipt(
              "blocked", failure_origin: decision.reason, owner: "operator",
              reason: "generation_conflict",
              remediation: "refresh status; a recoverable marker now owns this task"
            )
          end
          if locked_task.id.to_s.empty?
            return receipt(
              "blocked", failure_origin: decision.reason, owner: "hive",
              reason: "missing_task_id",
              remediation: "wait for Hive to assign the task id, then retry admission"
            )
          end

          generation = current_generation(
            locked_task, project: project, intended_stage: task_stage(locked_task)
          )
          unless admission_decision_matches?(decision, generation)
            return receipt(
              "blocked", failure_origin: decision.reason, owner: "operator",
              reason: "generation_conflict",
              remediation: "retry admission from the current task generation and routing policy"
            )
          end

          existing = @request_queue.find_admission_recovery(
            project: project, slug: slug,
            task_generation: generation.task_generation,
            policy_digest: decision.policy_digest,
            state_home: @state_home
          )
          return receipt_for_request(existing, now: now) if existing

          request_id = deterministic_admission_request_id(
            project: project, task: locked_task,
            dispatch_generation: generation.task_generation,
            policy_digest: decision.policy_digest
          )
          observation = admission_observation(decision)
          operator_blocked = decision.reason == "health_state_unavailable"
          recovery = {
            "variant" => "admission_failure",
            "phase" => "admitted",
            "observed_marker_generation" => nil,
            "expected_marker_attrs" => {},
            "canonical_task_folder" => canonical_path(locked_task.folder),
            "expected_post_clear_progress_fingerprint" => generation.progress_token,
            "dispatch_generation" => generation.task_generation,
            "failure_origin" => decision.reason,
            "next_eligible_at" => (now + request_retry_delay_sec(request)).iso8601(6),
            "owner" => operator_blocked ? "operator" : "scheduler",
            "blocked_reason" => operator_blocked ? "health_state_unavailable" : nil,
            "blocked_remediation" => operator_blocked ?
              "inspect and repair the unavailable provider-health scope" : nil,
            "retry_count" => durable_retry_count_for(
              project: project, slug: slug, expected_stage: task_stage(locked_task)
            ) + 1,
            "provider_hint" => nil,
            "policy_digest" => decision.policy_digest,
            "source_receipt" => nil,
            "admission_observation" => observation
          }
          @request_queue.write_request!(
            project: project, slug: slug, argv: request.argv,
            requestor: request.requestor || "daemon",
            chat_id: request.chat_id, update_id: request.update_id,
            trigger: "recovery/admission_failure", request_id: request_id,
            task_generation: generation.task_generation,
            predecessor_attempt_id: request.predecessor_attempt_id,
            inherited_outputs: request.inherited_outputs || [],
            task_id: locked_task.id, expected_stage: task_stage(locked_task),
            expected_marker_name: nil, expected_marker_id: nil,
            recovery: recovery, state_home: @state_home, now: now
          )
          @request_queue.remove_terminal_recoveries(
            project: project, slug: slug, except_request_id: request_id,
            expected_stage: task_stage(locked_task),
            state_home: @state_home
          )
          persisted = @request_queue.fetch(request_id, state_home: @state_home)
          persisted ? receipt_for_request(persisted, now: now) :
            unavailable_request(request, "request_disappeared_after_admission")
        end
      rescue Hive::ConcurrentRunError => e
        holder = e.respond_to?(:holder) ? e.holder : nil
        receipt(
          "running", attempt_id: holder && holder["attempt_id"],
          failure_origin: decision&.reason, owner: "agent", reason: "existing_live",
          remediation: "attach to the current owner and wait for its terminal receipt"
        )
      rescue Hive::Error, SystemCallError, IOError, ArgumentError => e
        receipt(
          "unavailable", failure_origin: decision&.reason, owner: "hive",
          reason: "recovery_unavailable", remediation: "#{e.class}: #{e.message}"
        )
      end

      # Attach a routed admission result to the same durable recovery request.
      # Capacity remains neutral (no deadline change); exhaustion uses the
      # coordinator's existing cadence without another request or charge.
      def observe_admission_result(request:, result:, now: Time.now.utc)
        decision = result.respond_to?(:decision) ? result.decision : nil
        expected = result.status == :deferred ? :capacity_saturated : :no_route
        validate_admission_decision!(decision, expected_status: expected)
        @request_queue.with_request_lock(request.request_id, state_home: @state_home) do
          current = @request_queue.fetch(request.request_id, state_home: @state_home) || request
          recovery = current.recovery || {}
          unless %w[admitted cleared].include?(recovery["phase"])
            return receipt_for_request(current, now: now)
          end

          operator_blocked = decision.reason == "health_state_unavailable"
          changes = {
            "admission_observation" => admission_observation(decision),
            "owner" => operator_blocked ? "operator" : "scheduler",
            "blocked_reason" => operator_blocked ? "health_state_unavailable" : nil,
            "blocked_remediation" => operator_blocked ?
              "inspect and repair the unavailable provider-health scope" : nil
          }
          unless decision.capacity_saturated?
            changes["next_eligible_at"] =
              (now.utc + request_retry_delay_sec(request)).iso8601(6)
          end
          transitioned = @request_queue.update_recovery!(
            current.request_id, expected_phase: recovery["phase"], changes: changes,
            state_home: @state_home, request_locked: true
          )
          refreshed = @request_queue.fetch(current.request_id, state_home: @state_home)
          return unavailable_request(current, "transition_conflict") unless transitioned && refreshed

          receipt_for_request(refreshed, now: now)
        end
      rescue Hive::Error, SystemCallError, IOError, ArgumentError => e
        unavailable_request(request, "#{e.class}: #{e.message}")
      end

      # Resume the admitted/cleared transition. This method is called by the
      # daemon immediately before ordinary attempt admission. It can recover a
      # crash after the marker rewrite because the expected markerless
      # fingerprint was persisted before mutation.
      def resume(request:, row:, now: Time.now.utc)
        now = now.utc
        recovery = request.recovery
        return unavailable_request(request, "request_has_no_recovery_transition") unless recovery.is_a?(Hash)
        return receipt_for_request(request, now: now) if %w[dispatched terminal].include?(recovery["phase"])

        task = resolve_task_for(row)
        Hive::Lock.with_task_lock(task.folder, "operation" => "recovery_transition") do
          @request_queue.with_request_lock(request.request_id, state_home: @state_home) do
            current_request = @request_queue.fetch(request.request_id, state_home: @state_home)
            return unavailable_request(request, "request_disappeared_before_transition") unless current_request

            recovery = current_request.recovery
            return receipt_for_request(current_request, now: now) if %w[dispatched terminal].include?(recovery["phase"])
            return receipt_for_request(current_request, now: now) if
              recovery["blocked_reason"] == "deterministic_failure"

            locked_task = resolve_task_for(row)
            unless same_task_identity?(task, locked_task) &&
                   observed_task_identity_matches?(row, locked_task) &&
                   request_task_identity_matches?(current_request, locked_task)
              return block_request(
                current_request,
                "task_identity_conflict",
                owner: "operator",
                remediation: "refresh status; the canonical task identity or stage changed",
                request_locked: true
              )
            end

            unless source_health_acknowledged?(recovery["source_receipt"])
              return receipt(
                "queued", request_id: current_request.request_id,
                phase: recovery["phase"],
                failure_origin: recovery["failure_origin"], owner: "hive",
                reason: "provider_health_pending",
                remediation: "wait for provider health to acknowledge the terminal receipt",
                retry_count: recovery["retry_count"]
              )
            end

            marker = Hive::Markers.current(locked_task.state_file)
            safety_marker = recovery_safety_marker(current_request, marker)
            locked_safe, locked_safety_reason = @safety.call(
              safety_observation(row, locked_task, safety_marker)
            )
            unless locked_safe == true
              assessment = { safety_reason: locked_safety_reason.to_s }
              return block_request(
                current_request,
                "safety_blocked",
                owner: safety_owner(assessment),
                remediation: locked_safety_reason.to_s,
                request_locked: true
              )
            end

            generation = generation_for_current(locked_task, current_request)
            if recovery["phase"] == "admitted"
              if admission_failure_recovery?(recovery)
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) if recoverable_marker?(marker) || !generation_matches?(generation, recovery)
              elsif marker.none?
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) unless generation_matches?(generation, recovery)
              else
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) unless
                  marker.name.to_s == current_request.expected_marker_name.to_s &&
                  marker_generation(marker) == recovery["observed_marker_generation"].to_s &&
                  expected_attrs_match?(marker, recovery.fetch("expected_marker_attrs"))

                markerless = Hive::Markers.without_markers(File.binread(locked_task.state_file))
                predicted = @generation_resolver.call(
                  locked_task,
                  project: current_request.project,
                  intended_stage: current_request.expected_stage,
                  state_file_content: markerless
                )
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) unless generation_matches?(predicted, recovery)

                cleared = clear_recoverable_marker(
                  locked_task.state_file,
                  expected_name: current_request.expected_marker_name,
                  match_attrs: recovery.fetch("expected_marker_attrs")
                )
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) unless cleared
                generation = generation_for_current(locked_task, current_request)
                return block_request(
                  current_request, "generation_conflict",
                  owner: "operator", request_locked: true
                ) unless generation_matches?(generation, recovery)
              end

              transitioned = @request_queue.update_recovery!(
                current_request.request_id,
                expected_phase: "admitted",
                changes: {
                  "phase" => "cleared",
                  "owner" => "scheduler",
                  "blocked_reason" => nil,
                  "blocked_remediation" => nil
                },
                state_home: @state_home,
                request_locked: true
              )
              refreshed = @request_queue.fetch(current_request.request_id, state_home: @state_home)
              return block_request(
                current_request,
                "transition_conflict",
                owner: "hive",
                request_locked: true
              ) unless transitioned && refreshed
              return receipt_for_request(refreshed, now: now)
            end

            return block_request(
              current_request, "generation_conflict",
              owner: "operator", request_locked: true
            ) unless
              recovery["phase"] == "cleared" &&
              cleared_marker_state_valid?(marker, recovery) &&
              generation_matches?(generation, recovery)

            refreshed = clear_resolved_block(current_request, request_locked: true)
            receipt_for_request(refreshed, now: now)
          end
        end
      rescue Hive::ConcurrentRunError => e
        holder = e.respond_to?(:holder) ? e.holder : nil
        receipt(
          "running", request_id: request.request_id,
          attempt_id: holder && holder["attempt_id"], phase: request.recovery["phase"],
          failure_origin: request.recovery["failure_origin"], owner: "agent",
          reason: "existing_live",
          remediation: "attach to the current owner and wait for its terminal receipt"
        )
      rescue Hive::Error, SystemCallError, IOError => e
        unavailable_request(request, "#{e.class}: #{e.message}")
      end

      def mark_dispatched(request, attempt_id:, terminal: false, outcome: nil,
                          now: Time.now.utc)
        @request_queue.with_request_lock(request.request_id, state_home: @state_home) do
          current = @request_queue.fetch(request.request_id, state_home: @state_home) || request
          recovery = current.recovery || {}
          return receipt_for_request(current, attempt_id: attempt_id) if recovery["phase"] == "terminal"
          if !terminal && recovery["phase"] == "dispatched"
            return receipt_for_request(current, attempt_id: attempt_id)
          end

          valid_source = terminal ? %w[cleared dispatched] : [ "cleared" ]
          unless valid_source.include?(recovery["phase"])
            return unavailable_request(current, "transition_conflict")
          end

          phase = terminal ? "terminal" : "dispatched"
          changes = {
            "phase" => phase,
            "attempt_id" => attempt_id,
            "owner" => terminal ? "none" : "agent",
            "blocked_reason" => nil,
            "blocked_remediation" => nil
          }
          if terminal
            changes["terminal_outcome"] = outcome
            changes["terminal_at"] = now.utc.iso8601(6)
          end
          transitioned = @request_queue.update_recovery!(
            request.request_id,
            expected_phase: recovery["phase"],
            changes: changes,
            state_home: @state_home,
            request_locked: true
          )
          refreshed = @request_queue.fetch(request.request_id, state_home: @state_home)
          return unavailable_request(current, "transition_conflict") unless transitioned && refreshed

          receipt_for_request(refreshed, attempt_id: attempt_id)
        end
      end

      RETRYABLE_TERMINAL_OUTCOMES = %w[failed cancelled lost].freeze

      # A stage normally writes a fresh ERROR/REVIEW_ERROR before its failed
      # recovery attempt terminalizes. An exception before that stage-owned
      # boundary (for example Process.spawn raising E2BIG) used to leave a
      # terminal recovery receipt over a markerless task forever. Repair only
      # that exact unchanged post-clear generation; meaningful progress or a
      # newer marker/attempt wins and is never overwritten.
      def repair_failed_terminal_marker(request, refresh: true)
        current = if refresh
          @request_queue.fetch(request.request_id, state_home: @state_home) || request
        else
          request
        end
        recovery = current.recovery || {}
        return false unless recovery["phase"] == "terminal"
        return false unless RETRYABLE_TERMINAL_OUTCOMES.include?(recovery["terminal_outcome"])

        task = @task_resolver.call(
          project: current.project,
          slug: current.slug,
          folder: recovery["canonical_task_folder"],
          stage: current.expected_stage
        )
        Hive::Lock.with_task_lock(task.folder, "operation" => "terminal_recovery_repair") do
          locked_task = @task_resolver.call(
            project: current.project,
            slug: current.slug,
            folder: recovery["canonical_task_folder"],
            stage: current.expected_stage
          )
          return false unless same_task_identity?(task, locked_task)
          return false unless request_task_identity_matches?(current, locked_task)

          marker = Hive::Markers.current(locked_task.state_file)
          return false unless marker.none?

          generation = generation_for_current(locked_task, current)
          return false unless generation_matches?(generation, recovery)

          Hive::Markers.set(
            locked_task.state_file, :error,
            reason: "recovery_attempt_failed",
            attempt_id: recovery["attempt_id"],
            outcome: recovery["terminal_outcome"],
            recovery_request_id: current.request_id
          )
          true
        end
      rescue Hive::Error, SystemCallError, IOError, ArgumentError, TypeError
        false
      end

      # A preflight/spawn failure after the marker was cleared must not be
      # retried on every daemon tick. Keep the durable transition in `cleared`
      # and schedule the next admission with the same shared hourly cadence.
      def defer_dispatch_failure(request, now: Time.now.utc)
        now = now.utc
        @request_queue.with_request_lock(request.request_id, state_home: @state_home) do
          current = @request_queue.fetch(request.request_id, state_home: @state_home) || request
          recovery = current.recovery || {}
          return receipt_for_request(current, now: now) unless recovery["phase"] == "cleared"

          transitioned = @request_queue.update_recovery!(
            request.request_id,
            expected_phase: "cleared",
            changes: {
              "next_eligible_at" => (now + request_retry_delay_sec(request)).iso8601(6),
              "owner" => "scheduler",
              "blocked_reason" => nil,
              "blocked_remediation" => nil
            },
            state_home: @state_home,
            request_locked: true
          )
          refreshed = @request_queue.fetch(request.request_id, state_home: @state_home)
          return unavailable_request(current, "transition_conflict") unless transitioned && refreshed

          receipt_for_request(refreshed, now: now)
        end
      end

      def receipt_for_request(request, attempt_id: nil, replay: false,
                              now: Time.now.utc)
        recovery = request.recovery || {}
        blocked = recovery["blocked_reason"].to_s
        status = if !blocked.empty?
          "blocked"
        else
          case recovery["phase"]
          when "admitted", "cleared"
            recovery_due?(recovery, now: now) ? "queued" : "cooldown"
          when "dispatched" then "running"
          when "terminal" then "terminal"
          else "unavailable"
          end
        end
        observation_reason = recovery.dig("admission_observation", "reason")
        receipt(
          status,
          request_id: request.request_id,
          attempt_id: attempt_id || recovery["attempt_id"],
          phase: recovery["phase"],
          failure_origin: recovery["failure_origin"],
          next_eligible_at: recovery["next_eligible_at"],
          owner: case status
                 when "running" then "agent"
                 when "terminal" then "none"
                 when "cooldown" then "scheduler"
                 else recovery["owner"]
                 end,
          reason: blocked.empty? ? (replay ? "terminal_replay" : observation_reason) : blocked,
          remediation: blocked.empty? ? nil :
            (recovery["blocked_remediation"] || remediation_for(blocked)),
          retry_count: recovery["retry_count"],
          provider_hint: recovery["provider_hint"],
          terminal_outcome: recovery["terminal_outcome"],
          terminal_at: recovery["terminal_at"],
          failure_fingerprint: recovery["failure_fingerprint"],
          identical_failure_count: recovery["identical_failure_count"],
          escalation_tier: escalation_tier_for(recovery)
        )
      end

      def escalation_tier_for(recovery)
        return "parked" if recovery["blocked_reason"] == "deterministic_failure"
        return "degraded" if recovery["identical_failure_count"].to_i > 1
        return "silent_retry" if recovery["failure_fingerprint"]

        nil
      end

      def observation_token_for(row)
        self.class.observation_token(row)
      end

      private

      def durable_retry_count(row)
        durable_retry_count_for(
          project: value(row, :project), slug: value(row, :slug),
          expected_stage: value(row, :stage)
        )
      end

      def durable_retry_count_for(project:, slug:, expected_stage:)
        @request_queue.recovery_retry_count(
          project: project, slug: slug, expected_stage: expected_stage,
          state_home: @state_home
        )
      end

      def failure_evidence_for(row, retry_count:, marker_attrs:)
        fingerprint = failure_fingerprint(row, marker_attrs)
        previous = @request_queue.latest_terminal_recovery(
          project: value(row, :project), slug: value(row, :slug),
          expected_stage: value(row, :stage), state_home: @state_home
        )
        previous_recovery = previous&.recovery || {}
        repeated = previous_recovery["failure_fingerprint"].to_s == fingerprint
        count = repeated ? previous_recovery["identical_failure_count"].to_i + 1 : 1
        attempts = repeated ? Array(previous_recovery["failure_attempt_history"]).dup : []
        attempt_id = marker_attrs["attempt_id"].to_s
        attempt_id = value(row, :attempt_id).to_s if attempt_id.empty?
        attempts << attempt_id unless attempt_id.empty? || attempts.include?(attempt_id)
        attempts = attempts.last(FAILURE_HISTORY_LIMIT)
        at_ceiling = retry_count.to_i >= RETRY_BACKOFF_SEC.length - 1

        {
          "fingerprint" => fingerprint,
          "count" => count,
          "attempts" => attempts,
          "deterministic" => at_ceiling && count >= DETERMINISTIC_FAILURE_THRESHOLD
        }
      end

      def failure_fingerprint(row, attrs)
        message = attrs["message"] || attrs["diagnostic"] || attrs["exception_class"]
        normalized_message = message.to_s.scrub.downcase.gsub(/\s+/, " ").strip
        Digest::SHA256.hexdigest(JSON.generate(
          "reason" => attrs["reason"].to_s,
          "provider" => (attrs["provider"] || attrs["provider_account_id"] ||
            value(row, :provider)).to_s,
          "status_code" => (attrs["status_code"] || attrs["status"]).to_s,
          "message_digest" => Digest::SHA256.hexdigest(normalized_message)
        ))
      end

      def source_receipt_for(marker:, task:, project:)
        return nil unless marker.attrs["reason"].to_s == "provider_route_failed"

        attempt_id = marker.attrs["attempt_id"].to_s
        return nil if attempt_id.empty?

        record = attempts_store.fetch(attempt_id)
        return nil unless record&.state == "terminal" && record.explicit_routing?
        return nil unless record["project"].to_s == project.to_s
        return nil unless record["task_slug"].to_s == task.slug.to_s
        return nil unless record["task_id"].to_s == task.id.to_s
        return nil unless record["intended_stage"].to_s == task_stage(task)
        return nil unless record.task_generation.to_s == marker.attrs["task_generation"].to_s
        return nil unless record.ownership_generation.to_s ==
                          marker.attrs["ownership_generation"].to_s

        routing = record["routing"] || {}
        route = routing["route"] || {}
        return nil unless route["provider_account_id"].to_s ==
                          marker.attrs["provider_account_id"].to_s
        return nil unless route["route_id"].to_s == marker.attrs["route_id"].to_s

        terminal = record.receipt || {}
        return nil unless terminal["outcome"] == "failed" && terminal["provider_evidence"].is_a?(Hash)

        identity = {
          "attempt_id" => attempt_id,
          "receipt_version" => terminal["receipt_version"],
          "terminal_lease_version" => terminal["terminal_lease_version"]
        }
        source_receipt_matches?(record, identity) ? identity.freeze : nil
      rescue Hive::Attempts::StoreError
        nil
      end

      def source_health_acknowledged?(source_receipt)
        return true if source_receipt.nil?

        hot = attempts_store.fetch_hot(source_receipt.fetch("attempt_id"))
        if hot
          return false unless source_receipt_matches?(hot, source_receipt)

          pending = attempts_store.pending_finalizations.fetch(hot.attempt_id)
          return pending&.dig("consumers", "provider_health") == true
        end

        proof = attempts_store.permanent_proofs.fetch(source_receipt.fetch("attempt_id"))
        source_receipt_matches?(proof, source_receipt)
      rescue KeyError, Hive::Attempts::StoreError
        false
      end

      def source_receipt_matches?(record, source_receipt)
        return false unless record&.final?

        terminal = record.receipt || {}
        record.attempt_id.to_s == source_receipt["attempt_id"].to_s &&
          terminal["receipt_version"] == source_receipt["receipt_version"] &&
          terminal["terminal_lease_version"] == source_receipt["terminal_lease_version"]
      end

      def attempts_store
        @attempt_store ||= @attempt_store_factory.call
      end

      def validate_admission_decision!(decision, expected_status:)
        unless decision.is_a?(Hive::ProviderRouting::Decision) &&
               decision.status == expected_status &&
               %w[
                 capacity_saturated health_state_unavailable no_eligible_provider_route
               ].include?(decision.reason)
          raise ArgumentError, "invalid provider-routing admission decision"
        end
      end

      def admission_observation(decision)
        Hive::ProviderRouting.deep_copy(decision.to_h)
      end

      def resolve_admission_task(project:, slug:)
        @task_resolver.call(project: project, slug: slug, folder: nil, stage: nil)
      end

      def admission_request_identity_matches?(request, task)
        return false unless request.slug.to_s == task.slug.to_s
        return true if request.task_id.to_s.empty?

        request.task_id.to_s == task.id.to_s
      end

      def admission_decision_matches?(decision, generation)
        decision.request.task_generation.to_s == generation.task_generation.to_s &&
          decision.policy_digest.to_s == decision.request.policy.digest.to_s
      end

      def current_generation(task, project:, intended_stage:)
        @generation_resolver.call(
          task, project: project, intended_stage: intended_stage,
          state_file_content: File.binread(task.state_file)
        )
      end

      def clear_recoverable_marker(state_file, expected_name:, match_attrs:)
        marker_name = expected_name.to_s
        unless Hive::Recovery.recoverable_marker?(marker_name)
          raise ArgumentError, "not a recoverable marker: #{marker_name}"
        end

        Hive::Markers.clear_current(
          state_file,
          expected_name: marker_name.to_sym,
          match_attrs: match_attrs,
          purge_history: true
        )
      end

      def receipt(status, request_id: nil, attempt_id: nil, phase: nil,
                  failure_origin: nil, next_eligible_at: nil, owner: nil,
                  reason: nil, remediation: nil, retry_count: nil,
                  provider_hint: nil, terminal_outcome: nil, terminal_at: nil,
                  failure_fingerprint: nil, identical_failure_count: nil,
                  escalation_tier: nil)
        raise ArgumentError, "unknown recovery lifecycle #{status}" unless LIFECYCLE_STATES.include?(status)

        Receipt.new(
          status: status, request_id: request_id, attempt_id: attempt_id,
          phase: phase, failure_origin: failure_origin,
          next_eligible_at: next_eligible_at, owner: owner, reason: reason,
          remediation: remediation, retry_count: retry_count,
          provider_hint: provider_hint, terminal_outcome: terminal_outcome,
          terminal_at: terminal_at, failure_fingerprint: failure_fingerprint,
          identical_failure_count: identical_failure_count,
          escalation_tier: escalation_tier
        )
      end

      def value(row, key)
        return row.public_send(key) if row.respond_to?(key)
        return row[key] if row.respond_to?(:key?) && row.key?(key)
        return row[key.to_s] if row.respond_to?(:key?) && row.key?(key.to_s)
        return row[key.to_s] if row.respond_to?(:[]) && !row.respond_to?(:members)

        nil
      end

      def marker_attrs(row)
        attrs = value(row, :marker_attrs)
        attrs = value(row, :attrs) unless attrs.is_a?(Hash)
        attrs.is_a?(Hash) ? attrs.to_h.transform_keys(&:to_s) : {}
      end

      def observed_marker_generation(row)
        marker_generation(
          Hive::Markers::State.new(
            name: value(row, :marker).to_s.downcase.to_sym,
            attrs: marker_attrs(row),
            raw: nil
          )
        )
      end

      def marker_generation(marker)
        attrs = Hive::Recovery.canonical_marker_attrs(marker.attrs)
        return nil if attrs["marker_id"].to_s.empty?

        ::Digest::SHA256.hexdigest(JSON.generate(
          "name" => marker.name.to_s,
          "attrs" => attrs
        ))
      end

      def marker_identity(marker)
        marker_id = marker.attrs["marker_id"].to_s
        raise ArgumentError, "recoverable marker_id is required" if marker_id.empty?

        marker_id
      end

      def recoverable_marker?(marker)
        Hive::Recovery.recoverable_marker?(marker.name)
      end

      def resolve_task_for(row)
        @task_resolver.call(
          project: value(row, :project),
          slug: value(row, :slug),
          folder: value(row, :folder),
          stage: value(row, :stage)
        )
      end

      def same_task_identity?(observed, current)
        return false unless observed.slug.to_s == current.slug.to_s
        return false unless canonical_path(observed.folder) == canonical_path(current.folder)
        return false unless canonical_path(observed.state_file) == canonical_path(current.state_file)
        return false if observed.respond_to?(:id) && current.respond_to?(:id) &&
                        observed.id && current.id && observed.id.to_s != current.id.to_s

        true
      end

      def observed_task_identity_matches?(row, task)
        observed_folder = value(row, :folder)
        observed_state_file = value(row, :state_file)
        return false unless value(row, :slug).to_s == task.slug.to_s
        return false if observed_folder && !observed_folder.to_s.empty? &&
                        canonical_path(observed_folder) != canonical_path(task.folder)
        return false if observed_state_file && !observed_state_file.to_s.empty? &&
                        canonical_path(observed_state_file) != canonical_path(task.state_file)
        return false unless value(row, :stage).to_s == task_stage(task)

        true
      end

      def request_task_identity_matches?(request, task)
        recovery = request.recovery || {}
        return false unless request.slug.to_s == task.slug.to_s
        return false if request.task_id.to_s.empty? || task.id.to_s.empty?
        return false unless request.task_id.to_s == task.id.to_s
        return false unless request.expected_stage.to_s == task_stage(task)
        return false unless recovery["canonical_task_folder"].to_s ==
                            canonical_path(task.folder)
        return false unless request.task_generation.to_s ==
                            recovery["dispatch_generation"].to_s

        true
      end

      def task_stage(task)
        "#{task.stage_index}-#{task.stage_name}"
      end

      def canonical_path(path)
        expanded = File.expand_path(path.to_s)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
      end

      def safety_observation(row, task, marker)
        SafetyObservation.new(
          marker: marker.name.to_s,
          marker_attrs: marker.attrs.to_h.transform_keys(&:to_s),
          state_file: task.state_file,
          stage: value(row, :stage),
          folder: task.folder
        )
      end

      # A crash can occur after the atomic marker rewrite but before the
      # admitted -> cleared phase CAS. Safety still needs the persisted failure
      # reason in that markerless window so secret/tamper rescans cannot be
      # bypassed merely by restarting the daemon.
      def recovery_safety_marker(request, marker)
        recovery = request.recovery || {}
        return marker if admission_failure_recovery?(recovery)
        return marker unless marker.none?
        return marker unless %w[admitted cleared].include?(recovery["phase"].to_s)

        Hive::Markers::State.new(
          name: request.expected_marker_name.to_s.downcase.to_sym,
          attrs: recovery.fetch("expected_marker_attrs", {}),
          raw: nil
        )
      end

      def locked_observation_token(row, task, marker)
        self.class.observation_token(
          "project" => value(row, :project),
          "slug" => task.slug,
          "folder" => task.folder,
          "stage" => "#{task.stage_index}-#{task.stage_name}",
          "marker" => marker.name.to_s,
          "marker_attrs" => marker.attrs.to_h.transform_keys(&:to_s),
          "state_file_mtime" => File.mtime(task.state_file).utc,
          "task_generation" => value(row, :task_generation),
          "attempt_id" => value(row, :attempt_id)
        )
      end

      def resolve_task(project:, slug:, folder:, stage:)
        # Status already resolved the canonical current-generation folder.
        # Reuse it while TaskResolver enforces project and stage identity.
        target = folder.to_s.empty? ? slug : folder
        Hive::TaskResolver.new(target, project_filter: project, stage_filter: stage).resolve
      end

      def resolve_generation(task, project:, intended_stage:, state_file_content:)
        progress = Hive::Attempts::Generation.artifact_token(
          task, state_file_content: state_file_content
        )
        Hive::Attempts::Generation.resolve(
          task: task,
          project: project,
          intended_stage: intended_stage,
          progress_token: progress
        )
      end

      def generation_for_current(task, request)
        @generation_resolver.call(
          task,
          project: request.project,
          intended_stage: request.expected_stage,
          state_file_content: File.binread(task.state_file)
        )
      end

      def generation_matches?(generation, recovery)
        generation.progress_token.to_s ==
          recovery["expected_post_clear_progress_fingerprint"].to_s &&
          generation.task_generation.to_s == recovery["dispatch_generation"].to_s
      end

      def admission_failure_recovery?(recovery)
        recovery["variant"].to_s == "admission_failure"
      end

      def cleared_marker_state_valid?(marker, recovery)
        if admission_failure_recovery?(recovery)
          !recoverable_marker?(marker)
        else
          marker.none?
        end
      end

      def expected_attrs_match?(marker, expected)
        Hive::Recovery.marker_attrs_match?(marker.attrs, expected)
      end

      def retry_argv(row)
        stage = value(row, :stage).to_s
        project = value(row, :project).to_s
        slug = value(row, :slug).to_s
        verb = Hive::Recovery::RetryPolicy.verb_for(
          stage, workflow: value(row, :workflow), project: project
        )
        raise Hive::Error, "no retry verb for stage #{stage}" unless verb

        command = value(row, :suggested_command).to_s
        argv = Shellwords.split(command)
        return argv if @request_queue.valid_argv?(argv) && argv[1] != "markers"

        if verb != "run"
          [ "hive", verb, slug, "--project", project, "--from", stage, "--json" ]
        else
          [ "hive", "run", slug, "--project", project, "--stage", stage, "--json" ]
        end
      rescue ArgumentError
        raise Hive::Error, "invalid retry command for #{value(row, :slug)}"
      end

      def deterministic_request_id(row, task, marker_generation, dispatch_generation,
                                   source_receipt: nil)
        identity = if source_receipt
          [
            source_receipt["attempt_id"], source_receipt["receipt_version"],
            source_receipt["terminal_lease_version"]
          ]
        else
          [ marker_generation, dispatch_generation ]
        end
        ::Digest::SHA256.hexdigest(
          [
            "hive-recovery-request-v2", value(row, :project), task.id || task.slug,
            value(row, :stage), *identity
          ].join("\0")
        )[0, 32]
      end

      def deterministic_admission_request_id(project:, task:, dispatch_generation:,
                                             policy_digest:)
        ::Digest::SHA256.hexdigest(
          [
            "hive-admission-recovery-v1", project, task.id || task.slug,
            task_stage(task), dispatch_generation, policy_digest
          ].join("\0")
        )[0, 32]
      end

      def provider_hint(row)
        retry_after = marker_attrs(row)["retry_after"]
        return nil if retry_after.to_s.empty?

        { "retry_after" => retry_after.to_s, "display_only" => true }
      end

      def safety_owner(assessment)
        assessment[:safety_reason].start_with?("inspection failed:") ? "hive" : "operator"
      end

      def block_request(request, reason, owner:, remediation: nil,
                        request_locked: false)
        recovery = request.recovery
        resolved_remediation = remediation || remediation_for(reason)
        if recovery["blocked_reason"].to_s == reason.to_s &&
           recovery["blocked_remediation"].to_s == resolved_remediation.to_s &&
           recovery["owner"].to_s == owner.to_s
          return receipt_for_request(request)
        end

        transitioned = @request_queue.update_recovery!(
          request.request_id,
          expected_phase: recovery["phase"],
          changes: {
            "blocked_reason" => reason,
            "blocked_remediation" => resolved_remediation,
            "owner" => owner
          },
          state_home: @state_home,
          request_locked: request_locked
        )
        refreshed = @request_queue.fetch(request.request_id, state_home: @state_home)
        return unavailable_request(request, "transition_conflict") unless transitioned && refreshed

        receipt_for_request(refreshed)
      end

      def clear_resolved_block(request, request_locked:)
        recovery = request.recovery || {}
        return request if recovery["blocked_reason"].nil? &&
                          recovery["blocked_remediation"].nil? &&
                          recovery["owner"].to_s == "scheduler"

        transitioned = @request_queue.update_recovery!(
          request.request_id,
          expected_phase: recovery["phase"],
          changes: {
            "blocked_reason" => nil,
            "blocked_remediation" => nil,
            "owner" => "scheduler"
          },
          state_home: @state_home,
          request_locked: request_locked
        )
        refreshed = @request_queue.fetch(request.request_id, state_home: @state_home)
        return refreshed if transitioned && refreshed

        request
      end

      # Evidence parking is inert under daemon replay. Only an explicit,
      # freshness-bound operator retry releases the same guarded request back
      # into its admitted -> cleared -> dispatched transition.
      def unpark_deterministic_failure(request, now:)
        recovery = request.recovery || {}
        return request unless recovery["phase"] == "admitted"
        return request unless recovery["blocked_reason"] == "deterministic_failure"

        transitioned = @request_queue.update_recovery!(
          request.request_id,
          expected_phase: "admitted",
          changes: {
            "next_eligible_at" => now.utc.iso8601(6),
            "blocked_reason" => nil,
            "blocked_remediation" => nil,
            "owner" => "scheduler"
          },
          state_home: @state_home
        )
        refreshed = @request_queue.fetch(request.request_id, state_home: @state_home)
        return refreshed if transitioned && refreshed

        request
      end

      def recovery_due?(recovery, now:)
        eligible_at = Time.parse(recovery["next_eligible_at"].to_s)
        now.utc >= eligible_at.utc
      rescue ArgumentError, TypeError
        true
      end

      def unavailable_request(request, reason)
        receipt(
          "unavailable", request_id: request.request_id,
          phase: request.recovery&.fetch("phase", nil),
          failure_origin: request.recovery&.fetch("failure_origin", nil),
          owner: "hive", reason: reason,
          remediation: "refresh status and inspect the recovery request"
        )
      end

      def remediation_for(reason)
        case reason
        when "generation_conflict"
          "refresh status; task or marker generation changed"
        when "transition_conflict"
          "refresh status; another recovery owner advanced the request"
        else
          "inspect the recovery request and current task state"
        end
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) do |difference, (a, b)|
          difference | (a ^ b)
        end.zero?
      end
    end
  end
end
