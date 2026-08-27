require "date"
require "digest"
require "json"
require "time"
require "hive/attempts/point_storage"
require "hive/attempts/record"
require "hive/provider_routing/decision"

module Hive
  module Attempts
    # Point-addressed decision cells used by later admission/reconciliation
    # work. Each compound key is digest-addressed and embedded in its payload.
    # Operator inspection alone may enumerate the bounded current routing
    # projection; mutation and replay remain point-addressed.
    class DecisionIndex
      SCHEMA = "hive-attempt-decision-index".freeze
      SCHEMA_VERSION = 1
      MAX_ENTRY_BYTES = 2 * 1024 * 1024
      MAX_DAILY_ATTEMPTS = 10_000
      MAX_LIVE_RESERVATIONS = 1_024
      MAX_ROUTING_PROJECTIONS = 4_096
      MAX_FAILURE_COHORTS = 512
      FAILURE_COHORT_THRESHOLD = 3
      FAILURE_COHORT_COOLDOWN_SEC = 60 * 60
      FAILURE_COHORT_PROBE_TTL_SEC = 24 * 60 * 60
      TERMINAL_REQUEST = "terminal-request".freeze
      LATEST_TERMINAL = "latest-terminal".freeze
      SUCCESSFUL_OWNER = "successful-owner".freeze
      UNRESOLVED_LOSS = "unresolved-loss".freeze
      SUCCESSOR = "successor".freeze
      DAILY_ACCOUNTING = "daily-accounting".freeze
      LIVE_CAPACITY = "live-capacity".freeze
      ROUTING_DECISION = "routing-decision".freeze
      FAILURE_COHORTS = "failure-cohorts".freeze
      ENTRY_KEYS = %w[kind key schema schema_version value].freeze

      attr_reader :root

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt decision indexes",
          create_directories: create_directories
        )
        @root = @storage.root
      end

      def record_terminal(record)
        terminal!(record)
        update_ordered(
          TERMINAL_REQUEST,
          request_key(record["request_id"]),
          ordered_value(record).merge("outcome" => record.outcome)
        )
        update_ordered(
          LATEST_TERMINAL,
          semantic_key(record.task_generation, record.subject),
          ordered_value(record)
        )
        return record unless record.outcome == "succeeded"

        update_ordered(
          SUCCESSFUL_OWNER,
          semantic_key(record.task_generation, record.subject),
          ordered_value(record)
        )
        record
      end

      def terminal_attempt_id(request_id:)
        value = read_value(TERMINAL_REQUEST, request_key(request_id))
        value && value.fetch("attempt_id")
      end

      def latest_terminal_attempt_id(task_generation:, subject:)
        value = read_value(
          LATEST_TERMINAL,
          semantic_key(task_generation, subject)
        )
        value && value.fetch("attempt_id")
      end

      def successful_attempt_id(task_generation:, subject:)
        value = read_value(
          SUCCESSFUL_OWNER,
          semantic_key(task_generation, subject)
        )
        value && value.fetch("attempt_id")
      end

      def record_unresolved_loss(record)
        unless record.is_a?(Record) && record.state == "lost"
          raise StoreError, "unresolved-loss index requires a lost schema-v4 record"
        end

        key = semantic_key(record.task_generation, record.subject)
        candidate = ordered_value(record).merge("resolved_by" => nil)
        update_entry(UNRESOLVED_LOSS, key) do |current|
          value = current && current.fetch("value")
          if value && (order(value) <=> order(candidate)) >= 0
            value
          else
            candidate
          end
        end
        record
      end

      def unresolved_loss_attempt_id(task_generation:, subject:)
        value = read_value(
          UNRESOLVED_LOSS,
          semantic_key(task_generation, subject)
        )
        return nil if value.nil? || value["resolved_by"]

        value.fetch("attempt_id")
      end

      def record_successor(record)
        unless record.is_a?(Record) && !record["predecessor_attempt_id"].to_s.empty?
          raise StoreError, "successor index requires a predecessor-bound schema-v4 record"
        end

        predecessor = record["predecessor_attempt_id"]
        key = predecessor_key(predecessor)
        value = ordered_value(record)
        update_entry(SUCCESSOR, key) do |current|
          existing = current && current.fetch("value")
          existing && (order(existing) <=> order(value)) >= 0 ? existing : value
        end

        loss_key = semantic_key(record.task_generation, record.subject)
        update_entry(UNRESOLVED_LOSS, loss_key) do |current|
          next nil unless current

          existing = current.fetch("value")
          next existing unless existing["attempt_id"] == predecessor

          existing.merge("resolved_by" => record.attempt_id)
        end
        record
      end

      def successor_attempt_id(predecessor_attempt_id:)
        value = read_value(
          SUCCESSOR,
          predecessor_key(predecessor_attempt_id)
        )
        value && value.fetch("attempt_id")
      end

      def record_acceptance(record)
        record!(record)
        date = accepted_date(record)
        key = accounting_key(date)
        update_entry(DAILY_ACCOUNTING, key) do |current|
          attempts = current ? current.fetch("value").fetch("attempts").dup : {}
          existing = attempts[record.attempt_id]
          candidate = {
            "accepted_at" => record["accepted_at"],
            "project" => record["project"],
            "refunded" => false
          }
          if existing && existing != candidate && existing != candidate.merge("refunded" => true)
            raise StoreError, "daily accounting attempt conflicts with its accepted identity"
          end
          attempts[record.attempt_id] ||= candidate
          if attempts.size > MAX_DAILY_ATTEMPTS
            raise StoreError, "daily accounting index exceeds its bounded shard"
          end
          { "attempts" => attempts }
        end
        record
      end

      # An attempt that never reached `running` has no `started_at`, which
      # means no agent ever spawned and not one token was spent. Charging it a
      # daily slot makes a launch that failed cost exactly as much budget as a
      # full run, so a night of failed handoffs can exhaust the day and lock
      # out the work that would have succeeded.
      #
      # This is the same principle the TEMPFAIL refund already encodes — "we
      # did not actually do work" — applied to the other way that happens.
      # Attempts lost *after* starting keep their charge: the agent ran, the
      # tokens are gone, and the cap is a spend bound.
      def refund_unstarted(record)
        unless record.state == "lost"
          raise StoreError, "daily accounting unstarted refund requires a lost record"
        end
        unless record["started_at"].nil?
          raise StoreError, "daily accounting unstarted refund requires an attempt that never ran"
        end

        mark_refunded(record)
      end

      def refund_tempfail(record)
        terminal!(record)
        unless record.receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL
          raise StoreError, "daily accounting refund requires a TEMPFAIL receipt"
        end

        mark_refunded(record)
      end

      def mark_refunded(record)
        key = accounting_key(accepted_date(record))
        update_entry(DAILY_ACCOUNTING, key) do |current|
          unless current
            raise StoreError, "daily accounting acceptance is missing"
          end

          attempts = current.fetch("value").fetch("attempts").dup
          acceptance = attempts[record.attempt_id]
          unless acceptance && acceptance["accepted_at"] == record["accepted_at"] &&
                 acceptance["project"] == record["project"]
            raise StoreError, "daily accounting acceptance is missing"
          end
          attempts[record.attempt_id] = acceptance.merge("refunded" => true)
          { "attempts" => attempts }
        end
        record
      end

      def daily_count(project:, date:)
        daily_counts(date: date).fetch([ StorageKey.string(project), date_value(date) ], 0)
      end

      def daily_counts(date:)
        utc_date = date_value(date)
        counts = Hash.new(0)
        daily_acceptances(date: utc_date).each_value do |acceptance|
          counts[[ acceptance.fetch("project"), utc_date ]] += 1 unless acceptance["refunded"]
        end
        counts.to_h.freeze
      end

      def daily_acceptances(date:)
        utc_date = date_value(date)
        value = read_value(DAILY_ACCOUNTING, accounting_key(utc_date))
        return {}.freeze unless value

        value.fetch("attempts").to_h do |attempt_id, acceptance|
          [ attempt_id.dup.freeze, acceptance.dup.freeze ]
        end.freeze
      end

      # The host-wide admission lock is the transaction boundary for these
      # methods. This single bounded cell contains current reservations only;
      # it is not attempt history. Pending-before-create makes a crash
      # conservative, and the next lock holder can remove a pending entry only
      # after observing that no hot record was created.
      def reserve_live(attempt_id:, project:, task_slug:, admission: nil)
        update_live_reservations do |reservations|
          id = StorageKey.string(attempt_id)
          candidate = live_reservation(
            project: project, task_slug: task_slug, phase: "pending",
            admission: admission
          )
          existing = reservations[id]
          if existing && existing.except("phase") != candidate.except("phase")
            raise StoreError, "live capacity reservation conflicts with attempt identity"
          end
          reservations[id] ||= candidate
          reservations
        end
      end

      def confirm_live(attempt_id:, project:, task_slug:, admission: nil)
        update_live_reservations do |reservations|
          id = StorageKey.string(attempt_id)
          candidate = live_reservation(
            project: project, task_slug: task_slug, phase: "active",
            admission: admission
          )
          existing = reservations[id]
          if existing && existing.except("phase") != candidate.except("phase")
            raise StoreError, "live capacity reservation conflicts with attempt identity"
          end
          reservations[id] = candidate
          reservations
        end
      end

      def release_live(attempt_id:)
        update_live_reservations do |reservations|
          reservations.delete(StorageKey.string(attempt_id))
          reservations
        end
      end

      def live_reservations
        value = read_value(LIVE_CAPACITY, live_capacity_key)
        reservations = value ? value.fetch("reservations") : {}
        reservations.to_h do |attempt_id, reservation|
          [ attempt_id.dup.freeze, reservation.dup.freeze ]
        end.freeze
      end

      def record_failure_cohort(attempt_id:, identity:, occurred_at:)
        normalized_identity = failure_cohort_identity(identity)
        attempt = StorageKey.string(attempt_id)
        occurred = time_value(occurred_at)
        date = occurred.utc.to_date
        digest = failure_cohort_digest(normalized_identity)
        update_failure_cohorts(date) do |value|
          next value if value.fetch("processed_attempts").key?(attempt)

          cohorts = value.fetch("cohorts")
          cohorts.each do |key, candidate|
            next unless candidate.fetch("probe_attempt_id") == attempt &&
                        candidate.fetch("identity") != normalized_identity

            cohorts[key] = refresh_failure_cohort(
              candidate, occurred: occurred, clear_probe: true
            )
          end
          entry = cohorts[digest] || empty_failure_cohort(normalized_identity)
          count = entry.fetch("failure_count") + 1
          probe_finished = entry.fetch("probe_attempt_id") == attempt
          refreshed = refresh_failure_cohort(
            entry, occurred: occurred, clear_probe: probe_finished,
            failure_count: count
          )
          cohorts[digest] = refreshed.merge(
            "failure_count" => count,
            "retry_at" => count >= FAILURE_COHORT_THRESHOLD ?
              refreshed.fetch("retry_at") : nil
          )
          value.fetch("processed_attempts")[attempt] = digest
          value
        end
      end

      def record_failure_cohort_success(attempt_id:, date:)
        attempt = StorageKey.string(attempt_id)
        found = false
        update_failure_cohorts(date, create: false) do |value|
          value.fetch("cohorts").delete_if do |_digest, entry|
            matched = entry.fetch("probe_attempt_id") == attempt
            found ||= matched
            matched
          end
          value.fetch("processed_attempts")[attempt] = "succeeded" if found
          value
        end
        found
      end

      def failure_cohort_admission(identity:, date:, now:, explicit_release: false)
        normalized_identity = failure_cohort_identity(identity)
        value = read_value(FAILURE_COHORTS, failure_cohorts_key(date))
        entry = value&.fetch("cohorts", {})&.fetch(
          failure_cohort_digest(normalized_identity), nil
        )
        return open_failure_cohort unless entry
        return open_failure_cohort if entry.fetch("failure_count") < FAILURE_COHORT_THRESHOLD

        current = expire_failure_cohort_probe(entry, now: time_value(now))
        return blocked_failure_cohort if current.fetch("probe_attempt_id")
        retry_at = Time.iso8601(current.fetch("retry_at"))
        return probe_failure_cohort if explicit_release || time_value(now) >= retry_at

        blocked_failure_cohort(retry_at: current.fetch("retry_at"))
      end

      def claim_failure_cohort_probe(identity:, date:, attempt_id:, now:,
                                     explicit_release: false)
        normalized_identity = failure_cohort_identity(identity)
        digest = failure_cohort_digest(normalized_identity)
        claimed = false
        update_failure_cohorts(date) do |value|
          entry = value.fetch("cohorts")[digest]
          next value unless entry && entry.fetch("failure_count") >= FAILURE_COHORT_THRESHOLD

          current = expire_failure_cohort_probe(entry, now: time_value(now))
          next value if current.fetch("probe_attempt_id")
          retry_at = Time.iso8601(current.fetch("retry_at"))
          next value unless explicit_release || time_value(now) >= retry_at

          value.fetch("cohorts")[digest] = current.merge(
            "probe_attempt_id" => StorageKey.string(attempt_id),
            "probe_expires_at" =>
              (time_value(now) + FAILURE_COHORT_PROBE_TTL_SEC).utc.iso8601(6)
          )
          claimed = true
          value
        end
        claimed
      end

      def release_failure_cohort_probe(identity:, date:, attempt_id:)
        normalized_identity = failure_cohort_identity(identity)
        digest = failure_cohort_digest(normalized_identity)
        attempt = StorageKey.string(attempt_id)
        released = false
        update_failure_cohorts(date, create: false) do |value|
          entry = value.fetch("cohorts")[digest]
          next value unless entry&.fetch("probe_attempt_id") == attempt

          value.fetch("cohorts")[digest] = entry.merge(
            "probe_attempt_id" => nil, "probe_expires_at" => nil
          )
          released = true
          value
        end
        released
      end

      def replace_live_reservations(reservations)
        replacements = reservations.to_h do |attempt_id, reservation|
          value = live_reservation(
            project: reservation.fetch("project"),
            task_slug: reservation.fetch("task_slug"),
            phase: reservation.fetch("phase"),
            admission: reservation["admission"]
          )
          [ StorageKey.string(attempt_id), value ]
        end
        update_live_reservations { replacements }
        replacements.freeze
      rescue KeyError
        raise StoreError, "live capacity reservation is invalid"
      end

      def record_routing_decision(decision:, task_generation:, subject:, project:,
                                  attempt_id: nil)
        unless decision.is_a?(Hive::ProviderRouting::Decision) && !decision.legacy?
          raise StoreError, "routing decision index requires an explicit typed decision"
        end
        key = semantic_key(task_generation, subject)
        unless decision.request.task_generation == key.fetch("task_generation")
          raise StoreError, "routing decision task generation does not match its index key"
        end
        candidate = {
          "project" => StorageKey.string(project),
          "attempt_id" => attempt_id && StorageKey.string(attempt_id),
          "decision" => decision.to_h
        }
        validate_value!(ROUTING_DECISION, candidate, key: key)
        update_entry(ROUTING_DECISION, key) { candidate }
        candidate.fetch("decision")
      end

      def routing_decision(task_generation:, subject:)
        value = read_value(
          ROUTING_DECISION,
          semantic_key(task_generation, subject)
        )
        value && value.fetch("decision")
      end

      def routing_decisions(limit: MAX_ROUTING_PROJECTIONS)
        unless limit.is_a?(Integer)
          raise StoreError, "routing decision projection limit is invalid"
        end
        maximum = limit
        unless maximum.positive? && maximum <= MAX_ROUTING_PROJECTIONS
          raise StoreError, "routing decision projection limit is invalid"
        end

        entries = []
        @storage.each_entry(
          ROUTING_DECISION,
          max_entries: MAX_ROUTING_PROJECTIONS,
          max_bytes: MAX_ENTRY_BYTES
        ) do |bytes|
          payload = parse_enumerated_entry(bytes, expected_kind: ROUTING_DECISION)
          entries << {
            "task_generation" => payload.dig("key", "task_generation"),
            "subject" => payload.dig("key", "subject"),
            "project" => payload.dig("value", "project"),
            "attempt_id" => payload.dig("value", "attempt_id"),
            "decision" => payload.dig("value", "decision")
          }
        end
        entries.sort_by do |entry|
          decision = entry.fetch("decision")
          [ decision.fetch("decided_at"), decision.fetch("decision_id") ]
        end.last(maximum).reverse.freeze
      rescue ArgumentError, TypeError
        raise StoreError, "routing decision projection limit is invalid"
      end

      def path_for(kind, key)
        @storage.path_for(kind, StorageKey.normalize(key))
      end

      private

      def update_ordered(kind, key, candidate)
        update_entry(kind, key) do |current|
          existing = current && current.fetch("value")
          if existing && (order(existing) <=> order(candidate)) >= 0
            existing
          else
            candidate
          end
        end
      end

      def update_entry(kind, key)
        normalized_key = StorageKey.normalize(key)
        @storage.synchronize(kind, normalized_key) do
          bytes = @storage.read(kind, normalized_key, max_bytes: MAX_ENTRY_BYTES)
          current = bytes && parse_entry(bytes, expected_kind: kind, expected_key: normalized_key)
          value = yield(current)
          next current if current && current.fetch("value") == value
          next nil if current.nil? && value.nil?

          payload = {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "kind" => kind,
            "key" => normalized_key,
            "value" => value
          }
          replacement = StorageKey.dump(payload)
          raise StoreError, "attempt decision index entry is too large" if replacement.bytesize > MAX_ENTRY_BYTES

          @storage.write(
            kind,
            normalized_key,
            replacement,
            expected_bytes: bytes,
            max_existing_bytes: MAX_ENTRY_BYTES
          )
          payload
        end
      end

      def read_value(kind, key)
        normalized_key = StorageKey.normalize(key)
        bytes = @storage.read(kind, normalized_key, max_bytes: MAX_ENTRY_BYTES)
        return nil unless bytes

        parse_entry(
          bytes,
          expected_kind: kind,
          expected_key: normalized_key
        ).fetch("value")
      end

      def parse_entry(bytes, expected_kind:, expected_key:)
        payload = JSON.parse(bytes)
        valid = payload.is_a?(Hash) &&
          payload.keys.sort == ENTRY_KEYS.sort &&
          payload["schema"] == SCHEMA &&
          payload["schema_version"] == SCHEMA_VERSION &&
          payload["kind"] == expected_kind &&
          payload["key"] == expected_key &&
          bytes == StorageKey.dump(payload) &&
          payload["value"].is_a?(Hash)
        raise StoreError, "attempt decision index entry is corrupt or colliding" unless valid

        validate_value!(expected_kind, payload.fetch("value"), key: expected_key)

        payload
      rescue JSON::ParserError, EncodingError, ArgumentError, TypeError, KeyError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      end

      def parse_enumerated_entry(bytes, expected_kind:)
        payload = JSON.parse(bytes)
        key = payload["key"]
        unless key.is_a?(Hash)
          raise StoreError, "attempt decision index entry is corrupt or colliding"
        end

        parse_entry(
          bytes,
          expected_kind: expected_kind,
          expected_key: StorageKey.normalize(key)
        )
      rescue JSON::ParserError, EncodingError, ArgumentError, TypeError, KeyError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      end

      def validate_value!(kind, value, key: nil)
        case kind
        when TERMINAL_REQUEST
          ordered_value_shape!(value, extra_keys: [ "outcome" ])
          raise StoreError unless Record::TERMINAL_OUTCOMES.include?(value["outcome"])
        when LATEST_TERMINAL, SUCCESSFUL_OWNER, SUCCESSOR
          ordered_value_shape!(value)
        when UNRESOLVED_LOSS
          ordered_value_shape!(value, extra_keys: [ "resolved_by" ])
          resolved_by = value["resolved_by"]
          StorageKey.string(resolved_by) if resolved_by
        when DAILY_ACCOUNTING
          attempts = value["attempts"]
          raise StoreError unless value.keys == [ "attempts" ] && attempts.is_a?(Hash)
          raise StoreError if attempts.size > MAX_DAILY_ATTEMPTS

          attempts.each do |attempt_id, acceptance|
            StorageKey.string(attempt_id)
            valid = acceptance.is_a?(Hash) &&
              acceptance.keys.sort == %w[accepted_at project refunded] &&
              (acceptance["refunded"] == true || acceptance["refunded"] == false)
            raise StoreError unless valid

            Time.iso8601(acceptance.fetch("accepted_at"))
            StorageKey.string(acceptance.fetch("project"))
          end
        when LIVE_CAPACITY
          reservations = value["reservations"]
          raise StoreError unless value.keys == [ "reservations" ] && reservations.is_a?(Hash)
          raise StoreError if reservations.size > MAX_LIVE_RESERVATIONS

          reservations.each do |attempt_id, reservation|
            StorageKey.string(attempt_id)
            valid_keys = [ %w[phase project task_slug], %w[admission phase project task_slug] ]
            valid = reservation.is_a?(Hash) &&
              valid_keys.include?(reservation.keys.sort) &&
              %w[pending active].include?(reservation["phase"])
            raise StoreError unless valid

            StorageKey.string(reservation.fetch("project"))
            StorageKey.string(reservation.fetch("task_slug"))
            live_admission(reservation["admission"]) if reservation.key?("admission")
          end
        when ROUTING_DECISION
          validate_routing_decision_value!(value, key: key)
        when FAILURE_COHORTS
          validate_failure_cohorts_value!(value, key: key)
        end
        true
      rescue StoreError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      rescue ArgumentError, TypeError, KeyError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      end

      def validate_routing_decision_value!(value, key:)
        unless value.keys.sort == %w[attempt_id decision project]
          raise StoreError
        end
        StorageKey.string(value.fetch("project"))
        attempt_id = value.fetch("attempt_id")
        StorageKey.string(attempt_id) unless attempt_id.nil?

        decision = value.fetch("decision")
        expected_keys = %w[
          candidates circuit_generations decided_at decision_id exclusions
          next_action_owner policy policy_digest probe_requirements reason
          selected_route status task_generation
        ]
        unless decision.is_a?(Hash) && decision.keys.sort == expected_keys.sort
          raise StoreError
        end
        StorageKey.string(decision.fetch("decision_id"))
        Time.iso8601(decision.fetch("decided_at"))
        StorageKey.string(decision.fetch("task_generation"))
        unless decision.fetch("task_generation") == key.fetch("task_generation")
          raise StoreError
        end
        unless decision.fetch("policy_digest").is_a?(String) &&
               decision.fetch("policy_digest").match?(Record::SHA256_PATTERN)
          raise StoreError
        end
        unless %w[selected capacity_saturated no_route].include?(decision.fetch("status"))
          raise StoreError
        end
        selected = decision.fetch("status") == "selected"
        unless selected == !attempt_id.nil?
          raise StoreError
        end
        unless Hive::ProviderRouting::Decision::OWNERS.include?(
          decision.fetch("next_action_owner")
        )
          raise StoreError
        end
        StorageKey.string(decision.fetch("reason"))
        policy = decision.fetch("policy")
        unless policy.is_a?(Hash) && policy.keys.sort == %w[pin requirements stage]
          raise StoreError
        end
        StorageKey.string(policy.fetch("stage"))
        pin = policy.fetch("pin")
        unless pin.nil? || (pin.is_a?(Hash) && pin.keys.sort == %w[model provider] &&
          pin["provider"].is_a?(String) && (pin["model"].nil? || pin["model"].is_a?(String)))
          raise StoreError
        end
        requirements = policy.fetch("requirements")
        unless requirements.is_a?(Hash) && requirements.keys.sort == %w[context permissions quality tools] &&
               requirements.fetch("tools").is_a?(Array) && requirements.fetch("permissions").is_a?(Array)
          raise StoreError
        end
        selected_route = decision.fetch("selected_route")
        StorageKey.string(selected_route) unless selected_route.nil?
        unless selected == !selected_route.nil?
          raise StoreError
        end
        %w[candidates exclusions circuit_generations probe_requirements].each do |field|
          entries = decision.fetch(field)
          maximum = case field
          when "candidates" then 1_024
          when "exclusions" then 2_048
          else 2
          end
          raise StoreError unless entries.is_a?(Array) && entries.length <= maximum
        end
        reject_unsafe_routing_keys!(decision)
        StorageKey.normalize(decision)
      end

      def reject_unsafe_routing_keys!(value)
        forbidden = %w[
          credential credentials message prompt raw stderr stdout token tokens
          tool_output
        ]
        case value
        when Hash
          raise StoreError unless (value.keys & forbidden).empty?

          value.each_value { |child| reject_unsafe_routing_keys!(child) }
        when Array
          value.each { |child| reject_unsafe_routing_keys!(child) }
        end
      end

      def ordered_value_shape!(value, extra_keys: [])
        keys = %w[accepted_at attempt_id lease_version] + extra_keys
        raise StoreError unless value.keys.sort == keys.sort

        StorageKey.string(value.fetch("attempt_id"))
        Time.iso8601(value.fetch("accepted_at"))
        lease_version = value.fetch("lease_version")
        raise StoreError unless lease_version.is_a?(Integer) && lease_version >= 0
      end

      def request_key(request_id) = { "request_id" => StorageKey.string(request_id) }

      def predecessor_key(attempt_id)
        { "predecessor_attempt_id" => StorageKey.string(attempt_id) }
      end

      def semantic_key(task_generation, subject)
        {
          "task_generation" => StorageKey.string(task_generation),
          "subject" => StorageKey.normalize(subject)
        }
      end

      def accounting_key(date) = { "utc_date" => date_value(date).iso8601 }

      def live_capacity_key = { "scope" => "host" }

      def failure_cohorts_key(date) = { "utc_date" => date_value(date).iso8601 }

      def update_failure_cohorts(date, create: true)
        update_entry(FAILURE_COHORTS, failure_cohorts_key(date)) do |current|
          next nil if current.nil? && !create

          existing = current&.fetch("value")
          value = if existing
            {
              "cohorts" => existing.fetch("cohorts").dup,
              "processed_attempts" => existing.fetch("processed_attempts").dup
            }
          else
            { "cohorts" => {}, "processed_attempts" => {} }
          end
          result = yield(value)
          if result.fetch("cohorts").size > MAX_FAILURE_COHORTS ||
             result.fetch("processed_attempts").size > MAX_DAILY_ATTEMPTS
            raise StoreError, "failure cohort index exceeds its bounded UTC shard"
          end
          result
        end
      end

      def failure_cohort_identity(identity)
        value = StorageKey.normalize(identity)
        unless value.keys.sort == %w[code project runtime_digest stage workflow]
          raise StoreError, "failure cohort identity is invalid"
        end
        %w[code project stage workflow].each { |key| StorageKey.string(value.fetch(key)) }
        digest = value.fetch("runtime_digest")
        unless digest.is_a?(String) && digest.match?(Record::SHA256_PATTERN)
          raise StoreError, "failure cohort runtime digest is invalid"
        end
        value
      rescue ArgumentError, TypeError, KeyError
        raise StoreError, "failure cohort identity is invalid"
      end

      def failure_cohort_digest(identity)
        Digest::SHA256.hexdigest(StorageKey.dump(identity))
      end

      def empty_failure_cohort(identity)
        {
          "identity" => identity,
          "failure_count" => 0,
          "retry_at" => nil,
          "probe_attempt_id" => nil,
          "probe_expires_at" => nil
        }
      end

      def expire_failure_cohort_probe(entry, now:)
        expiry = entry.fetch("probe_expires_at")
        return entry unless expiry && Time.iso8601(expiry) <= now

        entry.merge("probe_attempt_id" => nil, "probe_expires_at" => nil)
      end

      def refresh_failure_cohort(entry, occurred:, clear_probe:, failure_count: nil)
        count = failure_count || entry.fetch("failure_count")
        retry_at = entry.fetch("retry_at")
        if count >= FAILURE_COHORT_THRESHOLD
          candidate = occurred + FAILURE_COHORT_COOLDOWN_SEC
          retry_at = [ retry_at && Time.iso8601(retry_at), candidate ].compact.max
            .utc.iso8601(6)
        end
        entry.merge(
          "retry_at" => retry_at,
          "probe_attempt_id" => clear_probe ? nil : entry.fetch("probe_attempt_id"),
          "probe_expires_at" => clear_probe ? nil : entry.fetch("probe_expires_at")
        )
      end

      def open_failure_cohort = { "status" => "open", "reason" => nil }.freeze
      def probe_failure_cohort = { "status" => "probe", "reason" => nil }.freeze

      def blocked_failure_cohort(retry_at: nil)
        {
          "status" => "blocked",
          "reason" => "failure_cohort_cooldown",
          "retry_at" => retry_at
        }.freeze
      end

      def validate_failure_cohorts_value!(value, key:)
        unless value.keys.sort == %w[cohorts processed_attempts] &&
               value.fetch("cohorts").is_a?(Hash) &&
               value.fetch("processed_attempts").is_a?(Hash) &&
               value.fetch("cohorts").size <= MAX_FAILURE_COHORTS &&
               value.fetch("processed_attempts").size <= MAX_DAILY_ATTEMPTS
          raise StoreError
        end
        date_value(key.fetch("utc_date"))
        value.fetch("processed_attempts").each do |attempt_id, digest|
          StorageKey.string(attempt_id)
          unless digest == "succeeded" ||
                 (digest.is_a?(String) && digest.match?(Record::SHA256_PATTERN))
            raise StoreError
          end
        end
        value.fetch("cohorts").each do |digest, entry|
          raise StoreError unless digest.match?(Record::SHA256_PATTERN)
          unless entry.is_a?(Hash) && entry.keys.sort == %w[
            failure_count identity probe_attempt_id probe_expires_at retry_at
          ]
            raise StoreError
          end
          identity = failure_cohort_identity(entry.fetch("identity"))
          raise StoreError unless failure_cohort_digest(identity) == digest
          count = entry.fetch("failure_count")
          raise StoreError unless count.is_a?(Integer) && count.positive?
          retry_at = entry.fetch("retry_at")
          Time.iso8601(retry_at) if retry_at
          probe = entry.fetch("probe_attempt_id")
          expiry = entry.fetch("probe_expires_at")
          unless probe.nil? == expiry.nil?
            raise StoreError
          end
          StorageKey.string(probe) if probe
          Time.iso8601(expiry) if expiry
        end
      end

      def time_value(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        raise StoreError, "failure cohort time is invalid"
      end

      def live_reservation(project:, task_slug:, phase:, admission: nil)
        unless %w[pending active].include?(phase)
          raise StoreError, "live capacity reservation phase is invalid"
        end
        value = {
          "project" => StorageKey.string(project),
          "task_slug" => StorageKey.string(task_slug),
          "phase" => phase
        }
        value["admission"] = live_admission(admission) if admission
        value
      end

      def live_admission(admission)
        value = StorageKey.normalize(admission)
        unless value.keys.sort == %w[runtime_digest stage utc_date workflow] &&
               value.fetch("workflow") == "patrol_fix" &&
               value.fetch("runtime_digest").match?(Record::SHA256_PATTERN)
          raise StoreError, "live capacity admission metadata is invalid"
        end
        StorageKey.string(value.fetch("stage"))
        date_value(value.fetch("utc_date"))
        value
      rescue ArgumentError, TypeError, KeyError
        raise StoreError, "live capacity admission metadata is invalid"
      end

      def update_live_reservations
        update_entry(LIVE_CAPACITY, live_capacity_key) do |current|
          reservations = current ?
            current.fetch("value").fetch("reservations").transform_values(&:dup) : {}
          reservations = yield(reservations)
          if reservations.size > MAX_LIVE_RESERVATIONS
            raise StoreError, "live capacity index exceeds its bounded reservation set"
          end
          { "reservations" => reservations }
        end
      end

      def date_value(value)
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error, ArgumentError
        raise StoreError, "daily accounting date is invalid"
      end

      def accepted_date(record)
        Time.iso8601(record["accepted_at"]).utc.to_date
      end

      def ordered_value(record)
        {
          "attempt_id" => record.attempt_id,
          "accepted_at" => record["accepted_at"],
          "lease_version" => record.lease_version
        }
      end

      def order(value)
        [ value.fetch("accepted_at"), value.fetch("lease_version"), value.fetch("attempt_id") ]
      end

      def record!(record)
        return record if record.is_a?(Record)

        raise StoreError, "attempt decision index requires a schema-v4 record"
      end

      def terminal!(record)
        record!(record)
        return record if record.state == "terminal"

        raise StoreError, "terminal decision index requires a terminal schema-v4 record"
      end
    end
  end
end
