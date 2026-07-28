require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/stringify_keys"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    class DecisionJournalError < Hive::Error; end

    # Immutable launch/skip receipts. A decision is never edited after its
    # atomic publish; later attempt state is joined by status projection.
    class DecisionJournal
      SCHEMA = "hive-module-decision".freeze
      SCHEMA_VERSION = 1
      OUTCOMES = %w[launch skip].freeze
      REASONS = %w[
        admitted activation_fenced capacity_blocked concurrency_blocked cursor_stale
        disabled duplicate hook_disabled invalid_binding no_match not_installed
        permission_blocked terminal_replay uninstalled
        launch_handoff_failed
      ].freeze

      attr_reader :root, :decisions_root

      def initialize(root:, id_generator: -> { SecureRandom.uuid }, create_directories: true)
        @root = File.expand_path(root)
        @decisions_root = File.join(@root, "decisions")
        @id_generator = id_generator
        @read_only = !create_directories
        if create_directories
          FileUtils.mkdir_p(@decisions_root, mode: 0o700)
          File.chmod(0o700, @decisions_root)
        end
      rescue SystemCallError => e
        raise DecisionJournalError, "module decision journal is unavailable: #{e.message}"
      end

      def append(attributes)
        raise DecisionJournalError, "module decision journal is read-only" if @read_only

        data = Hive::StringifyKeys.call(attributes)
        data = normalize(data)
        token = @id_generator.call.to_s
        raise DecisionJournalError, "module decision identity is unavailable" if token.empty?
        data["decision_id"] = "dec-#{::Digest::SHA256.hexdigest([ token, canonical(data) ].join("\0"))}"
        validate!(data)
        path = decision_path(data.fetch("decision_id"))
        with_lock do
          raise DecisionJournalError, "module decision identity already exists" if File.exist?(path)
          Hive::AtomicFile.write(path, canonical(data), mode: 0o600)
          Hive::AtomicFile.fsync_directory(decisions_root)
          if @all_cache
            @all_cache = (@all_cache.dup << data.freeze).freeze
            @all_cache_signature = decisions_signature
          end
        end
        data.freeze
      rescue DecisionJournalError
        raise
      rescue SystemCallError, IOError => e
        raise DecisionJournalError, "module decision could not be persisted: #{e.message}"
      end

      def all
        signature = decisions_signature
        return @all_cache if @all_cache && @all_cache_signature == signature

        reader = lambda do
          next [].freeze unless File.directory?(decisions_root)

          Dir.glob(File.join(decisions_root, "dec-*.json")).sort.map do |path|
            parse(File.binread(path), expected_id: File.basename(path, ".json"))
          end.freeze
        end
        return reader.call if @read_only

        @all_cache, @all_cache_signature = with_lock(shared: true) do
          [ reader.call, decisions_signature ]
        end
        @all_cache
      end

      def for_binding(module_name:, hook_id:, event_id: nil)
        all.select do |decision|
          decision["module"] == module_name.to_s && decision["hook"] == hook_id.to_s &&
            (event_id.nil? || decision["event_id"] == event_id)
        end
      end

      def admitted?(module_name:, hook_id:, event_id:)
        for_binding(module_name: module_name, hook_id: hook_id, event_id: event_id)
          .any? { |decision| decision["outcome"] == "launch" }
      end

      private

      def decisions_signature
        stat = File.stat(decisions_root)
        [ stat.mtime.to_r, stat.size, stat.ino ]
      rescue Errno::ENOENT
        nil
      end

      def normalize(data)
        now = data.delete("evaluated_at") || Time.now.utc
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "decision_id" => nil,
          "project_id" => data.fetch("project_id").to_s,
          "project" => data.fetch("project").to_s,
          "module" => data.fetch("module").to_s,
          "hook" => data.fetch("hook").to_s,
          "event_id" => data.fetch("event_id").to_s,
          "event_name" => data.fetch("event_name").to_s,
          "evaluated_at" => timestamp(now),
          "outcome" => data.fetch("outcome").to_s,
          "reason" => data.fetch("reason").to_s,
          "binding_digest" => data["binding_digest"],
          "cursor_before" => data["cursor_before"],
          "cursor_after" => data["cursor_after"],
          "module_generation" => data["module_generation"],
          "configuration_digest" => data["configuration_digest"],
          "grant_digest" => data["grant_digest"],
          "concurrency" => data["concurrency"],
          "attempt_id" => data["attempt_id"],
          "task_id" => data["task_id"],
          "artifacts" => Array(data["artifacts"]),
          "retry" => data["retry"]
        }
      rescue KeyError => e
        raise DecisionJournalError, "module decision is missing #{e.key}"
      end

      def validate!(data)
        expected = %w[
          artifacts attempt_id binding_digest concurrency configuration_digest cursor_after
          cursor_before decision_id evaluated_at event_id event_name grant_digest hook module
          module_generation outcome project project_id reason retry schema schema_version task_id
        ]
        unless data.keys.sort == expected && data["schema"] == SCHEMA &&
               data["schema_version"] == SCHEMA_VERSION && OUTCOMES.include?(data["outcome"]) &&
               REASONS.include?(data["reason"]) &&
               %w[decision_id project_id project module hook event_id event_name].all? do |key|
                 data[key].is_a?(String) && !data[key].empty?
               end
          raise DecisionJournalError, "module decision receipt is malformed"
        end
        %w[binding_digest configuration_digest grant_digest].each do |key|
          value = data[key]
          next if value.nil? || /\A[0-9a-f]{64}\z/.match?(value.to_s)
          raise DecisionJournalError, "module decision #{key} is malformed"
        end
        unless data["artifacts"].is_a?(Array) && data["artifacts"].all? { |item| item.is_a?(Hash) }
          raise DecisionJournalError, "module decision artifacts are malformed"
        end
        Time.iso8601(data.fetch("evaluated_at"))
      rescue ArgumentError, TypeError
        raise DecisionJournalError, "module decision timestamp is malformed"
      end

      def parse(bytes, expected_id:)
        data = JSON.parse(bytes)
        validate!(data)
        unless bytes == canonical(data) && data["decision_id"] == expected_id
          raise DecisionJournalError, "module decision journal contains malformed evidence"
        end
        data.freeze
      rescue JSON::ParserError, EncodingError
        raise DecisionJournalError, "module decision journal contains malformed evidence"
      end

      def decision_path(decision_id)
        unless decision_id.to_s.match?(/\Adec-[0-9a-f]{64}\z/)
          raise DecisionJournalError, "module decision id is malformed"
        end
        File.join(decisions_root, "#{decision_id}.json")
      end

      def with_lock(shared: false)
        File.open(File.join(root, "decisions.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise DecisionJournalError, "module decision journal lock is unavailable: #{e.message}"
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise DecisionJournalError, "module decision timestamp is malformed"
      end

      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
    end
  end
end
