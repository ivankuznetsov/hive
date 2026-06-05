require "json"
require "fileutils"
require "time"
require "hive/daemon/dispatch_request_queue"

module Hive
  module Commands
    class Daemon
      # Read-only inspection surface for the dispatch-request queue
      # (`hive daemon queue list|show|prune`). Extracted from
      # `Commands::Daemon` (#254): the queue methods touch only
      # `queue_args` / `json` / `hive_home` — a cohesive concern orthogonal
      # to the start/stop/reload daemon lifecycle, mirroring the existing
      # `ServiceInstaller` extraction. `Commands::Daemon#queue_command`
      # delegates here.
      class QueueCommand
        def initialize(queue_args:, json:, hive_home:)
          @queue_args = Array(queue_args)
          @json = json
          @hive_home = hive_home
        end

        def call
          action = @queue_args[0] || "list"
          unless VALID_QUEUE_ACTIONS.include?(action)
            queue_usage_error!(action: action, error_kind: "unknown_action",
                               message: "hive daemon queue: unknown action #{action.inspect} " \
                                        "(expected: #{VALID_QUEUE_ACTIONS.join(', ')})")
          end

          case action
          when "list"  then queue_list
          when "show"  then queue_show(@queue_args[1])
          when "prune" then queue_prune
          end
        rescue Hive::InvalidTaskPath, Hive::Error
          # Already-structured failures (queue_usage_error! / queue_show
          # not-found) — re-raise for the exit code without re-emitting.
          raise
        rescue StandardError => e
          # Unexpected failure (IO/parse). Under --json an agent must still
          # get a parseable envelope rather than a bare stack trace (cli-1
          # from PR #244 ce-code-review). Wrap in InternalError so the exit
          # code is 70 (SOFTWARE), matching the envelope's
          # `error_kind: "internal"` (#262).
          emit_queue_error_envelope(action: @queue_args[0], error_kind: "internal",
                                    message: "#{e.class}: #{e.message}") if @json
          raise Hive::InternalError, "hive daemon queue #{@queue_args[0]}: #{e.class}: #{e.message}"
        end

        private

        # Emit a hive-daemon-queue error envelope (under --json) and raise a
        # USAGE-class error so the exit code is non-zero and a human sees
        # the message on stderr.
        def queue_usage_error!(action:, error_kind:, message:)
          emit_queue_error_envelope(action: action, error_kind: error_kind, message: message) if @json
          raise Hive::InvalidTaskPath, message
        end

        def emit_queue_error_envelope(action:, error_kind:, message:)
          puts JSON.generate(
            "schema" => "hive-daemon-queue",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-queue"),
            "ok" => false,
            "action" => action,
            "error_kind" => error_kind,
            "message" => message
          )
        end

        def queue_list
          requests, malformed = load_queue_requests
          if @json
            puts JSON.generate(queue_envelope(
                                 action: "list",
                                 requests: requests.map { |req| queue_request_hash(req) },
                                 malformed: malformed
                               ))
          else
            print_queue_list(requests, malformed)
          end
        end

        def queue_show(request_id)
          if request_id.to_s.empty?
            queue_usage_error!(action: "show", error_kind: "missing_request_id",
                               message: "hive daemon queue show: missing REQUEST_ID " \
                                        "(try `hive daemon queue list` first)")
          end

          requests, = load_queue_requests
          req = requests.find { |r| r.request_id == request_id }
          unless req
            if @json
              puts JSON.generate(queue_envelope(action: "show", ok: false, request: nil,
                                                request_id: request_id))
            else
              warn "hive daemon queue: no pending request with id #{request_id}"
            end
            raise Hive::Error, "request #{request_id} not found"
          end

          if @json
            puts JSON.generate(queue_envelope(action: "show", request: queue_request_hash(req)))
          else
            print_queue_show(req)
          end
        end

        # `prune` runs in a separate CLI process against the live queue dir
        # with no lock, so a request can be claimed+dispatched by the daemon
        # between the `pending` scan and removal. `remove_if_unclaimed` skips
        # any id the daemon has since claimed (never deleting a `.claimed`
        # file's crash-recovery state), and we count only files actually
        # unlinked — so the reported count is advisory under concurrency but
        # never over-reports a removal that a racing claim turned into a no-op
        # (#265).
        def queue_prune
          requests, malformed = load_queue_requests
          expired = requests.select do |req|
            Hive::Daemon::DispatchRequestQueue.expired?(req) &&
              Hive::Daemon::DispatchRequestQueue.remove_if_unclaimed(req.request_id, state_home: @hive_home)
          end
          malformed.each { |bad| FileUtils.rm_f(bad[:path]) }

          pruned = expired.length + malformed.length
          if @json
            puts JSON.generate(queue_envelope(
                                 action: "prune",
                                 pruned_count: pruned,
                                 requests: expired.map { |req| queue_request_hash(req) },
                                 malformed: malformed
                               ))
          else
            puts "hive daemon queue: pruned #{pruned} request(s) " \
                 "(#{expired.length} expired, #{malformed.length} malformed)"
          end
        end

        # Read + parse every pending request file, collecting malformed
        # entries separately so a single corrupt file never hides the rest.
        def load_queue_requests
          malformed = []
          requests = Hive::Daemon::DispatchRequestQueue.pending(
            state_home: @hive_home,
            bad_handler: ->(path:, reason:) { malformed << { path: path, reason: reason } }
          )
          [ requests, malformed ]
        end

        def queue_request_hash(req)
          {
            "request_id" => req.request_id,
            "created_at" => req.created_at.utc.iso8601,
            "age_sec" => (Time.now - req.created_at).to_i,
            "project" => req.project,
            "slug" => req.slug,
            "verb" => req.argv[1],
            "argv" => req.argv,
            "trigger" => req.trigger,
            "requestor" => req.requestor,
            "chat_id" => req.chat_id,
            "update_id" => req.update_id,
            "expired" => Hive::Daemon::DispatchRequestQueue.expired?(req),
            "allowlisted" => Hive::Daemon::DispatchRequestQueue.valid_argv?(req.argv)
          }
        end

        def queue_envelope(action:, ok: true, **extra)
          {
            "schema" => "hive-daemon-queue",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-queue"),
            "ok" => ok,
            "action" => action
          }.merge(extra.transform_keys(&:to_s))
        end

        def print_queue_list(requests, malformed)
          if requests.empty? && malformed.empty?
            puts "hive daemon queue: empty (no pending dispatch requests)"
            return
          end

          requests.each do |req|
            flags = []
            flags << "EXPIRED" if Hive::Daemon::DispatchRequestQueue.expired?(req)
            flags << "NOT-ALLOWLISTED" unless Hive::Daemon::DispatchRequestQueue.valid_argv?(req.argv)
            suffix = flags.empty? ? "" : " [#{flags.join(' ')}]"
            puts "#{req.request_id}  #{(Time.now - req.created_at).to_i}s  " \
                 "#{req.project}/#{req.slug}  #{req.argv[1]}#{suffix}"
          end
          malformed.each { |bad| puts "(malformed) #{bad[:path]}  reason=#{bad[:reason]}" }
          puts "#{requests.length} pending, #{malformed.length} malformed"
        end

        def print_queue_show(req)
          puts "request_id: #{req.request_id}"
          puts "created_at: #{req.created_at.utc.iso8601} (#{(Time.now - req.created_at).to_i}s ago)"
          puts "project:    #{req.project}"
          puts "slug:       #{req.slug}"
          puts "argv:       #{req.argv.inspect}"
          puts "trigger:    #{req.trigger}"
          puts "requestor:  #{req.requestor}"
          puts "chat_id:    #{req.chat_id.inspect}"
          puts "update_id:  #{req.update_id.inspect}"
          puts "expired:    #{Hive::Daemon::DispatchRequestQueue.expired?(req)}"
          puts "allowlisted:#{Hive::Daemon::DispatchRequestQueue.valid_argv?(req.argv)}"
        end
      end
    end
  end
end
