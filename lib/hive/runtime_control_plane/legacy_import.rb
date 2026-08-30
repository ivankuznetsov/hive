require "date"
require "digest"
require "json"
require "sequel"
require "yaml"
require "hive/runtime_control_plane"
require "hive/attempts/record"
require "hive/provider_health/event"
require "hive/provider_health/circuit"

module Hive
  module RuntimeControlPlane
    # Frozen, read-only decoder for the last filesystem-backed runtime layout.
    # It is intentionally absent from the normal RuntimeControlPlane entrypoint
    # and may be loaded only by explicit migration/recovery code.
    class LegacyImport
      MAX_SOURCE_BYTES = 4 * 1024 * 1024
      TERMINAL_ATTEMPT_STATES = %w[lost terminal].freeze
      DISPOSABLE_DOMAINS = %w[operational_projections].freeze
      ATTEMPT_ROOT_ENTRIES = %w[
        cold-logs decision-indexes generation-locks log-state logs maintenance
        outputs pending-finalization proof records routing-policies
      ].freeze
      SEMANTIC_ID_KEYS = %w[
        id attempt_id request_id result_id event_id reservation_id session_id
        task_id
      ].freeze

      Source = Data.define(:domain, :home, :relative_path, :kind)
      Result = Data.define(:records, :ledger, :digest) do
        def to_h
          { "records" => records, "ledger" => ledger, "digest" => digest }
        end
      end

      class Error < RuntimeControlPlane::Error
        attr_reader :path

        def initialize(message, code:, path: nil, details: {})
          super(message, code: code, action: "repair or explicitly exclude the source before cutover", details: details)
          @path = path
        end
      end

      class ClassificationError < Error; end
      class QuiescenceError < Error; end

      GLOBAL_SOURCES = [
        Source.new("dispatch_requests", :state, "dispatch_requests", :tree),
        Source.new("dispatch_results", :state, "dispatch_results", :tree),
        Source.new("attempts", :state, "attempts/v4/records", :tree),
        Source.new("retained_payloads", :state, "attempts/v4/logs", :payload_tree),
        Source.new("retained_payloads", :state, "attempts/v4/cold-logs", :payload_tree),
        Source.new("retained_payloads", :state, "attempts/v4/outputs", :payload_tree),
        Source.new("attempt_revisions", :state, "attempts/v4/log-state", :tree),
        Source.new("operational_projections", :state, "attempts/v4/maintenance", :tree),
        Source.new("attempt_revisions", :state, "attempts/v4/decision-indexes", :decision_tree),
        Source.new("task_leases", :state, "attempts/v4/generation-locks", :tree),
        Source.new("terminal_receipts", :state, "attempts/v4/proof", :tree),
        Source.new("terminal_pending", :state, "attempts/v4/pending-finalization", :tree),
        Source.new("routing_policies", :state, "attempts/v4/routing-policies", :tree),
        Source.new("task_counters", :state, "task-counter.yml", :file),
        Source.new("task_leases", :state, ".task-counter.lock", :file),
        Source.new("patrol_allowances", :data, "usage.db.patrol-discovery-allowances", :tree),
        Source.new("usage_sessions", :data, "usage.db", :sqlite),
        Source.new("operational_projections", :state, "operational", :tree)
      ].freeze

      PROJECT_SOURCES = [
        [ "pr_merge_reconciliations", ".hive-state/daemon/pr-merge-reconciliation.json", :file ]
      ].freeze
      PROJECT_BASENAMES = {
        ".lock" => "task_leases"
      }.freeze

      attr_reader :state_home, :data_home, :project_roots, :attempt_root, :usage_path,
                  :patrol_allowances_path, :project_names

      def initialize(state_home:, data_home:, project_roots: [], attempt_root: nil, usage_path: nil,
                     patrol_allowances_path: nil, project_names: {})
        @state_home = File.expand_path(state_home)
        @data_home = File.expand_path(data_home)
        @project_roots = Array(project_roots).map { |path| File.expand_path(path) }.uniq.sort.freeze
        @project_names = project_names.to_h.transform_keys { |path| File.expand_path(path) }.freeze
        @attempt_root = File.expand_path(
          attempt_root || environment_path("HIVE_ATTEMPT_STORE_ROOT") ||
            File.join(@state_home, "attempts", "v4")
        )
        @usage_path = File.expand_path(
          usage_path || environment_path("HIVE_USAGE_DB_PATH") || File.join(@data_home, "usage.db")
        )
        @patrol_allowances_path = File.expand_path(
          patrol_allowances_path || "#{@usage_path}.patrol-discovery-allowances"
        )
      end

      def call
        @records = Hash.new { |hash, key| hash[key] = [] }
        @ledger = []
        @semantic_identities = {}
        validate_attempt_root_layout!
        GLOBAL_SOURCES.each { |source| decode_global(source) }
        decode_provider_health(File.join(state_home, "provider-health", "v1"))
        project_roots.each { |root| decode_project(root) }
        normalized_records = @records.keys.sort.to_h do |domain|
          [ domain, @records.fetch(domain).sort_by { |record| canonical(record) }.freeze ]
        end.freeze
        normalized_ledger = @ledger.sort_by { |entry| entry.fetch("source_identity") }.freeze
        payload = { "records" => normalized_records, "ledger" => normalized_ledger }
        Result.new(normalized_records, normalized_ledger, Digest::SHA256.hexdigest(canonical(payload)))
      ensure
        @records = @ledger = @semantic_identities = nil
      end

      private

      def decode_global(source)
        path = global_source_path(source)
        case source.kind
        when :tree then decode_tree(source.domain, path, logical: source.relative_path)
        when :payload_tree then decode_payload_tree(source.domain, path, logical: source.relative_path)
        when :decision_tree then decode_decision_tree(path, logical: source.relative_path)
        when :file then decode_file_or_empty(source.domain, path, logical: source.relative_path)
        when :sqlite then decode_usage(path, logical: source.relative_path)
        end
      end

      def global_source_path(source)
        if source.relative_path.start_with?("attempts/v4/")
          return File.join(attempt_root, source.relative_path.delete_prefix("attempts/v4/"))
        end
        return usage_path if source.relative_path == "usage.db"
        return patrol_allowances_path if
          source.relative_path == "usage.db.patrol-discovery-allowances"

        root = source.home == :state ? state_home : data_home
        File.join(root, source.relative_path)
      end

      def decode_project(root)
        project = project_names.fetch(root, File.basename(root))
        PROJECT_SOURCES.each do |domain, relative, kind|
          path = File.join(root, relative)
          logical = "projects/#{project}/#{relative}"
          kind == :tree ? decode_tree(domain, path, logical: logical, project: project) :
            decode_file_or_empty(domain, path, logical: logical, project: project)
        end
        PROJECT_BASENAMES.each do |basename, domain|
          paths = safe_project_matches(root, basename)
          if paths.empty?
            record_empty(domain, "projects/#{project}/**/#{basename}")
          else
            paths.each do |path|
              logical = "projects/#{project}/#{path.delete_prefix(root + File::SEPARATOR)}"
              decode_file(domain, path, logical: logical, project: project)
            end
          end
        end
      end

      def safe_project_matches(root, basename)
        ensure_directory!(root)
        Dir.glob(File.join(root, "**", basename), File::FNM_DOTMATCH).sort.tap do |paths|
          paths.each { |path| ensure_ancestor_chain!(path, root) }
        end
      rescue Errno::ENOENT
        []
      end

      def decode_tree(domain, path, logical:, project: nil)
        status = optional_lstat(path)
        return record_empty(domain, logical) unless status
        unsafe!(path, :unsafe_source, "legacy source root must be a real directory") if
          status.symlink? || !status.directory?

        files = safe_files(path)
        return record_empty(domain, logical) if files.empty?

        files.each do |file|
          relative = file.delete_prefix(path + File::SEPARATOR)
          decode_file(domain, file, logical: File.join(logical, relative), project: project)
        end
      end

      def decode_file_or_empty(domain, path, logical:, project: nil)
        return record_empty(domain, logical) unless optional_lstat(path)

        decode_file(domain, path, logical: logical, project: project)
      end

      def decode_file(domain, path, logical:, project: nil)
        status = secure_file_status(path)
        return prove_lock_empty(domain, path, logical) if lock_file?(path)
        return decode_dispatch_sequence(path, logical, status) if
          domain == "dispatch_requests" && path.end_with?(".sequence")

        if File.basename(path).start_with?(".") && !path.end_with?(".claimed")
          raise ClassificationError.new(
            "unfinished legacy source remains at #{path}", code: :unfinished_source, path: path
          )
        end

        if domain == "task_leases"
          raise QuiescenceError.new(
            "active task lease remains at #{path}", code: :active_task_lease, path: path
          )
        end
        if domain == "dispatch_requests" && path.end_with?(".claimed")
          raise QuiescenceError.new(
            "claimed dispatch request remains at #{path}", code: :claimed_dispatch_request, path: path
          )
        end
        bytes = bounded_read(path, status)
        documents = parse_documents(path, bytes)
        documents.each_with_index do |document, index|
          validate_project!(document, project, path) if project
          validate_attempt_contract!(document, path) if domain == "attempts"
          validate_quiescence!(domain, document, path)
          logical_identity = documents.one? ? logical : "#{logical}##{index + 1}"
          record_document(domain, logical_identity, document, path: path)
        end
      rescue JSON::ParserError, Psych::Exception, EncodingError, TypeError => error
        raise ClassificationError.new(
          "legacy source is malformed at #{path}: #{error.message}",
          code: :malformed_source, path: path, details: { error_class: error.class.name }
        )
      end

      def decode_provider_health(root)
        status = optional_lstat(root)
        return record_empty("provider_health", "provider-health/v1") unless status
        unsafe!(root, :unsafe_source, "legacy provider-health root must be a real directory") if
          status.symlink? || !status.directory?
        files = safe_files(root)
        return record_empty("provider_health", "provider-health/v1") if files.empty?

        scopes = Hash.new do |hash, key|
          hash[key] = { journals: [], history: [], idempotency: {}, projection: nil }
        end
        files.each do |path|
          relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
          if relative == "mutation.lock"
            prove_lock_empty("provider_health", path, "provider-health/v1/#{relative}")
          elsif relative.start_with?("intents/")
            raise QuiescenceError.new(
              "in-flight provider probe intent remains at #{path}",
              code: :in_flight_probe, path: path
            )
          elsif relative.start_with?("quarantine/")
            raise ClassificationError.new(
              "quarantined provider-health evidence remains at #{path}",
              code: :quarantined_source, path: path
            )
          elsif (match = relative.match(%r{\Ascopes/(provider-account|model)/([0-9a-f]{64})/(journal\.jsonl|current\.json)\z}))
            key = [ match[1], match[2] ]
            if match[3] == "journal.jsonl"
              events = provider_events(path)
              scopes[key][:journals] << [ path, events ]
              provider_ledger(relative, "imported", events.map(&:to_h))
            else
              projection = provider_circuit(path)
              scopes[key][:projection] = projection
              provider_ledger(relative, "superseded", projection.to_h)
            end
          elsif (match = relative.match(%r{\Ahistory/(provider-account|model)/([0-9a-f]{64})/.+\.jsonl\z}))
            key = [ match[1], match[2] ]
            events = provider_events(path)
            scopes[key][:history].concat(events)
            provider_ledger(relative, "imported", events.map(&:to_h))
          elsif (match = relative.match(%r{\Aidempotency/(provider-account|model)/([0-9a-f]{64})/(.+\.json)\z}))
            key = [ match[1], match[2] ]
            entries = provider_idempotency(path)
            entries.each do |idempotency_key, event_id|
              previous = scopes[key][:idempotency][idempotency_key]
              if previous && previous != event_id
                raise ClassificationError.new(
                  "provider-health idempotency evidence conflicts at #{path}",
                  code: :duplicate_source_identity, path: path
                )
              end
              scopes[key][:idempotency][idempotency_key] = event_id
            end
            provider_ledger(relative, "imported", entries)
          else
            raise ClassificationError.new(
              "legacy provider-health source is unattributed at #{path}",
              code: :unattributed_source, path: path
            )
          end
        end
        scopes.sort.each do |(kind, key), state|
          unless state[:journals].one?
            raise ClassificationError.new(
              "provider-health scope has no unique current journal",
              code: :malformed_source, path: root
            )
          end
          current_events = state[:journals].first.last
          circuit = replay_provider_events(current_events, path: state[:journals].first.first)
          unless circuit.scope.key == key &&
                 (kind == "provider-account" ? circuit.scope.provider_account? : circuit.scope.model?)
            raise ClassificationError.new(
              "provider-health scope path does not match its journal", code: :cross_project_record,
              path: state[:journals].first.first
            )
          end
          if state[:projection] && state[:projection].to_h != circuit.to_h
            raise ClassificationError.new(
              "provider-health projection differs from its journal",
              code: :source_changed, path: state[:journals].first.first
            )
          end
          events_by_id = {}
          (state[:history] + current_events).each do |event|
            previous = events_by_id[event.event_id]
            if previous && previous.to_h != event.to_h
              raise ClassificationError.new(
                "provider-health event identity conflicts across retained journals",
                code: :duplicate_source_identity, path: root
              )
            end
            events_by_id[event.event_id] = event
          end
          events = events_by_id.values
          events.each do |event|
            mapped = state[:idempotency][event.idempotency_key]
            if mapped && mapped != event.event_id
              raise ClassificationError.new(
                "provider-health idempotency evidence differs from its event",
                code: :malformed_source, path: root
              )
            end
            state[:idempotency][event.idempotency_key] ||= event.event_id
          end
          missing = state[:idempotency].reject do |idempotency_key, event_id|
            events.any? { |event| event.idempotency_key == idempotency_key && event.event_id == event_id }
          end
          unless missing.empty?
            raise ClassificationError.new(
              "provider-health idempotency evidence has no retained audit event",
              code: :malformed_source, path: root
            )
          end
          classify_provider_circuit!(circuit, state[:journals].first.first)
          @records["provider_health"] << Codec.normalize(
            "circuit" => circuit.to_h,
            "events" => events.sort_by { |event| [ event.occurred_at, event.event_id ] }.map(&:to_h),
            "idempotency" => state[:idempotency]
          )
        end
      rescue Hive::ProviderHealth::Error, JSON::ParserError, KeyError, TypeError => error
        raise ClassificationError.new(
          "legacy provider-health state is malformed: #{error.message}",
          code: :malformed_source, path: root, details: { error_class: error.class.name }
        )
      end

      def provider_events(path)
        status = secure_file_status(path)
        lines = bounded_read(path, status).lines.reject { |line| line.strip.empty? }
        raise JSON::ParserError, "empty provider journal" if lines.empty?
        lines.map.with_index(1) do |line, sequence|
          event = Hive::ProviderHealth::Event.from_h(JSON.parse(line))
          raise Hive::ProviderHealth::Unavailable, "provider event sequence gap" unless
            event.sequence == sequence
          event
        end
      end

      def provider_circuit(path)
        Hive::ProviderHealth::Circuit.from_h(
          JSON.parse(bounded_read(path, secure_file_status(path)))
        )
      end

      def provider_idempotency(path)
        document = JSON.parse(bounded_read(path, secure_file_status(path)))
        entries = if document["schema"] == "hive-provider-health-idempotency-shard"
          unless document.keys.sort == %w[entries schema schema_version] && document["schema_version"] == 1
            raise JSON::ParserError, "invalid provider idempotency shard"
          end
          document.fetch("entries")
        else
          { document.fetch("idempotency_key") => document.fetch("event_id") }
        end
        unless entries.is_a?(Hash) && entries.all? do |key, event_id|
          key.to_s.match?(Hive::ProviderHealth::SHA256_PATTERN) && !event_id.to_s.empty?
        end
          raise JSON::ParserError, "invalid provider idempotency evidence"
        end
        entries
      end

      def replay_provider_events(events, path:)
        first = events.first
        unless %w[reset snapshot].include?(first.kind) ||
               (first.journal_epoch.zero? && first.previous_generation.zero?)
          raise Hive::ProviderHealth::Unavailable, "invalid provider journal genesis"
        end
        circuit = Hive::ProviderHealth::Circuit.closed(
          scope: first.scope, generation: first.previous_generation,
          journal_epoch: first.journal_epoch
        )
        events.each { |event| circuit = event.apply(circuit) }
        circuit
      rescue Hive::ProviderHealth::Error => error
        raise ClassificationError.new(
          "provider-health journal cannot be replayed: #{error.message}",
          code: :malformed_source, path: path
        )
      end

      def classify_provider_circuit!(circuit, path)
        if circuit.probe
          raise QuiescenceError.new(
            "in-flight provider probe remains at #{path}", code: :in_flight_probe, path: path
          )
        end
        record_empty("provider_probes", "provider-health/v1/#{circuit.scope.key}#probe")
      end

      def provider_ledger(relative, disposition, value)
        @ledger << ledger_entry(
          "provider_health", "provider-health/v1/#{relative}", disposition, value
        )
      end

      def decode_dispatch_sequence(path, logical, status)
        sequence = JSON.parse(bounded_read(path, status))
        request_id = sequence.fetch("request_id").to_s
        remaining = sequence.fetch("remaining_argvs")
        unless !request_id.empty? && remaining.is_a?(Array) && remaining.all? do |argv|
          argv.is_a?(Array) && !argv.empty? && argv.all? { |item| item.is_a?(String) }
        end
          raise ArgumentError
        end

        record_document(
          "dispatch_sequence", logical,
          { "request_id" => request_id, "remaining_argvs" => remaining },
          path: path
        )
      rescue ArgumentError, JSON::ParserError, KeyError
        raise ClassificationError.new(
          "dispatch sequence is malformed at #{path}", code: :malformed_source, path: path
        )
      end

      def decode_payload_tree(domain, path, logical:)
        status = optional_lstat(path)
        return record_empty(domain, logical) unless status
        unsafe!(path, :unsafe_source, "legacy payload root must be a real directory") if
          status.symlink? || !status.directory?
        files = safe_files(path)
        return record_empty(domain, logical) if files.empty?

        files.each do |file|
          relative = file.delete_prefix(path + File::SEPARATOR)
          before = secure_file_status(file)
          digest, size = digest_file(file, before, max_bytes: PayloadLimit)
          record_document(
            domain, File.join(logical, relative),
            {
              "legacy_path" => File.join(logical, relative),
              "attempt_id" => payload_attempt_id(relative),
              "size" => size,
              "sha256" => digest
            }.compact,
            path: file
          )
        end
      end

      def decode_decision_tree(path, logical:)
        status = optional_lstat(path)
        return record_empty("attempt_revisions", logical) unless status
        unsafe!(path, :unsafe_source, "legacy decision-index root must be a real directory") if
          status.symlink? || !status.directory?
        files = safe_files(path)
        return record_empty("attempt_revisions", logical) if files.empty?

        files.each do |file|
          relative = file.delete_prefix(path + File::SEPARATOR)
          if lock_file?(file)
            prove_lock_empty("task_leases", file, File.join(logical, relative))
            next
          end
          status = secure_file_status(file)
          documents = parse_documents(file, bounded_read(file, status))
          document = documents.first if documents.one?
          unless document.is_a?(Hash)
            raise ClassificationError.new(
              "legacy decision index is malformed at #{file}", code: :malformed_source, path: file
            )
          end
          normalized = Codec.normalize(document)
          kind = normalized["kind"] || relative.split(File::SEPARATOR).first
          domain = kind == "live-capacity" ? "capacity_reservations" : "attempt_revisions"
          validate_decision_quiescence!(kind, normalized, file)
          record_document(domain, File.join(logical, relative), normalized, path: file)
        end
      rescue JSON::ParserError, CodecError, EncodingError, TypeError => error
        raise ClassificationError.new(
          "legacy decision index is malformed at #{path}: #{error.message}",
          code: :malformed_source, path: path, details: { error_class: error.class.name }
        )
      end

      def validate_decision_quiescence!(kind, document, path)
        value = document["value"] || document
        if kind == "live-capacity"
          reservations = value["reservations"]
          unless reservations.is_a?(Hash) && reservations.empty?
            raise QuiescenceError.new(
              "active capacity reservation remains at #{path}",
              code: :active_capacity_reservation, path: path
            )
          end
        end
        return unless kind == "failure-cohorts"

        cohorts = value["cohorts"]
        active = cohorts.is_a?(Hash) && cohorts.values.any? do |cohort|
          cohort.is_a?(Hash) && !cohort["probe_attempt_id"].nil?
        end
        return unless active

        raise QuiescenceError.new(
          "in-flight failure-cohort probe remains at #{path}",
          code: :in_flight_probe, path: path
        )
      end

      def decode_usage(path, logical:)
        return record_empty("usage_sessions", logical) unless optional_lstat(path)

        before = secure_file_status(path)
        database = Sequel.connect(
          adapter: "sqlite", database: path, readonly: true, max_connections: 1
        )
        unless database.table_exists?(:token_usage)
          raise ClassificationError.new(
            "legacy usage database has no token_usage table", code: :malformed_source, path: path
          )
        end
        rows = database[:token_usage].order(:id).all
        after = File.lstat(path)
        unless file_snapshot(before) == file_snapshot(after)
          unsafe!(path, :source_changed, "legacy usage database changed while being read")
        end
        return record_empty("usage_sessions", logical) if rows.empty?

        rows.each do |row|
          record_document(
            "usage_sessions", "#{logical}##{row.fetch(:id)}",
            row.transform_keys(&:to_s), path: path
          )
        end
      rescue Sequel::Error => error
        raise ClassificationError.new(
          "legacy usage database is malformed: #{error.message}",
          code: :malformed_source, path: path, details: { error_class: error.class.name }
        )
      ensure
        database&.disconnect
      end

      def record_document(domain, logical, document, path:)
        unless document.is_a?(Hash)
          raise ClassificationError.new(
            "legacy source must decode to an object at #{path}", code: :malformed_source, path: path
          )
        end
        normalized = Codec.normalize(document)
        semantic = semantic_identity(domain, normalized, logical)
        if (previous = @semantic_identities[semantic])
          raise ClassificationError.new(
            "legacy #{domain} identity appears more than once: #{semantic.last}",
            code: :duplicate_source_identity, path: path, details: { previous: previous }
          )
        end
        @semantic_identities[semantic] = path
        disposition = if DISPOSABLE_DOMAINS.include?(domain) || superseded?(normalized)
          "superseded"
        else
          "imported"
        end
        @records[domain] << normalized unless disposition == "superseded"
        @ledger << ledger_entry(domain, logical, disposition, normalized)
        classify_probe(logical, normalized, path) if domain == "provider_health"
      end

      def record_empty(domain, logical)
        @records[domain]
        @ledger << ledger_entry(domain, "#{logical}:empty", "proven_empty", nil)
      end

      def ledger_entry(domain, identity, disposition, document)
        {
          "domain" => domain,
          "source_identity" => "#{domain}:#{identity}",
          "disposition" => disposition,
          "source_digest" => document && Digest::SHA256.hexdigest(canonical(document))
        }
      end

      def validate_quiescence!(domain, document, path)
        case domain
        when "attempts"
          return if TERMINAL_ATTEMPT_STATES.include?(document["state"])

          raise QuiescenceError.new(
            "live attempt remains at #{path}", code: :live_attempt, path: path,
            details: { attempt_id: document["attempt_id"], state: document["state"] }
          )
        when "capacity_reservations"
          reservations = document.dig("value", "reservations")
          return if reservations.is_a?(Hash) && reservations.empty?
          return if %w[released terminal superseded].include?(document["state"])

          raise QuiescenceError.new(
            "active capacity reservation remains at #{path}",
            code: :active_capacity_reservation, path: path
          )
        when "terminal_pending"
          return if superseded?(document)
          raise QuiescenceError.new(
            "pending task publication remains at #{path}",
            code: :pending_terminal_publication, path: path
          )
        end
      end

      def validate_attempt_contract!(document, path)
        return unless document["schema"] == Hive::Attempts::Record::SCHEMA

        Hive::Attempts::Record.new(document)
      rescue Hive::Attempts::InvalidRecord => error
        raise ClassificationError.new(
          "legacy attempt is invalid at #{path}: #{error.message}",
          code: :malformed_attempt, path: path,
          details: { error_class: error.class.name }
        )
      end

      def classify_probe(logical, document, path)
        if document["schema"] == "hive-provider-health-probe-intent"
          raise QuiescenceError.new(
            "in-flight provider probe intent remains at #{path}",
            code: :in_flight_probe, path: path
          )
        end

        probe = document["probe"] || document.dig("circuit", "probe")
        if probe.nil?
          record_empty("provider_probes", "#{logical}#probe")
          return
        end
        unless probe.is_a?(Hash)
          raise ClassificationError.new(
            "provider probe is malformed at #{path}", code: :malformed_source, path: path
          )
        end
        raise QuiescenceError.new(
          "in-flight provider probe remains at #{path}", code: :in_flight_probe, path: path
        )
      end

      def validate_project!(document, project, path)
        observed = document["project"] || document["project_slug"] || document.dig("task", "project")
        return if observed.nil? || observed.to_s == project

        raise ClassificationError.new(
          "legacy record under #{project} names project #{observed}",
          code: :cross_project_record, path: path
        )
      end

      def semantic_identity(domain, document, fallback)
        return [ domain, fallback ] if domain == "retained_payloads"

        key = SEMANTIC_ID_KEYS.find { |candidate| document[candidate].is_a?(String) && !document[candidate].empty? }
        [ domain, key ? "#{key}=#{document.fetch(key)}" : fallback ]
      end

      def superseded?(document)
        document["superseded"] == true || document["state"] == "superseded" ||
          document["status"] == "superseded"
      end

      def parse_documents(path, bytes)
        if path.end_with?(".jsonl")
          bytes.lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
        elsif path.end_with?(".yml", ".yaml")
          [ YAML.safe_load(bytes, permitted_classes: [ Date, Time ], aliases: false) ]
        else
          [ JSON.parse(bytes) ]
        end
      end

      def safe_files(root)
        pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
        files = []
        until pending.empty?
          path = pending.pop
          status = File.lstat(path)
          unsafe!(path, :unsafe_source, "legacy source contains a symlink") if status.symlink?
          if status.directory?
            Dir.children(path).sort.reverse_each { |name| pending << File.join(path, name) }
          elsif status.file?
            secure_file_status(path, status)
            files << path
          else
            unsafe!(path, :unsafe_source, "legacy source contains a non-regular entry")
          end
        end
        files
      rescue Errno::ENOENT
        unsafe!(root, :source_changed, "legacy source changed while being inventoried")
      end

      PayloadLimit = 256 * 1024 * 1024
      private_constant :PayloadLimit

      def digest_file(path, before, max_bytes:)
        unsafe!(path, :source_too_large, "legacy payload exceeds #{max_bytes} bytes") if
          before.size > max_bytes
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        digest = Digest::SHA256.new
        size = 0
        File.open(path, flags) do |file|
          opened = file.stat
          unless [ before.dev, before.ino ] == [ opened.dev, opened.ino ]
            unsafe!(path, :source_changed, "legacy payload changed before being opened")
          end
          while (chunk = file.read(64 * 1024))
            size += chunk.bytesize
            unsafe!(path, :source_too_large, "legacy payload exceeds #{max_bytes} bytes") if
              size > max_bytes
            digest.update(chunk)
          end
          after = file.stat
          after_path = File.lstat(path)
          expected = [ before.dev, before.ino, before.size, before.mtime, before.ctime, before.nlink ]
          unless [ after.dev, after.ino, after.size, after.mtime, after.ctime, after.nlink ] == expected &&
                 [ after_path.dev, after_path.ino, after_path.size, after_path.mtime,
                   after_path.ctime, after_path.nlink ] == expected
            unsafe!(path, :source_changed, "legacy payload changed while being read")
          end
        end
        [ digest.hexdigest, size ]
      rescue Errno::ELOOP
        unsafe!(path, :unsafe_source, "legacy payload became a symlink")
      end

      def payload_attempt_id(relative)
        basename = File.basename(relative)
        return basename.sub(/\.frames\z/, "") if basename.end_with?(".frames")

        relative.split(File::SEPARATOR).first
      end

      def lock_file?(path)
        basename = File.basename(path)
        basename.end_with?(".lock") || basename.start_with?(".request-lock-") ||
          path.split(File::SEPARATOR).include?("locks")
      end

      def prove_lock_empty(domain, path, logical)
        active_code = domain == "task_leases" ? :active_task_lease : :active_legacy_writer
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise QuiescenceError.new(
              "legacy writer lock is held at #{path}", code: active_code, path: path
            )
          end
          lock.flock(File::LOCK_UN)
        end
        record_empty(domain, "#{logical}#unlocked")
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        raise QuiescenceError.new(
          "legacy writer lock is held at #{path}", code: active_code, path: path
        )
      end

      def secure_file_status(path, status = File.lstat(path))
        unsafe!(path, :unsafe_source, "legacy source is a symlink") if status.symlink?
        unsafe!(path, :unsafe_source, "legacy source is not a regular file") unless status.file?
        unsafe!(path, :hardlink, "legacy source has multiple hard links") unless status.nlink == 1
        status
      end

      def bounded_read(path, before)
        unsafe!(path, :source_too_large, "legacy source exceeds #{MAX_SOURCE_BYTES} bytes") if
          before.size > MAX_SOURCE_BYTES
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          unless [ before.dev, before.ino ] == [ opened.dev, opened.ino ]
            unsafe!(path, :source_changed, "legacy source changed before being opened")
          end
          bytes = file.read(MAX_SOURCE_BYTES + 1)
          unsafe!(path, :source_too_large, "legacy source exceeds #{MAX_SOURCE_BYTES} bytes") if
            bytes.bytesize > MAX_SOURCE_BYTES
          after = file.stat
          after_path = File.lstat(path)
          expected = [ before.dev, before.ino, before.size, before.mtime, before.ctime, before.nlink ]
          unless [ after.dev, after.ino, after.size, after.mtime, after.ctime, after.nlink ] == expected &&
                 [ after_path.dev, after_path.ino, after_path.size, after_path.mtime,
                   after_path.ctime, after_path.nlink ] == expected
            unsafe!(path, :source_changed, "legacy source changed while being read")
          end
          bytes
        end
      rescue Errno::ELOOP
        unsafe!(path, :unsafe_source, "legacy source became a symlink")
      end

      def ensure_directory!(path)
        status = File.lstat(path)
        unsafe!(path, :unsafe_source, "project source must be a real directory") if
          status.symlink? || !status.directory?
      end

      def validate_attempt_root_layout!
        root = attempt_root
        status = optional_lstat(root)
        return unless status
        unsafe!(root, :unsafe_source, "legacy attempt root must be a real directory") if
          status.symlink? || !status.directory?
        unknown = Dir.children(root) - ATTEMPT_ROOT_ENTRIES
        return if unknown.empty?

        raise ClassificationError.new(
          "legacy attempt root contains unattributed entries: #{unknown.sort.join(', ')}",
          code: :unattributed_source, path: root, details: { entries: unknown.sort }
        )
      end

      def ensure_contained!(path, root)
        expanded = File.expand_path(path)
        return if expanded.start_with?(root + File::SEPARATOR)

        unsafe!(path, :path_escape, "legacy source escaped its project root")
      end

      def ensure_ancestor_chain!(path, root)
        ensure_contained!(path, root)
        relative = path.delete_prefix(root + File::SEPARATOR)
        current = root
        relative.split(File::SEPARATOR)[0...-1].each do |component|
          current = File.join(current, component)
          status = File.lstat(current)
          unsafe!(current, :unsafe_source, "project source traverses a symlink") if
            status.symlink? || !status.directory?
        end
      end

      def file_snapshot(status)
        [ status.dev, status.ino, status.size, status.mtime, status.ctime, status.nlink ]
      end

      def unsafe!(path, code, message)
        raise ClassificationError.new(message, code: code, path: path)
      end

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def canonical(value)
        Codec.dump_json(value)
      end

      def environment_path(name)
        value = ENV[name]
        return nil if value.nil? || value.empty?

        value
      end
    end
  end
end
