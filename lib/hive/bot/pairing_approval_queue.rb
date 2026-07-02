require "json"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/paths"
require "hive/daemon/queue_directory"

module Hive
  module Bot
    module PairingApprovalQueue
      module_function

      SCHEMA = "hive-pairing-approval".freeze
      SCHEMA_VERSION = 1
      DIRNAME = "pairing_approvals".freeze
      EXPIRY_SEC = 3600

      # Frozen on construction: `pending` hands these back as a point-in-time
      # snapshot, so a consumer must not be able to mutate one and think it
      # changed the on-disk queue.
      Notice = Struct.new(:notice_id, :created_at, :chat_id, :path, keyword_init: true) do
        def initialize(*)
          super
          freeze
        end
      end

      def directory(state_home: Hive::Paths.state_home)
        Hive::Daemon::QueueDirectory.directory_for(dirname: DIRNAME, state_home: state_home)
      end

      def write!(chat_id:, state_home: Hive::Paths.state_home, now: Time.now)
        notice_id = SecureRandom.hex(8)
        created_at = now.utc
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "notice_id" => notice_id,
          "created_at" => created_at.iso8601,
          "chat_id" => chat_id
        }

        dir = directory(state_home: state_home)
        filename = "#{created_at.strftime('%Y%m%dT%H%M%S%6N')}-#{notice_id}.json"
        Hive::AtomicFile.write(File.join(dir, filename), JSON.generate(payload))
        notice_id
      end

      def pending(state_home: Hive::Paths.state_home, bad_handler: nil)
        dir = directory(state_home: state_home)
        entries = []
        Dir.glob(File.join(dir, "*.json")).each do |path|
          parsed = parse_file(path)
          if parsed == :io_error
            # Transient read fault: leave the file untouched for a later tick.
            # It is never routed to bad_handler, so a deleting drain cannot
            # discard a structurally-valid notice we simply could not read.
            next
          elsif parsed.is_a?(Symbol)
            bad_handler&.call(path: path, reason: parsed.to_s)
            next
          end
          entries << parsed
        end
        entries.sort_by { |notice| [ notice.created_at, notice.notice_id.to_s ] }
      end

      def expired?(notice, now: Time.now, expiry_sec: EXPIRY_SEC)
        return false unless notice.respond_to?(:created_at)

        created_at = notice.created_at
        return false unless created_at.is_a?(Time)

        (now - created_at) > expiry_sec
      end

      def remove(notice_id, state_home: Hive::Paths.state_home, path: nil)
        return false if notice_id.to_s.empty?

        # Fast path: `pending` already resolved each notice to its on-disk
        # path, so a caller that hands that path back lets us unlink directly
        # instead of re-globbing and re-parsing the whole directory.
        return remove_known_path(path, notice_id) unless path.nil?

        dir = directory(state_home: state_home)
        Dir.glob(File.join(dir, "*.json")).each do |candidate|
          next unless candidate.include?(notice_id.to_s)

          data = begin
            JSON.parse(File.read(candidate))
          rescue StandardError
            next
          end
          next unless data.is_a?(Hash) && data["notice_id"] == notice_id.to_s

          File.unlink(candidate)
          return true
        end
        false
      rescue Errno::ENOENT, Errno::EACCES
        # ENOENT: the file vanished (another drainer, or the reaper's prune).
        # EACCES: a read-only/perm-locked dir left the unlink un-performable —
        # a clean `false` lets the caller log + retry rather than crash.
        false
      end

      class << self
        private

        # Unlink the notice at its known path, verifying the notice_id still
        # matches the file's contents (a forged/stale path must not delete the
        # wrong file). Mirrors the by-id glob path's verification.
        def remove_known_path(path, notice_id)
          return false unless File.exist?(path)

          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            return false
          end
          return false unless data.is_a?(Hash) && data["notice_id"] == notice_id.to_s

          File.unlink(path)
          true
        rescue Errno::ENOENT, Errno::EACCES
          # ENOENT: the file vanished between resolve and unlink. EACCES: a
          # read-only/perm-locked dir — return a clean `false` so the caller
          # can log + retry instead of crashing the reaper tick.
          false
        end

        def parse_file(path)
          data = JSON.parse(File.read(path))
        rescue Errno::ENOENT, Errno::EACCES, IOError
          # A transient FS fault (perm-locked/NFS-hiccup dir, or the file
          # vanishing mid-drain) is NOT corruption. Keep it distinct from
          # :malformed_json so the caller leaves the notice on disk for a later
          # tick instead of deleting owner-authored state we merely failed to
          # read.
          :io_error
        rescue JSON::ParserError
          :malformed_json
        else
          return :not_a_hash unless data.is_a?(Hash)
          return :wrong_schema unless data["schema"] == SCHEMA
          return :unknown_schema_version unless data["schema_version"] == SCHEMA_VERSION

          notice_id = data["notice_id"].to_s
          return :missing_notice_id if notice_id.empty?

          created_at = begin
            Time.parse(data["created_at"].to_s)
          rescue ArgumentError
            nil
          end
          return :invalid_created_at if created_at.nil?
          return :invalid_chat_id unless data["chat_id"].is_a?(Integer)

          Notice.new(
            notice_id: notice_id,
            created_at: created_at,
            chat_id: data["chat_id"],
            path: path
          )
        end
      end
    end
  end
end
