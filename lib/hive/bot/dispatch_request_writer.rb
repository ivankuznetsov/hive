require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/paths"
require "hive/daemon/dispatch_request_queue"

module Hive
  module Bot
    # Writes a single dispatch request file into the daemon's queue
    # directory (`<state_home>/dispatch_requests/`). The bot is the
    # only producer today; the daemon's
    # `Hive::Daemon::DispatchRequestQueue` is the only consumer.
    #
    # The write is atomic: tmp file + `File.rename` to the final
    # path. A concurrent daemon scan therefore never observes a
    # partial JSON document — either the file is absent or it parses
    # whole. That's the whole reason this lives outside the bot's
    # process-supervised `ChildSupervisor`: the bot stops being a
    # child-process launcher for `hive run`-class verbs, and the
    # write here is the only side-effect we still need.
    module DispatchRequestWriter
      module_function

      SCHEMA = Hive::Daemon::DispatchRequestQueue::SCHEMA
      SCHEMA_VERSION = Hive::Daemon::DispatchRequestQueue::SCHEMA_VERSION

      # Build, atomic-write, and return the new request_id.
      #
      # Required:
      #   project: the project name (matches `hive status` rows).
      #   slug:    the task slug.
      #   argv:    `["hive", "<verb>", ...]`. The verb must already be
      #            in `Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS`
      #            — callers go through the same allowlist the daemon
      #            enforces so a typo at the call site doesn't write a
      #            request the daemon will reject + remove.
      #
      # Optional:
      #   chat_id, update_id — Telegram routing context. Carried through
      #     to telemetry only; the daemon does not read them.
      #   trigger — operator-facing reason for the request (e.g.
      #     "answer_complete", "autofix", "slash_done"). Telemetry only.
      #   state_home — test injection point.
      #   now — clock injection.
      def write!(project:, slug:, argv:, chat_id: nil, update_id: nil,
                 trigger: nil, state_home: Hive::Paths.state_home,
                 now: Time.now)
        unless Hive::Daemon::DispatchRequestQueue.valid_argv?(argv)
          # Caller bug: reject loudly so we never write a request the
          # daemon would discard + log as rejected. The bot test
          # harness asserts on this exception so the regression is
          # caught at the unit-test layer, not in the bot's runtime
          # logs.
          raise ArgumentError, "argv #{argv.inspect} is not allowlisted for dispatch requests"
        end

        request_id = SecureRandom.hex(8)
        created_at = now.utc
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "request_id" => request_id,
          "created_at" => created_at.iso8601,
          "project" => project.to_s,
          "slug" => slug.to_s,
          "argv" => argv,
          "requestor" => "bot",
          "chat_id" => chat_id,
          "update_id" => update_id,
          "trigger" => trigger.to_s
        }

        dir = Hive::Daemon::DispatchRequestQueue.directory(state_home: state_home)
        filename = Hive::Daemon::DispatchRequestQueue.filename_for(
          created_at: created_at, request_id: request_id
        )
        final_path = File.join(dir, filename)
        tmp_path = File.join(dir, ".#{filename}.tmp.#{Process.pid}.#{Thread.current.object_id}")

        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |f|
          f.write(JSON.generate(payload))
          f.flush
          begin
            f.fsync
          rescue StandardError
            # fsync is best-effort on exotic filesystems; the atomic
            # rename below still guarantees a consistent observable
            # state.
            nil
          end
        end
        File.rename(tmp_path, final_path)
        request_id
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end
    end
  end
end
