require "date"
require "digest"
require "fileutils"
require "json"
require "hive/attempts/capability"
require "hive/attempts/record"
require "hive/attempts/coordination"
require "hive/attempts/publication"
require "hive/output_reference"
require "hive/paths"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/payload_store"
require "hive/stringify_keys"

module Hive
  module Attempts
    class RepositoryError < Hive::Error; end
    class CompareAndSwapFailed < RepositoryError; end
    class CapacityExceeded < RepositoryError; end

    InvalidStoredRecord = Data.define(:path, :error)
    Scan = Data.define(:records, :invalid_records)

    # The attempt facade persists lifecycle state in the runtime control plane.
    # The filesystem root contains only retained bytes referenced by those rows.
    class Repository
      include Coordination
      include Publication
      DEFAULT_ROOT = Object.new.freeze

      class ProjectionReader
        def initialize(store)
          @repository = store
          @bindings = {}
          @terminal_diagnostic_bindings = {}
        end

        def fetch_projection_binding(attempt_id)
          key = attempt_id.to_s
          @bindings[key] = @repository.fetch_projection_binding(key) unless @bindings.key?(key)
          @bindings[key]
        end

        def fetch_terminal_diagnostic_binding(attempt_id)
          key = attempt_id.to_s
          unless @terminal_diagnostic_bindings.key?(key)
            record = @repository.fetch(key)
            @terminal_diagnostic_bindings[key] = record&.final? ? {
              "attempt_id" => record.attempt_id,
              "stage" => record["intended_stage"],
              "task_generation" => record.task_generation,
              "receipt" => record.receipt
            } : nil
          end
          @terminal_diagnostic_bindings[key]
        end

        def read_output(reference, max_bytes:)
          @repository.read_output(reference, max_bytes: max_bytes)
        end
      end

      attr_reader :database

      def self.open_default(state_home: Hive::Paths.state_home, create_directories: true)
        new(
          root: Hive::Paths.runtime_payload_root(state_home),
          database: RuntimeControlPlane::Database.new(
            path: Hive::Paths.runtime_control_plane_path(state_home)
          ),
          create_directories: create_directories,
          migrate: false
        )
      end

      def self.runtime(create_directories: true, state_home: Hive::Paths.state_home)
        open_default(state_home: state_home, create_directories: create_directories)
      end

      def initialize(root: DEFAULT_ROOT, database: nil, create_directories: true, migrate: false)
        explicit_root = !root.equal?(DEFAULT_ROOT)
        root = Hive::Paths.runtime_payload_root if !explicit_root
        @root = File.expand_path(root)
        @create_directories = create_directories
        @database = database || RuntimeControlPlane::Database.new(
          path: explicit_root ? File.join(@root, ".runtime-control-plane.sqlite3") :
            Hive::Paths.runtime_control_plane_path
        )
        @isolated_identity = database.nil? && explicit_root
        connect!(migrate: migrate)
        prepare_payload_root! if create_directories
      rescue RuntimeControlPlane::Error, SystemCallError, IOError => error
        raise RepositoryError, "attempt runtime control plane is unavailable: #{error.message}"
      end

      def root
        validate_directory!(@root, "payload root")
      end

      def logs_root = validate_directory!(File.join(@root, "open"), "open payload")
      def outputs_root = logs_root
      def ephemeral_locks_root = ensure_payload_directory(".locks")

      def payload_store
        @payload_store ||= RuntimeControlPlane::PayloadStore.new(root: @root)
      end

      def log_archive
        require "hive/attempts/log_archive"
        @log_archive ||= LogArchive.new(store: self)
      end

      def storage_health
        require "hive/attempts/storage_health"
        @storage_health ||= StorageHealth.new(store: self)
      end

      def routing_policies
        require "hive/provider_routing/policy_repository"
        @routing_policies ||= Hive::ProviderRouting::PolicyRepository.new(store: self)
      end

      def output_directory(attempt_id, *segments, create: false)
        components = [ attempt_id, *segments ].map { |segment| safe_id(segment) }
        path = outputs_root
        components.each do |component|
          path = File.join(path, component)
          if create
            FileUtils.mkdir_p(path, mode: 0o700)
            File.chmod(0o700, path)
          elsif !File.exist?(path)
            next
          end
          validate_directory!(path, "attempt output")
          ensure_contained!(path, outputs_root)
        end
        path
      rescue SystemCallError, IOError => error
        raise RepositoryError, "attempt output directory is unavailable: #{error.message}"
      end

      def output_path(attempt_id, filename, create_directory: false)
        path = File.join(output_directory(attempt_id, create: create_directory), safe_id(filename))
        status = optional_lstat(path)
        if status
          raise RepositoryError, "attempt output file is a symlink" if status.symlink?
          raise RepositoryError, "attempt output path is not a regular file" unless status.file?
        end
        path
      end

      def read_output(reference, max_bytes:)
        return Hive::OutputReference.read(reference, root: root, max_bytes: max_bytes) if
          Hive::OutputReference.verify(reference, root: root)

        sealed = sealed_payload_reference(reference)
        raise RepositoryError, "attempt output is unavailable" unless sealed
        raise RepositoryError, "attempt output exceeds read bound" unless
          max_bytes.is_a?(Integer) && max_bytes.positive? && sealed.fetch("size") <= max_bytes

        payload_store.read_sealed(
          sealed.merge("algorithm" => "sha256")
        )
      rescue Hive::InvalidOutputReference => error
        raise RepositoryError, error.message
      end

      def create_launching(source_fingerprint: nil, admission: nil, limits: nil,
                           failure_cohort_probe: nil, **attributes)
        record = Record.launching(**attributes)
        source_fingerprint ||= record["progress_token"]
        persist_new(
          record, source_fingerprint: source_fingerprint,
          admission: admission, limits: limits,
          failure_cohort_probe: failure_cohort_probe
        )
      rescue InvalidRecord, Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt could not be created")
      end

      def arm_launch_handoff(observed, launch_timeout_sec:, now:)
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "claim_deadline" => Record.iso8601(now + launch_timeout_sec),
            "diagnostics" => data.fetch("diagnostics").merge(
              "handoff_armed_at" => Record.iso8601(now)
            )
          )
        end
      end

      def fetch(attempt_id)
        row = read_row(attempt_id)
        row && record_from(row)
      end

      def fetch_hot(attempt_id)
        row = read_row(attempt_id)
        return nil unless row
        return record_from(row) if %w[launching running].include?(row.fetch(:state))
        return nil unless database.read { |db| db[:terminal_pending_publications].where(attempt_id: row[:attempt_id]).any? }

        record_from(row)
      end

      def fetch_projection_binding(attempt_id)
        record = fetch(attempt_id)
        return nil unless record

        {
          "attempt_id" => record.attempt_id,
          "task_id" => record["task_id"],
          "task_slug" => record["task_slug"],
          "intended_stage" => record["intended_stage"],
          "task_generation" => record.task_generation,
          "task_input_epoch" => record.task_input_epoch,
          "ownership_generation" => record.ownership_generation,
          "predecessor_attempt_id" => record["predecessor_attempt_id"],
          "accepted_at" => record["accepted_at"],
          "state" => record.state,
          "outcome" => record.outcome,
          "lease_version" => record.lease_version,
          "receipt" => record.receipt,
          "subject" => record.subject
        }
      end

      def projection_reader = ProjectionReader.new(self)

      def scan
        rows = database.read do |db|
          pending = db[:terminal_pending_publications].select_map(:attempt_id)
          db[:attempts].where(state: %w[launching running]).or(attempt_id: pending).order(:attempt_id).all
        end
        records = []
        invalid = []
        rows.each do |row|
          records << record_from(row)
        rescue RepositoryError => error
          invalid << InvalidStoredRecord.new(
            path: "runtime-control-plane:attempt:#{row.fetch(:attempt_id)}",
            error: error.message
          )
        end
        Scan.new(records: records.freeze, invalid_records: invalid.freeze)
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt scan failed")
      end

      def claim(observed, owner:, claim_capability:, first_heartbeat_timeout_sec:, now:)
        raise CompareAndSwapFailed, "launch claim deadline expired" if
          observed.active_deadline && now > observed.active_deadline
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          unless Capability.matches?(data["claim_capability_digest"], claim_capability)
            raise CompareAndSwapFailed, "attempt claim capability is invalid"
          end
          raise CompareAndSwapFailed, "attempt is already claimed" if data["wrapper"]

          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "wrapper" => Hive::StringifyKeys.call(owner),
            "claim_deadline" => nil,
            "first_heartbeat_deadline" => Record.iso8601(now + first_heartbeat_timeout_sec),
            "diagnostics" => data.fetch("diagnostics").merge("claimed_at" => Record.iso8601(now))
          )
        end
      end

      def first_heartbeat(observed, stale_sec:, now:)
        raise CompareAndSwapFailed, "first heartbeat deadline expired" if
          observed.active_deadline && now > observed.active_deadline
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          raise CompareAndSwapFailed, "attempt has not been claimed" unless data["wrapper"]

          timestamp = Record.iso8601(now)
          data.merge(
            "state" => "running", "lease_version" => data.fetch("lease_version") + 1,
            "first_heartbeat_deadline" => nil, "heartbeat_at" => timestamp,
            "heartbeat_deadline" => Record.iso8601(now + stale_sec), "started_at" => timestamp
          )
        end
      end

      def heartbeat(observed, stale_sec:, now:)
        mutate(observed, allowed_states: [ "running" ]) do |data|
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "heartbeat_at" => Record.iso8601(now),
            "heartbeat_deadline" => Record.iso8601(now + stale_sec)
          )
        end
      end

      def checkpoint(observed, checkpoint:, now:, worker: nil, output_references: nil, log_reference: nil)
        mutate(observed, allowed_states: [ "running" ]) do |data|
          outputs = output_references.nil? ? data.fetch("current_outputs") :
            Hive::StringifyKeys.call(output_references)
          outputs.each { |reference| OutputReference.validate_shape!(reference) }
          OutputReference.validate_shape!(log_reference) if log_reference
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "checkpoint" => Hive::StringifyKeys.call(checkpoint),
            "latest_revision" => checkpoint["revision"] || checkpoint[:revision] || data["latest_revision"],
            "worker" => worker ? Hive::StringifyKeys.call(worker) : data["worker"],
            "current_outputs" => outputs, "log_reference" => log_reference || data["log_reference"],
            "diagnostics" => data.fetch("diagnostics").merge("checkpoint_at" => Record.iso8601(now))
          )
        end
      end

      def terminalize(observed, outcome:, exit_status:, final_checkpoint:, output_references:,
                      log_reference:, now:, provider_evidence: nil)
        version = observed.lease_version + 1
        receipt = {
          "receipt_version" => Record::RECEIPT_VERSION,
          "terminal_lease_version" => version, "attempt_id" => observed.attempt_id,
          "task_generation" => observed.task_generation,
          "ownership_generation" => observed.ownership_generation,
          "task_input_epoch" => observed.task_input_epoch, "outcome" => outcome,
          "exit_status" => exit_status, "started_at" => observed["started_at"],
          "ended_at" => Record.iso8601(now),
          "final_checkpoint" => Hive::StringifyKeys.call(final_checkpoint),
          "output_references" => Hive::StringifyKeys.call(output_references),
          "log_reference" => Hive::StringifyKeys.call(log_reference),
          "provider_evidence" => Hive::StringifyKeys.call(provider_evidence)
        }
        Record.validate_receipt!(
          receipt, attempt_id: observed.attempt_id,
          task_generation: observed.task_generation,
          ownership_generation: observed.ownership_generation,
          task_input_epoch: observed.task_input_epoch,
          terminal_lease_version: version, routing: observed["routing"]
        )
        mutate(observed, allowed_states: [ "running" ], pending_receipt: receipt) do |data|
          data.merge(
            "state" => "terminal", "outcome" => outcome, "lease_version" => version,
            "heartbeat_deadline" => nil, "ended_at" => Record.iso8601(now),
            "latest_revision" => final_checkpoint["revision"] || final_checkpoint[:revision] || data["latest_revision"],
            "checkpoint" => Hive::StringifyKeys.call(final_checkpoint),
            "current_outputs" => Hive::StringifyKeys.call(output_references),
            "log_reference" => Hive::StringifyKeys.call(log_reference), "receipt" => receipt
          )
        end
      end

      def mark_lost(observed, reason:, now:, diagnostics: {})
        mutate(observed, allowed_states: %w[launching running], pending_receipt: {}) do |data|
          data.merge(
            "state" => "lost", "lease_version" => data.fetch("lease_version") + 1,
            "claim_deadline" => nil, "first_heartbeat_deadline" => nil,
            "heartbeat_deadline" => nil, "ended_at" => Record.iso8601(now),
            "loss" => { "reason" => reason, "at" => Record.iso8601(now) },
            "diagnostics" => data.fetch("diagnostics").merge(Hive::StringifyKeys.call(diagnostics))
          )
        end
      end

      def annotate_lost(observed, output_references:, diagnostics:, now:)
        mutate(observed, allowed_states: [ "lost" ]) do |data|
          outputs = (data.fetch("current_outputs") + Hive::StringifyKeys.call(output_references)).uniq
          outputs.each { |reference| OutputReference.validate_shape!(reference) }
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "current_outputs" => outputs,
            "diagnostics" => data.fetch("diagnostics").merge(
              Hive::StringifyKeys.call(diagnostics).merge("loss_processed_at" => Record.iso8601(now))
            )
          )
        end
      end

      private

      def connect!(migrate:)
        if migrate
          database.migrate!
        elsif File.file?(database.path)
          database.open!
        elsif @create_directories
          database.open!
        end
      end

      def persist_new(record, source_fingerprint:, admission:, limits:, failure_cohort_probe:)
        database.transaction do |db|
          raise RepositoryError, "attempt #{record.attempt_id} already exists" if
            db[:attempts].where(attempt_id: record.attempt_id).any?
          task_id, project_id = ensure_subject!(db, record)
          ensure_dispatch_request!(
            db, record, task_id, project_id,
            source_fingerprint: source_fingerprint
          )
          validate_capacity!(db, record, limits) if limits
          row = row_for(record, task_id: task_id, source_fingerprint: source_fingerprint)
          db[:attempts].insert(row)
          db[:attempt_accounting].insert(
            attempt_id: record.attempt_id,
            provider_account_id: record["routing"].dig("route", "provider_account_id"),
            retry_charge: record["retry_charge"],
            refunded: 0,
            reservation_json: RuntimeControlPlane::Codec.dump_json(
              live_reservation(
                project: record["project"], task_slug: record["task_slug"],
                admission: admission
              )
            ),
            billing_json: RuntimeControlPlane::Codec.dump_json("refunded" => false),
            updated_at: record["accepted_at"]
          )
          db[:capacity_reservations].insert(
            reservation_id: "attempt:#{record.attempt_id}", attempt_id: record.attempt_id,
            scope_kind: "host", scope_key: "global", units: 1, state: "reserved",
            created_at: record["accepted_at"]
          )
          if record["predecessor_attempt_id"]
            db[:attempt_relationships].insert(
              attempt_id: record.attempt_id,
              related_attempt_id: record["predecessor_attempt_id"],
              kind: "successor", created_at: record["accepted_at"]
            )
          end
          if failure_cohort_probe &&
             !claim_failure_cohort_probe_in(db, attempt_id: record.attempt_id, **failure_cohort_probe)
            raise RepositoryError, "failure cohort probe claim became stale"
          end
        end
        record
      end

      def validate_capacity!(db, record, limits)
        limits = limits.to_h
        reserved = db[:capacity_reservations].where(
          Sequel[:capacity_reservations][:state] => "reserved"
        )
        attempts = reserved.join(:attempts, attempt_id: :attempt_id)
        units = Sequel[:capacity_reservations][:units]
        at_limit = reserved.sum(units).to_i >= Integer(limits.fetch(:max_global)) ||
          attempts.where(project_name: record["project"]).sum(units).to_i >=
            Integer(limits.fetch(:max_per_project)) ||
          attempts.where(
            project_name: record["project"], task_slug: record["task_slug"]
          ).any? ||
          accepted_count(db, record) >= Integer(limits.fetch(:max_daily))
        raise CapacityExceeded, "attempt capacity is exhausted" if at_limit
      rescue KeyError, TypeError, ArgumentError
        raise RepositoryError, "attempt capacity limits are invalid"
      end

      def accepted_count(db, record)
        date = Time.iso8601(record["accepted_at"]).utc.to_date.iso8601
        db[:attempts].where(
          project_name: record["project"], accepted_date: date
        ).join(:attempt_accounting, attempt_id: :attempt_id)
          .where(Sequel[:attempt_accounting][:refunded] => 0).count
      end

      def mutate(observed, allowed_states:, pending_receipt: nil)
        replacement = nil
        database.transaction do |db|
          row = db[:attempts].where(attempt_id: observed.attempt_id).first
          current = row && record_from(row)
          verify_cas!(current, observed, allowed_states)
          replacement = Record.new(yield(current.to_h))
          verify_immutable!(current, replacement)
          updated = db[:attempts].where(
            attempt_id: current.attempt_id,
            lease_version: current.lease_version,
            state: current.state,
            record_digest: row.fetch(:record_digest)
          ).update(mutable_columns(replacement))
          raise CompareAndSwapFailed, "attempt lease compare-and-swap lost" unless updated == 1
          if pending_receipt
            receipt_json = RuntimeControlPlane::Codec.dump_json(pending_receipt)
            digest = Digest::SHA256.hexdigest(receipt_json)
            db[:terminal_pending_publications].insert_conflict(
              target: :attempt_id,
              update: {
                task_source_fingerprint: row.fetch(:source_fingerprint),
                receipt_json: receipt_json, expected_receipt_digest: digest,
                state: "pending", created_at: replacement["ended_at"], published_at: nil
              }
            ).insert(
              attempt_id: current.attempt_id,
              task_source_fingerprint: row.fetch(:source_fingerprint),
              receipt_json: receipt_json, expected_receipt_digest: digest,
              state: "pending", created_at: replacement["ended_at"]
            )
          end
          if replacement.final?
            db[:capacity_reservations].where(
              attempt_id: replacement.attempt_id, state: "reserved"
            ).update(state: "released", released_at: replacement["ended_at"])
            if replacement["request_id"]
              db[:dispatch_requests].where(request_id: replacement["request_id"]).update(
                state: "completed", updated_at: replacement["ended_at"]
              )
            end
          end
        end
        replacement
      rescue InvalidRecord, InvalidOutputReference, Sequel::Error,
             RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt transition failed")
      end

      def verify_cas!(current, observed, allowed_states)
        raise CompareAndSwapFailed, "attempt no longer exists" unless current
        unless current.attempt_id == observed.attempt_id &&
               current.task_generation == observed.task_generation &&
               current.state == observed.state &&
               current.lease_version == observed.lease_version &&
               current.active_deadline_value == observed.active_deadline_value &&
               allowed_states.include?(current.state)
          raise CompareAndSwapFailed, "attempt lease compare-and-swap lost"
        end
      end

      def verify_immutable!(before, after)
        changed = Record::IMMUTABLE_KEYS.reject { |key| before[key] == after[key] }
        raise RepositoryError, "attempt immutable identity changed: #{changed.join(', ')}" unless changed.empty?
      end

      def row_for(record, task_id:, source_fingerprint:)
        payload = RuntimeControlPlane::Codec.dump_json(record.to_h)
        {
          attempt_id: record.attempt_id, request_id: record["request_id"], task_id: task_id,
          subject_kind: record.subject_kind, subject_key: subject_key(record.subject),
          task_generation: record.task_generation,
          ownership_generation: record.ownership_generation, state: record.state,
          outcome: record.outcome, lease_version: record.lease_version,
          owner_identity_json: json_or_nil(record.wrapper),
          routing_json: RuntimeControlPlane::Codec.dump_json(record["routing"]),
          source_fingerprint: source_fingerprint.to_s,
          checkpoint_json: json_or_nil(record.checkpoint), record_json: payload,
          record_digest: Digest::SHA256.hexdigest(payload),
          subject_json: RuntimeControlPlane::Codec.dump_json(record.subject),
          project_name: record["project"], task_slug: record["task_slug"],
          accepted_date: Time.iso8601(record["accepted_at"]).utc.to_date.iso8601,
          terminal_receipt_digest: receipt_digest(record.receipt),
          created_at: record["created_at"], accepted_at: record["accepted_at"],
          started_at: record["started_at"], heartbeat_at: record["heartbeat_at"],
          ended_at: record["ended_at"]
        }
      end

      def mutable_columns(record)
        payload = RuntimeControlPlane::Codec.dump_json(record.to_h)
        {
          state: record.state, outcome: record.outcome,
          lease_version: record.lease_version,
          owner_identity_json: json_or_nil(record.wrapper),
          checkpoint_json: json_or_nil(record.checkpoint),
          record_json: payload, record_digest: Digest::SHA256.hexdigest(payload),
          terminal_receipt_digest: receipt_digest(record.receipt),
          started_at: record["started_at"], heartbeat_at: record["heartbeat_at"],
          ended_at: record["ended_at"]
        }
      end

      def record_from(row)
        payload = row.fetch(:record_json)
        unless Digest::SHA256.hexdigest(payload) == row.fetch(:record_digest)
          raise RepositoryError, "attempt #{row.fetch(:attempt_id)} record digest is invalid"
        end
        record = Record.new(RuntimeControlPlane::Codec.load_json(payload))
        unless record.attempt_id == row.fetch(:attempt_id) &&
               record.state == row.fetch(:state) && record.lease_version == row.fetch(:lease_version) &&
               record.task_generation == row.fetch(:task_generation)
          raise RepositoryError, "attempt #{row.fetch(:attempt_id)} indexed fields disagree with its record"
        end
        record
      rescue InvalidRecord, RuntimeControlPlane::Error => error
        raise RepositoryError, "attempt #{row.fetch(:attempt_id)} is unreadable: #{error.message}"
      end

      def read_row(attempt_id)
        id = safe_id(attempt_id)
        database.read { |db| db[:attempts].where(attempt_id: id).first }
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt lookup failed")
      end

      def ensure_subject!(db, record)
        project_id = "isolated-#{Digest::SHA256.hexdigest(record['project'])[0, 40]}"
        task_id = "isolated-#{Digest::SHA256.hexdigest([ record['project'], record['task_id'], record['task_slug'] ].join("\0"))[0, 40]}"
        unless @isolated_identity
          task = db[:task_subjects].where(task_id: task_id).first ||
            db[:task_subjects].where(observed_path: record["task_id"].to_s).first
          raise RepositoryError, "attempt task identity is not registered in the runtime control plane" unless task
          return [ task.fetch(:task_id), task.fetch(:project_id) ]
        end

        installation = db[:installations].first.fetch(:installation_id)
        now = record["accepted_at"]
        db[:projects].insert_conflict.insert(
          project_id: project_id, installation_id: installation,
          registration_id: project_id, name: record["project"], observed_path: @root,
          state_root_path: @root, active: 1, registered_at: now, last_observed_at: now
        )
        db[:task_subjects].insert_conflict.insert(
          task_id: task_id, project_id: project_id, workflow_id: "attempt-runtime",
          task_slug: record["task_slug"], observed_path: record["task_id"].to_s,
          source_fingerprint: record["progress_token"], generation: record.task_input_epoch,
          created_at: now, last_observed_at: now
        )
        [ task_id, project_id ]
      end

      def ensure_dispatch_request!(db, record, task_id, project_id, source_fingerprint:)
        request_id = record["request_id"]
        return unless request_id
        existing = db[:dispatch_requests].where(request_id: request_id).first
        if existing
          expected = {
            project_id: project_id, task_id: task_id,
            subject_kind: record.subject_kind, subject_key: subject_key(record.subject),
            task_generation: record.task_generation,
            intended_stage: record["intended_stage"],
            source_fingerprint: source_fingerprint.to_s
          }
          mismatch = expected.any? { |key, value| existing.fetch(key) != value }
          raise RepositoryError, "dispatch request identity conflicts with attempt" if mismatch
          return
        end

        timestamp = record["accepted_at"]
        db[:dispatch_requests].insert(
          request_id: request_id, project_id: project_id, task_id: task_id,
          subject_kind: record.subject_kind, subject_key: subject_key(record.subject),
          task_generation: record.task_generation, intended_stage: record["intended_stage"],
          state: "admitted", priority: 0, source_fingerprint: source_fingerprint.to_s,
          routing_policy_digest: record["routing"]["policy_digest"],
          payload_json: RuntimeControlPlane::Codec.dump_json("source" => "attempt-admission"),
          created_at: timestamp, updated_at: timestamp
        )
      end

      def subject_key(subject)
        Digest::SHA256.hexdigest(RuntimeControlPlane::Codec.dump_json(subject))
      end

      def receipt_digest(receipt)
        return nil unless receipt
        Digest::SHA256.hexdigest(RuntimeControlPlane::Codec.dump_json(receipt))
      end

      def json_or_nil(value)
        value && RuntimeControlPlane::Codec.dump_json(value)
      end

      def prepare_payload_root!
        RuntimeControlPlane::PayloadStore.new(root: @root)
        ensure_payload_directory(".locks")
      end

      def ensure_payload_directory(*segments)
        path = File.join(@root, *segments)
        FileUtils.mkdir_p(path, mode: 0o700) if @create_directories
        validate_directory!(path, segments.join("/"))
      end

      def validate_directory!(path, label)
        status = File.lstat(path)
        raise RepositoryError, "attempt #{label} is a symlink" if status.symlink?
        raise RepositoryError, "attempt #{label} is not a directory" unless status.directory?
        raise RepositoryError, "attempt #{label} has the wrong owner" unless status.uid == Process.euid
        path
      rescue Errno::ENOENT
        return path unless @create_directories
        raise RepositoryError, "attempt #{label} is missing"
      end

      def ensure_contained!(path, parent)
        Hive::OutputReference.ensure_contained!(File.realpath(path), File.realpath(parent))
      rescue Hive::InvalidOutputReference
        raise RepositoryError, "attempt output directory escapes the payload root"
      end

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def safe_id(value)
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)
        raise RepositoryError, "unsafe attempt id"
      end

      def translate_store_error(error, prefix)
        raise error if error.is_a?(RepositoryError) || error.is_a?(CompareAndSwapFailed)
        raise RepositoryError, "#{prefix}: #{error.message}"
      end
    end
  end
end
