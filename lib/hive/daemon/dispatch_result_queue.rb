require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/paths"
require "hive/daemon/queue_directory"

module Hive
  module Daemon
    # ADV-1 (PR #241 ce-code-review): a file-backed notice channel that
    # runs the OPPOSITE direction of `DispatchRequestQueue`. After the
    # single-dispatcher refactor the daemon (not the bot) spawns
    # `hive run`-class children, and the daemon has no Telegram handle —
    # so bot-initiated queued work needs an out-of-band reply path. The
    # daemon writes one notice file here per bot-originated completion;
    # the bot drains the directory in its reaper loop and replies to the
    # originating chat, then unlinks the file.
    #
    # Symmetry with `DispatchRequestQueue`: one JSON file per notice
    # under `<state_home>/dispatch_results/`, atomic-write-then-rename so
    # the bot never observes a partial document, per-file unlink on
    # consumption, no cross-process lock.
    #
    # Schema (`hive-dispatch-result`, version 1):
    #
    #   {
    #     "schema": "hive-dispatch-result",
    #     "schema_version": 1,
    #     "result_id": "<hex>",
    #     "created_at": "2026-05-28T18:14:02Z",
    #     "chat_id": 123456789,
    #     "update_id": 926850952,
    #     "project": "hive",
    #     "slug": "explore-...",
    #     "request_id": "<hex>",
    #     "exit_code": 4,
    #     "command": "hive markers clear ..."
    #   }
    module DispatchResultQueue
      module_function

      SCHEMA = "hive-dispatch-result".freeze
      SCHEMA_VERSION = 1
      DIRNAME = "dispatch_results".freeze

      # Age after which a notice is considered stale: not worth relaying
      # (the operator does not need an hour-old completion ping) and a
      # candidate for pruning. Bounds directory growth when the bot is
      # down for an extended period. 1h.
      EXPIRY_SEC = 3600

      Result = Struct.new(
        :result_id, :created_at, :chat_id, :update_id, :project, :slug,
        :request_id, :exit_code, :command, :path,
        keyword_init: true
      )

      # Resolve (and mkdir, mode 0700) the results directory via the shared
      # QueueDirectory helper so the owner-only invariant lives in one place
      # (#253).
      def directory(state_home: Hive::Paths.state_home)
        QueueDirectory.directory_for(dirname: DIRNAME, state_home: state_home)
      end

      # Atomic-write a completion notice. Returns the new result_id.
      # `chat_id` is required — a notice with no chat to reply to is
      # pointless, so the daemon only calls this when it has one.
      def write!(chat_id:, project:, slug:, request_id:, exit_code:, command:,
                 update_id: nil, state_home: Hive::Paths.state_home, now: Time.now)
        result_id = SecureRandom.hex(8)
        created_at = now.utc
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "result_id" => result_id,
          "created_at" => created_at.iso8601,
          "chat_id" => chat_id,
          "update_id" => update_id,
          "project" => project.to_s,
          "slug" => slug.to_s,
          "request_id" => request_id.to_s,
          "exit_code" => exit_code,
          "command" => command.to_s
        }

        dir = directory(state_home: state_home)
        filename = "#{created_at.strftime('%Y%m%dT%H%M%S%6N')}-#{result_id}.json"
        final_path = File.join(dir, filename)
        tmp_path = File.join(dir, ".#{filename}.tmp.#{Process.pid}")
        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |f|
          f.write(JSON.generate(payload))
          f.flush
          f.fsync
        end
        File.rename(tmp_path, final_path)
        result_id
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      # Parse every pending notice, sorted by created_at ascending.
      # Malformed entries route to `bad_handler` (when supplied) and are
      # skipped so one bad file can't block the rest.
      def pending(state_home: Hive::Paths.state_home, bad_handler: nil)
        dir = directory(state_home: state_home)
        entries = []
        Dir.glob(File.join(dir, "*.json")).each do |path|
          parsed = parse_file(path)
          if parsed.is_a?(Symbol)
            bad_handler&.call(path: path, reason: parsed.to_s)
            next
          end
          entries << parsed
        end
        entries.sort_by { |r| [ r.created_at, r.result_id.to_s ] }
      end

      # True when `notice` is older than `expiry_sec` relative to `now`.
      def expired?(notice, now: Time.now, expiry_sec: EXPIRY_SEC)
        return false unless notice.respond_to?(:created_at)

        created = notice.created_at
        return false unless created.is_a?(Time)

        (now - created) > expiry_sec
      end

      # Bound directory growth: remove notices older than `expiry_sec`
      # (and malformed files) without delivering them. Called by the
      # daemon each tick so a down/wedged bot can't let the dir grow
      # without limit. Returns the count removed.
      def prune_expired(state_home: Hive::Paths.state_home, now: Time.now,
                        expiry_sec: EXPIRY_SEC)
        removed = 0
        pending(state_home: state_home,
                bad_handler: ->(path:, reason:) { FileUtils.rm_f(path); removed += 1 })
          .each do |notice|
          next unless expired?(notice, now: now, expiry_sec: expiry_sec)

          removed += 1 if remove(notice.result_id, state_home: state_home)
        end
        removed
      end

      # Idempotent removal of the notice for `result_id`.
      def remove(result_id, state_home: Hive::Paths.state_home)
        return false if result_id.to_s.empty?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json")).each do |path|
          next unless path.include?(result_id.to_s)

          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          next unless data.is_a?(Hash) && data["result_id"] == result_id.to_s

          File.unlink(path)
          return true
        end
        false
      rescue Errno::ENOENT
        false
      end

      class << self
        private

        def parse_file(path)
          data = JSON.parse(File.read(path))
        rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
          :malformed_json
        else
          return :not_a_hash unless data.is_a?(Hash)
          return :wrong_schema unless data["schema"] == SCHEMA
          return :unknown_schema_version unless data["schema_version"] == SCHEMA_VERSION

          result_id = data["result_id"].to_s
          return :missing_result_id if result_id.empty?

          created_at = begin
            Time.parse(data["created_at"].to_s)
          rescue ArgumentError
            nil
          end
          return :invalid_created_at if created_at.nil?

          Result.new(
            result_id: result_id, created_at: created_at,
            chat_id: data["chat_id"], update_id: data["update_id"],
            project: data["project"].to_s, slug: data["slug"].to_s,
            request_id: data["request_id"].to_s, exit_code: data["exit_code"],
            command: data["command"].to_s, path: path
          )
        end
      end
    end
  end
end
