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
      # files live. Created lazily by `directory` with mode 0700 so the
      # queue's de-facto auth boundary (any process with write access
      # can enqueue an allowlisted verb) is at minimum scoped to the
      # owning user. The `requestor` field in each request is NOT
      # verified against process credentials — file ownership is.
      DIRNAME = "dispatch_requests".freeze

      # C3 (PR #241 ce-code-review): suffix appended to a request file the
      # instant the daemon spawns its child. A claimed file is invisible
      # to `pending` (the glob matches `*.json`, not `*.json.claimed`), so
      # each queued request is dispatched AT MOST ONCE even across a
      # daemon restart: a crash between spawn and reap leaves a `.claimed`
      # file, which `recover_claims` cleans up on the next start rather
      # than blindly re-dispatching a run that already happened. The claim
      # records the child's pid + process_start_time so recovery can tell
      # "owner still alive" from "owner gone".
      CLAIMED_SUFFIX = ".claimed".freeze

      # ADR-012 slug regex. Slugs from request payloads flow into
      # filesystem path construction (state-file lookup, log paths);
      # any character outside this set is rejected at parse time to
      # prevent path-traversal via the slug field.
      SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/

      # Project name pattern. Loose alphanumeric + dot/underscore/hyphen
      # matches the `name` keys in `Hive::Config`. The daemon's
      # `find_project` lookup is the actual authoritative gate; this
      # regex catches the most obvious traversal candidates (slashes,
      # nulls, leading dots) before any path is constructed.
      PROJECT_RE = /\A[A-Za-z0-9_.\-]+\z/

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
        # Mode 0700 enforces the user-owned-dir invariant: only the
        # process owner can enqueue requests. Without this, a default
        # umask of 0022 leaves the dir at 0755 and any local user
        # could write a request (which the daemon would dispatch
        # against an allowlisted verb). Idempotent on existing dirs;
        # if the dir was previously created with looser perms,
        # `chmod` to tighten.
        FileUtils.mkdir_p(path, mode: 0o700)
        # mkdir_p doesn't chmod existing dirs — re-tighten in case
        # the dir was created by a prior version with default umask.
        File.chmod(0o700, path) if File.directory?(path)
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
        # Match both pending (`*.json`) and claimed (`*.json.claimed`)
        # files — `reap_completed` calls this after the child exits, by
        # which point the file has already been renamed to its claimed
        # form (C3).
        request_files(dir).each do |path|
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

      # C3: atomically mark `request_id` as claimed by recording the
      # spawned child's `pid` + `process_start_time` and renaming the
      # `<...>.json` file to `<...>.json.claimed`. Called right after the
      # daemon spawns the child. The claimed file is invisible to
      # `pending`, so the request is never re-observed (and never
      # re-dispatched) by a later tick. Returns the claimed path, or nil
      # when no matching pending file was found (already claimed/removed).
      #
      # The metadata is merged under a `claim` key; the original request
      # fields are preserved so `remove` (and the queue CLI) still parse
      # the file. Atomic via tmp + rename, mirroring the writer side.
      def claim(request_id, pid:, process_start_time: nil, now: Time.now,
                state_home: Hive::Paths.state_home)
        return nil if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json")).each do |path|
          next unless path.include?(request_id.to_s)

          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          next unless data.is_a?(Hash) && data["request_id"] == request_id.to_s

          data["claim"] = {
            "pid" => pid,
            "process_start_time" => process_start_time,
            "claimed_at" => now.utc.iso8601
          }
          claimed_path = "#{path}#{CLAIMED_SUFFIX}"
          tmp_path = File.join(dir, ".#{File.basename(path)}.claim.#{Process.pid}")
          File.write(tmp_path, JSON.generate(data))
          File.rename(tmp_path, claimed_path)
          File.unlink(path) if File.exist?(path)
          return claimed_path
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      # C3: at daemon startup, sweep claimed files left behind by a prior
      # process. For each claim, `alive.call(pid, process_start_time)`
      # decides whether the claiming child is still running:
      #   - alive  → leave the file (we cannot reap a process we did not
      #              spawn; a later restart cleans it once it dies).
      #   - gone   → remove the file. We deliberately do NOT re-dispatch:
      #              the run already happened once (at-most-once); if it
      #              died mid-flight the task's own marker drives recovery
      #              through the normal status→alert path.
      # Claims older than `expiry_sec` are removed regardless (a stuck
      # alive-but-wedged child should not pin a claim forever). `handler`
      # (when supplied) receives `(request_id:, reason:, path:)` per
      # removed file so the caller can log. Returns the count removed.
      def recover_claims(state_home: Hive::Paths.state_home, now: Time.now,
                         alive: nil, expiry_sec: EXPIRY_SEC, handler: nil)
        dir = directory(state_home: state_home)
        removed = 0
        Dir.glob(File.join(dir, "*#{CLAIMED_SUFFIX}")).each do |path|
          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            File.unlink(path) if File.exist?(path)
            handler&.call(request_id: nil, reason: "malformed_claim", path: path)
            removed += 1
            next
          end

          claim = data.is_a?(Hash) ? data["claim"] : nil
          request_id = data.is_a?(Hash) ? data["request_id"] : nil
          aged_out = claim_aged_out?(claim, now: now, expiry_sec: expiry_sec)
          owner_alive = !aged_out && alive &&
                        alive.call(claim && claim["pid"], claim && claim["process_start_time"])
          next if owner_alive

          File.unlink(path) if File.exist?(path)
          reason = aged_out ? "claim_expired" : "owner_gone"
          handler&.call(request_id: request_id, reason: reason, path: path)
          removed += 1
        end
        removed
      rescue Errno::ENOENT
        0
      end

      # ADV-1: read the Telegram routing metadata (chat_id, update_id,
      # project, slug) for `request_id` from its on-disk file — pending
      # (`*.json`) or claimed (`*.json.claimed`). Used by the dispatcher
      # at reap time, BEFORE `remove` unlinks the file, so a non-zero
      # completion can be routed back to the originating chat. Returns a
      # Hash with symbol keys, or nil when the file is gone/unparseable.
      def metadata(request_id, state_home: Hive::Paths.state_home)
        return nil if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        request_files(dir).each do |path|
          next unless path.include?(request_id.to_s)

          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          next unless data.is_a?(Hash) && data["request_id"] == request_id.to_s

          return {
            chat_id: data["chat_id"], update_id: data["update_id"],
            project: data["project"], slug: data["slug"]
          }
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      # Validate a request's argv. Returns true when:
      #   - argv is an Array of Strings
      #   - argv has at least 2 entries (hive + verb)
      #   - argv[0] is "hive"
      #   - argv[1] (the verb) is in ALLOWED_VERBS
      #   - argv[2] (when present and not a `--flag`) matches SLUG_RE —
      #     the slug is the most common positional argument and the
      #     primary path-construction surface; reject malformed slugs
      #     at the queue boundary instead of trusting downstream parse.
      #
      # All checks gate the allowlist; failing any is a reject. This
      # is the operator-trust gate against a compromised producer
      # identity running arbitrary CLI verbs or smuggling path-
      # traversal slugs.
      def valid_argv?(argv)
        return false unless argv.is_a?(Array)
        return false if argv.length < 2
        return false unless argv.all? { |tok| tok.is_a?(String) && !tok.empty? }
        return false unless argv[0] == "hive"

        verb = argv[1].to_s
        return false unless ALLOWED_VERBS.include?(verb)

        # If the third positional argument is present and not a flag,
        # treat it as a slug and validate against ADR-012's regex.
        # `markers clear <folder>` passes a folder path (not a slug),
        # so allow paths under hive-state when the verb is `markers`.
        return true if argv.length < 3
        return true if argv[2].start_with?("-")
        return true if verb == "markers" # folder argument, not slug

        SLUG_RE.match?(argv[2])
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

      # Pending (`*.json`) + claimed (`*.json.claimed`) request files in
      # `dir`. Used by `remove` so a post-spawn unlink finds the file
      # regardless of whether it was claimed yet (C3).
      def request_files(dir)
        Dir.glob(File.join(dir, "*.json")) +
          Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}"))
      end

      # True when a claim's `claimed_at` is older than `expiry_sec`. A nil
      # / unparseable claim or timestamp is treated as aged-out so a
      # malformed claim never pins a file forever.
      def claim_aged_out?(claim, now:, expiry_sec:)
        return true unless claim.is_a?(Hash)

        claimed_at = claim["claimed_at"]
        return true if claimed_at.to_s.empty?

        begin
          (now - Time.parse(claimed_at.to_s)) > expiry_sec
        rescue ArgumentError
          true
        end
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
          return :invalid_project unless PROJECT_RE.match?(project)

          slug = data["slug"].to_s
          return :missing_slug if slug.empty?
          # Slugs flow into path construction in resolve_post_completion_path
          # + log paths. Reject any character outside ADR-012's slug
          # regex at the queue boundary to prevent path-traversal.
          return :invalid_slug unless SLUG_RE.match?(slug)

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
