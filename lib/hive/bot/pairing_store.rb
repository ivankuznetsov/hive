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

      Entry = Struct.new(:code, :chat_id, :created_at, keyword_init: true)

      attr_reader :path

      def initialize(state_home: Hive::Paths.state_home, now: -> { Time.now })
        @state_home = state_home
        @path = File.join(state_home, FILENAME)
        @now = now
      end

      def mint_or_get(chat_id:)
        with_lock do
          entries = pruned_entries(load_entries)
          existing = entries.find do |_code, payload|
            payload["chat_id"] == chat_id && !expired_payload?(payload)
          end
          return existing.first if existing

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
          entries = pruned_entries(load_entries)
          write_entries(entries)
          entry_structs(entries)
        end
      end

      def resolve_and_consume(code:)
        normalized = code.to_s.strip
        return :unknown if normalized.empty?

        with_lock do
          entries = load_entries
          payload = entries[normalized]
          unless payload
            pruned = pruned_entries(entries)
            write_entries(pruned) if pruned.length != entries.length
            return :unknown
          end

          entries.delete(normalized)
          write_entries(pruned_entries(entries))
          return :expired if expired_payload?(payload)

          payload["chat_id"]
        end
      end

      def prune_expired!
        with_lock do
          entries = load_entries
          pruned = pruned_entries(entries)
          write_entries(pruned)
          entries.length - pruned.length
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
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
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
