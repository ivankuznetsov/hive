require "json"
require "fileutils"
require "time"
require "hive/paths"

module Hive
  module Daemon
    # File-backed queue of dispatch requests written by external callers
    # (today: the Telegram bot) and consumed by the daemon dispatcher.
    #
    # One JSON file per pending request under
    # `<state_home>/dispatch_requests/`. Filenames sort lexicographically
    # by creation time so `pending` walks the queue in arrival order.
    # The bot atomic-writes a file via tmp + rename; the daemon reads
    # whole files and `File.unlink`s them on dispatch or rejection. No
    # cross-process lock is required: the atomic-write side guarantees a
    # complete file is observable, and per-file unlink avoids contention.
    #
    # Schema (`hive-dispatch-request`, version 1):
    #
    #   {
    #     "schema": "hive-dispatch-request",
    #     "schema_version": 1,
    #     "request_id": "<hex>",
    #     "created_at": "2026-05-28T18:11:44Z",
    #     "project": "hive",
    #     "slug": "explore-the-simplest-way-to-260528-2503",
    #     "argv": ["hive", "run", "...", "--json"],
    #     "requestor": "bot",
    #     "chat_id": 123456789,
    #     "update_id": 926850952,
    #     "trigger": "answer_complete"
    #   }
    #
    # The dispatcher is the only writer of `hive run`-class verbs; the
    # bot writes a request and the daemon picks it up. That removes the
    # dual-writer race that let post-completion mtime baselines go stale
    # (see plan 2026-05-28-002).
    module DispatchRequestQueue
      module_function

      SCHEMA = "hive-dispatch-request".freeze
      SCHEMA_VERSION = 1

      # Allowlisted hive verbs. A request file whose argv[1] is not in
      # this list is rejected with a logged reason and removed; this is
      # the operator-trust gate against a compromised bot identity
      # running arbitrary CLI verbs.
      ALLOWED_VERBS = %w[
        run develop brainstorm plan review open-pr artifacts finalize
        archive markers
      ].freeze

      # Default directory inside `<state_home>` where pending request
      # files live. Created lazily by `directory`.
      DIRNAME = "dispatch_requests".freeze

      # Parsed request record returned by `pending`.
      Request = Struct.new(
        :request_id, :created_at, :project, :slug, :argv, :requestor,
        :chat_id, :update_id, :trigger, :path,
        keyword_init: true
      )

      # Resolve (and mkdir) the requests directory. `state_home:` lets
      # tests inject a sandbox path; production passes
      # `Hive::Paths.state_home` so every dispatch request lives next to
      # the daemon's other state.
      def directory(state_home: Hive::Paths.state_home)
        path = File.join(state_home, DIRNAME)
        FileUtils.mkdir_p(path)
        path
      end

      # Read and parse every pending request file in `directory`,
      # sorted by `created_at` ascending. Malformed entries (bad JSON,
      # missing fields, unknown schema_version, non-array argv) are
      # skipped — `bad_handler` (when supplied) receives
      # `(path:, reason:)` so the caller can log + remove. Returning
      # them inline would let one bad file block all downstream
      # processing.
      #
      # `now:` is accepted only for parity with other queue helpers; the
      # caller decides what to do with a request once it's parsed.
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
        entries.sort_by { |req| [ req.created_at, req.request_id.to_s ] }
      end

      # Remove the request file for `request_id`. Idempotent: a missing
      # file is not an error. Returns true if a file was removed, false
      # otherwise. `state_home:` mirrors `directory`.
      def remove(request_id, state_home: Hive::Paths.state_home)
        return false if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        removed = false
        Dir.glob(File.join(dir, "*.json")).each do |path|
          next unless path.include?(request_id.to_s)

          begin
            data = JSON.parse(File.read(path))
          rescue StandardError
            # Race: the file disappeared (or was rewritten with
            # malformed JSON) between glob and read. Idempotent
            # removal already covers the desired outcome — skip and
            # let `pending`'s next pass handle it via bad_handler.
            next
          end
          next unless data.is_a?(Hash) && data["request_id"] == request_id.to_s

          File.unlink(path)
          removed = true
        end
        removed
      rescue Errno::ENOENT
        # Outer race: the directory itself disappeared between
        # `directory` and `Dir.glob`. Same idempotent contract.
        false
      end

      # Validate a request's argv. Returns true when:
      #   - argv is an Array of Strings
      #   - argv[0] is "hive"
      #   - argv[1] (the verb) is in ALLOWED_VERBS
      # All three checks gate this allowlist; failing any is a reject.
      def valid_argv?(argv)
        return false unless argv.is_a?(Array)
        return false if argv.empty?
        return false unless argv.all? { |tok| tok.is_a?(String) }
        return false unless argv[0] == "hive"

        verb = argv[1].to_s
        ALLOWED_VERBS.include?(verb)
      end

      # Filename helper exposed for the writer side so tests can predict
      # the on-disk layout. Pure: `created_at` + `request_id` → filename.
      def filename_for(created_at:, request_id:)
        ts = created_at.utc.strftime("%Y%m%dT%H%M%S%6N")
        "#{ts}-#{request_id}.json"
      end

      # Default expiry window. Requests older than this are removed
      # without dispatch (the daemon was down or refused them
      # repeatedly). Tunable from the dispatcher's tick to keep the
      # constant local but adjustable per call.
      EXPIRY_SEC = 600

      # Treat `request` as expired if `created_at` is older than
      # `expiry_sec` relative to `now`. `created_at` is a Time; the
      # caller decides what to do with the result (log + remove).
      def expired?(request, now: Time.now, expiry_sec: EXPIRY_SEC)
        return false unless request.respond_to?(:created_at)

        created = request.created_at
        return false unless created.is_a?(Time)

        (now - created) > expiry_sec
      end

      class << self
        private

        def parse_file(path)
          raw = File.read(path)
          data = JSON.parse(raw)
        rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
          :malformed_json
        else
          parse_data(data, path: path)
        end

        def parse_data(data, path:)
          return :not_a_hash unless data.is_a?(Hash)
          return :wrong_schema unless data["schema"] == SCHEMA
          return :unknown_schema_version unless data["schema_version"] == SCHEMA_VERSION

          request_id = data["request_id"].to_s
          return :missing_request_id if request_id.empty?

          project = data["project"].to_s
          return :missing_project if project.empty?

          slug = data["slug"].to_s
          return :missing_slug if slug.empty?

          argv = data["argv"]
          return :invalid_argv unless argv.is_a?(Array)

          created_at = parse_time(data["created_at"])
          return :invalid_created_at if created_at.nil?

          Request.new(
            request_id: request_id,
            created_at: created_at,
            project: project,
            slug: slug,
            argv: argv,
            requestor: data["requestor"].to_s,
            chat_id: data["chat_id"],
            update_id: data["update_id"],
            trigger: data["trigger"].to_s,
            path: path
          )
        end

        def parse_time(value)
          return nil if value.nil? || value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
