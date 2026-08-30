require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"
require "hive/atomic_file"
require "hive/config"
require "hive/daemon/activation_lock"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/cutover_manifest"
require "hive/runtime_control_plane/identity"
require "hive/runtime_control_plane/payload_store"
require "hive/provider_health/circuit"
require "hive/provider_health/event"

module Hive
  module RuntimeControlPlane
    # One offline, installation-wide transition. Files are mutable inputs only
    # before the intended manifest; every later resume consumes the closed
    # candidate and converges forward.
    class Cutover
      Result = Data.define(:phase, :cutover_id, :database_path, :exclusions)
      Target = Data.define(:home, :relative_path, :expected_type)
      PHASES = %w[preparing ready intended active].freeze
      FENCE_BYTES = "HIVE_RUNTIME_RETIRED\nUse the active Hive launcher and run hive runtime status.\n".freeze
      TARGETS = [
        Target.new(:state, "dispatch_requests", :directory),
        Target.new(:state, "dispatch_results", :directory),
        Target.new(:state, "attempts", :directory),
        Target.new(:state, "provider-health", :directory),
        Target.new(:state, "operational", :directory),
        Target.new(:state, ".task-counter.lock", :file),
        Target.new(:state, "task-counter.yml", :file),
        Target.new(:data, "usage.db", :file),
        Target.new(:data, "usage.db-wal", :file),
        Target.new(:data, "usage.db-shm", :file),
        Target.new(:data, "usage.db.patrol-discovery-allowances", :directory)
      ].freeze
      PROJECT_RUNTIME_FILES = [
        ".hive-state/daemon/pr-merge-reconciliation.json",
        ".hive-state/daemon/pr-merge-reconciliation.json.lock"
      ].freeze
      TASK_RUNTIME_FILES = %w[
        .lock .lock.tmp.guard
      ].freeze
      SEALED_SET_KEYS = %w[
        schema schema_version cutover_id created_at source_release target_release
        projects exclusions task_authority legacy_paths source_digest usage_snapshot
      ].freeze
      SEALED_PRESENT_KEYS = %w[
        home relative_path expected_type present type mode uid gid sha256
      ].freeze
      SEALED_ABSENT_KEYS = %w[home relative_path expected_type present].freeze
      MAX_MANIFEST_BYTES = 4 * 1024 * 1024
      MAX_FILE_BYTES = 512 * 1024 * 1024
      DISPOSABLE_TABLES = %i[daemon_runtime maintenance_checkpoints projections].freeze
      AUTHORITATIVE_TABLES = (EXPECTED_TABLES - DISPOSABLE_TABLES).sort.freeze

      class Error < RuntimeControlPlane::Error; end
      class ConfirmationRequired < Error; end
      class ProjectError < Error; end

      def self.task_authority(projects)
        Array(projects).sort_by { |project| project.fetch("project_id") }.map do |project|
          project_path = File.expand_path(project.fetch("path"))
          path = project.key?("hive_state_path") ? File.expand_path(project.fetch("hive_state_path")) : project_path
          { "project_id" => project.fetch("project_id"), "name" => project.fetch("name"),
            "state_path" => path, "sha256" => tree_digest(path) }
        end.freeze
      end

      def self.execution_fingerprint(database)
        database.read do |db|
          missing = AUTHORITATIVE_TABLES - db.tables
          unless missing.empty?
            raise Error.new(
              "runtime fingerprint is missing authoritative tables: #{missing.join(', ')}",
              code: :runtime_fingerprint_invalid
            )
          end
          payload = AUTHORITATIVE_TABLES.to_h do |table|
            rows = db[table].all.map { |row| row.transform_keys(&:to_s) }
            [ table.to_s, rows.sort_by { |row| Codec.dump_json(row) } ]
          end
          Digest::SHA256.hexdigest(Codec.dump_json(payload))
        end
      end

      def self.tree_digest(root)
        status = File.lstat(root)
        raise Errno::ENOTDIR, root unless status.directory? && !status.symlink?

        digest = Digest::SHA256.new
        pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
        until pending.empty?
          path = pending.pop
          relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
          next if relative.split(File::SEPARATOR).include?(".git")
          next if retired_runtime_authority_path?(relative)

          entry = File.lstat(path)
          raise Error.new("task authority contains a symlink", code: :task_authority_unsafe) if entry.symlink?
          if entry.directory?
            Dir.children(path).sort.reverse_each { |name| pending << File.join(path, name) }
          elsif entry.file? && entry.nlink == 1 && entry.size <= MAX_FILE_BYTES
            digest << "f\0#{relative}\0#{entry.mode & 0o7777}\0#{entry.size}\0"
            File.open(path, "rb") { |file| digest << file.read(64 * 1024) until file.eof? }
          else
            raise Error.new("task authority contains an unsafe entry", code: :task_authority_unsafe)
          end
        end
        digest.hexdigest
      rescue SystemCallError => error
        raise Error.new("task authority is unavailable: #{error.message}", code: :task_authority_unavailable)
      end

      def self.retired_runtime_authority_path?(relative)
        %w[daemon/pr-merge-reconciliation.json daemon/pr-merge-reconciliation.json.lock].include?(relative) ||
          %w[.lock .lock.tmp.guard].include?(relative) ||
          relative.match?(%r{\Astages/[^/]+/[^/]+/\.lock(?:\.tmp\.guard)?\z})
      end

      def self.inspect_status(state_home:, database:)
        root = File.join(File.expand_path(state_home), ".runtime-cutover", "current")
        phase = PHASES.reverse.find do |name|
          path = File.join(root, "#{name}.json")
          File.exist?(path) || File.symlink?(path)
        end
        document = if phase
          CutoverManifest.new(path: File.join(root, "#{phase}.json")).load.fetch("document")
        end
        if document && document.fetch("phase") != phase
          raise Error.new(
            "cutover manifest phase does not match its checkpoint",
            code: :activation_manifest_mismatch
          )
        end
        diagnosis = database.diagnostics
        if diagnosis.ok?
          unless phase == "active"
            raise Error.new(
              "runtime database has no active cutover manifest",
              code: :activation_manifest_missing,
              action: "run hive runtime status and hive runtime resume"
            )
          end
          identity = database.installation_identity
          unless identity && identity.fetch(:installation_id) == document.fetch("installation_id") &&
                 identity.fetch(:lineage_id) == document.fetch("lineage_id") &&
                 identity[:activation_epoch] == document.dig("evidence", "activation_epoch")
            raise Error.new(
              "runtime database identity differs from the active manifest",
              code: :activation_identity_mismatch,
              action: "keep services stopped and run hive runtime resume"
            )
          end
        end
        { "schema" => "hive-runtime-cutover-status", "phase" => phase || "absent",
          "installation_id" => document && document.fetch("installation_id"),
          "database" => diagnosis.to_h }
      ensure
        database.disconnect if diagnosis&.ok?
      end

      attr_reader :services

      def initialize(state_home: Hive::Paths.state_home, data_home: Hive::Paths.data_home,
                     projects: Hive::Config.registered_projects,
                     source_release: Hive::VERSION, target_release: Hive::VERSION,
                     services:, maintenance_gate: nil,
                     clock: -> { Time.now.utc }, uuid_generator: -> { SecureRandom.uuid },
                     fault: nil)
        @state_home = File.expand_path(state_home)
        @data_home = File.expand_path(data_home)
        @projects = Array(projects)
        @source_release = source_release.to_s
        @target_release = target_release.to_s
        @services = services
        @gate = maintenance_gate || Hive::Daemon::ActivationLock.new(hive_home: @state_home)
        @clock = clock
        @uuid_generator = uuid_generator
        @fault = fault
      end

      def run(confirm:, exclusions: [])
        return result_for("active") if current_phase == "active"
        return resume if current_phase
        confirmation! unless confirm
        perform(exclusions: exclusions, fresh: false)
      end

      def bootstrap(confirm:)
        return result_for("active") if current_phase == "active"
        return resume if current_phase
        confirmation! unless confirm
        material = target_paths.select { |target| File.exist?(target.fetch(:live)) || File.symlink?(target.fetch(:live)) }
        unless material.empty?
          raise Error.new(
            "legacy runtime state exists; bootstrap cannot choose an authority",
            code: :legacy_state_present, action: "run hive migrate --all"
          )
        end
        perform(exclusions: [], fresh: true)
      end

      def resume
        phase = current_phase
        return result_for("active") if phase == "active"
        unless phase
          raise Error.new(
            "no forward-only cutover is ready to resume", code: :resume_unavailable,
            action: "rerun hive migrate --all"
          )
        end
        document = load_phase(phase).fetch("document")
        @cutover_id = document.fetch("installation_id")
        @active_projects = active_projects_from(document)
        @services.stop!(cutover_id: cutover_id)
        @gate.synchronize do
          continue_preparing(document) if phase == "preparing"
          publish_intent_from_ready if current_phase == "ready"
          activate_from_intent
        end
      end

      def status
        self.class.inspect_status(
          state_home: @state_home, database: Database.new(path: database_path)
        )
      end

      private

      def perform(exclusions:, fresh:)
        reject_existing_run!
        active, excluded = validate_projects(exclusions)
        @active_projects = active
        task_authority = self.class.task_authority(active)
        registry_digest = digest(@projects)
        prepare_run!
        fault!(:run_prepared)
        publish_phase(
          "preparing", active, excluded, task_authority,
          "registry_digest" => registry_digest, "fresh" => fresh
        )
        @services.stop!(cutover_id: cutover_id)
        @gate.synchronize do
          continue_preparing(load_phase("preparing").fetch("document"))
          publish_intent_from_ready
          activate_from_intent
        end
      end

      def continue_preparing(document)
        ensure_no_live_database!
        active = active_projects_from(document)
        excluded = document.fetch("exclusions")
        task_authority = document.fetch("task_authority")
        registry_digest = document.dig("evidence", "registry_digest")
        fresh = document.dig("evidence", "fresh")
        unless File.file?(sealed_manifest_path)
          preview = fresh ? empty_import : import_live(active)
          preflight_legacy_owners!(preview.records)
          create_sealed_set(active, excluded, task_authority, source_digest: preview.digest)
        end
        sealed = validate_sealed_set!
        fences = fresh ? [] : seal_and_fence!(target_paths, sealed)
        fault!(:sources_sealed)
        imported = import_legacy(active, fresh: fresh)
        validate_sealed_set!
        unless imported.digest == sealed.fetch("source_digest")
          raise Error.new("sealed legacy import differs from preflight", code: :source_changed)
        end
        unless registry_digest == digest(@projects) &&
               task_authority == self.class.task_authority(active)
          raise Error.new(
            "registry or task authority changed during cutover", code: :source_changed,
            action: "stop task mutations and run hive runtime resume"
          )
        end
        epoch = activation_epoch
        activated_at = Codec.dump_time(@clock.call)
        candidate = build_candidate(
          active, imported, activation_epoch: epoch, activated_at: activated_at
        )
        fault!(:candidate_validated)
        evidence = {
          "registry_digest" => registry_digest, "source_digest" => imported.digest,
          "sealed_sha256" => Digest::SHA256.file(sealed_manifest_path).hexdigest,
          "candidate_sha256" => Digest::SHA256.file(candidate).hexdigest,
          "fences" => fences, "activation_epoch" => epoch, "activated_at" => activated_at,
          "project_results" => active.map { |project| { "name" => project.fetch("name"), "status" => "ready" } }
        }
        candidate_database = Database.new(path: candidate).open!
        evidence["execution_fingerprint"] = execution_fingerprint(candidate_database)
        evidence["candidate_payloads"] = candidate_payload_evidence(candidate_database)
        candidate_database.disconnect
        publish_phase("ready", active, excluded, task_authority, evidence)
        fault!(:fleet_ready)
      ensure
        candidate_database&.disconnect
      end

      def publish_intent_from_ready
        return if manifest_present?("intended")
        ready = load_phase("ready").fetch("document")
        validate_sealed_set!
        publish_phase(
          "intended", active_projects_from(ready), ready.fetch("exclusions"),
          ready.fetch("task_authority"), ready.fetch("evidence")
        )
        fault!(:activation_intent)
      end

      def activate_from_intent
        envelope = load_phase("intended")
        document = envelope.fetch("document")
        @cutover_id = document.fetch("installation_id")
        validate_sealed_set!
        unless Digest::SHA256.file(sealed_manifest_path).hexdigest == document.dig("evidence", "sealed_sha256")
          raise Error.new("sealed cutover source changed", code: :source_changed)
        end
        validate_intended_candidate!(document)
        live_payloads = Hive::Paths.runtime_payload_root(@state_home)
        install_candidate_payloads!(live_payloads, document.dig("evidence", "candidate_payloads"))
        fault!(:candidate_payloads_installed)
        install_candidate_database!(document)
        fault!(:candidate_database_installed)
        database = Database.new(path: database_path).open!
        installation = database.read { |db| db[:installations].first }
        unless installation.fetch(:activation_epoch) == document.dig("evidence", "activation_epoch") &&
               installation.fetch(:activated_at) == document.dig("evidence", "activated_at")
          raise Error.new("activated candidate identity differs", code: :candidate_invalid)
        end
        database.disconnect
        fault!(:candidate_identity_published)
        @services.activate! if @services.respond_to?(:activate!)
        publish_phase(
          "active", active_projects_from(document), document.fetch("exclusions"),
          document.fetch("task_authority"), document.fetch("evidence")
        ) unless manifest_present?("active")
        result_for("active")
      end

      def validate_projects(exclusions)
        names = Array(exclusions).map(&:to_s).uniq.sort
        unknown = names - @projects.map { |project| project.fetch("name") }
        raise ProjectError.new("unknown project exclusions: #{unknown.join(', ')}", code: :unknown_exclusion) unless unknown.empty?

        active = []
        excluded = []
        Identity.new.validate_projects!(@projects).each_with_index do |_identity, index|
          project = @projects.fetch(index)
          missing = !File.directory?(project.fetch("path")) ||
                    !File.directory?(project.fetch("hive_state_path"))
          if names.include?(project.fetch("name"))
            excluded << { "name" => project.fetch("name"), "project_id" => project.fetch("project_id"),
                          "reason" => missing ? "missing" : "operator_excluded" }
          elsif missing
            raise ProjectError.new(
              "registered project #{project.fetch('name')} is missing",
              code: :project_missing,
              action: "restore it or rerun with --exclude-project #{project.fetch('name')}"
            )
          else
            active << project
          end
        end
        [ active.freeze, excluded.freeze ]
      end

      def build_candidate(projects, imported, activation_epoch:, activated_at:)
        FileUtils.rm_f([ candidate_path, "#{candidate_path}-wal", "#{candidate_path}-shm" ])
        FileUtils.rm_rf(candidate_payload_root)
        database = Database.new(path: candidate_path).migrate!
        timestamp = Codec.dump_time(@clock.call)
        database.transaction do |db|
          original = db[:installations].first.fetch(:installation_id)
          db[:installations].where(installation_id: original).update(
            installation_id: cutover_id, lineage_id: cutover_id, created_at: timestamp,
            activation_epoch: activation_epoch, activated_at: activated_at
          )
          projects.each do |project|
            db[:projects].insert(
              project_id: project.fetch("project_id"), installation_id: cutover_id,
              registration_id: project.fetch("registration_id"), name: project.fetch("name"),
              observed_path: File.expand_path(project.fetch("path")),
              state_root_path: File.expand_path(project.fetch("hive_state_path")),
              repository_identity_json: project["repository_identity"] && Codec.dump_json(project["repository_identity"]),
              active: 1, registered_at: project.fetch("registered_at", timestamp), last_observed_at: timestamp
            )
            insert_tasks(db, project, timestamp)
          end
          import_requests(db, imported.records, timestamp)
          import_attempts(db, imported.records.fetch("attempts", []), timestamp)
          import_usage(db, imported.records.fetch("usage_sessions", []))
          import_counter(db, imported.records.fetch("task_counters", []), timestamp)
          import_provider_health(db, imported.records.fetch("provider_health", []), timestamp)
          import_routing_policies(db, imported.records.fetch("routing_policies", []), timestamp)
          import_patrol_allowances(db, imported.records.fetch("patrol_allowances", []), timestamp)
          import_pr_reconciliations(
            db, imported.records.fetch("pr_merge_reconciliations", []), timestamp
          )
          verify_terminal_receipts(db, imported.records.fetch("terminal_receipts", []))
          validate_derived_legacy_state!(db, imported.records)
          reject_unrepresented!(imported.records)
          db[:maintenance_checkpoints].insert(
            checkpoint_id: "cutover:#{cutover_id}", installation_id: cutover_id,
            kind: "fleet_cutover", state: "completed", generation: 1,
            payload_json: Codec.dump_json(
              "source_digest" => imported.digest,
              "domain_counts" => imported.records.transform_values(&:length)
            ), created_at: timestamp,
            completed_at: timestamp
          )
        end
        database.read { |db| db.run("PRAGMA wal_checkpoint(TRUNCATE)") }
        import_payloads(database, imported.records.fetch("retained_payloads", []), timestamp)
        database.read { |db| db.run("PRAGMA wal_checkpoint(TRUNCATE)") }
        database.disconnect
        diagnosis = Database.new(path: candidate_path).diagnostics
        raise diagnosis.error unless diagnosis.ok?
        candidate_path
      rescue Sequel::Error => error
        raise Error.new("candidate import failed: #{error.message}", code: :candidate_import_failed)
      end

      def insert_tasks(db, project, timestamp)
        root = File.join(project.fetch("hive_state_path"), "stages")
        Dir.glob(File.join(root, "*", "*")).sort.each do |folder|
          next unless File.directory?(folder)
          metadata = YAML.safe_load_file(File.join(folder, "meta.yml"), permitted_classes: [], aliases: false) || {}
          slug = File.basename(folder)
          task_id = metadata["id"]&.to_s
          if task_id.to_s.empty?
            raise ProjectError.new(
              "project #{project.fetch('name')} task #{slug} has no durable id",
              code: :task_identity_missing,
              action: "run the previous release's hive migrate for this project, then retry the fleet cutover"
            )
          end
          db[:task_subjects].insert(
            task_id: task_id, project_id: project.fetch("project_id"),
            workflow_id: metadata.fetch("workflow", "coding").to_s, task_slug: slug,
            observed_path: folder, source_fingerprint: self.class.tree_digest(folder),
            generation: 0, created_at: timestamp, last_observed_at: timestamp
          )
        end
      rescue Psych::Exception, Errno::ENOENT => error
        raise ProjectError.new(
          "project #{project.fetch('name')} task metadata is invalid: #{error.message}",
          code: :project_invalid
        )
      end

      def import_usage(db, records)
        columns = db[:token_usage].columns
        records.each do |record|
          row = record.to_h { |key, value| [ key.to_sym, value ] }.slice(*columns)
          row[:task_id] = nil unless row[:task_id] && db[:task_subjects].where(task_id: row[:task_id].to_s).any?
          row[:attempt_id] = nil unless row[:attempt_id] &&
            db[:attempts].where(attempt_id: row[:attempt_id].to_s).any?
          row[:input] ||= 0
          row[:output] ||= 0
          row[:cached] ||= 0
          db[:token_usage].insert_conflict(target: :id).insert(row)
        end
      end

      def import_counter(db, records, timestamp)
        value = records.filter_map { |record| record["generation"] || record["value"] }.map(&:to_i).max
        return unless value
        db[:task_counters].insert(
          installation_id: cutover_id, namespace: "tasks", value: value, updated_at: timestamp
        )
      end

      def import_requests(db, records, timestamp)
        results = records.fetch("dispatch_results", []).to_h do |record|
          [ record.fetch("request_id"), record ]
        end
        sequences = records.fetch("dispatch_sequence", []).to_h do |record|
          [ record.fetch("request_id"), record.fetch("remaining_argvs") ]
        end
        records.fetch("dispatch_requests", []).each do |record|
          project = project_row(db, record.fetch("project"))
          slug = record["slug"] || record["task_slug"]
          task = task_row(db, project, slug)
          stage = (record["intended_stage"] || record["stage"] || "legacy").to_s
          payload = Codec.dump_json(record.merge(
            "remaining_argvs" => sequences.fetch(record.fetch("request_id"), [])
          ))
          state = results.key?(record.fetch("request_id")) ? "completed" : "queued"
          db[:dispatch_requests].insert(
            request_id: record.fetch("request_id"), project_id: project.fetch(:project_id),
            task_id: task.fetch(:task_id), subject_kind: "task_stage",
            subject_key: digest([ project.fetch(:project_id), slug, stage ]),
            task_generation: (record["task_generation"] || "legacy").to_s,
            intended_stage: stage, state: state, priority: Integer(record.fetch("priority", 0)),
            idempotency_key: record["idempotency_key"], revision: 0,
            source_fingerprint: Digest::SHA256.hexdigest(payload), payload_json: payload,
            created_at: record["created_at"] || timestamp, updated_at: timestamp
          )
        end
        orphaned = results.keys - records.fetch("dispatch_requests", []).map { |record| record.fetch("request_id") }
        raise Error.new("dispatch results have no request: #{orphaned.join(', ')}", code: :orphaned_legacy_state) unless orphaned.empty?
        results.each_value do |record|
          created_at = record["created_at"] || timestamp
          retain_until = (Time.iso8601(created_at) + 3600).utc.iso8601(6)
          db[:dispatch_outbox].insert(
            delivery_id: record.fetch("result_id"), request_id: record.fetch("request_id"),
            kind: "bot_result", state: "pending",
            idempotency_key: "legacy-result:#{record.fetch('result_id')}",
            payload_json: Codec.dump_json(record), delivery_attempts: 0,
            available_at: created_at, retain_until: retain_until
          )
        end
      rescue ArgumentError
        raise Error.new("legacy dispatch timestamp is invalid", code: :unsupported_legacy_state)
      end

      def import_attempts(db, records, timestamp)
        require "date"
        require "hive/attempts/record"
        parsed = records.map { |raw| Hive::Attempts::Record.new(raw) }
        parsed.each do |record|
          project = project_row(db, record["project"])
          task = task_row(db, project, record["task_slug"])
          unless task.fetch(:task_id) == record["task_id"].to_s
            raise Error.new("attempt task identity does not match task authority", code: :orphaned_legacy_state)
          end
          request_id = record["request_id"]
          request_id = nil unless request_id && db[:dispatch_requests].where(request_id: request_id).any?
          payload = Codec.dump_json(record.to_h)
          db[:attempts].insert(
            attempt_id: record.attempt_id, request_id: request_id, task_id: task.fetch(:task_id),
            subject_kind: record.subject_kind, subject_key: digest(record.subject),
            task_generation: record.task_generation,
            ownership_generation: record.ownership_generation, state: record.state,
            outcome: record.outcome, lease_version: record.lease_version,
            owner_identity_json: record.wrapper && Codec.dump_json(record.wrapper),
            routing_json: Codec.dump_json(record["routing"]),
            source_fingerprint: record["progress_token"],
            checkpoint_json: record.checkpoint && Codec.dump_json(record.checkpoint),
            record_json: payload, record_digest: Digest::SHA256.hexdigest(payload),
            subject_json: Codec.dump_json(record.subject), project_name: record["project"],
            task_slug: record["task_slug"],
            accepted_date: Time.iso8601(record["accepted_at"]).utc.to_date.iso8601,
            terminal_receipt_digest: record.receipt && digest(record.receipt),
            created_at: record["created_at"], accepted_at: record["accepted_at"],
            started_at: record["started_at"], heartbeat_at: record["heartbeat_at"],
            ended_at: record["ended_at"]
          )
          db[:attempt_accounting].insert(
            attempt_id: record.attempt_id, retry_charge: record["retry_charge"], refunded: 0,
            reservation_json: "{}", billing_json: "{}", updated_at: timestamp
          )
        end
        parsed.each do |record|
          predecessor = record["predecessor_attempt_id"]
          next unless predecessor
          unless db[:attempts].where(attempt_id: predecessor).any?
            raise Error.new("attempt predecessor is missing", code: :orphaned_legacy_state)
          end
          db[:attempt_relationships].insert(
            attempt_id: record.attempt_id, related_attempt_id: predecessor,
            kind: "predecessor", created_at: record["created_at"]
          )
        end
      rescue Hive::Attempts::InvalidRecord => error
        raise Error.new("legacy attempt cannot be represented: #{error.message}", code: :unsupported_legacy_state)
      end

      def import_provider_health(db, records, timestamp)
        records.each do |record|
          circuit = Hive::ProviderHealth::Circuit.from_h(record.fetch("circuit"))
          raise Error.new("provider circuit is not quiescent", code: :live_runtime_owner) if
            circuit.probe_owned?
          db[:provider_circuits].insert(
            circuit_id: circuit.scope.key, scope_kind: circuit.scope.kind,
            provider_account_id: circuit.scope.account_id,
            model: circuit.scope.model_id.to_s, automatic_state: circuit.automatic_state,
            manual_block: circuit.blocked? ? 1 : 0,
            manual_block_json: circuit.manual_block && Codec.dump_json(circuit.manual_block),
            generation: circuit.generation, journal_epoch: circuit.journal_epoch,
            eligible_at: circuit.eligible_at,
            evidence_json: circuit.evidence && Codec.dump_json(circuit.evidence),
            last_event_id: circuit.last_event_id, updated_at: timestamp
          )
          Array(record.fetch("events")).each_with_index do |raw, index|
            event = Hive::ProviderHealth::Event.from_h(raw)
            unless event.scope == circuit.scope
              raise Error.new("provider audit scope is unsupported", code: :unsupported_legacy_state)
            end
            rejected = event.kind == "evidence_rejected"
            db[:provider_audit].insert(
              event_id: event.event_id, circuit_id: circuit.scope.key,
              generation: event.resulting_generation, sequence: index + 1,
              event_type: event.kind, idempotency_key: event.idempotency_key,
              status: rejected ? "rejected" : "accepted",
              reason: rejected ? event.payload.fetch("reason") : nil,
              payload_json: Codec.dump_json(event.to_h), occurred_at: event.occurred_at
            )
          end
        end
      rescue Hive::ProviderHealth::Error, KeyError, TypeError => error
        raise Error.new(
          "provider health cannot be represented: #{error.message}",
          code: :unsupported_legacy_state
        )
      end

      def import_routing_policies(db, records, timestamp)
        records.each do |record|
          unless record["schema"] == "hive-routing-policy" && record["ownership_generation"].is_a?(String) &&
                 record["subject"].is_a?(Hash) && record["policy"].is_a?(Hash)
            raise Error.new("routing policy cannot be represented", code: :unsupported_legacy_state)
          end
          policy_digest = record.dig("policy", "digest")
          raise Error.new("routing policy digest is missing", code: :unsupported_legacy_state) unless policy_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
          key = { "ownership_generation" => record.fetch("ownership_generation"),
                  "subject" => record.fetch("subject") }
          db[:routing_policies].insert(
            installation_id: cutover_id, policy_key: digest(key), revision: 0,
            policy_digest: policy_digest, policy_json: Codec.dump_json(record), updated_at: timestamp
          )
        end
      end

      def import_patrol_allowances(db, records, timestamp)
        records.each do |record|
          window = record.fetch("generation").to_s
          record.fetch("projects").each do |identity, lanes|
            project = db[:projects].where(project_id: identity).first ||
              db[:projects].where(name: identity.to_s.delete_prefix("project-")).first
            raise Error.new("Patrol allowance project is orphaned", code: :orphaned_legacy_state) unless project
            lanes.each do |kind, lane|
              ids = Array(lane.fetch("reservations", []))
              db[:patrol_allowances].insert(
                project_id: project.fetch(:project_id), kind: kind, window_key: window,
                used: ids.length, limit_value: ids.length, revision: 0,
                reservation_ids_json: Codec.dump_json(ids), seed_state: "complete",
                seeded_launches: ids.length, ambiguous_rows: 0, updated_at: timestamp
              )
            end
          end
        end
      end

      def import_pr_reconciliations(db, records, timestamp)
        records.each do |record|
          unless record.fetch("schema") == "hive-pr-merge-reconciliation" &&
                 record.fetch("schema_version") == 1 && record.fetch("candidates").is_a?(Hash) &&
                 record.fetch("backlog").is_a?(Hash)
            raise Error.new(
              "PR reconciliation cannot be represented", code: :unsupported_legacy_state
            )
          end
          project = db[:projects].where(registration_id: record.fetch("registration")).first
          unless project && project.fetch(:observed_path) == File.expand_path(record.fetch("project_path")) &&
                 project.fetch(:state_root_path) == File.expand_path(record.fetch("hive_state_path"))
            raise Error.new(
              "PR reconciliation project identity is orphaned", code: :orphaned_legacy_state
            )
          end
          record.fetch("candidates").sort.each do |key, candidate|
            unless key.match?(/\A[0-9a-f]{64}\z/) && candidate.fetch("key") == key
              raise Error.new(
                "PR reconciliation key is invalid", code: :unsupported_legacy_state
              )
            end
            task = candidate.fetch("task")
            task_row = db[:task_subjects].where(
              project_id: project.fetch(:project_id), workflow_id: task.fetch("workflow"),
              task_slug: task.fetch("slug")
            ).first
            raise Error.new("PR reconciliation task is orphaned", code: :orphaned_legacy_state) unless task_row
            observation = candidate.fetch("observation")
            remote = candidate.fetch("remote")
            architecture = candidate.fetch("architecture")
            archive = candidate.fetch("archive")
            retry_state = candidate.fetch("retry")
            remote_state = remote.fetch("state")
            archive_state = archive.fetch("status")
            state = if archive_state == "failed"
              "failed"
            elsif remote_state == "merged"
              "merged"
            elsif remote_state == "closed_unmerged"
              "closed"
            else
              "pending"
            end
            db[:pr_merge_reconciliations].insert(
              reconciliation_id: key, project_id: project.fetch(:project_id),
              task_id: task_row.fetch(:task_id),
              task_generation: observation.fetch("task_generation"),
              repository_identity: record.fetch("repository"),
              registration_id: record.fetch("registration"),
              project_path: File.expand_path(record.fetch("project_path")),
              state_root_path: File.expand_path(record.fetch("hive_state_path")),
              host: record.fetch("host"), default_branch: record.fetch("default_branch"),
              pr_number: Integer(candidate.dig("pull_request", "number")),
              merge_sha: remote["merge_oid"], state: state,
              retry_failures: Integer(retry_state.fetch("failures")),
              retry_not_before: retry_state["not_before"], remote_state: remote_state,
              architecture_state: architecture.fetch("status"),
              archive_state: archive_state, held: observation.fetch("held") ? 1 : 0,
              hold_reason: observation["hold_reason"], revision: 0,
              observation_json: Codec.dump_json(candidate),
              observed_at: observation["state_file_mtime"] || candidate.fetch("updated_at"),
              updated_at: candidate.fetch("updated_at"),
              completed_at: %w[archived superseded].include?(archive_state) ? candidate.fetch("updated_at") : nil
            )
          end
          backlog = record.fetch("backlog")
          db[:pr_merge_project_state].insert(
            project_id: project.fetch(:project_id), cursor: record["cursor"],
            backlog_json: Codec.dump_json(backlog), updated_at: record.fetch("updated_at", timestamp)
          )
        end
      rescue KeyError, ArgumentError, TypeError => error
        raise Error.new(
          "PR reconciliation cannot be represented: #{error.message}",
          code: :unsupported_legacy_state
        )
      end

      def verify_terminal_receipts(db, records)
        records.each do |record|
          attempt = db[:attempts].where(attempt_id: record.fetch("attempt_id")).first
          expected = record["receipt_digest"]
          unless attempt && (!expected || attempt[:terminal_receipt_digest] == expected)
            raise Error.new("terminal receipt has no matching attempt", code: :terminal_receipt_mismatch)
          end
        end
      end

      def validate_derived_legacy_state!(db, records)
        requests = db[:dispatch_requests].select_map(:request_id)
        records.fetch("dispatch_sequence", []).each do |record|
          raise Error.new("dispatch sequence has no request", code: :orphaned_legacy_state) unless
            requests.include?(record.fetch("request_id"))
        end
        records.fetch("capacity_reservations", []).each do |record|
          reservations = record.dig("value", "reservations")
          raise Error.new("legacy capacity is not empty", code: :live_runtime_owner) unless
            reservations.is_a?(Hash) && reservations.empty?
        end
        records.fetch("attempt_revisions", []).each do |record|
          next if record["kind"] == "live-capacity" && record.dig("value", "reservations") == {}
          unless record["kind"] == "latest-terminal" &&
                 (attempt = db[:attempts].where(attempt_id: record.dig("value", "attempt_id")).first) &&
                 (!record.dig("value", "revision") ||
                   JSON.parse(attempt.fetch(:record_json))["latest_revision"] == record.dig("value", "revision"))
            raise Error.new("attempt decision index cannot be represented", code: :unsupported_legacy_state)
          end
        end
        %w[provider_probes task_leases].each do |domain|
          raise Error.new("live #{domain.tr('_', ' ')} remain", code: :live_runtime_owner) unless
            records.fetch(domain, []).empty?
        end
      end

      def import_payloads(database, records, timestamp)
        store = PayloadStore.new(root: candidate_payload_root)
        records.each_with_index do |record, index|
          attempt_id = record.fetch("attempt_id")
          exists = database.read { |db| db[:attempts].where(attempt_id: attempt_id).any? }
          raise Error.new("payload has no matching attempt", code: :orphaned_legacy_state) unless exists
          reference = store.seal(
            File.join(sealed_home(:state), record.fetch("legacy_path")),
            expected_sha256: record.fetch("sha256"), expected_size: record.fetch("size")
          )
          database.transaction do |db|
            db[:payload_references].insert(
              payload_id: "legacy:#{attempt_id}:#{index}", attempt_id: attempt_id,
              kind: "legacy_attempt_payload", relative_path: reference.fetch("path"),
              sha256: reference.fetch("sha256"), bytes: reference.fetch("size"),
              state: "sealed", created_at: timestamp
            )
          end
        end
      end

      def candidate_payload_evidence(database)
        store_root = candidate_payload_root
        database.read do |db|
          db[:payload_references].order(:payload_id).map do |row|
            relative = safe_recovery_relative!(row.fetch(:relative_path))
            path = File.join(store_root, relative)
            status = File.lstat(path)
            unless status.file? && !status.symlink? && status.nlink == 1 &&
                   status.size == row.fetch(:bytes) &&
                   Digest::SHA256.file(path).hexdigest == row.fetch(:sha256)
              raise Error.new(
                "candidate payload differs from its database reference",
                code: :candidate_payload_invalid
              )
            end
            { "payload_id" => row.fetch(:payload_id), "path" => relative,
              "bytes" => row.fetch(:bytes), "sha256" => row.fetch(:sha256) }
          end
        end
      rescue Errno::ENOENT
        raise Error.new("candidate payload is missing", code: :candidate_payload_invalid)
      end

      def validate_intended_candidate!(document)
        expected = document.dig("evidence", "candidate_sha256")
        unless File.file?(candidate_path) && Digest::SHA256.file(candidate_path).hexdigest == expected
          raise Error.new("closed cutover candidate changed", code: :candidate_invalid)
        end
        database = Database.new(path: candidate_path)
        diagnosis = database.diagnostics
        raise diagnosis.error unless diagnosis.ok?
        database.open!
        unless execution_fingerprint(database) == document.dig("evidence", "execution_fingerprint") &&
               candidate_payload_evidence(database) == document.dig("evidence", "candidate_payloads")
          raise Error.new("closed cutover candidate evidence differs", code: :candidate_invalid)
        end
        true
      ensure
        database&.disconnect
      end

      def install_candidate_payloads!(live, evidence)
        return true if payload_bundle_matches?(live, evidence)
        temporary = "#{live}.activate-#{cutover_id}"
        FileUtils.rm_rf(temporary)
        FileUtils.mkdir_p(temporary, mode: 0o700)
        Array(evidence).each do |entry|
          relative = safe_recovery_relative!(entry.fetch("path"))
          source = File.join(candidate_payload_root, relative)
          target = File.join(temporary, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          FileUtils.copy_file(source, target)
        end
        unless payload_bundle_matches?(temporary, evidence)
          raise Error.new("candidate payload bundle copy is invalid", code: :candidate_payload_invalid)
        end
        FileUtils.rm_rf(live) if File.exist?(live) || File.symlink?(live)
        File.rename(temporary, live)
        Hive::AtomicFile.fsync_directory(File.dirname(live))
        true
      ensure
        FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
      end

      def payload_bundle_matches?(root, evidence)
        return false unless File.directory?(root) && !File.symlink?(root)
        expected = Array(evidence).sort_by { |entry| entry.fetch("path") }
        actual = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
          next if File.directory?(path)
          status = File.lstat(path)
          return false unless status.file? && !status.symlink? && status.nlink == 1
          relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
          { "payload_id" => expected.find { |entry| entry.fetch("path") == relative }&.fetch("payload_id", nil),
            "path" => relative, "bytes" => status.size,
            "sha256" => Digest::SHA256.file(path).hexdigest }
        end
        actual.sort_by { |entry| entry.fetch("path") } == expected
      rescue SystemCallError, KeyError
        false
      end

      def install_candidate_database!(document)
        return true if live_candidate_activated?(document)
        temporary = File.join(
          File.dirname(database_path), ".candidate-#{cutover_id}-#{SecureRandom.hex(4)}.sqlite3"
        )
        FileUtils.mkdir_p(File.dirname(database_path), mode: 0o700)
        FileUtils.copy_file(candidate_path, temporary)
        File.open(temporary, "rb") { |file| file.fsync }
        unless Digest::SHA256.file(temporary).hexdigest == document.dig("evidence", "candidate_sha256")
          raise Error.new("candidate database copy is invalid", code: :candidate_invalid)
        end
        [ database_path, "#{database_path}-wal", "#{database_path}-shm" ].each do |path|
          FileUtils.rm_f(path)
        end
        File.rename(temporary, database_path)
        Hive::AtomicFile.fsync_directory(File.dirname(database_path))
        true
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def live_candidate_activated?(document)
        return false unless File.file?(database_path)
        database = Database.new(path: database_path)
        return false unless database.diagnostics.ok?
        installation = database.installation_identity
        installation.fetch(:installation_id) == cutover_id &&
          installation[:activation_epoch] == document.dig("evidence", "activation_epoch")
      rescue RuntimeControlPlane::Error, Sequel::Error, KeyError
        false
      ensure
        database&.disconnect
      end

      def reject_unrepresented!(records)
        represented = %w[
          attempts attempt_revisions capacity_reservations dispatch_requests dispatch_results
          dispatch_sequence provider_health provider_probes retained_payloads routing_policies
          task_counters task_leases terminal_receipts usage_sessions patrol_allowances
          pr_merge_reconciliations operational_projections
        ]
        unsupported = records.select { |domain, values| !values.empty? && !represented.include?(domain) }.keys
        return if unsupported.empty?
        raise Error.new(
          "legacy domains cannot be represented: #{unsupported.sort.join(', ')}",
          code: :unsupported_legacy_state,
          action: "finish or repair that legacy state before retrying cutover"
        )
      end

      def project_row(db, name)
        db[:projects].where(name: name.to_s).first ||
          raise(Error.new("legacy project #{name} is not registered", code: :orphaned_legacy_state))
      end

      def task_row(db, project, slug)
        db[:task_subjects].where(project_id: project.fetch(:project_id), task_slug: slug.to_s).first ||
          raise(Error.new("legacy task #{slug} is not registered", code: :orphaned_legacy_state))
      end

      def import_legacy(projects, fresh:)
        return empty_import if fresh
        require "hive/runtime_control_plane/legacy_import"
        sealed_projects = projects.to_h do |project|
          [ sealed_home("project-#{project.fetch('project_id')}"), project.fetch("name") ]
        end
        LegacyImport.new(
          state_home: sealed_home(:state), data_home: sealed_home(:data),
          project_roots: sealed_projects.keys, project_names: sealed_projects,
          attempt_root: File.join(sealed_home(:state), "attempts", "v4"),
          usage_path: sealed_usage_path,
          patrol_allowances_path: File.join(sealed_home(:data), "usage.db.patrol-discovery-allowances")
        ).call
      end

      def import_live(projects)
        require "hive/runtime_control_plane/legacy_import"
        LegacyImport.new(
          state_home: @state_home, data_home: @data_home,
          project_roots: projects.map { |project| project.fetch("path") }
        ).call
      end

      def preflight_legacy_owners!(records)
        %w[provider_probes task_leases terminal_pending].each do |domain|
          next if records.fetch(domain, []).empty?
          raise Error.new(
            "live #{domain.tr('_', ' ')} blocks irreversible sealing",
            code: :live_runtime_owner,
            action: "finish the owning legacy publication or lease, then retry"
          )
        end
        records.fetch("capacity_reservations", []).each do |record|
          reservations = record.dig("value", "reservations")
          next if reservations.is_a?(Hash) && reservations.empty?
          raise Error.new(
            "live capacity reservation blocks irreversible sealing",
            code: :live_runtime_owner, action: "let legacy work finish, then retry"
          )
        end
        reject_unrepresented!(records)
      end

      def empty_import
        require "hive/runtime_control_plane/legacy_import"
        LegacyImport::Result.new({}.freeze, [].freeze, digest({}))
      end

      def seal_and_fence!(targets, sealed)
        inventory = sealed.fetch("legacy_paths").to_h do |entry|
          [ [ entry.fetch("home"), entry.fetch("relative_path") ], entry ]
        end
        plan = fence_plan
        if plan.empty?
          plan = targets.map do |target|
            source = inventory.fetch([ target.fetch(:home).to_s, target.fetch(:relative_path) ])
            { "path" => target.fetch(:live), "expected_type" => target.fetch(:expected_type).to_s,
              "source_present" => source.fetch("present"), "source_sha256" => source["sha256"],
              "state" => "planned" }
          end
          write_fence_journal(plan)
        end
        plan.each do |entry|
          next if entry.fetch("state") == "applied" && fence_installed?(entry)

          live = entry.fetch("path")
          if entry.fetch("source_present") && !fence_installed?(entry)
            unless path_digest(live) == entry.fetch("source_sha256")
              raise Error.new("legacy source changed after it was sealed", code: :source_changed)
            end
          end
          entry["state"] = "applying"
          write_fence_journal(plan)
          FileUtils.rm_rf(live) unless fence_installed?(entry)
          install_fence(live, entry.fetch("expected_type").to_sym) unless fence_installed?(entry)
          fault!(:fence_installed)
          entry["state"] = "applied"
          write_fence_journal(plan)
        end
        plan.map { |entry| entry.slice("path", "expected_type", "source_present") }
      end

      def fence_installed?(entry)
        path = entry.fetch("path")
        if entry.fetch("expected_type") == "file"
          File.directory?(path) && !File.symlink?(path) &&
            File.binread(File.join(path, "RETIRED")) == FENCE_BYTES
        else
          File.file?(path) && !File.symlink?(path) && File.binread(path) == FENCE_BYTES
        end
      rescue SystemCallError
        false
      end

      def install_fence(path, expected_type)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        if expected_type == :file
          FileUtils.mkdir_p(path, mode: 0o700)
          Hive::AtomicFile.write(File.join(path, "RETIRED"), FENCE_BYTES, mode: 0o600)
        else
          Hive::AtomicFile.write(path, FENCE_BYTES, mode: 0o600)
        end
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def create_sealed_set(projects, exclusions, task_authority, source_digest:)
        temporary = "#{sealed_root}.tmp"
        FileUtils.rm_rf(temporary)
        FileUtils.mkdir_p(temporary, mode: 0o700)
        usage_snapshot = create_usage_snapshot!(temporary) if File.file?(File.join(@data_home, "usage.db"))
        paths = target_paths.map { |target| seal_target(target, temporary) }
        document = {
          "schema" => "hive-runtime-sealed-legacy", "schema_version" => 1,
          "cutover_id" => cutover_id, "created_at" => Codec.dump_time(@clock.call),
          "source_release" => @source_release, "target_release" => @target_release,
          "projects" => projects.map { |project| project.fetch("project_id") },
          "exclusions" => exclusions, "task_authority" => task_authority,
          "legacy_paths" => paths, "source_digest" => source_digest,
          "usage_snapshot" => usage_snapshot
        }
        Hive::AtomicFile.write(
          File.join(temporary, "manifest.json"), "#{Codec.dump_json(document)}\n", mode: 0o600
        )
        validate_sealed_set!(temporary)
        File.rename(temporary, sealed_root)
        Hive::AtomicFile.fsync_directory(current_root)
        validate_sealed_set!
      ensure
        FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
      end

      def seal_target(target, root)
        identity = { "home" => target.fetch(:home).to_s,
                     "relative_path" => target.fetch(:relative_path),
                     "expected_type" => target.fetch(:expected_type).to_s }
        live = target.fetch(:live)
        return identity.merge("present" => false) unless File.exist?(live) || File.symlink?(live)

        status = File.lstat(live)
        type = status.file? ? "file" : (status.directory? ? "directory" : "unsafe")
        raise Error.new("cutover source has the wrong type", code: :path_shape_mismatch) unless
          type == target.fetch(:expected_type).to_s
        before = path_digest(live)
        copy = File.join(root, target.fetch(:home).to_s, target.fetch(:relative_path))
        FileUtils.mkdir_p(File.dirname(copy), mode: 0o700)
        FileUtils.cp_r(live, copy, preserve: true)
        unless before == path_digest(copy) && before == path_digest(live)
          raise Error.new("cutover source changed while sealing", code: :source_changed)
        end
        identity.merge(
          "present" => true, "type" => type, "mode" => status.mode & 0o7777,
          "uid" => status.uid, "gid" => status.gid, "sha256" => before
        )
      end

      def create_usage_snapshot!(root)
        destination = File.join(root, "usage.snapshot.sqlite3")
        source = File.join(@data_home, "usage.db")
        database = Sequel.connect(adapter: "sqlite", database: source, max_connections: 1)
        database.run("VACUUM INTO #{database.literal(destination)}")
        check = Sequel.connect(adapter: "sqlite", database: destination, readonly: true)
        rows = check.fetch("PRAGMA quick_check").map { |row| row.values.first }
        raise Error.new("legacy usage snapshot failed integrity check", code: :usage_snapshot_invalid) unless rows == [ "ok" ]
        { "sha256" => Digest::SHA256.file(destination).hexdigest,
          "bytes" => File.size(destination) }
      rescue Sequel::Error => error
        raise Error.new("legacy usage snapshot failed: #{error.message}", code: :usage_snapshot_failed)
      ensure
        check&.disconnect
        database&.disconnect
      end

      def validate_sealed_set!(root = sealed_root)
        root = File.expand_path(root)
        status = File.lstat(root)
        raise Error.new("sealed legacy root is unsafe", code: :sealed_source_corrupt) unless
          status.directory? && !status.symlink?
        manifest_status = File.lstat(File.join(root, "manifest.json"))
        unless manifest_status.file? && !manifest_status.symlink? && manifest_status.nlink == 1 &&
               manifest_status.size <= MAX_MANIFEST_BYTES
          raise Error.new("sealed legacy manifest is unsafe", code: :sealed_source_corrupt)
        end
        document = JSON.parse(File.binread(File.join(root, "manifest.json")))
        unless document.is_a?(Hash) && document.keys.sort == SEALED_SET_KEYS.sort &&
               document["schema"] == "hive-runtime-sealed-legacy" &&
               document["schema_version"] == 1 && document["cutover_id"] == cutover_id &&
               document["projects"].is_a?(Array) && document["exclusions"].is_a?(Array) &&
               document["task_authority"].is_a?(Array) && document["legacy_paths"].is_a?(Array) &&
               document["source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Error.new("sealed legacy manifest is invalid", code: :sealed_source_corrupt)
        end
        expected = target_paths.to_h do |target|
          [ [ target.fetch(:home).to_s, target.fetch(:relative_path) ], target ]
        end
        entries = {}
        document.fetch("legacy_paths").each do |entry|
          keys = entry.fetch("present") ? SEALED_PRESENT_KEYS : SEALED_ABSENT_KEYS
          raise Error.new("sealed legacy inventory is not closed", code: :sealed_source_corrupt) unless
            entry.is_a?(Hash) && [ true, false ].include?(entry["present"]) && entry.keys.sort == keys.sort
          home = safe_recovery_component!(entry.fetch("home"))
          relative = safe_recovery_relative!(entry.fetch("relative_path"))
          identity = [ home, relative ]
          raise Error.new("sealed legacy inventory has an unknown or duplicate path", code: :sealed_source_corrupt) if
            entries.key?(identity) || !expected.key?(identity)
          target = expected.fetch(identity)
          raise Error.new("sealed legacy inventory type differs", code: :sealed_source_corrupt) unless
            entry.fetch("expected_type") == target.fetch(:expected_type).to_s
          path = contained_recovery_path!(root, home, relative)
          validate_sealed_entry!(path, entry) if entry.fetch("present")
          raise Error.new("sealed required absence is populated", code: :sealed_source_corrupt) if
            !entry.fetch("present") && (File.exist?(path) || File.symlink?(path))
          entries[identity] = entry
        end
        raise Error.new("sealed legacy inventory is incomplete", code: :sealed_source_corrupt) unless
          entries.keys.sort == expected.keys.sort
        validate_usage_snapshot!(root, document.fetch("usage_snapshot"))
        document
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError, Errno::ENOENT
        raise Error.new("sealed legacy set is incomplete", code: :sealed_source_corrupt)
      end

      def validate_sealed_entry!(path, entry)
        status = File.lstat(path)
        observed = status.file? ? "file" : (status.directory? ? "directory" : "unsafe")
        return if observed == entry.fetch("type") && observed == entry.fetch("expected_type") &&
                  status.mode & 0o7777 == Integer(entry.fetch("mode")) &&
                  status.uid == Integer(entry.fetch("uid")) && status.gid == Integer(entry.fetch("gid")) &&
                  path_digest(path) == entry.fetch("sha256")

        raise Error.new("sealed legacy source changed", code: :sealed_source_corrupt)
      end

      def validate_usage_snapshot!(root, evidence)
        return true if evidence.nil? && !File.exist?(File.join(root, "usage.snapshot.sqlite3"))
        unless evidence.is_a?(Hash) && evidence.keys.sort == %w[bytes sha256] &&
               evidence["bytes"].is_a?(Integer) && evidence["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Error.new("sealed usage snapshot evidence is invalid", code: :sealed_source_corrupt)
        end
        path = File.join(root, "usage.snapshot.sqlite3")
        status = File.lstat(path)
        return true if status.file? && !status.symlink? && status.nlink == 1 &&
                       status.size == evidence.fetch("bytes") &&
                       Digest::SHA256.file(path).hexdigest == evidence.fetch("sha256")

        raise Error.new("sealed usage snapshot changed", code: :sealed_source_corrupt)
      end

      def safe_recovery_component!(value)
        string = value.to_s
        unless string.match?(/\A(?:state|data|project-[0-9a-f-]+)\z/)
          raise Error.new("sealed legacy home is unsafe", code: :sealed_source_corrupt)
        end
        string
      end

      def safe_recovery_relative!(value)
        string = value.to_s
        if string.empty? || string.start_with?(File::SEPARATOR) ||
           string.split(File::SEPARATOR).any? { |part| part.empty? || part == ".." || part == "." }
          raise Error.new("sealed legacy path is unsafe", code: :sealed_source_corrupt)
        end
        string
      end

      def contained_recovery_path!(root, home, relative)
        path = File.expand_path(File.join(root, home, relative))
        unless path.start_with?("#{root}#{File::SEPARATOR}")
          raise Error.new("sealed legacy path escaped its root", code: :sealed_source_corrupt)
        end
        path
      end

      def execution_fingerprint(database) = self.class.execution_fingerprint(database)

      def publish_phase(phase, projects, exclusions, task_authority, evidence)
        return load_phase(phase) if manifest_present?(phase)
        document = CutoverManifest.build(
          phase: phase, installation_id: cutover_id, lineage_id: cutover_id,
          source_release: @source_release, target_release: @target_release,
          roots: { "cutover" => evidence_root },
          required_absences: phase == "active" ? [] : [ File.basename(database_path) ],
          exclusions: exclusions, task_authority: task_authority, payloads: [],
          evidence: evidence.merge("projects" => projects.map { |project| project.fetch("project_id") })
        )
        manifest(phase).publish(document)
      end

      def ensure_no_live_database!
        return unless File.exist?(database_path)
        diagnosis = Database.new(path: database_path).diagnostics
        return if diagnosis.status == :missing
        raise Error.new(
          "runtime control plane already exists (#{diagnosis.status})", code: :database_already_present,
          action: "use hive runtime status or hive runtime resume"
        )
      end

      def reject_existing_run!
        return unless File.exist?(current_root)
        return if current_phase == "active"
        if current_phase.nil? && !File.exist?(sealed_root) && !File.exist?(fence_journal_path)
          FileUtils.rm_rf(current_root)
          @cutover_id = nil
          return
        end
        raise Error.new("an incomplete cutover already exists", code: :cutover_incomplete,
                        action: "run hive runtime resume")
      end

      def prepare_run!
        FileUtils.mkdir_p(evidence_root, mode: 0o700)
        Hive::AtomicFile.write(File.join(evidence_root, "anchor"), "#{cutover_id}\n", mode: 0o600)
        preflight_filesystems!
        fault!(:filesystem_preflighted)
      end

      def preflight_filesystems!
        roots = target_paths.map do |target|
          path = File.dirname(target.fetch(:live))
          path = File.dirname(path) until File.directory?(path)
          path
        end
        roots.concat([ File.dirname(database_path), File.dirname(Hive::Paths.runtime_payload_root(@state_home)) ])
        roots.uniq.each do |root|
          probe = File.join(root, ".hive-cutover-probe-#{cutover_id}")
          owned = false
          if File.exist?(probe) || File.symlink?(probe)
            raise Error.new("cutover filesystem probe is ambiguous", code: :storage_preflight_failed)
          end
          owned = true
          Hive::AtomicFile.write(probe, "#{cutover_id}\n", mode: 0o600)
          unless File.binread(probe) == "#{cutover_id}\n"
            raise Error.new("cutover filesystem probe changed", code: :storage_preflight_failed)
          end
          File.unlink(probe)
          Hive::AtomicFile.fsync_directory(root)
        ensure
          FileUtils.rm_f(probe) if owned
        end
      rescue SystemCallError, IOError => error
        raise Error.new(
          "cutover filesystem preflight failed: #{error.message}",
          code: :storage_preflight_failed,
          action: "verify permissions and free space on every Hive/project filesystem"
        )
      end

      def active_projects_from(document)
        ids = document.dig("evidence", "projects")
        projects = @projects.select { |project| ids.include?(project.fetch("project_id")) }
        unless projects.map { |project| project.fetch("project_id") }.sort == ids.sort
          raise ProjectError.new(
            "registered project set changed during cutover", code: :source_changed,
            action: "make the registered project set match the cutover manifest, then run hive runtime resume"
          )
        end
        projects
      end

      def result_for(phase)
        document = load_phase(phase).fetch("document")
        Result.new(phase, document.fetch("installation_id"), database_path, document.fetch("exclusions"))
      end

      def target_paths = global_target_paths + project_target_paths

      def global_target_paths
        @global_target_paths ||= TARGETS.map do |target|
          home = target.home == :state ? @state_home : @data_home
          { home: target.home, root: home, relative_path: target.relative_path,
            expected_type: target.expected_type, live: File.join(home, target.relative_path) }
        end
      end

      def project_target_paths
        projects = @active_projects || @projects.select do |project|
          File.directory?(project["path"].to_s) && File.directory?(project["hive_state_path"].to_s)
        end
        projects.flat_map do |project|
          label = "project-#{project.fetch('project_id')}"
          root = File.expand_path(project.fetch("path"))
          relatives = PROJECT_RUNTIME_FILES + Dir.glob(
            File.join(project.fetch("hive_state_path"), "stages", "*", "*")
          ).select { |path| File.directory?(path) }.flat_map do |task|
            TASK_RUNTIME_FILES.map { |name| File.join(task.delete_prefix("#{root}/"), name) }
          end
          relatives.map do |relative|
            { home: label, root: root, relative_path: relative, expected_type: :file,
              live: File.join(root, relative) }
          end
        end
      end

      def current_phase
        PHASES.reverse.find { |phase| manifest_present?(phase) }
      end

      def manifest(phase) = CutoverManifest.new(path: manifest_path(phase))
      def manifest_present?(phase)
        File.exist?(manifest_path(phase)) || File.symlink?(manifest_path(phase))
      end
      def load_phase(phase)
        envelope = manifest(phase).load
        unless envelope.dig("document", "phase") == phase
          raise Error.new(
            "cutover manifest phase does not match #{phase}", code: :activation_manifest_mismatch
          )
        end
        envelope
      end
      def manifest_path(phase) = File.join(current_root, "#{phase}.json")
      def current_root = File.join(@state_home, ".runtime-cutover", "current")
      def evidence_root = File.join(current_root, "evidence")
      def sealed_root = File.join(current_root, "sealed")
      def sealed_home(home) = File.join(sealed_root, home.to_s)
      def sealed_manifest_path = File.join(sealed_root, "manifest.json")
      def candidate_path = File.join(current_root, "candidate.sqlite3")
      def candidate_payload_root = File.join(current_root, "candidate-payloads")
      def sealed_usage_path = File.join(current_root, "sealed", "usage.snapshot.sqlite3")
      def fence_journal_path = File.join(current_root, "fences.json")
      def database_path = Hive::Paths.runtime_control_plane_path(@state_home)
      def cutover_id
        @cutover_id ||= if File.file?(File.join(evidence_root, "anchor"))
          File.binread(File.join(evidence_root, "anchor")).strip
        else
          @uuid_generator.call
        end
      end
      def activation_epoch = Integer(@clock.call.utc.strftime("%Y%m%d%H%M%S"))
      def digest(value) = Digest::SHA256.hexdigest(Codec.dump_json(value))
      def path_digest(path)
        status = File.lstat(path)
        raise Error.new("cutover source is a symlink", code: :unsafe_source) if status.symlink?
        return self.class.tree_digest(path) if status.directory?
        return Digest::SHA256.file(path).hexdigest if status.file? && status.nlink == 1

        raise Error.new("cutover source is unsafe", code: :unsafe_source)
      end
      def fault!(point) = @fault&.call(point)

      def write_fence_journal(entries)
        Hive::AtomicFile.write(fence_journal_path, "#{Codec.dump_json(entries)}\n", mode: 0o600)
      end

      def fence_plan
        return [] unless File.exist?(fence_journal_path) || File.symlink?(fence_journal_path)
        status = File.lstat(fence_journal_path)
        unless status.file? && !status.symlink? && status.nlink == 1 &&
               status.size <= MAX_MANIFEST_BYTES
          raise Error.new("cutover fence journal is unsafe", code: :recovery_metadata_corrupt)
        end
        value = Codec.load_json(File.binread(fence_journal_path).strip)
        expected = target_paths.map { |target| target.fetch(:live) }.sort
        unless value.is_a?(Array) && value.map { |entry| entry["path"] }.sort == expected &&
               value.all? do |entry|
                 entry.is_a?(Hash) &&
                   entry.keys.sort == %w[expected_type path source_present source_sha256 state] &&
                   %w[file directory].include?(entry["expected_type"]) &&
                   [ true, false ].include?(entry["source_present"]) &&
                   (!entry["source_present"] || entry["source_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)) &&
                   %w[planned applying applied].include?(entry["state"])
               end
          raise Error.new("cutover fence journal is invalid", code: :recovery_metadata_corrupt)
        end
        value
      rescue RuntimeControlPlane::Error, SystemCallError => error
        raise Error.new(
          "cutover fence journal is unavailable: #{error.message}",
          code: :recovery_metadata_corrupt
        )
      end

      def confirmation!
        raise ConfirmationRequired.new(
          "runtime cutover requires explicit confirmation", code: :confirmation_required,
          action: "hive migrate --all --yes"
        )
      end
    end
  end
end
