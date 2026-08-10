require "date"
require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/finalization_maintenance"
require "hive/attempts/record"
require "hive/attempts/storage_health"
require "hive/attempts/store"
require "hive/paths"

module Hive
  module Recovery
    # Forward-only recovery cutover. Attempt records remain schema v3; only
    # their physical layout changes from the scan-only v2 tree to the split v3
    # store. Runtime code opens v3 only and v2 becomes an old-binary fence.
    class Migration
      class Error < Hive::Error; end

      RECEIPT_SCHEMA = "hive-recovery-migration".freeze
      RECEIPT_VERSION = 4
      RECEIPT_BASENAME = "recovery-migration-v4.json".freeze
      PRIOR_RECEIPT_BASENAMES = %w[
        recovery-migration-v2.json recovery-migration-v3.json
      ].freeze
      # Keep the historic lock name: released recovery migrations and this
      # layout cutover must never mutate the same state home concurrently.
      LOCK_BASENAME = ".recovery-migration-v2.lock".freeze

      FENCE_SCHEMA = "hive-attempt-layout-fence".freeze
      FENCE_VERSION = 1
      FENCE_PAYLOAD = {
        "schema" => FENCE_SCHEMA,
        "schema_version" => FENCE_VERSION,
        "target" => "v3"
      }.freeze
      CHECKPOINT_SCHEMA = "hive-attempt-layout-cutover".freeze
      CHECKPOINT_VERSION = 1
      CHECKPOINT_BASENAME = ".v3-cutover.json".freeze
      CHECKPOINT_PHASES = { "fenced" => 1, "verified" => 2, "complete" => 3 }.freeze

      CURRENT_ATTEMPT_VERSION = Hive::Attempts::Record::SCHEMA_VERSION
      CURRENT_REQUEST_VERSION = 4
      CURRENT_RESULT_VERSION = 2
      MAX_RECORD_BYTES = 4 * 1024 * 1024
      ATTEMPT_ROOT_ENTRIES = %w[
        records logs outputs generation-locks proof decision-indexes
        pending-finalization cold-logs log-state maintenance
      ].freeze
      RECEIPT_REQUIRED_KEYS = %w[
        completed_at attempts dispatch_requests dispatch_results
      ].freeze
      REQUEST_DEFAULTS = {
        "task_generation" => nil, "predecessor_attempt_id" => nil,
        "inherited_outputs" => [], "recovery" => nil
      }.freeze
      RESULT_DEFAULTS = {
        "attempt_id" => nil, "attempt_state" => nil, "receipt" => nil
      }.freeze

      attr_reader :state_home

      def self.ensure!(state_home: Hive::Paths.state_home, now: Time.now.utc)
        new(state_home: state_home).call(now: now)
      end

      def initialize(state_home:)
        @state_home = File.expand_path(state_home)
      end

      def call(now: Time.now.utc)
        prepare_private_directory!(state_home)
        result = with_recovery_lock do
          reject_obsolete_attempt_root!
          next read_receipt if complete?

          attempts = migrate_attempts!(now: now.utc)
          receipt = {
            "schema" => RECEIPT_SCHEMA,
            "schema_version" => RECEIPT_VERSION,
            "completed_at" => now.utc.iso8601(6),
            "attempts" => attempts,
            "dispatch_requests" => migrate_dispatch_requests!,
            "dispatch_results" => migrate_dispatch_results!
          }
          write_json!(receipt_path, receipt)
          Hive::AtomicFile.fsync_directory(state_home)
          remove_prior_receipts!
          receipt
        end
        storage_health.complete_migration(
          now: Time.iso8601(result.fetch("completed_at")),
          result: result.fetch("attempts")
        )
        result
      rescue Error => error
        record_migration_failure(error, now: now)
        raise
      rescue JSON::ParserError, SystemCallError, IOError,
             Hive::Attempts::InvalidRecord, Hive::Attempts::StoreError => error
        wrapped = Error.new("recovery migration failed: #{error.message}")
        record_migration_failure(wrapped, now: now)
        raise wrapped
      end

      private

      def with_recovery_lock
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          validate_open_regular_file!(lock, lock_path, label: "recovery migration lock")
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise Error, "recovery migration lock is a symlink"
      end

      def complete?
        return false unless regular_file?(receipt_path)

        validate_attempts_parent!
        validate_fence!
        validate_attempt_root_directory!(current_attempt_root)
        read_checkpoint!(minimum_phase: "complete")
        true
      end

      def read_receipt
        data = parse_object!(receipt_path)
        valid = data["schema"] == RECEIPT_SCHEMA &&
          data["schema_version"] == RECEIPT_VERSION &&
          data["completed_at"].is_a?(String) &&
          RECEIPT_REQUIRED_KEYS.drop(1).all? { |key| data[key].is_a?(Hash) }
        raise Error, "recovery migration receipt is invalid" unless valid

        data
      end

      def migrate_attempts!(now:)
        source = cut_over_layout!
        store = Hive::Attempts::Store.new(root: current_attempt_root)
        checkpoint = read_checkpoint!

        if phase_before?(checkpoint, "verified")
          observed = corpus_summary(current_attempt_root)
          assert_same_corpus!(source, observed)
          scan = store.scan
          assert_scan_counts!(source, scan)
          view = Hive::Attempts::AdmissionView.new(store: store, hot_scan: scan)
          store.with_admission_lock { view.refresh_for_admission }
          parity = verify_exact_parity!(store, scan, now: now)
          checkpoint = write_checkpoint!(
            source.merge(
              "phase" => "verified",
              "decision_digest" => parity.fetch("digest"),
              "decision_count" => parity.fetch("count")
            )
          )
        end

        promoted = promote_historical_finals!(store)
        remaining = store.scan
        checkpoint = write_checkpoint!(checkpoint.merge(
          "phase" => "complete",
          "promoted_count" => checkpoint.fetch("promoted_count", 0) + promoted,
          "hot_count" => remaining.records.size,
          "invalid_count" => remaining.invalid_records.size
        ))

        {
          "source_count" => checkpoint.fetch("source_count"),
          "source_digest" => checkpoint.fetch("source_digest"),
          "decision_count" => checkpoint.fetch("decision_count", 0),
          "decision_digest" => checkpoint["decision_digest"],
          "promoted" => checkpoint.fetch("promoted_count"),
          "hot" => checkpoint.fetch("hot_count"),
          "invalid" => checkpoint.fetch("invalid_count")
        }
      end

      def cut_over_layout!
        validate_attempts_parent!
        old = optional_lstat(legacy_attempt_root)
        current = optional_lstat(current_attempt_root)

        if old&.directory? && current&.directory?
          unless remove_empty_old_skeleton!
            raise Error,
                  "both attempts/v2 and attempts/v3 contain material state; " \
                  "preserve both roots and resolve the collision before retrying"
          end
          old = nil
        end

        if old && !old.directory?
          validate_fence!
          raise Error, "attempts/v2 fence exists without its attempts/v3 target" unless current&.directory?
        elsif current && !current.directory?
          raise Error, "attempts/v3 path is not a real directory"
        end

        checkpoint = read_checkpoint!
        source = checkpoint_source(checkpoint) if checkpoint && !phase_before?(checkpoint, "verified")
        if old&.directory?
          with_quiesced_source(legacy_attempt_root) do
            validate_attempt_tree!(legacy_attempt_root, normalize_modes: true)
            scan = Hive::Attempts::Store.new(
              root: legacy_attempt_root, create_directories: false
            ).scan
            refuse_live_attempts!(scan)
            source = corpus_summary(legacy_attempt_root)
            assert_scan_counts!(source, scan)
            File.rename(legacy_attempt_root, current_attempt_root)
            Hive::AtomicFile.fsync_directory(attempts_parent)
            publish_fence!
          end
        elsif current&.directory?
          validate_current_root!(normalize_modes: phase_before?(checkpoint, "verified"))
          observed = corpus_summary(current_attempt_root) unless source
          if checkpoint
            assert_same_corpus!(checkpoint_source(checkpoint), observed) if observed
            source ||= checkpoint_source(checkpoint)
          else
            source = observed
          end
          publish_fence! unless old
        else
          Dir.mkdir(current_attempt_root, 0o700)
          Hive::AtomicFile.fsync_directory(attempts_parent)
          source = corpus_summary(current_attempt_root)
          publish_fence!
        end
        write_checkpoint!(source.merge("phase" => "fenced")) unless checkpoint
        source
      end

      def with_quiesced_source(root)
        locks_root = File.join(root, "generation-locks")
        prepare_private_directory!(locks_root)
        admission = File.join(locks_root, "admission.lock")
        File.open(admission, lock_flags, 0o600) { } unless File.exist?(admission)
        paths = safe_tree_entries(root).select do |path, status|
          status.file? && File.basename(path).end_with?(".lock")
        end.map(&:first)
        paths.unshift(admission)
        paths.uniq!
        paths.sort_by! { |path| path == admission ? "" : path }

        locks = paths.map do |path|
          lock = File.open(path, lock_flags, 0o600)
          validate_open_regular_file!(lock, path, label: "attempt writer lock")
          lock.chmod(0o600)
          acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error, "active attempt writer holds #{path}; retry after it exits" unless acquired

          lock
        rescue StandardError
          lock&.close
          raise
        end
        yield
      ensure
        Array(locks).reverse_each do |lock|
          lock.flock(File::LOCK_UN) rescue nil
          lock.close rescue nil
        end
      end

      def refuse_live_attempts!(scan)
        live = scan.records.find(&:live?)
        return unless live

        raise Error,
              "live attempt #{live.attempt_id} in attempts/v2 must finish before cutover"
      end

      def promote_historical_finals!(store)
        maintenance = Hive::Attempts::FinalizationMaintenance.new(store: store)
        ordered_records(store.scan.records).count do |record|
          consumers = record.state == "lost" ?
            Hive::Attempts::FinalizationMaintenance::LOST_CONSUMERS :
            Hive::Attempts::FinalizationMaintenance::TERMINAL_CONSUMERS
          pending = store.pending_finalizations.fetch(record.attempt_id)
          unless pending
            next false unless maintenance.prepare(record)
            pending = store.pending_finalizations.fetch(record.attempt_id)
          end
          unless pending.fetch("consumers").keys.sort == consumers.sort
            raise Error, "historical finalization obligations conflict for #{record.attempt_id}"
          end
          pending.fetch("consumers").each do |consumer, acknowledged|
            maintenance.acknowledge(record, consumer) unless acknowledged
          end
          maintenance.promote(record)
        end
      end

      def verify_exact_parity!(store, scan, now:)
        records = ordered_records(scan.records)
        index = store.decision_index
        decisions = []
        compare = lambda do |kind, key, expected, actual|
          unless expected == actual
            raise Error,
                  "attempt index parity mismatch for #{kind} #{key}: " \
                  "scan=#{expected.inspect} index=#{actual.inspect}"
          end
          decisions << [ kind, key, expected ]
        end

        records.select { |record| record.state == "terminal" }
               .group_by { |record| record["request_id"] }.sort.each do |request, candidates|
          compare.call(
            "request", request, candidates.last.attempt_id,
            index.terminal_attempt_id(request_id: request)
          )
        end
        records.select { |record| record.state == "terminal" && record.outcome == "succeeded" }
               .group_by { |record| semantic_key(record) }.sort.each do |key, candidates|
          record = candidates.last
          compare.call(
            "semantic", key, record.attempt_id,
            index.successful_attempt_id(task_generation: record.task_generation, subject: record.subject)
          )
        end
        successors = records.select { |record| record["predecessor_attempt_id"] }
                            .group_by { |record| record["predecessor_attempt_id"] }
        resolved = successors.keys.to_h { |attempt_id| [ attempt_id, true ] }
        records.select { |record| record.state == "lost" && !resolved[record.attempt_id] }
               .group_by { |record| semantic_key(record) }.sort.each do |key, candidates|
          record = candidates.last
          compare.call(
            "loss", key, record.attempt_id,
            index.unresolved_loss_attempt_id(task_generation: record.task_generation, subject: record.subject)
          )
        end
        successors.sort.each do |predecessor, candidates|
          compare.call(
            "successor", predecessor, candidates.last.attempt_id,
            index.successor_attempt_id(predecessor_attempt_id: predecessor)
          )
        end

        expected = Hive::Attempts::CapacitySnapshot.build(store: store, scan: scan, now: now)
        actual = Hive::Attempts::CapacitySnapshot.build_from_live_reservations(
          scan: scan, reservations: index.live_reservations,
          daily_counts: index.daily_counts(date: now.utc.to_date)
        )
        expected_capacity = capacity_decision(expected, date: now.utc.to_date)
        actual_capacity = capacity_decision(actual, date: now.utc.to_date)
        compare.call("capacity", now.utc.to_date.iso8601, expected_capacity, actual_capacity)

        { "count" => decisions.size,
          "digest" => Digest::SHA256.hexdigest(Hive::Attempts::StorageKey.dump(decisions)) }
      end

      def capacity_decision(snapshot, date:)
        {
          "global" => snapshot.global_count,
          "projects" => snapshot.per_project.sort,
          "tasks" => snapshot.per_task.map { |(project, task), count| [ project, task, count ] }.sort,
          "daily" => snapshot.daily_counts.filter_map do |(project, observed), count|
            [ project, count ] if observed == date
          end.sort,
          "reserved" => snapshot.reserved_attempt_ids.sort,
          "invalid" => snapshot.invalid_count
        }
      end

      def semantic_key(record)
        Hive::Attempts::StorageKey.dump(
          "task_generation" => record.task_generation, "subject" => record.subject
        ).strip
      end

      def ordered_records(records)
        records.sort_by do |record|
          [ record["accepted_at"], record.lease_version, record.attempt_id ]
        end
      end

      def corpus_summary(root)
        records_root = File.join(root, "records")
        digest = Digest::SHA256.new
        count = 0
        valid = 0
        invalid = 0
        if File.directory?(records_root)
          Dir.children(records_root).sort.each do |basename|
            path = File.join(records_root, basename)
            status = File.lstat(path)
            unless status.file? && !status.symlink? && basename.end_with?(".json")
              raise Error, "attempt records contain a non-record entry at #{path}"
            end
            bytes = bounded_read(path, MAX_RECORD_BYTES)
            digest << basename << "\0" << bytes.bytesize.to_s << "\0"
            digest << Digest::SHA256.digest(bytes)
            count += 1
            begin
              data = JSON.parse(bytes)
              if data.is_a?(Hash) && data["schema"] == Hive::Attempts::Record::SCHEMA &&
                 data["schema_version"] != CURRENT_ATTEMPT_VERSION
                raise Error,
                      "#{path} has unsupported attempt schema #{data['schema_version'].inspect}; " \
                      "only schema v3 can move to attempts/v3"
              end
              Hive::Attempts::Record.new(data)
              valid += 1
            rescue JSON::ParserError, Hive::Attempts::InvalidRecord, TypeError
              invalid += 1
            end
          end
        end
        {
          "source_count" => count,
          "source_valid_count" => valid,
          "source_invalid_count" => invalid,
          "source_digest" => digest.hexdigest
        }
      end

      def assert_scan_counts!(source, scan)
        expected_valid = source.fetch("source_valid_count")
        expected_invalid = source.fetch("source_invalid_count")
        return if scan.records.size == expected_valid &&
                  scan.invalid_records.size == expected_invalid

        raise Error, "attempt source corpus changed while it was being validated"
      end

      def assert_same_corpus!(expected, actual)
        keys = %w[source_count source_valid_count source_invalid_count source_digest]
        return if keys.all? { |key| expected.fetch(key) == actual.fetch(key) }

        raise Error, "attempt source corpus does not match its cutover checkpoint"
      end

      def checkpoint_source(checkpoint)
        checkpoint.slice(
          "source_count", "source_valid_count", "source_invalid_count", "source_digest"
        )
      end

      def read_checkpoint!(minimum_phase: nil)
        return nil unless regular_file?(checkpoint_path)

        data = parse_object!(checkpoint_path)
        required = %w[
          schema schema_version phase source_count source_valid_count
          source_invalid_count source_digest
        ]
        valid = required.all? { |key| data.key?(key) } &&
          data["schema"] == CHECKPOINT_SCHEMA &&
          data["schema_version"] == CHECKPOINT_VERSION &&
          CHECKPOINT_PHASES.key?(data["phase"]) &&
          %w[source_count source_valid_count source_invalid_count].all? do |key|
            data[key].is_a?(Integer) && data[key] >= 0
          end && /\A[0-9a-f]{64}\z/.match?(data["source_digest"].to_s)
        raise Error, "attempt layout cutover checkpoint is invalid" unless valid
        if minimum_phase && CHECKPOINT_PHASES.fetch(data["phase"]) < CHECKPOINT_PHASES.fetch(minimum_phase)
          raise Error, "attempt layout cutover checkpoint is incomplete"
        end

        data
      end

      def write_checkpoint!(values)
        data = {
          "schema" => CHECKPOINT_SCHEMA,
          "schema_version" => CHECKPOINT_VERSION
        }.merge(values)
        write_json!(checkpoint_path, data)
        Hive::AtomicFile.fsync_directory(attempts_parent)
        data
      end

      def phase_before?(checkpoint, phase)
        checkpoint.nil? ||
          CHECKPOINT_PHASES.fetch(checkpoint.fetch("phase")) < CHECKPOINT_PHASES.fetch(phase)
      end

      def publish_fence!
        status = optional_lstat(legacy_attempt_root)
        return validate_fence! if status

        write_json!(legacy_attempt_root, FENCE_PAYLOAD)
        Hive::AtomicFile.fsync_directory(attempts_parent)
        validate_fence!
      end

      def validate_fence!
        status = File.lstat(legacy_attempt_root)
        if status.symlink? || !status.file?
          raise Error, "attempts/v2 old-binary fence is not a real regular file"
        end
        validate_owner!(status, legacy_attempt_root)
        unless (status.mode & 0o777) == 0o600
          raise Error, "attempts/v2 old-binary fence mode must be 0600"
        end
        unless parse_object!(legacy_attempt_root) == FENCE_PAYLOAD
          raise Error, "attempts/v2 old-binary fence is invalid or colliding"
        end

        true
      rescue Errno::ENOENT
        raise Error, "attempts/v2 old-binary fence is missing"
      rescue JSON::ParserError
        raise Error, "attempts/v2 old-binary fence is invalid or colliding"
      end

      def validate_attempts_parent!
        prepare_private_directory!(attempts_parent)
      end

      def validate_current_root!(normalize_modes:)
        validate_attempt_tree!(current_attempt_root, normalize_modes: normalize_modes)
      end

      def validate_attempt_root_directory!(root)
        status = File.lstat(root)
        if status.symlink? || !status.directory?
          raise Error, "attempt root #{root} is not a real directory"
        end
        validate_owner!(status, root)
        status
      end

      def validate_attempt_tree!(root, normalize_modes:)
        status = validate_attempt_root_directory!(root)
        File.chmod(0o700, root) if normalize_modes && (status.mode & 0o777) != 0o700
        children = Dir.children(root)
        unknown = children - ATTEMPT_ROOT_ENTRIES
        unless unknown.empty?
          raise Error, "attempt root contains unknown layout entries: #{unknown.sort.join(', ')}"
        end

        safe_tree_entries(root).each do |path, entry|
          validate_owner!(entry, path)
          if entry.directory?
            File.chmod(0o700, path) if normalize_modes && (entry.mode & 0o777) != 0o700
          elsif entry.file?
            File.chmod(0o600, path) if normalize_modes && (entry.mode & 0o777) != 0o600
          else
            raise Error, "attempt tree contains a non-regular entry at #{path}"
          end
        end
        true
      end

      def safe_tree_entries(root)
        entries = []
        pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
        until pending.empty?
          path = pending.pop
          status = File.lstat(path)
          raise Error, "attempt tree contains a symlink at #{path}" if status.symlink?

          entries << [ path, status ]
          if status.directory?
            Dir.children(path).sort.reverse_each do |name|
              pending << File.join(path, name)
            end
          end
        end
        entries
      end

      def remove_empty_old_skeleton!
        validate_attempt_tree!(legacy_attempt_root, normalize_modes: true)
        directories = safe_tree_entries(legacy_attempt_root).filter_map do |path, status|
          return false unless status.directory?

          path
        end
        directories.sort_by { |path| -path.count(File::SEPARATOR) }.each { |path| Dir.rmdir(path) }
        Dir.rmdir(legacy_attempt_root)
        Hive::AtomicFile.fsync_directory(attempts_parent)
        true
      rescue Errno::ENOTEMPTY
        false
      end

      def reject_obsolete_attempt_root!
        status = optional_lstat(obsolete_attempt_root)
        return unless status

        raise Error,
              "unsupported attempts/v1 state remains at #{obsolete_attempt_root}; " \
              "this forward-only cutover accepts schema-v3 records from attempts/v2 only"
      end

      def migrate_dispatch_requests!
        migrate_queue(
          dispatch_requests_root, "hive-dispatch-request",
          current: CURRENT_REQUEST_VERSION, legacy: [ 1, 2, 3 ],
          defaults: REQUEST_DEFAULTS, include_claimed: true
        )
      end

      def migrate_dispatch_results!
        migrate_queue(
          dispatch_results_root, "hive-dispatch-result",
          current: CURRENT_RESULT_VERSION, legacy: [ 1 ], defaults: RESULT_DEFAULTS
        )
      end

      def migrate_queue(root, schema, current:, legacy:, defaults:, include_claimed: false)
        return { "migrated" => 0 } unless File.directory?(root)

        suffixes = include_claimed ? [ ".json", ".json.claimed" ] : [ ".json" ]
        migrated = Dir.children(root).sort.count do |basename|
          next false unless suffixes.any? { |suffix| basename.end_with?(suffix) }

          path = File.join(root, basename)
          data = parse_queue_object(path)
          next false unless data&.fetch("schema", nil) == schema
          next false if data["schema_version"] == current
          next false unless legacy.include?(data["schema_version"])

          defaults.each { |key, value| data[key] = value unless data.key?(key) }
          data["schema_version"] = current
          write_json!(path, data)
          true
        end
        { "migrated" => migrated }
      rescue Errno::ENOENT
        { "migrated" => 0 }
      end

      def parse_queue_object(path)
        data = JSON.parse(File.binread(path))
        data if data.is_a?(Hash)
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def remove_prior_receipts!
        PRIOR_RECEIPT_BASENAMES.each do |basename|
          path = File.join(state_home, basename)
          next unless File.exist?(path)

          File.unlink(path)
        end
        Hive::AtomicFile.fsync_directory(state_home)
      end

      def prepare_private_directory!(path)
        status = optional_lstat(path)
        if status
          if status.symlink? || !status.directory?
            raise Error, "migration directory #{path} is not a real directory"
          end
          validate_owner!(status, path)
        else
          FileUtils.mkdir_p(path, mode: 0o700)
        end
        File.chmod(0o700, path)
        path
      end

      def validate_owner!(status, path)
        return if status.uid == Process.euid

        raise Error, "attempt state has the wrong owner at #{path}"
      end

      def validate_open_regular_file!(io, path, label:)
        opened = io.stat
        entry = File.lstat(path)
        valid = opened.file? && entry.file? && !entry.symlink? &&
          opened.dev == entry.dev && opened.ino == entry.ino
        raise Error, "#{label} is not a real regular file" unless valid
        validate_owner!(entry, path)
      end

      def bounded_read(path, max_bytes)
        size = File.stat(path).size
        raise Error, "attempt record #{path} exceeds #{max_bytes} bytes" if size > max_bytes

        File.binread(path)
      end

      def parse_object!(path)
        data = JSON.parse(File.binread(path))
        raise Error, "#{path} must contain a JSON object" unless data.is_a?(Hash)

        data
      end

      def write_json!(path, data)
        Hive::AtomicFile.write(path, JSON.generate(data) + "\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def regular_file?(path)
        status = optional_lstat(path)
        status && status.file? && !status.symlink?
      end

      def lock_flags
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags
      end

      def attempts_parent = File.join(state_home, "attempts")
      def obsolete_attempt_root = File.join(attempts_parent, "v1")
      def legacy_attempt_root = File.join(attempts_parent, "v2")
      def current_attempt_root = File.join(attempts_parent, "v3")
      def storage_health
        Hive::Attempts::StorageHealth.new(
          root: File.join(current_attempt_root, "maintenance")
        )
      end

      def record_migration_failure(error, now:)
        root = File.join(current_attempt_root, "maintenance")
        return unless File.directory?(root) && !File.symlink?(root)

        Hive::Attempts::StorageHealth.new(
          root: root,
          create_directories: false
        ).fail_migration(error: error, now: now)
      rescue StandardError
        nil
      end

      def checkpoint_path = File.join(attempts_parent, CHECKPOINT_BASENAME)
      def dispatch_requests_root = File.join(state_home, "dispatch_requests")
      def dispatch_results_root = File.join(state_home, "dispatch_results")
      def receipt_path = File.join(state_home, RECEIPT_BASENAME)
      def lock_path = File.join(state_home, LOCK_BASENAME)
    end
  end
end
