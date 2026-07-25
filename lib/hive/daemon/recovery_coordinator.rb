require "digest"
require "json"
require "shellwords"
require "time"
require "hive/agent_limit"
require "hive/attempts/generation"
require "hive/daemon/auto_retry_safety"
require "hive/daemon/dispatch_request_queue"
require "hive/lock"
require "hive/markers"
require "hive/recovery"
require "hive/recovery/retry_policy"
require "hive/task"
require "hive/task_resolver"

module Hive
  module Daemon
    # Sole producer and transition owner for ERROR / REVIEW_ERROR recovery.
    # Adapters submit an observed row; this coordinator re-resolves it under
    # the task lock, applies the shared cooldown and safety policy, then
    # persists one restartable v4 request before any marker mutation.
    class RecoveryCoordinator
      LIFECYCLE_STATES = %w[
        queued cooldown running blocked terminal unavailable
      ].freeze

      Receipt = Data.define(
        :status, :request_id, :attempt_id, :phase, :failure_origin,
        :next_eligible_at, :owner, :reason, :remediation, :retry_count,
        :provider_hint, :terminal_outcome, :terminal_at
      ) do
        def initialize(terminal_outcome: nil, terminal_at: nil, **rest)
          super(terminal_outcome: terminal_outcome, terminal_at: terminal_at, **rest)
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
          attrs = attrs.is_a?(Hash) ? attrs.to_h.transform_keys(&:to_s) : {}
          attrs = attrs.keys.sort.to_h { |key| [ key, attrs[key] ] }
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
                     generation_resolver: nil)
        @state_home = state_home
        @request_queue = request_queue
        @task_resolver = task_resolver || method(:resolve_task)
        @safety = safety.respond_to?(:call) ? safety : safety.method(:safe_to_retry?)
        @generation_resolver = generation_resolver || method(:resolve_generation)
      end

      def assessment(row, now: Time.now.utc)
        observed_at = value(row, :state_file_mtime)
        eligible_at = observed_at && observed_at + Hive::AgentLimit.retry_cooldown_sec
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
        assessment = assessment(row, now: now)
        unless assessment[:retry_at]
          return receipt(
            "unavailable", failure_origin: failure_origin, owner: "hive",
            reason: "missing_observation_time",
            remediation: "refresh status so Hive can observe the current marker generation",
            retry_count: retry_count
          )
        end
        unless assessment[:due]
          return receipt(
            "cooldown", failure_origin: failure_origin, owner: "scheduler",
            next_eligible_at: assessment[:retry_at].utc.iso8601(6),
            reason: "shared_cooldown",
            remediation: "retry remains available after the shared one-hour cooldown",
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
          canonical_request_id = request_id.to_s
          canonical_request_id = deterministic_request_id(
            row, locked_task, expected_generation, generation.task_generation
          ) if canonical_request_id.empty?
          attrs = current.attrs.to_h.transform_keys(&:to_s)
          marker_id = marker_identity(current)
          next_eligible_at = assessment[:retry_at].utc.iso8601(6)
          recovery = {
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
            "provider_hint" => provider_hint(row)
          }
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
            except_request_id: canonical_request_id,
            state_home: @state_home
          )
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
              if marker.none?
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
              marker.none? &&
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
              "next_eligible_at" => (now + Hive::AgentLimit.retry_cooldown_sec).iso8601(6),
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
          reason: blocked.empty? ? (replay ? "terminal_replay" : nil) : blocked,
          remediation: blocked.empty? ? nil :
            (recovery["blocked_remediation"] || remediation_for(blocked)),
          retry_count: recovery["retry_count"],
          provider_hint: recovery["provider_hint"],
          terminal_outcome: recovery["terminal_outcome"],
          terminal_at: recovery["terminal_at"]
        )
      end

      def receipt_for_id(request_id)
        request = @request_queue.fetch(request_id, state_home: @state_home)
        request && receipt_for_request(request)
      end

      def observation_token_for(row)
        self.class.observation_token(row)
      end

      private

      def durable_retry_count(row)
        @request_queue.recovery_retry_count(
          project: value(row, :project),
          slug: value(row, :slug),
          state_home: @state_home
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
                  provider_hint: nil, terminal_outcome: nil, terminal_at: nil)
        raise ArgumentError, "unknown recovery lifecycle #{status}" unless LIFECYCLE_STATES.include?(status)

        Receipt.new(
          status: status, request_id: request_id, attempt_id: attempt_id,
          phase: phase, failure_origin: failure_origin,
          next_eligible_at: next_eligible_at, owner: owner, reason: reason,
          remediation: remediation, retry_count: retry_count,
          provider_hint: provider_hint, terminal_outcome: terminal_outcome,
          terminal_at: terminal_at
        )
      end

      def value(row, key)
        return row.public_send(key) if row.respond_to?(key)
        return row[key.to_s] if row.respond_to?(:[])

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
        attrs = marker.attrs.to_h.transform_keys(&:to_s)
        return nil if attrs["marker_id"].to_s.empty?

        canonical = attrs.keys.sort.to_h { |key| [ key, attrs[key] ] }
        ::Digest::SHA256.hexdigest(JSON.generate(
          "name" => marker.name.to_s,
          "attrs" => canonical
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
        Hive::TaskResolver.new(slug, project_filter: project, stage_filter: stage).resolve
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

      def expected_attrs_match?(marker, expected)
        expected.to_h.all? do |key, expected_value|
          marker.attrs[key.to_s].to_s == expected_value.to_s
        end
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

      def deterministic_request_id(row, task, marker_generation, dispatch_generation)
        ::Digest::SHA256.hexdigest(
          [
            "hive-recovery-request-v2", value(row, :project), task.id || task.slug,
            value(row, :stage), marker_generation, dispatch_generation
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
