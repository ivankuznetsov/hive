require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/paths"
require "hive/attempts/output_reference"
require "hive/daemon/queue_directory"

module Hive
  module Daemon
    # File-backed queue of dispatch requests written by external callers
    # (today: the Telegram bot) and consumed by the daemon dispatcher.
    module DispatchRequestQueue
      module_function

      SCHEMA = "hive-dispatch-request".freeze
      SCHEMA_VERSION = 3
      SUPPORTED_SCHEMA_VERSIONS = [ 2, 3 ].freeze

      ALLOWED_VERBS = %w[
        run develop brainstorm plan review open-pr artifacts finalize
        archive markers daemon
      ].freeze

      DIRNAME = "dispatch_requests".freeze

      # Sentinel project for host-global maintenance requests that aren't tied
      # to any registered project (e.g. the web "Repair daemon" button enqueues
      # `hive daemon install --force`). The consumer special-cases this value
      # instead of rejecting it as unknown_project. The argv allowlist below
      # bounds what a global request may run.
      GLOBAL_MAINTENANCE_PROJECT = "__global__".freeze
      GLOBAL_MAINTENANCE_ARGVS = [
        %w[hive daemon install --force]
      ].freeze

      CLAIMED_SUFFIX = ".claimed".freeze
      CLAIM_META_SUFFIX = ".claim".freeze
      SEQUENCE_SUFFIX = ".sequence".freeze

      SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/
      PROJECT_RE = /\A[A-Za-z0-9_.\-]+\z/

      Request = Struct.new(
        :request_id, :created_at, :project, :slug, :argv, :requestor,
        :chat_id, :update_id, :trigger, :task_generation,
        :predecessor_attempt_id, :inherited_outputs, :actor,
        :expected_fingerprint, :transition_destination, :schema_version, :path,
        keyword_init: true
      )
      ClaimedDelivery = Data.define(:request, :claim, :path)

      EXPIRY_SEC = 600
      CLAIM_EXPIRY_SEC = 14_400

      # Resolve (and mkdir, mode 0700) the requests directory via the shared
      # QueueDirectory helper so the owner-only invariant lives in one place
      # (#253).
      def directory(state_home: Hive::Paths.state_home)
        QueueDirectory.directory_for(dirname: DIRNAME, state_home: state_home)
      end

      def generate_request_id
        SecureRandom.hex(8)
      end

      def write_request!(project:, slug:, argv:, requestor: "bot", chat_id: nil,
                         update_id: nil, trigger: nil, request_id: generate_request_id,
                         task_generation: nil, predecessor_attempt_id: nil,
                         inherited_outputs: [], actor: nil, expected_fingerprint: nil,
                         transition_destination: nil,
                         state_home: Hive::Paths.state_home, now: Time.now)
        unless valid_argv?(argv)
          raise ArgumentError, "argv #{argv.inspect} is not allowlisted for dispatch requests"
        end
        raise ArgumentError, "project is required for dispatch requests" if project.to_s.empty?
        raise ArgumentError, "slug is required for dispatch requests" if slug.to_s.empty?
        Array(inherited_outputs).each do |reference|
          Hive::Attempts::OutputReference.validate_shape!(reference)
        rescue Hive::Attempts::InvalidOutputReference => e
          raise ArgumentError, e.message
        end

        created_at = now.utc
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "request_id" => request_id.to_s,
          "created_at" => created_at.iso8601(6),
          "project" => project.to_s,
          "slug" => slug.to_s,
          "argv" => argv,
          "requestor" => requestor.to_s,
          "chat_id" => chat_id,
          "update_id" => update_id,
          "trigger" => trigger.to_s,
          "task_generation" => task_generation,
          "predecessor_attempt_id" => predecessor_attempt_id,
          "inherited_outputs" => inherited_outputs || [],
          "actor" => actor,
          "expected_fingerprint" => expected_fingerprint,
          "transition_destination" => transition_destination
        }

        dir = directory(state_home: state_home)
        filename = filename_for(created_at: created_at, request_id: request_id)
        final_path = File.join(dir, filename)
        tmp_path = File.join(dir, ".#{filename}.tmp.#{Process.pid}.#{Thread.current.object_id}")
        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.generate(payload))
          f.flush
          f.fsync
        end
        File.rename(tmp_path, final_path)
        request_id.to_s
      ensure
        FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
      end

      def pending(state_home: Hive::Paths.state_home, bad_handler: nil)
        dir = directory(state_home: state_home)
        claimed_ids = claimed_request_ids(dir)
        entries = []
        Dir.glob(File.join(dir, "*.json")).each do |path|
          parsed = parse_file(path)
          if parsed.is_a?(Symbol)
            bad_handler&.call(path: path, reason: parsed.to_s)
            next
          end
          next if claimed_ids.include?(parsed.request_id)

          entries << parsed
        end
        entries.sort_by { |req| [ req.created_at, req.request_id.to_s ] }
      end

      def claimed(state_home: Hive::Paths.state_home, bad_handler: nil)
        directory_path = directory(state_home: state_home)
        Dir.glob(File.join(directory_path, "*.json#{CLAIMED_SUFFIX}")).sort.filter_map do |path|
          request = parse_file(path)
          if request.is_a?(Symbol)
            bad_handler&.call(path: path, reason: request.to_s)
            next
          end
          claim = read_claim_metadata(path)
          unless claim.is_a?(Hash)
            bad_handler&.call(path: path, reason: "missing_claim_metadata")
            next
          end

          ClaimedDelivery.new(request: request, claim: claim, path: path)
        end
      rescue Errno::ENOENT
        []
      end

      def remove(request_id, state_home: Hive::Paths.state_home)
        return false if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        removed = false
        request_files(dir).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          File.unlink(path)
          FileUtils.rm_f(claim_metadata_path(path)) if path.end_with?(CLAIMED_SUFFIX)
          discard_sequence(request_id, state_home: state_home)
          removed = true
        end
        removed
      rescue Errno::ENOENT
        false
      end

      # Remove a request only if it is still unclaimed — i.e. only the
      # pending `*.json` file, never a `*.json.claimed` the daemon has since
      # taken. `queue prune` runs in a separate CLI process with no lock, so
      # a request can be claimed+dispatched between the prune's `pending`
      # scan and its removal; deleting the `.claimed` sibling then would drop
      # a live claim's crash-recovery state (#265). Returns true only when an
      # unclaimed pending file was actually unlinked, so prune counts reflect
      # real removals rather than racing claims.
      def remove_if_unclaimed(request_id, state_home: Hive::Paths.state_home)
        return false if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        return false if claimed_request_ids(dir).include?(request_id.to_s)

        removed = false
        Dir.glob(File.join(dir, "*.json")).each do |path|
          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          File.unlink(path)
          discard_sequence(request_id, state_home: state_home)
          removed = true
        end
        removed
      rescue Errno::ENOENT
        false
      end

      # Mark a request as claimed before spawn. The claimed JSON remains a
      # schema-valid hive-dispatch-request; pid/start metadata lives in a
      # `.claim` sidecar and can be updated after spawn.
      def claim(request_id, pid:, process_start_time: nil, now: Time.now,
                attempt_id: nil, task_generation: nil,
                state_home: Hive::Paths.state_home)
        return nil if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json")).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          claimed_path = "#{path}#{CLAIMED_SUFFIX}"
          File.rename(path, claimed_path)
          write_claim_metadata(
            claimed_path, pid: pid, process_start_time: process_start_time, now: now,
            attempt_id: attempt_id, task_generation: task_generation
          )
          # The `.claimed` rename is the at-most-once commit point. fsync the
          # directory so both that rename and the sidecar's rename survive an
          # unclean shutdown — otherwise a power loss could leave the claim
          # un-persisted and the request re-dispatchable on restart (#248).
          fsync_directory(dir)
          return claimed_path
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      def update_claim(request_id, pid:, process_start_time: nil, now: Time.now,
                       attempt_id: nil, task_generation: nil,
                       state_home: Hive::Paths.state_home)
        return nil if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}")).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          write_claim_metadata(
            path, pid: pid, process_start_time: process_start_time, now: now,
            attempt_id: attempt_id, task_generation: task_generation
          )
          return path
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      def release_claim(request_id, state_home: Hive::Paths.state_home)
        return false if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}")).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          pending_path = path.delete_suffix(CLAIMED_SUFFIX)
          File.rename(path, pending_path)
          FileUtils.rm_f(claim_metadata_path(path))
          return true
        end
        false
      rescue Errno::ENOENT
        false
      end

      # `alive:` is required: it must be a `->(pid, process_start_time)` that
      # returns whether the claim's owner is still running. A nil/omitted
      # `alive` would short-circuit `alive && alive.call(...)` to false and
      # silently reap every non-aged-out claim, including live orphans (#250).
      def recover_claims(state_home: Hive::Paths.state_home, now: Time.now,
                         alive:, attempt_alive: nil, attempt_for_request: nil,
                         expiry_sec: CLAIM_EXPIRY_SEC, handler: nil)
        dir = directory(state_home: state_home)
        removed = 0
        Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}")).each do |path|
          data = parse_json_hash(path)
          unless data
            File.unlink(path) if File.exist?(path)
            FileUtils.rm_f(claim_metadata_path(path))
            handler&.call(request_id: nil, reason: "malformed_claim", path: path)
            removed += 1
            next
          end

          request_id = data["request_id"]
          claim = read_claim_metadata(path)
          attempt_id = claim && claim["attempt_id"]
          task_generation = claim && claim["task_generation"]
          if attempt_id.to_s.empty? && attempt_for_request
            correlation = attempt_for_request.call(request_id)
            if correlation
              attempt_id = correlation.fetch(:attempt_id)
              task_generation = correlation.fetch(:task_generation)
              write_claim_metadata(
                path, pid: claim && claim["pid"],
                process_start_time: claim && claim["process_start_time"],
                now: now, attempt_id: attempt_id, task_generation: task_generation
              )
            end
          end
          if !attempt_id.to_s.empty? && attempt_alive
            next if attempt_alive.call(attempt_id, task_generation)
          end
          aged_out = claim_aged_out?(claim, now: now, expiry_sec: expiry_sec)
          owner_alive = !aged_out && alive &&
                        alive.call(claim && claim["pid"], claim && claim["process_start_time"])
          next if owner_alive

          File.unlink(path) if File.exist?(path)
          FileUtils.rm_f(claim_metadata_path(path))
          discard_sequence(request_id, state_home: state_home) if request_id
          remove_pending_sibling(dir, request_id) if request_id
          reason = aged_out ? "claim_expired" : "owner_gone"
          handler&.call(request_id: request_id, reason: reason, path: path)
          removed += 1
        end
        removed
      rescue Errno::ENOENT
        0
      end

      def metadata(request_id, state_home: Hive::Paths.state_home)
        return nil if request_id.to_s.empty?

        dir = directory(state_home: state_home)
        request_files(dir).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          return {
            chat_id: data["chat_id"], update_id: data["update_id"],
            project: data["project"], slug: data["slug"],
            requestor: data["requestor"], actor: data["actor"],
            expected_fingerprint: data["expected_fingerprint"],
            transition_destination: data["transition_destination"],
            task_generation: data["task_generation"],
            predecessor_attempt_id: data["predecessor_attempt_id"]
          }
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      def write_sequence!(request_id, remaining_argvs:, state_home: Hive::Paths.state_home)
        remaining = Array(remaining_argvs)
        return discard_sequence(request_id, state_home: state_home) if remaining.empty?

        unless remaining.all? { |argv| valid_argv?(argv) }
          raise ArgumentError, "sequence contains an argv that is not allowlisted"
        end

        path = sequence_path(directory(state_home: state_home), request_id)
        tmp_path = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.generate("request_id" => request_id.to_s, "remaining_argvs" => remaining))
          f.flush
          f.fsync
        end
        File.rename(tmp_path, path)
        true
      ensure
        FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
      end

      def discard_sequence(request_id, state_home: Hive::Paths.state_home)
        return false if request_id.to_s.empty?

        path = sequence_path(directory(state_home: state_home), request_id)
        existed = File.exist?(path)
        FileUtils.rm_f(path)
        existed
      rescue Errno::ENOENT
        false
      end

      def promote_sequence(request_id, project:, slug:, requestor: "bot", chat_id: nil,
                           update_id: nil, actor: nil, expected_fingerprint: nil,
                           transition_destination: nil, trigger: "sequence_continuation",
                           state_home: Hive::Paths.state_home, now: Time.now)
        dir = directory(state_home: state_home)
        path = sequence_path(dir, request_id)
        sequence = read_sequence(path)
        return nil if sequence.empty?

        next_argv = sequence.shift
        next_request_id = write_request!(
          project: project, slug: slug, argv: next_argv, requestor: requestor,
          chat_id: chat_id, update_id: update_id, trigger: trigger,
          actor: actor, expected_fingerprint: expected_fingerprint,
          transition_destination: transition_destination,
          state_home: state_home, now: now
        )
        if sequence.empty?
          FileUtils.rm_f(path)
        else
          write_sequence!(next_request_id, remaining_argvs: sequence, state_home: state_home)
          FileUtils.rm_f(path)
        end
        Request.new(
          request_id: next_request_id, created_at: now.utc, project: project.to_s,
          slug: slug.to_s, argv: next_argv, requestor: requestor.to_s,
          chat_id: chat_id, update_id: update_id, trigger: trigger.to_s,
          task_generation: nil, predecessor_attempt_id: nil, inherited_outputs: [],
          actor: actor, expected_fingerprint: expected_fingerprint,
          transition_destination: transition_destination,
          schema_version: SCHEMA_VERSION, path: nil
        )
      end

      # Queue files remain delivery records. Ownership resolution is delegated
      # to the same dispatcher used by foreground callers.
      def dispatch(request, dispatcher:, **options)
        dispatcher.dispatch_request(request, **options)
      end

      def valid_argv?(argv)
        return false unless argv.is_a?(Array)
        return false if argv.length < 2
        return false unless argv.all? { |tok| tok.is_a?(String) && !tok.empty? }
        return false unless argv[0] == "hive"

        verb = argv[1].to_s
        return false unless ALLOWED_VERBS.include?(verb)

        # The `daemon` verb runs host-global maintenance, not project-scoped
        # work. Constrain it to the explicit GLOBAL_MAINTENANCE_ARGVS allowlist
        # so a request carrying a real registered+enabled project can't smuggle
        # `hive daemon stop|disable|restart` through the generic project route
        # (which would execute a host-wide daemon command). The feature only
        # needs `hive daemon install --force` under the __global__ sentinel.
        return GLOBAL_MAINTENANCE_ARGVS.include?(argv) if verb == "daemon"

        return true if argv.length < 3
        return true if argv[2].start_with?("-")
        return true if verb == "markers"

        SLUG_RE.match?(argv[2])
      end

      def filename_for(created_at:, request_id:)
        ts = created_at.utc.strftime("%Y%m%dT%H%M%S%6N")
        "#{ts}-#{request_id}.json"
      end

      def expired?(request, now: Time.now, expiry_sec: EXPIRY_SEC)
        return false unless request.respond_to?(:created_at)

        created = request.created_at
        return false unless created.is_a?(Time)

        (now - created) > expiry_sec
      end

      def request_files(dir)
        Dir.glob(File.join(dir, "*.json")) +
          Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}"))
      end

      def claimed_request_ids(dir)
        Dir.glob(File.join(dir, "*.json#{CLAIMED_SUFFIX}")).each_with_object([]) do |path, ids|
          data = parse_json_hash(path)
          ids << data["request_id"] if data && data["request_id"]
        end
      end

      def remove_pending_sibling(dir, request_id)
        Dir.glob(File.join(dir, "*.json")).each do |path|
          next unless path.include?(request_id.to_s)

          data = parse_json_hash(path)
          next unless data && data["request_id"] == request_id.to_s

          File.unlink(path) if File.exist?(path)
        end
      end

      def claim_aged_out?(claim, now:, expiry_sec:)
        return true unless claim.is_a?(Hash)

        claimed_at = claim["claimed_at"]
        return true if claimed_at.to_s.empty?

        (now - Time.parse(claimed_at.to_s)) > expiry_sec
      rescue ArgumentError
        true
      end

      def sequence_path(dir, request_id)
        File.join(dir, "#{request_id}#{SEQUENCE_SUFFIX}")
      end

      def read_sequence(path)
        data = JSON.parse(File.read(path))
        remaining = data.is_a?(Hash) ? data["remaining_argvs"] : nil
        return [] unless remaining.is_a?(Array)
        return [] unless remaining.all? { |argv| valid_argv?(argv) }

        remaining
      rescue Errno::ENOENT, JSON::ParserError, IOError
        []
      end

      # Persist directory entries (renames/unlinks) so they survive an
      # unclean shutdown. Best-effort: not every platform/filesystem allows
      # opening a directory for fsync, and a failure here must not abort the
      # claim it is hardening.
      def fsync_directory(dir)
        File.open(dir) { |d| d.fsync }
      rescue StandardError
        nil
      end

      def claim_metadata_path(claimed_path)
        "#{claimed_path}#{CLAIM_META_SUFFIX}"
      end

      def write_claim_metadata(claimed_path, pid:, process_start_time:, now:,
                               attempt_id: nil, task_generation: nil)
        path = claim_metadata_path(claimed_path)
        tmp_path = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.generate(
            "pid" => pid,
            "process_start_time" => process_start_time,
            "claimed_at" => now.utc.iso8601(6),
            "attempt_id" => attempt_id,
            "task_generation" => task_generation
          ))
          f.flush
          f.fsync
        end
        File.rename(tmp_path, path)
      ensure
        FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
      end

      def read_claim_metadata(claimed_path)
        JSON.parse(File.read(claim_metadata_path(claimed_path)))
      rescue Errno::ENOENT, JSON::ParserError, IOError
        nil
      end

      def parse_json_hash(path)
        data = JSON.parse(File.read(path))
        data if data.is_a?(Hash)
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
        nil
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
          schema_version = data["schema_version"]
          return :unknown_schema_version unless SUPPORTED_SCHEMA_VERSIONS.include?(schema_version)

          request_id = data["request_id"].to_s
          return :missing_request_id if request_id.empty?

          project = data["project"].to_s
          return :missing_project if project.empty?
          return :invalid_project unless PROJECT_RE.match?(project)

          slug = data["slug"].to_s
          return :missing_slug if slug.empty?
          return :invalid_slug unless SLUG_RE.match?(slug)

          argv = data["argv"]
          # The schema declares `argv minItems: 2` (argv[0]=hive, argv[1]=verb);
          # mirror it here so a single-element argv doesn't parse into a row
          # whose `verb => argv[1]` is nil in `queue list` (#259).
          return :invalid_argv unless argv.is_a?(Array) && argv.length >= 2

          created_at = parse_time(data["created_at"])
          return :invalid_created_at if created_at.nil?

          if schema_version == 3
            required_v3 = %w[task_generation predecessor_attempt_id inherited_outputs]
            return :missing_v3_fields unless required_v3.all? { |key| data.key?(key) }
            return :invalid_inherited_outputs unless data["inherited_outputs"].is_a?(Array)
            begin
              data["inherited_outputs"].each do |reference|
                Hive::Attempts::OutputReference.validate_shape!(reference)
              end
            rescue Hive::Attempts::InvalidOutputReference
              return :invalid_inherited_outputs
            end
          end

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
            task_generation: data["task_generation"],
            predecessor_attempt_id: data["predecessor_attempt_id"],
            inherited_outputs: data["inherited_outputs"].is_a?(Array) ? data["inherited_outputs"] : [],
            actor: data["actor"],
            expected_fingerprint: data["expected_fingerprint"],
            transition_destination: data["transition_destination"],
            schema_version: schema_version,
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
