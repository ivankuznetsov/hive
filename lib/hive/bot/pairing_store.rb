require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/paths"

module Hive
  module Bot
    class PairingStore
      EXPIRY_SEC = 86_400
      CODE_LENGTH = 8
      CODE_ALPHABET = ("A".."Z").to_a.freeze
      FILENAME = ".bot.pairings.json".freeze

      # Frozen on construction: `pending` hands these back as a point-in-time
      # snapshot, so a consumer must not be able to mutate one and think it
      # changed the store.
      Entry = Struct.new(:code, :chat_id, :created_at, keyword_init: true) do
        def initialize(*)
          super
          freeze
        end
      end

      attr_reader :path

      # Codes are minted from an A–Z alphabet, so an operator who retypes one
      # by hand may pad it with whitespace or lowercase it. Strip + upcase so
      # those harmless variations still match the stored key.
      def self.normalize_code(code)
        code.to_s.strip.upcase
      end

      def initialize(state_home: Hive::Paths.state_home, now: -> { Time.now })
        @state_home = state_home
        @path = File.join(state_home, FILENAME)
        @now = now
      end

      def mint_or_get(chat_id:)
        with_lock do
          loaded = load_entries
          entries = pruned_entries(loaded)
          existing = entries.find do |_code, payload|
            payload["chat_id"] == chat_id && !expired_payload?(payload)
          end
          if existing
            # Persist the prune even on the reuse path, so expired sibling
            # codes don't linger on disk until some later write.
            write_entries(entries) if entries.length != loaded.length
            return existing.first
          end

          code = fresh_code(entries)
          entries[code] = {
            "chat_id" => chat_id,
            "created_at" => now.utc.iso8601
          }
          write_entries(entries)
          code
        end
      end

      def pending
        with_lock do
          entries = load_entries
          pruned = pruned_entries(entries)
          # `pending` is a read-mostly query (the digest and `hive pairing
          # list` both call it). Only rewrite when pruning actually removed an
          # entry — an unconditional tmp+rename+fsync on every call turned a
          # count into a write and crashed those paths on a read-only/full
          # state dir.
          write_entries(pruned) if pruned.length != entries.length
          entry_structs(pruned)
        end
      end

      # Look up a code WITHOUT consuming it. Returns the chat_id, :expired, or
      # :unknown. Kept separate from `consume` so callers can run their
      # fallible work (allowlist write, notice queue) before the destructive
      # delete — a failure before consume then leaves the code pending for a
      # clean retry instead of silently losing it.
      def resolve(code:)
        normalized = self.class.normalize_code(code)
        return :unknown if normalized.empty?

        with_lock do
          entries = load_entries
          payload = entries[normalized]
          unless payload
            pruned = pruned_entries(entries)
            write_entries(pruned) if pruned.length != entries.length
            return :unknown
          end

          expired_payload?(payload) ? :expired : payload["chat_id"]
        end
      end

      # Delete a code from the pending set. Idempotent: returns true when an
      # entry was removed, false when nothing matched.
      #
      # Protocol: `consume` is the SECOND phase of `resolve` → fallible work →
      # `consume`. It performs no validity check of its own — it deletes
      # whatever `code` you pass — so callers must `resolve` first and run
      # their fallible work BEFORE consuming. `approve` is the reference
      # implementation: it resolves (peeks), writes the allowlist + notice, and
      # only then consumes, so a failure in between leaves the code pending for
      # a clean retry. Consuming a code you never resolved (or one that resolved
      # `:expired`) silently drops it.
      def consume(code:)
        normalized = self.class.normalize_code(code)
        return false if normalized.empty?

        with_lock do
          entries = load_entries
          removed = entries.delete(normalized)
          write_entries(pruned_entries(entries)) unless removed.nil?
          !removed.nil?
        end
      end

      private

      def now
        @now.call
      end

      def with_lock
        FileUtils.mkdir_p(@state_home)
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def load_entries
        return {} unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        return {} unless data.is_a?(Hash)

        data.each_with_object({}) do |(code, payload), memo|
          next unless valid_code?(code)
          next unless payload.is_a?(Hash)
          next unless payload["chat_id"].is_a?(Integer)
          next unless parse_time(payload["created_at"])

          memo[code] = {
            "chat_id" => payload["chat_id"],
            "created_at" => payload["created_at"].to_s
          }
        end
      rescue JSON::ParserError, Errno::EACCES, IOError => e
        # A garbled or unreadable pairings file must not read as "no pending":
        # `hive pairing list` would print "No pending pairing requests." and
        # the owner could not tell empty from broken. Warn (the only
        # observability channel here — the store has no logger), then keep the
        # {} fallback so a corrupt file can't wedge minting/approval.
        warn "hive: pairing store at #{@path} is unreadable " \
             "(#{e.class}: #{e.message}); treating as empty"
        {}
      rescue Errno::ENOENT
        # Benign: the file vanished between the exist? check and the read.
        {}
      end

      def write_entries(entries)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = File.join(File.dirname(@path), ".#{File.basename(@path)}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
        File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(entries))
          file.write("\n")
          file.flush
          file.fsync
        end
        File.rename(tmp_path, @path)
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      def pruned_entries(entries)
        entries.reject { |_code, payload| expired_payload?(payload) }
      end

      def entry_structs(entries)
        entries.map do |code, payload|
          Entry.new(code: code, chat_id: payload["chat_id"], created_at: parse_time(payload["created_at"]))
        end.sort_by { |entry| [ entry.created_at, entry.code ] }
      end

      def expired_payload?(payload)
        created_at = parse_time(payload["created_at"])
        return true unless created_at

        (now - created_at) > EXPIRY_SEC
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def fresh_code(entries)
        loop do
          code = Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
          return code unless entries.key?(code)
        end
      end

      def valid_code?(code)
        code.to_s.match?(/\A[A-Z]{#{CODE_LENGTH}}\z/)
      end
    end
  end
end
