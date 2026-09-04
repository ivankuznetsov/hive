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
require "hive/runtime_control_plane/admission_transition"
require "hive/stringify_keys"

module Hive
  module Attempts
    class RepositoryError < Hive::Error; end
    class CompareAndSwapFailed < RepositoryError; end
    class CapacityExceeded < RepositoryError; end
    class StaleTaskSource < RepositoryError; end

    # The attempt facade persists lifecycle state in the runtime control plane.
    # The filesystem root contains only retained bytes referenced by those rows.
    class Repository
      include Coordination
      include Publication

      class ReadSession
        def initialize(store)
          @repository = store
          @records = {}
          @terminal_diagnostic_bindings = {}
        end

        def fetch(attempt_id)
          key = attempt_id.to_s
          @records.fetch(key) { @records[key] = @repository.fetch(key) }
        end

        def fetch_terminal_diagnostic_binding(attempt_id)
          key = attempt_id.to_s
          unless @terminal_diagnostic_bindings.key?(key)
            record = fetch(key)
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

      def self.open_default(create_directories: true, state_home: Hive::Paths.state_home)
        requested_home = File.expand_path(state_home)
        new(
          database: RuntimeControlPlane.database(
            path: Hive::Paths.runtime_control_plane_path(requested_home)
          ), create_directories: create_directories,
          root: Hive::Paths.runtime_payload_root(requested_home)
        )
      end

      def initialize(database:, root: Hive::Paths.runtime_payload_root, create_directories: true)
        @root, @create_directories = File.expand_path(root), create_directories
        @database = database
        database_exists = File.file?(database.path)
        database.open!(revalidate: !database_exists) if database_exists || create_directories
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

      # The one authoritative attempt-log read contract. Readers consume this
      # instead of resolving hot/cold frame paths themselves; availability is
      # the repository's custody-checked judgment, not a caller-side lstat.
      def read_log(attempt_id, after_sequence: 0)
        log_archive.read(attempt_id, after_sequence: after_sequence)
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
                           failure_cohort_probe: nil, route_decision: nil, **attributes)
        source_fingerprint ||= attributes[:progress_token]
        RuntimeControlPlane::AdmissionTransition.new(repository: self).call(
          attributes: attributes, source_fingerprint: source_fingerprint,
          admission: admission, limits: limits,
          failure_cohort_probe: failure_cohort_probe,
          route_decision: route_decision
        )
      rescue InvalidRecord, Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt could not be created")
      end

      # Bind the filesystem observation used to derive a task generation before
      # the final admission transaction rechecks it. This is deliberately a
      # separate, short transaction: task/file inspection stays outside the
      # admission lock, while a concurrent newer observation still fences this
      # caller at admission_validate_subject_in.
      def observe_task_source(task:, generation:, observed_at:)
        task_id = generation.task_id.to_s
        fingerprint = generation.progress_token.to_s
        input_epoch = Integer(generation.task_input_epoch)
        folder = File.expand_path(task.folder)
        stages = File.dirname(File.dirname(folder))
        unless File.basename(stages) == "stages" && File.basename(folder) == generation.task_slug.to_s
          raise StaleTaskSource, "attempt task path is outside a workflow stage"
        end
        workflow = task.workflow
        workflow_id = (workflow.respond_to?(:id) ? workflow.id : workflow).to_s
        workflow_id = "coding" if workflow_id.empty?
        timestamp = Record.iso8601(observed_at)
        database.transaction do |db|
          project = db[:projects].where(state_root_path: File.dirname(stages)).first
          unless project && project.fetch(:name) == generation.project.to_s
            raise StaleTaskSource, "attempt project identity is not registered for the task path"
          end
          alias_row = db[:task_subjects].where(
            project_id: project.fetch(:project_id), workflow_id: workflow_id,
            task_slug: generation.task_slug.to_s
          ).first
          if alias_row && alias_row.fetch(:task_id) != task_id
            raise StaleTaskSource, "attempt task alias belongs to a different task identity"
          end

          row = db[:task_subjects].where(task_id: task_id).first
          if row
            unless row.fetch(:project_id) == project.fetch(:project_id) &&
                   row.fetch(:workflow_id) == workflow_id &&
                   row.fetch(:task_slug) == generation.task_slug.to_s
              raise StaleTaskSource, "attempt task identity disagrees with its registered subject"
            end
            observed = Time.iso8601(row.fetch(:last_observed_at).to_s)
            placeholder = row[:source_fingerprint].to_s.empty? && row.fetch(:generation).zero?
            if observed > observed_at || (observed == observed_at &&
               !placeholder &&
               (row[:source_fingerprint].to_s != fingerprint || row.fetch(:generation) != input_epoch))
              raise StaleTaskSource, "attempt task source observation was superseded"
            end
            changed = db[:task_subjects].where(
              task_id: task_id, last_observed_at: row.fetch(:last_observed_at)
            ).update(
              observed_path: folder, source_fingerprint: fingerprint,
              generation: input_epoch, last_observed_at: timestamp
            )
            raise StaleTaskSource, "attempt task source observation was superseded" unless changed == 1
          else
            db[:task_subjects].insert(
              task_id: task_id, project_id: project.fetch(:project_id),
              workflow_id: workflow_id, task_slug: generation.task_slug.to_s,
              observed_path: folder, source_fingerprint: fingerprint,
              generation: input_epoch, created_at: timestamp,
              last_observed_at: timestamp
            )
          end
        end
        true
      rescue ArgumentError, TypeError
        raise StaleTaskSource, "attempt task source generation is invalid"
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "attempt task source could not be observed")
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
        return nil unless database.read do |db|
          db[:terminal_pending_publications].where(attempt_id: row[:attempt_id]).any?
        end

        record_from(row)
      end

      def read_session = ReadSession.new(self)

      # Internal seams used only by AdmissionTransition's one SQL transaction.
      def admission_subject_in(db, record, source_fingerprint:)
        return ensure_module_subject!(db, record) if record.module_hook?

        ensure_subject!(db, record, source_fingerprint: source_fingerprint)
      end
      def admission_validate_subject_in(db, task_id:, source_fingerprint:, generation:)
        return true unless task_id

        row = db[:task_subjects].where(task_id: task_id).first
        unless row && row[:source_fingerprint].to_s == source_fingerprint.to_s &&
               row.fetch(:generation) == Integer(generation)
          raise StaleTaskSource, "attempt task source changed before admission"
        end
        true
      rescue ArgumentError, TypeError
        raise StaleTaskSource, "attempt task source generation is invalid"
      end
      def admission_row(record, task_id:, project_id:, source_fingerprint:) =
        row_for(
          record, task_id: task_id, project_id: project_id,
          source_fingerprint: source_fingerprint
        )
      def admission_validate_capacity_in(db, record, limits) = validate_capacity!(db, record, limits)
      def admission_reservation(record, admission) = live_reservation(
        project: record["project"], task_slug: record["task_slug"], admission: admission
      )
      def admission_claim_cohort_in(db, record, probe)
        return unless probe
        return if claim_failure_cohort_probe_in(db, attempt_id: record.attempt_id, **probe)
        raise RepositoryError, "failure cohort probe claim became stale"
      end

      def active_attempts
        rows = database.read do |db|
          publication_pending = Sequel.lit(
            "terminal_receipt_json IS NOT NULL AND " \
            "(publication_journal_acknowledged = 0 OR " \
            "publication_accounting_acknowledged = 0 OR publication_dispatch_acknowledged = 0)"
          )
          db[:attempts].where(state: %w[launching running])
            .or(publication_pending).order(:attempt_id).all
        end
        rows.map { |row| record_from(row) }.freeze
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "active attempt query failed")
      end

      def live_attempt_for(task_id:)
        id = safe_id(task_id, error: "unsafe task id")
        row = database.read do |db|
          db[:attempts]
            .where(task_id: id)
            .where(state: %w[launching running])
            .order(:attempt_id)
            .first
        end
        row && record_from(row)
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        translate_store_error(error, "live attempt query failed")
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

      def validate_capacity!(db, record, limits)
        limits = limits.to_h
        live = db[:attempts].where(state: %w[launching running])
        at_limit = live.count >= Integer(limits.fetch(:max_global)) ||
          live.where(project_name: record["project"]).count >=
            Integer(limits.fetch(:max_per_project)) ||
          live.where(
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
          project_name: record["project"], accepted_date: date, refunded: 0
        ).count
      end

      def mutate(observed, allowed_states:, pending_receipt: nil)
        replacement = nil
        database.transaction do |db|
          row = db[:attempts].where(attempt_id: observed.attempt_id).first
          current = row && record_from(row)
          verify_cas!(current, observed, allowed_states)
          replacement = Record.new(yield(current.to_h))
          verify_immutable!(current, replacement)
          values = mutable_columns(replacement)
          if pending_receipt
            receipt_json = RuntimeControlPlane::Codec.dump_json(pending_receipt)
            values.merge!(
              terminal_receipt_json: receipt_json,
              terminal_receipt_digest: Digest::SHA256.hexdigest(receipt_json),
              terminal_task_source_fingerprint: row.fetch(:source_fingerprint),
              terminal_publication_created_at: replacement["ended_at"]
            )
          end
          updated = db[:attempts].where(
            attempt_id: current.attempt_id,
            lease_version: current.lease_version,
            state: current.state,
            record_digest: row.fetch(:record_digest)
          ).update(values)
          raise CompareAndSwapFailed, "attempt lease compare-and-swap lost" unless updated == 1
          if replacement.final?
            db[:dispatch_requests].where(
              request_id: replacement["request_id"],
              claim_attempt_id: replacement.attempt_id,
              state: "admitted"
            ).update(
              state: "awaiting_delivery", updated_at: replacement["ended_at"],
              revision: Sequel[:revision] + 1
            ) if replacement["request_id"]
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

      def row_for(record, task_id:, project_id:, source_fingerprint:)
        payload = RuntimeControlPlane::Codec.dump_json(record.to_h)
        {
          attempt_id: record.attempt_id, request_id: record["request_id"],
          project_id: project_id, task_id: task_id,
          subject_kind: record.subject_kind, subject_key: digest(record.subject),
          task_generation: record.task_generation,
          ownership_generation: record.ownership_generation, state: record.state,
          outcome: record.outcome, lease_version: record.lease_version,
          provider_account_id: record["routing"].dig("route", "provider_account_id"),
          retry_charge: record["retry_charge"], refunded: 0,
          source_fingerprint: source_fingerprint.to_s,
          record_json: payload,
          record_digest: Digest::SHA256.hexdigest(payload),
          subject_json: RuntimeControlPlane::Codec.dump_json(record.subject),
          project_name: record["project"], task_slug: record["task_slug"],
          accepted_date: Time.iso8601(record["accepted_at"]).utc.to_date.iso8601,
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
          record_json: payload, record_digest: Digest::SHA256.hexdigest(payload),
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

      def ensure_subject!(db, record, source_fingerprint:)
        task = db[:task_subjects].where(task_id: record["task_id"].to_s).first
        raise RepositoryError, "attempt task identity is not registered in the runtime control plane" unless task
        [ task.fetch(:task_id), task.fetch(:project_id) ]
      end

      def ensure_module_subject!(db, record)
        project_id = record.subject.fetch("project_id").to_s
        project = db[:projects].where(project_id: project_id, active: 1).first
        unless project && project.fetch(:name) == record["project"]
          raise RepositoryError,
                "attempt module project identity is not registered in the runtime control plane"
        end

        [ nil, project.fetch(:project_id) ]
      end

      def json(value) = value && RuntimeControlPlane::Codec.dump_json(value)
      def digest(value) = value && Digest::SHA256.hexdigest(json(value))

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

      def safe_id(value, error: "unsafe attempt id")
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)
        raise RepositoryError, error
      end

      def translate_store_error(error, prefix)
        raise error if error.is_a?(RepositoryError) || error.is_a?(CompareAndSwapFailed)
        raise RepositoryError, "#{prefix}: #{error.message}"
      end
    end
  end
end
