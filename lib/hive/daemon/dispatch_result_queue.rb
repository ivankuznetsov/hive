require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/paths"

module Hive
  module Daemon
    # ADV-1 (PR #241 ce-code-review): a file-backed notice channel that
    # runs the OPPOSITE direction of `DispatchRequestQueue`. After the
    # single-dispatcher refactor the daemon (not the bot) spawns
    # `hive run`-class children, and the daemon has no Telegram handle —
    # so a bot-initiated run that exits non-zero (a failed Autofix, a
    # failed retry verb) used to fail silently for the operator who
    # tapped the button. The daemon writes one notice file here per
    # non-zero, bot-originated completion; the bot drains the directory
    # in its reaper loop and replies to the originating chat, then
    # unlinks the file.
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

      Result = Struct.new(
        :result_id, :created_at, :chat_id, :update_id, :project, :slug,
        :request_id, :exit_code, :command, :path,
        keyword_init: true
      )

      # Resolve (and mkdir, mode 0700) the results directory. Mirrors
      # DispatchRequestQueue.directory's owner-only invariant.
      def directory(state_home: Hive::Paths.state_home)
        path = File.join(state_home, DIRNAME)
        FileUtils.mkdir_p(path, mode: 0o700)
        File.chmod(0o700, path) if File.directory?(path)
        path
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
