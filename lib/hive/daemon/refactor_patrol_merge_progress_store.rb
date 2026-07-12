require "digest"
require "json"
require "time"
require "uri"
require "hive/atomic_file"

module Hive
  module Daemon
    # Durable, identity-bound continuation state for incremental merge intake.
    # The authoritative reconciler checkpoint remains schema v2; this sidecar
    # can be discarded only after its base-checkpoint fingerprint is stale.
    class RefactorPatrolMergeProgressStore
      SCHEMA = "hive-refactor-patrol-reconciler-progress".freeze
      SCHEMA_VERSION = 1
      KEYS = %w[
        schema schema_version registration host repository default_branch
        base_checkpoint_sha256 scan retry updated_at
      ].freeze
      SCAN_KEYS = %w[
        phase merged_since merged_until result_count cursor items seen_cursors
        started_at ingest_index enqueued_prs
      ].freeze
      RETRY_KEYS = %w[failures not_before last_error].freeze
      CHECKPOINT_KEYS = %w[
        schema schema_version registration host repository default_branch high_water
        overlap_occurrences seeded_at updated_at
      ].freeze
      DEFAULT_BACKOFF_BASE_SEC = 5.0
      DEFAULT_BACKOFF_MAX_SEC = 300.0

      class Invalid < Hive::Error; end

      def initialize(dry_run: false, backoff_base_sec: DEFAULT_BACKOFF_BASE_SEC,
                     backoff_max_sec: DEFAULT_BACKOFF_MAX_SEC, jitter: nil)
        @dry_run = dry_run
        @backoff_base_sec = positive_float!(backoff_base_sec, "backoff base")
        @backoff_max_sec = positive_float!(backoff_max_sec, "backoff maximum")
        if @backoff_max_sec < @backoff_base_sec
          raise ArgumentError, "refactor patrol merge backoff maximum cannot be below its base"
        end
        @jitter = jitter || -> { Random.rand }
        @transient = {}
      end

      def path(project_root)
        File.join(project_root, ".hive-state", "refactor_patrol", "v2", "reconciler-progress.json")
      end

      def load(project_root)
        key = File.expand_path(project_root)
        return @transient[key] if @dry_run

        progress_path = path(project_root)
        return nil unless File.file?(progress_path)

        raw = File.binread(progress_path)
        data = JSON.parse(raw)
        validate!(data)
        data
      rescue Invalid => e
        quarantine(project_root, raw.to_s, reason: e.message)
        raise
      rescue JSON::ParserError, SystemCallError, IOError, ArgumentError, TypeError => e
        quarantine(project_root, raw.to_s, reason: "#{e.class}: #{e.message}")
        raise Invalid, "cannot read reconciler progress (#{e.class}: #{e.message})"
      end

      def write(project_root, progress)
        validate!(progress)
        key = File.expand_path(project_root)
        if @dry_run
          @transient[key] = Marshal.load(Marshal.dump(progress))
          return progress
        end

        progress_path = path(project_root)
        Hive::AtomicFile.write(progress_path, "#{JSON.pretty_generate(progress)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(File.dirname(progress_path))
        progress
      end

      def clear(project_root)
        key = File.expand_path(project_root)
        if @dry_run
          @transient.delete(key)
          return
        end

        progress_path = path(project_root)
        return unless File.exist?(progress_path)

        File.delete(progress_path)
        Hive::AtomicFile.fsync_directory(File.dirname(progress_path))
      end

      def build(registration:, host:, repository:, default_branch:, previous:,
                merged_since:, now:)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "registration" => registration,
          "host" => host,
          "repository" => repository,
          "default_branch" => default_branch,
          "base_checkpoint_sha256" => checkpoint_fingerprint(previous),
          "scan" => {
            "phase" => "pages",
            "merged_since" => merged_since.utc.iso8601,
            "merged_until" => now.utc.iso8601,
            "result_count" => nil,
            "cursor" => nil,
            "items" => [],
            "seen_cursors" => [],
            "started_at" => now.utc.iso8601,
            "ingest_index" => 0,
            "enqueued_prs" => []
          },
          "retry" => nil,
          "updated_at" => now.utc.iso8601
        }
      end

      def checkpoint_fingerprint(state)
        return nil unless state

        ::Digest::SHA256.hexdigest(JSON.generate(state.slice(*CHECKPOINT_KEYS)))
      end

      def assert_identity!(progress, registration:, host:, repository:, default_branch:,
                           project_root:)
        return unless progress

        reason = if progress.fetch("registration") != registration
          "progress registration identity changed from #{progress.fetch('registration')} to #{registration}"
        elsif progress.fetch("host") != host
          "progress repository host changed from #{progress.fetch('host')} to #{host}"
        elsif progress.fetch("repository") != repository
          "progress repository identity changed from #{progress.fetch('repository')} to #{repository}"
        elsif progress.fetch("default_branch") != default_branch
          "progress default branch changed from #{progress.fetch('default_branch')} to #{default_branch}"
        end
        return unless reason

        quarantine(
          project_root, JSON.generate(progress), reason: reason,
          observed: {
            "registration" => registration,
            "host" => host,
            "repository" => repository,
            "default_branch" => default_branch
          }
        )
        raise Invalid, reason
      end

      def retry_pending?(progress, now)
        retry_state = progress["retry"]
        retry_state && now < Time.iso8601(retry_state.fetch("not_before"))
      end

      def record_failure!(project_root, progress, error, now)
        failures = progress.dig("retry", "failures").to_i + 1
        exponent = [ failures - 1, 30 ].min
        ceiling = [ @backoff_base_sec * (2**exponent), @backoff_max_sec ].min
        sample = Float(@jitter.call)
        sample = 0.0 unless sample.finite?
        sample = sample.clamp(0.0, 1.0)
        delay = [ ceiling * (0.5 + sample), @backoff_max_sec ].min
        progress["retry"] = {
          "failures" => failures,
          "not_before" => (now + delay).utc.iso8601(6),
          "last_error" => "#{error.class}: #{error.message}"[0, 2000]
        }
        touch!(progress, now)
        write(project_root, progress)
      end

      def touch!(progress, now)
        progress["updated_at"] = now.utc.iso8601
        progress
      end

      def quarantine(project_root, authoritative_bytes, reason:, observed: nil)
        return if @dry_run

        directory = File.join(
          project_root, ".hive-state", "refactor_patrol", "v2",
          "quarantine", "reconciler-progress"
        )
        fingerprint = ::Digest::SHA256.hexdigest(
          [ authoritative_bytes, reason, JSON.generate(observed) ].join("\0")
        )
        evidence_path = File.join(directory, "#{fingerprint}.json")
        return evidence_path if File.file?(evidence_path)

        evidence = {
          "schema" => "hive-refactor-patrol-reconciler-progress-conflict",
          "schema_version" => 1,
          "reason" => reason,
          "authoritative_state_sha256" => ::Digest::SHA256.hexdigest(authoritative_bytes),
          "observed" => observed
        }
        Hive::AtomicFile.write(evidence_path, "#{JSON.pretty_generate(evidence)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(directory)
        evidence_path
      end

      private

      def validate!(data)
        raise Invalid, "reconciler progress must be an object" unless data.is_a?(Hash)
        raise Invalid, "unexpected reconciler progress schema" unless data["schema"] == SCHEMA
        unless data["schema_version"] == SCHEMA_VERSION
          raise Invalid, "unsupported reconciler progress schema version #{data['schema_version'].inspect}"
        end
        raise Invalid, "reconciler progress keys are invalid" unless data.keys.sort == KEYS.sort

        %w[registration host repository default_branch updated_at].each do |key|
          unless data[key].is_a?(String) && !data[key].empty?
            raise Invalid, "reconciler progress #{key} is missing"
          end
        end
        fingerprint = data.fetch("base_checkpoint_sha256")
        unless fingerprint.nil? ||
               (fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/))
          raise Invalid, "reconciler progress base checkpoint fingerprint is invalid"
        end
        Time.iso8601(data.fetch("updated_at"))
        validate_scan!(data.fetch("scan"), data)
        validate_retry!(data.fetch("retry")) if data.fetch("retry")
        data
      rescue KeyError, ArgumentError, TypeError => e
        raise Invalid, "reconciler progress is invalid (#{e.message})"
      end

      def validate_scan!(scan, progress)
        unless scan.is_a?(Hash) && scan.keys.sort == SCAN_KEYS.sort &&
               %w[pages ingest].include?(scan["phase"])
          raise Invalid, "reconciler progress scan is invalid"
        end
        Time.iso8601(scan.fetch("merged_since"))
        Time.iso8601(scan.fetch("merged_until"))
        Time.iso8601(scan.fetch("started_at"))
        if Time.iso8601(scan.fetch("merged_until")) != Time.iso8601(scan.fetch("started_at"))
          raise Invalid, "reconciler progress scan upper bound changed"
        end
        count = scan.fetch("result_count")
        unless count.nil? || (count.is_a?(Integer) && count >= 0)
          raise Invalid, "reconciler progress result count is invalid"
        end
        unless scan["cursor"].nil? ||
               (scan["cursor"].is_a?(String) && !scan["cursor"].empty?)
          raise Invalid, "reconciler progress cursor is invalid"
        end
        unless scan["items"].is_a?(Array) && scan["seen_cursors"].is_a?(Array) &&
               scan["seen_cursors"].all? { |cursor| cursor.is_a?(String) && !cursor.empty? } &&
               scan["seen_cursors"].uniq.length == scan["seen_cursors"].length
          raise Invalid, "reconciler progress pagination data is invalid"
        end
        if scan["cursor"] && scan.fetch("seen_cursors").include?(scan.fetch("cursor"))
          raise Invalid, "reconciler progress current cursor was already consumed"
        end
        scan.fetch("items").each { |item| validate_item!(item, progress) }
        if count && scan.fetch("items").length > count
          raise Invalid, "reconciler progress has more items than its frozen result count"
        end
        unless scan["ingest_index"].is_a?(Integer) && scan["ingest_index"] >= 0 &&
               scan["enqueued_prs"].is_a?(Array) &&
               scan["enqueued_prs"].all? { |number| number.is_a?(Integer) && number.positive? } &&
               scan["enqueued_prs"].uniq.length == scan["enqueued_prs"].length
          raise Invalid, "reconciler progress intake data is invalid"
        end
      rescue KeyError, ArgumentError, TypeError => e
        raise Invalid, "reconciler progress scan is invalid (#{e.message})"
      end

      def validate_item!(item, progress)
        unless item.is_a?(Hash) &&
               %w[url repository base_branch merge_sha merged_at].all? do |key|
                 item[key].is_a?(String) && !item[key].empty?
               end && item["number"].is_a?(Integer) && item["number"].positive? &&
               item.fetch("merge_sha").match?(/\A[a-f0-9]{40,64}\z/)
          raise Invalid, "reconciler progress contains an invalid merged-PR item"
        end
        Time.iso8601(item.fetch("merged_at"))
        uri = URI.parse(item.fetch("url"))
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        unless item.fetch("repository").to_s.casecmp?(progress.fetch("repository")) &&
               uri.is_a?(URI::HTTP) && uri.host.to_s.casecmp?(progress.fetch("host")) &&
               match && match[1].casecmp?(progress.fetch("repository")) &&
               match[2].to_i == item.fetch("number") && uri.userinfo.nil? &&
               uri.query.nil? && uri.fragment.nil? &&
               item.fetch("base_branch") == progress.fetch("default_branch")
          raise Invalid, "reconciler progress merged-PR identity changed"
        end
      rescue KeyError, ArgumentError, TypeError, URI::InvalidURIError => e
        raise Invalid, "reconciler progress merged-PR item is invalid (#{e.message})"
      end

      def validate_retry!(retry_state)
        unless retry_state.is_a?(Hash) && retry_state.keys.sort == RETRY_KEYS.sort &&
               retry_state["failures"].is_a?(Integer) && retry_state["failures"].positive? &&
               retry_state["last_error"].is_a?(String) && !retry_state["last_error"].empty? &&
               retry_state["not_before"].is_a?(String) && !retry_state["not_before"].empty?
          raise Invalid, "reconciler progress retry state is invalid"
        end
        Time.iso8601(retry_state.fetch("not_before"))
      rescue KeyError, ArgumentError, TypeError => e
        raise Invalid, "reconciler progress retry state is invalid (#{e.message})"
      end

      def positive_float!(value, label)
        number = Float(value)
        unless number.finite? && number.positive?
          raise ArgumentError, "refactor patrol merge #{label} must be positive"
        end

        number
      rescue TypeError, ArgumentError
        raise ArgumentError, "refactor patrol merge #{label} must be positive"
      end
    end
  end
end
