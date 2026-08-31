require "digest"
require "securerandom"
require "time"
require "hive/attempts/output_reference"
require "hive/paths"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Durable dispatch requests and their completion outbox. Task/provider
    # admission itself belongs exclusively to AdmissionTransition.
    class DispatchRepository
      SCHEMA = "hive-dispatch-request".freeze
      SCHEMA_VERSION = 5
      REQUESTORS = %w[bot healer web tui cli action daemon recorder operator].freeze
      ALLOWED_VERBS = %w[
        run develop brainstorm plan plan-review-run review open-pr artifacts finalize
        archive markers daemon
      ].freeze
      GLOBAL_MAINTENANCE_PROJECT = "__global__".freeze
      GLOBAL_MAINTENANCE_ARGVS = [ %w[hive daemon install --force] ].freeze
      RECOVERY_PHASES = %w[admitted cleared dispatched terminal].freeze
      DELIVERY_STATES = %w[claimed admitted awaiting_delivery].freeze
      EXPIRY_SEC = 600
      CLAIM_EXPIRY_SEC = 14_400
      TERMINAL_RECOVERY_RETENTION_SEC = 7 * 24 * 60 * 60
      OUTBOX_EXPIRY_SEC = 3600
      RECOVERY_PROJECTION_LIMIT = 500
      PROJECT_RE = /\A[A-Za-z0-9_.\-]+\z/
      SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/
      REQUEST_ID_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

      Request = Data.define(
        :request_id, :created_at, :project, :slug, :argv, :requestor,
        :chat_id, :update_id, :trigger, :task_generation,
        :predecessor_attempt_id, :inherited_outputs, :task_id,
        :expected_stage, :expected_marker_name, :expected_marker_id,
        :recovery, :schema_version, :state, :revision
      ) do
        def initialize(request_id:, created_at:, project:, slug:, argv:, requestor:,
                       chat_id: nil, update_id: nil, trigger: "", task_generation: nil,
                       predecessor_attempt_id: nil, inherited_outputs: [], task_id: nil,
                       expected_stage: nil, expected_marker_name: nil, expected_marker_id: nil,
                       recovery: nil, schema_version: DispatchRepository::SCHEMA_VERSION,
                       state: "queued", revision: 0)
          super(
            request_id: request_id, created_at: created_at, project: project, slug: slug,
            argv: argv, requestor: requestor, chat_id: chat_id, update_id: update_id,
            trigger: trigger, task_generation: task_generation,
            predecessor_attempt_id: predecessor_attempt_id,
            inherited_outputs: inherited_outputs, task_id: task_id,
            expected_stage: expected_stage, expected_marker_name: expected_marker_name,
            expected_marker_id: expected_marker_id, recovery: recovery,
            schema_version: schema_version, state: state, revision: revision
          )
        end
      end
      ClaimedDelivery = Data.define(:request, :claim)
      Result = Data.define(
        :result_id, :created_at, :chat_id, :update_id, :project, :slug,
        :request_id, :exit_code, :command, :attempt_id, :attempt_state,
        :receipt, :schema_version
      )

      attr_reader :database

      def self.open_default(state_home: Hive::Paths.state_home)
        new(database: RuntimeControlPlane.database(
          path: Hive::Paths.runtime_control_plane_path(state_home)
        ).open!)
      end

      def self.valid_argv?(argv)
        values = Array(argv)
        return false unless values.length >= 2 && values[0] == "hive"
        return GLOBAL_MAINTENANCE_ARGVS.include?(values) if values[1] == "daemon"
        ALLOWED_VERBS.include?(values[1]) && values.all? { |item| item.is_a?(String) }
      end

      def initialize(database:, clock: -> { Time.now.utc })
        @database = database
        @clock = clock
      end

      def generate_request_id = SecureRandom.hex(8)

      def write_request!(project:, slug:, argv:, requestor: "bot", chat_id: nil,
                         update_id: nil, trigger: nil, request_id: generate_request_id,
                         task_generation: nil, predecessor_attempt_id: nil,
                         inherited_outputs: [], task_id: nil,
                         expected_stage: nil, expected_marker_name: nil,
                         expected_marker_id: nil, recovery: nil, now: @clock.call, **)
        payload = request_payload(
          project: project, slug: slug, argv: argv, requestor: requestor,
          request_id: request_id, chat_id: chat_id, update_id: update_id, trigger: trigger,
          task_generation: task_generation, predecessor_attempt_id: predecessor_attempt_id,
          inherited_outputs: inherited_outputs, task_id: task_id, expected_stage: expected_stage,
          expected_marker_name: expected_marker_name, expected_marker_id: expected_marker_id,
          recovery: recovery, now: now
        )
        database.transaction do |db|
          insert_request!(db, payload)
        end
        request_id.to_s
      rescue Sequel::UniqueConstraintViolation => error
        existing_by_id, active = database.read do |db|
          by_id = db[:dispatch_requests].where(request_id: request_id.to_s).first
          registered_id = registered_task_id(db, task_id)
          current = if registered_id
            db[:dispatch_requests].where(
              task_id: registered_id,
              subject_key: subject_key(project, slug, expected_stage, argv),
              task_generation: task_generation.to_s,
              state: %w[queued claimed admitted]
            ).first
          end
          [ by_id, current ]
        end
        return request_id.to_s if existing_by_id && same_request?(existing_by_id, payload)
        raise IntegrityError.new(
          "dispatch request id is already bound", code: :dispatch_request_conflict
        ) if existing_by_id
        if active
          raise IntegrityError.new(
            "active dispatch subject is already queued as #{active.fetch(:request_id)}",
            code: :dispatch_subject_conflict,
            details: { request_id: active.fetch(:request_id) }
          )
        end

        raise IntegrityError.new(
          "dispatch request conflicts: #{error.message}", code: :dispatch_request_conflict
        )
      end

      def pending(**)
        rows_for_state("queued").reject { |request| request.recovery&.fetch("phase", nil) == "terminal" }
      end

      def claimed(**)
        database.read do |db|
          db[:dispatch_requests].where(state: DELIVERY_STATES)
            .order(:created_at, :request_id).map do |row|
            request = request_from(row)
            ClaimedDelivery.new(
              request: request,
              claim: {
                "pid" => row[:claim_pid],
                "process_start_time" => row[:claim_process_identity],
                "claimed_at" => row[:claimed_at],
                "attempt_id" => row[:claim_attempt_id],
                "task_generation" => row[:task_generation]
              }
            )
          end
        end
      end

      def delivery_pending_for_attempt?(attempt_id)
        database.read do |db|
          db[:dispatch_requests].where(
            claim_attempt_id: attempt_id.to_s, state: DELIVERY_STATES
          ).any?
        end
      end

      def recovery_requests(limit: RECOVERY_PROJECTION_LIMIT, **)
        database.read do |db|
          db[:dispatch_requests]
            .where(recovery_request: 1)
            .reverse_order(:updated_at, :request_id).limit(Integer(limit))
            .all.reverse.map { |row| request_from(row) }
        end
      end

      def fetch(request_id, **)
        row = database.read { |db| db[:dispatch_requests].where(request_id: request_id.to_s).first }
        row && request_from(row)
      end

      def claim(request_id, pid:, process_start_time: nil, now: @clock.call,
                attempt_id: nil, task_generation: nil, **)
        timestamp = now.utc.iso8601(6)
        changed = database.transaction do |db|
          dataset = db[:dispatch_requests].where(request_id: request_id.to_s, state: "queued")
          dataset.update(
            state: "claimed", claim_owner: "process", claim_pid: positive_pid(pid),
            claim_process_identity: process_start_time&.to_s, claimed_at: timestamp,
            claim_attempt_id: attempt_id&.to_s,
            task_generation: task_generation.to_s.empty? ? Sequel[:task_generation] : task_generation.to_s,
            updated_at: timestamp, revision: Sequel[:revision] + 1
          )
        end
        changed == 1 ? request_id.to_s : nil
      end

      def update_claim(request_id, pid:, process_start_time: nil, now: @clock.call,
                       attempt_id: nil, task_generation: nil, **)
        changed = database.transaction do |db|
          values = {
            claim_pid: positive_pid(pid), claim_process_identity: process_start_time&.to_s,
            claimed_at: now.utc.iso8601(6), updated_at: now.utc.iso8601(6),
            revision: Sequel[:revision] + 1
          }
          values[:claim_attempt_id] = attempt_id.to_s unless attempt_id.to_s.empty?
          values[:task_generation] = task_generation.to_s unless task_generation.to_s.empty?
          db[:dispatch_requests].where(
            request_id: request_id.to_s, state: DELIVERY_STATES
          ).update(values)
        end
        changed == 1 ? request_id.to_s : nil
      end

      def release_claim(request_id, **)
        database.transaction do |db|
          db[:dispatch_requests].where(request_id: request_id.to_s, state: "claimed").update(
            state: "queued", claim_owner: nil, claim_pid: nil,
            claim_process_identity: nil, claim_attempt_id: nil, claimed_at: nil,
            updated_at: @clock.call.utc.iso8601(6), revision: Sequel[:revision] + 1
          ) == 1
        end
      end

      def remove(request_id, **)
        database.transaction do |db|
          row = db[:dispatch_requests].where(request_id: request_id.to_s).first
          next false unless row
          dataset = db[:dispatch_requests].where(request_id: request_id.to_s)
          if db[:dispatch_outbox].where(request_id: request_id.to_s).any?
            dataset.update(
              state: "completed", claim_owner: nil, claim_pid: nil,
              claim_process_identity: nil, claim_attempt_id: nil, claimed_at: nil,
              updated_at: @clock.call.utc.iso8601(6), revision: Sequel[:revision] + 1
            ) == 1
          else
            dataset.delete == 1
          end
        end
      end

      def remove_if_unclaimed(request_id, **)
        database.transaction do |db|
          row = db[:dispatch_requests].where(request_id: request_id.to_s, state: "queued").first
          next false unless row
          payload = Codec.load_json(row.fetch(:payload_json))
          next false if payload["recovery"].is_a?(Hash)
          db[:dispatch_requests].where(request_id: request_id.to_s, state: "queued").delete == 1
        end
      end

      def write_sequence!(request_id, remaining_argvs:, **)
        remaining = Array(remaining_argvs)
        return discard_sequence(request_id) if remaining.empty?
        raise ArgumentError, "sequence contains an argv that is not allowlisted" unless
          remaining.all? { |argv| valid_argv?(argv) }
        mutate_payload(request_id) { |payload| payload["remaining_argvs"] = remaining }
      end

      def discard_sequence(request_id, **)
        mutate_payload(request_id) do |payload|
          existed = !Array(payload["remaining_argvs"]).empty?
          payload["remaining_argvs"] = []
          next existed
        end
      end

      def promote_sequence(request_id, project:, slug:, requestor: "bot", chat_id: nil,
                           update_id: nil, trigger: "sequence_continuation", now: @clock.call, **)
        next_id = database.transaction do |db|
          row = db[:dispatch_requests].where(request_id: request_id.to_s).first
          next unless row
          parent = Codec.load_json(row.fetch(:payload_json))
          remaining = Array(parent["remaining_argvs"])
          next if remaining.empty?
          id = "seq-#{Digest::SHA256.hexdigest(request_id.to_s)[0, 32]}"
          child = request_payload(
            project: project, slug: slug, argv: remaining.shift, requestor: requestor,
            request_id: id, chat_id: chat_id, update_id: update_id, trigger: trigger,
            remaining_argvs: remaining, now: now
          )
          insert_request!(db, child)
          parent["remaining_argvs"] = []
          updated = db[:dispatch_requests].where(
            request_id: request_id.to_s, revision: row.fetch(:revision)
          ).update(payload_json: Codec.dump_json(parent), updated_at: now.utc.iso8601(6),
                   revision: Sequel[:revision] + 1)
          raise IntegrityError.new("dispatch sequence raced", code: :dispatch_update_conflict) unless updated == 1
          id
        end
        next_id && fetch(next_id)
      end

      def find_recovery(project:, slug:, observed_marker_generation:, **)
        matching_recoveries(project, slug).find do |request|
          request.recovery["observed_marker_generation"].to_s == observed_marker_generation.to_s
        end
      end

      def find_admission_recovery(project:, slug:, task_generation:, policy_digest:, **)
        matching_recoveries(project, slug).find do |request|
          request.recovery["variant"] == "admission_failure" &&
            request.task_generation.to_s == task_generation.to_s &&
            request.recovery["policy_digest"].to_s == policy_digest.to_s
        end
      end

      def find_markerless_recovery(project:, slug:, task_generation:, failure_origin:, **)
        matching_recoveries(project, slug).find do |request|
          request.recovery["variant"] == "markerless_failure" &&
            request.task_generation.to_s == task_generation.to_s &&
            request.recovery["failure_origin"].to_s == failure_origin.to_s
        end
      end

      def recovery_retry_count(project:, slug:, expected_stage: nil, **)
        matching_recoveries(project, slug).filter_map do |request|
          next if expected_stage && request.expected_stage.to_s != expected_stage.to_s
          request.recovery["retry_count"]
        end.max.to_i
      end

      def latest_terminal_recovery(project:, slug:, expected_stage:, **)
        matching_recoveries(project, slug).select do |request|
          request.expected_stage.to_s == expected_stage.to_s &&
            request.recovery["phase"] == "terminal"
        end.max_by { |request| [ request.created_at, request.request_id ] }
      end

      def update_recovery!(request_id, expected_phase:, changes:, **)
        update_recovery(request_id, expected_phase, changes, state: nil)
      end

      def complete_delivery(request_id, now: @clock.call, **)
        database.transaction do |db|
          db[:dispatch_requests].where(request_id: request_id.to_s, state: DELIVERY_STATES).update(
            state: "completed", claim_owner: nil, claim_pid: nil,
            claim_process_identity: nil, claim_attempt_id: nil, claimed_at: nil,
            updated_at: now.utc.iso8601(6), revision: Sequel[:revision] + 1
          ) == 1
        end
      end

      def requeue_recovery!(request_id, expected_phase:, changes:, **)
        update_recovery(request_id, expected_phase, changes, state: "queued")
      end

      def remove_terminal_recoveries(project:, slug:, expected_stage:, except_request_id: nil, **)
        remove_matching(project, slug) do |request|
          request.request_id != except_request_id.to_s &&
            request.expected_stage.to_s == expected_stage.to_s &&
            request.recovery["phase"] == "terminal"
        end
      end

      def remove_nonterminal_for_task(project:, slug:, **)
        remove_matching(project, slug) { |request| request.recovery&.fetch("phase", nil) != "terminal" }
      end

      def prune_terminal_recoveries(now: @clock.call, retention_sec: TERMINAL_RECOVERY_RETENTION_SEC, **)
        cutoff = now.utc - retention_sec
        database.transaction do |db|
          ids = db[:dispatch_requests].where(state: "completed").where { updated_at < cutoff.iso8601(6) }
            .select_map(:request_id)
          db[:dispatch_requests].where(request_id: ids).delete
        end
      end

      def recover_claims(now: @clock.call, alive:, attempt_alive: nil,
                         expiry_sec: CLAIM_EXPIRY_SEC, handler: nil, **)
        claimed.each.sum do |delivery|
          request = delivery.request
          next 0 if request.recovery&.fetch("phase", nil) == "terminal"
          claim = delivery.claim
          attempt_id = claim["attempt_id"]
          if attempt_id && attempt_alive&.call(attempt_id, claim["task_generation"])
            next 0
          end
          claimed_at = parse_time(claim["claimed_at"])
          aged = claimed_at.nil? || now.utc - claimed_at > expiry_sec
          owner_alive = !aged && alive.call(claim["pid"], claim["process_start_time"])
          next 0 if owner_alive
          if request.recovery && attempt_id.nil?
            release_claim(request.request_id)
            handler&.call(request_id: request.request_id, reason: "recovery_claim_requeued")
          else
            remove(request.request_id)
            handler&.call(
              request_id: request.request_id,
              reason: aged ? "claim_expired" : "owner_gone"
            )
          end
          1
        end
      end

      def dispatch(request, dispatcher:, **options) = dispatcher.dispatch_request(request, **options)

      def valid_argv?(argv)
        self.class.valid_argv?(argv)
      end

      def expired?(request, now: @clock.call, expiry_sec: EXPIRY_SEC)
        !request.recovery && now.utc - request.created_at.utc > expiry_sec
      end

      def write_result!(chat_id:, project:, slug:, request_id:, exit_code:, command:,
                        update_id: nil, attempt_id: nil, attempt_state: nil,
                        receipt: nil, now: @clock.call, **)
        delivery_id = SecureRandom.hex(8)
        timestamp = now.utc.iso8601(6)
        payload = {
          "schema" => "hive-dispatch-result", "schema_version" => 2,
          "result_id" => delivery_id, "created_at" => timestamp,
          "chat_id" => chat_id, "update_id" => update_id, "project" => project.to_s,
          "slug" => slug.to_s, "request_id" => request_id.to_s,
          "exit_code" => exit_code, "command" => command.to_s,
          "attempt_id" => attempt_id, "attempt_state" => attempt_state, "receipt" => receipt
        }
        database.transaction do |db|
          db[:dispatch_outbox].insert(
            delivery_id: delivery_id, request_id: request_id.to_s,
            kind: "bot_result", state: "pending",
            idempotency_key: "result:#{request_id}:#{attempt_id}:#{exit_code}",
            payload_json: Codec.dump_json(payload), delivery_attempts: 0,
            available_at: timestamp, retain_until: (now.utc + OUTBOX_EXPIRY_SEC).iso8601(6)
          )
        end
        delivery_id
      rescue Sequel::UniqueConstraintViolation
        database.read do |db|
          db[:dispatch_outbox].where(
            idempotency_key: "result:#{request_id}:#{attempt_id}:#{exit_code}"
          ).get(:delivery_id)
        end
      end

      def pending_results(now: @clock.call, **)
        database.read do |db|
          db[:dispatch_outbox].where(state: "pending").where { available_at <= now.utc.iso8601(6) }
            .order(:available_at, :delivery_id).map { |row| result_from(row) }
        end
      end

      def result_expired?(result, now: @clock.call, expiry_sec: OUTBOX_EXPIRY_SEC)
        now.utc - result.created_at.utc > expiry_sec
      end

      def remove_result(result_id, **)
        database.transaction do |db|
          db[:dispatch_outbox].where(delivery_id: result_id.to_s, state: "pending").update(
            state: "delivered", delivered_at: @clock.call.utc.iso8601(6)
          ) == 1
        end
      end

      def prune_results(now: @clock.call, **)
        database.transaction do |db|
          db[:dispatch_outbox].where { retain_until < now.utc.iso8601(6) }.delete
        end
      end

      private

      def request_payload(project:, slug:, argv:, requestor:, request_id:, now:, chat_id: nil,
                          update_id: nil, trigger: nil, task_generation: nil,
                          predecessor_attempt_id: nil, inherited_outputs: [], task_id: nil,
                          expected_stage: nil, expected_marker_name: nil,
                          expected_marker_id: nil, recovery: nil, remaining_argvs: [])
        validate_request!(project, slug, argv, requestor, request_id, inherited_outputs, recovery)
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "request_id" => request_id.to_s, "created_at" => now.utc.iso8601(6),
          "project" => project.to_s, "slug" => slug.to_s, "argv" => Array(argv),
          "requestor" => requestor.to_s, "chat_id" => chat_id, "update_id" => update_id,
          "trigger" => trigger.to_s, "task_generation" => task_generation,
          "predecessor_attempt_id" => predecessor_attempt_id,
          "inherited_outputs" => Array(inherited_outputs), "task_id" => task_id,
          "expected_stage" => expected_stage, "expected_marker_name" => expected_marker_name,
          "expected_marker_id" => expected_marker_id, "recovery" => recovery,
          "remaining_argvs" => Array(remaining_argvs)
        }
      end

      def insert_request!(db, payload)
        request_id = payload.fetch("request_id")
        existing = db[:dispatch_requests].where(request_id: request_id).first
        return request_id if existing && same_request?(existing, payload)
        raise IntegrityError.new("dispatch request id is already bound", code: :dispatch_request_conflict) if existing

        timestamp = payload.fetch("created_at")
        stage = payload["expected_stage"]
        argv = payload.fetch("argv")
        db[:dispatch_requests].insert(
          request_id: request_id, project_id: project_id_for!(db, payload.fetch("project"), timestamp),
          task_id: registered_task_id(db, payload["task_id"]), subject_kind: "task_stage",
          subject_key: subject_key(payload.fetch("project"), payload.fetch("slug"), stage, argv),
          task_slug: payload.fetch("slug"), task_generation: payload["task_generation"].to_s,
          intended_stage: stage.to_s.empty? ? intended_stage(argv) : stage.to_s,
          state: "queued", priority: 0, idempotency_key: request_id,
          source_fingerprint: source_fingerprint(payload), payload_json: Codec.dump_json(payload),
          created_at: timestamp, updated_at: timestamp, due_at: timestamp, revision: 0,
          recovery_request: payload["recovery"] ? 1 : 0
        )
        request_id
      end

      def same_request?(row, payload)
        existing = Codec.load_json(row.fetch(:payload_json))
        %w[
          request_id project slug argv requestor chat_id update_id trigger task_generation
          predecessor_attempt_id inherited_outputs task_id expected_stage
          expected_marker_name expected_marker_id recovery
          remaining_argvs
        ].all? { |key| existing[key] == payload[key] }
      end

      def rows_for_state(state)
        database.read do |db|
          db[:dispatch_requests].where(state: state).order(:priority, :created_at, :request_id).map do |row|
            request_from(row)
          end
        end
      end

      def request_from(row)
        payload = Codec.load_json(row.fetch(:payload_json))
        Request.new(
          request_id: row.fetch(:request_id), created_at: Time.iso8601(row.fetch(:created_at)),
          project: payload.fetch("project"), slug: payload.fetch("slug"),
          argv: payload.fetch("argv"), requestor: payload.fetch("requestor"),
          chat_id: payload["chat_id"], update_id: payload["update_id"],
          trigger: payload.fetch("trigger"),
          task_generation: blank_to_nil(row[:task_generation]),
          predecessor_attempt_id: payload["predecessor_attempt_id"],
          inherited_outputs: payload.fetch("inherited_outputs"), task_id: payload["task_id"],
          expected_stage: payload["expected_stage"],
          expected_marker_name: payload["expected_marker_name"],
          expected_marker_id: payload["expected_marker_id"], recovery: payload["recovery"],
          schema_version: payload.fetch("schema_version"), state: row.fetch(:state),
          revision: row.fetch(:revision)
        )
      rescue KeyError, ArgumentError, CodecError => error
        raise IntegrityError.new(
          "dispatch request row is invalid: #{error.message}",
          code: :dispatch_row_invalid, action: "stop Hive and restore a verified recovery set"
        )
      end

      def result_from(row)
        payload = Codec.load_json(row.fetch(:payload_json))
        Result.new(
          result_id: row.fetch(:delivery_id), created_at: Time.iso8601(payload.fetch("created_at")),
          chat_id: payload.fetch("chat_id"), update_id: payload["update_id"],
          project: payload.fetch("project"), slug: payload.fetch("slug"),
          request_id: payload.fetch("request_id"), exit_code: payload.fetch("exit_code"),
          command: payload.fetch("command"), attempt_id: payload["attempt_id"],
          attempt_state: payload["attempt_state"], receipt: payload["receipt"],
          schema_version: payload.fetch("schema_version")
        )
      rescue KeyError, ArgumentError, CodecError => error
        raise IntegrityError.new(
          "dispatch result row is invalid: #{error.message}",
          code: :dispatch_result_row_invalid,
          action: "stop Hive and inspect the runtime control-plane database"
        )
      end

      def blank_to_nil(value)
        value.to_s.empty? ? nil : value
      end

      def payload_for(request_id)
        value = database.read do |db|
          db[:dispatch_requests].where(request_id: request_id.to_s).get(:payload_json)
        end
        value && Codec.load_json(value)
      end

      def mutate_payload(request_id)
        result = nil
        database.transaction do |db|
          row = db[:dispatch_requests].where(request_id: request_id.to_s).first
          next false unless row
          payload = Codec.load_json(row.fetch(:payload_json))
          row_changes = {}
          result = yield(payload, row_changes)
          changed = db[:dispatch_requests].where(
            request_id: request_id.to_s, revision: row.fetch(:revision)
          ).update(
            {
              payload_json: Codec.dump_json(payload),
              updated_at: @clock.call.utc.iso8601(6),
              revision: Sequel[:revision] + 1
            }.merge(row_changes)
          )
          unless changed == 1
            raise IntegrityError.new(
              "dispatch request update raced", code: :dispatch_update_conflict,
              action: "retry the dispatch transition"
            )
          end
        end
        result.nil? ? true : result
      end

      def update_recovery(request_id, expected_phase, changes, state:)
        mutate_payload(request_id) do |payload, row_changes|
          recovery = payload["recovery"]
          next false unless recovery.is_a?(Hash) && recovery["phase"] == expected_phase
          recovery.merge!(changes.to_h.transform_keys(&:to_s))
          recovery["phase"] = changes[:phase] if changes.key?(:phase)
          validate_recovery!(recovery)
          if state
            row_changes.merge!(
              state: state, claim_owner: nil, claim_pid: nil,
              claim_process_identity: nil, claim_attempt_id: nil, claimed_at: nil
            )
          end
          true
        end
      end

      def matching_recoveries(project, slug)
        database.read do |db|
          db[:dispatch_requests].join(:projects, project_id: :project_id).where(
            Sequel[:projects][:name] => project.to_s,
            Sequel[:dispatch_requests][:task_slug] => slug.to_s,
            Sequel[:dispatch_requests][:recovery_request] => 1
          ).select_all(:dispatch_requests).order(
            Sequel[:dispatch_requests][:created_at], Sequel[:dispatch_requests][:request_id]
          ).map { |row| request_from(row) }
        end
      end

      def remove_matching(project, slug)
        ids = matching_recoveries(project, slug).select { |request| yield(request) }.map(&:request_id)
        return 0 if ids.empty?
        database.transaction { |db| db[:dispatch_requests].where(request_id: ids).delete }
      end

      def validate_request!(project, slug, argv, requestor, request_id, outputs, recovery)
        raise ArgumentError, "argv is not allowlisted for dispatch requests" unless valid_argv?(argv)
        raise ArgumentError, "project is invalid" unless PROJECT_RE.match?(project.to_s)
        raise ArgumentError, "slug is invalid" unless SLUG_RE.match?(slug.to_s)
        raise ArgumentError, "requestor is invalid" unless REQUESTORS.include?(requestor.to_s)
        raise ArgumentError, "request id is invalid" unless REQUEST_ID_RE.match?(request_id.to_s)
        Array(outputs).each { |reference| Hive::Attempts::OutputReference.validate_shape!(reference) }
        validate_recovery!(recovery) if recovery
      end

      def validate_recovery!(recovery)
        unless recovery.is_a?(Hash) && RECOVERY_PHASES.include?(recovery["phase"].to_s)
          raise ArgumentError, "recovery phase is invalid"
        end
      end

      def project_id_for!(db, name, timestamp)
        row = db[:projects].where(name: name).first
        return row.fetch(:project_id) if row
        unless name == GLOBAL_MAINTENANCE_PROJECT
          raise IdentityError.new(
            "dispatch project is not registered", code: :missing_project_identity
          )
        end
        installation = db[:installations].first.fetch(:installation_id)
        project_id = "global-maintenance"
        db[:projects].insert_conflict.insert(
          project_id: project_id, installation_id: installation,
          registration_id: project_id, name: name, observed_path: "__global__",
          state_root_path: "__global__", active: 1,
          registered_at: timestamp, last_observed_at: timestamp
        )
        project_id
      end

      def registered_task_id(db, task_id)
        return nil if task_id.to_s.empty?
        db[:task_subjects].where(task_id: task_id.to_s).get(:task_id)
      end

      def subject_key(project, slug, stage, argv)
        Digest::SHA256.hexdigest(Codec.dump_json([ project.to_s, slug.to_s, stage.to_s, Array(argv)[1] ]))
      end

      def source_fingerprint(payload) = Digest::SHA256.hexdigest(Codec.dump_json(payload))
      def intended_stage(argv) = Array(argv)[1].to_s
      def positive_pid(value) = value && Integer(value).positive? ? Integer(value) : nil
      def parse_time(value) = value && Time.iso8601(value.to_s)
    end
  end
end
