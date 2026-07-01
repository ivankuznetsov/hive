require "json"
require "time"
require "yaml"
require "hive"
require "hive/config"
require "hive/paths"
require "hive/bot/pairing_store"
require "hive/bot/pairing_approval_queue"
require "hive/pid_file"

module Hive
  module Commands
    class Pairing
      VALID_SUBCOMMANDS = %w[list approve].freeze
      APPROVE_PLATFORM = "telegram".freeze

      class ApprovalError < Hive::Error
        attr_reader :error_kind

        def initialize(message, error_kind:)
          @error_kind = error_kind
          super(message)
        end
      end

      def initialize(subcommand, args: [], json: false, output: $stdout,
                     store: Hive::Bot::PairingStore.new,
                     approval_queue: Hive::Bot::PairingApprovalQueue,
                     config: Hive::Config,
                     process: Process,
                     now: -> { Time.now })
        @subcommand = subcommand
        @args = Array(args)
        @json = json
        @output = output
        @store = store
        @approval_queue = approval_queue
        @config = config
        @process = process
        @now = now
      end

      def call
        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise Hive::InvalidTaskPath,
                "hive pairing: unknown subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end

        case @subcommand
        when "list" then list
        when "approve" then approve
        end
      rescue Hive::InvalidTaskPath, ApprovalError, Hive::ConfigError => e
        emit_error(e) if @json
        raise
      end

      private

      def list
        ensure_no_args!("list")
        entries = pending_entries
        if @json
          @output.puts JSON.generate(list_payload(entries))
        elsif entries.empty?
          @output.puts "No pending pairing requests."
        else
          print_table(entries)
        end
        entries
      end

      def approve
        platform, code, *extra = @args
        unless platform && code && extra.empty?
          raise Hive::InvalidTaskPath,
                "hive pairing approve: usage: hive pairing approve telegram <CODE>"
        end
        unless platform == APPROVE_PLATFORM
          raise Hive::InvalidTaskPath,
                "hive pairing approve: platform must be `telegram`; got #{platform.inspect}"
        end

        # Load + validate the global bot config once before any side effect.
        # `bot_config` memoizes the same load `signal_bot_reload` reuses, so
        # the config is read a single time per approve and a bad config fails
        # fast (exit 78) before the allowlist is touched.
        bot_config
        normalized_code = Hive::Bot::PairingStore.normalize_code(code)
        # Resolve (peek) without consuming, then run every fallible side
        # effect — the allowlist write and the approval-notice write — and
        # ONLY THEN consume the code. A failure before the consume leaves the
        # code pending so a retry works, instead of deleting it first and
        # losing it when the allowlist write or notice write blows up.
        chat_id = resolve_code!(normalized_code)
        already_allowlisted = append_allowlist(chat_id)
        reloaded = signal_bot_reload
        notice_id = write_approval_notice!(chat_id)
        consume_code!(normalized_code)
        payload = approve_payload(
          code: normalized_code,
          chat_id: chat_id,
          already_allowlisted: already_allowlisted,
          reloaded: reloaded,
          notice_id: notice_id
        )

        if @json
          @output.puts JSON.generate(payload)
        else
          @output.puts "Approved Telegram chat_id #{chat_id}."
          @output.puts "Bot reload requested." if reloaded
          @output.puts "Approval notice queued."
        end
        payload
      end

      def ensure_no_args!(subcommand)
        return if @args.empty?

        raise Hive::InvalidTaskPath,
              "hive pairing #{subcommand}: unexpected arguments: #{@args.join(' ')}"
      end

      # `PairingStore#pending` prunes-on-read and opens a lock file, so a
      # read-only/full state dir can make it raise SystemCallError/IOError. Turn
      # that into a clean envelope instead of a raw backtrace on `hive pairing
      # list`.
      def pending_entries
        @store.pending
      rescue SystemCallError, IOError => e
        raise ApprovalError.new("failed to read pending pairing requests: #{e.message}",
                                error_kind: "store_read_failed")
      end

      def resolve_code!(code)
        resolved = @store.resolve(code: code)
        case resolved
        when Integer
          resolved
        when :expired
          raise ApprovalError.new("pairing code #{code} expired; ask the user to run /start again",
                                  error_kind: "expired_code")
        when :unknown
          raise ApprovalError.new("pairing code #{code} was not found", error_kind: "unknown_code")
        else
          # The store contract is Integer | :expired | :unknown. Anything else
          # is a programming error — fail loudly instead of folding it into the
          # "not found" arm where a future sentinel could hide silently.
          raise ApprovalError.new("pairing code resolution returned unexpected value #{resolved.inspect}",
                                  error_kind: "internal_error")
        end
      end

      def write_approval_notice!(chat_id)
        @approval_queue.write!(chat_id: chat_id)
      rescue SystemCallError, IOError => e
        # The code is still pending at this point (consume runs after this), so
        # surface a clean envelope and leave it for a retry rather than
        # crashing with a raw backtrace after the chat was already allowlisted.
        raise ApprovalError.new("failed to queue approval notice: #{e.message}",
                                error_kind: "notice_write_failed")
      end

      # Consume runs LAST, after the allowlist write, reload, and notice write
      # have all succeeded — at which point the approval is complete. A
      # read-only/full state dir can still make `consume → write_entries`
      # raise, but that is best-effort cleanup of a now-redundant pending code:
      # never let it mask a completed approval with a raw backtrace (which
      # would also make a retry resolve into `unknown_code`). Warn and let the
      # success envelope through; the stale code expires on its own (24h).
      def consume_code!(code)
        @store.consume(code: code)
      rescue SystemCallError, IOError => e
        warn "hive: approval for code #{code} succeeded but the pending code " \
             "could not be consumed (#{e.class}: #{e.message}); it will expire on its own"
      end

      def append_allowlist(chat_id)
        already = false
        @config.update_global_config! do |data|
          bot = data["bot"]
          bot = {} unless bot.is_a?(Hash)
          data["bot"] = bot
          allowlist = Array(bot["chat_id_allowlist"])
          already = allowlist.include?(chat_id)
          bot["chat_id_allowlist"] = already ? allowlist : allowlist + [ chat_id ]
        end
        already
      end

      def signal_bot_reload
        pid_file = File.expand_path(bot_config.fetch("pid_file", File.join(Hive::Paths.state_home, ".bot.pid")))
        # Coerce defensively: a hand-edited `pid: "4242"` (string) would make
        # Process.kill raise TypeError *after* the allowlist write. Integer(…,
        # exception: false) yields nil for a non-numeric/missing pid, which we
        # treat as "bot not running".
        pid = Integer(pid_file_payload(pid_file)["pid"], exception: false)
        return false unless pid && pid_alive?(pid)

        @process.kill("HUP", pid)
        true
      rescue Errno::ESRCH
        # The process vanished between the alive probe and the signal — a
        # genuine "bot not running" race, not a failure to reach a live bot.
        false
      rescue SystemCallError, IOError => e
        # The bot IS live (the alive probe passed) but the SIGHUP did not land
        # (EPERM, a transient IOError, …). Surface it: the running bot keeps
        # serving the STALE allowlist until restart, so the freshly-approved
        # chat stays locked out — the operator must know to restart it.
        warn "hive: failed to signal live bot (pid #{pid}) to reload " \
             "(#{e.class}: #{e.message}); restart the bot so the new allowlist takes effect"
        false
      end

      def bot_config
        @bot_config ||= @config.load_global_bot
      end

      def pid_file_payload(path)
        Hive::PidFile.read(path)
      rescue Psych::Exception => e
        # Mirror commands/bot.rb: a corrupt PID file must not silently read as
        # "bot down". Surface it so the operator knows the live bot (if any)
        # was NOT reloaded — but, unlike bot.rb, do NOT raise: the allowlist
        # write has already landed, and aborting here would mask a completed
        # approval.
        warn "hive: bot PID file at #{path} is corrupted " \
             "(#{e.class}: #{e.message}); skipping live reload"
        {}
      rescue SystemCallError, IOError
        {}
      end

      def pid_alive?(pid)
        Hive::PidFile.alive?(pid, process: @process)
      end

      def list_payload(entries)
        {
          "schema" => "hive-pairing-list",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-pairing-list"),
          "ok" => true,
          "pending" => entries.map { |entry| pending_entry_payload(entry) }
        }
      end

      def approve_payload(code:, chat_id:, already_allowlisted:, reloaded:, notice_id:)
        {
          "schema" => "hive-pairing-approve",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-pairing-approve"),
          "ok" => true,
          "platform" => APPROVE_PLATFORM,
          "code" => code,
          "chat_id" => chat_id,
          "already_allowlisted" => already_allowlisted,
          "reloaded" => reloaded,
          "notice_queued" => true,
          "notice_id" => notice_id
        }
      end

      def emit_error(error)
        schema = @subcommand == "approve" ? "hive-pairing-approve" : "hive-pairing-list"
        @output.puts JSON.generate(
          "schema" => schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(schema),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        )
      end

      def error_kind(error)
        return error.error_kind if error.respond_to?(:error_kind)
        return "config" if error.is_a?(Hive::ConfigError)

        "invalid_arguments"
      end

      def print_table(entries)
        @output.puts format("%-10s %-16s %-25s %-8s %-10s",
                            "CODE", "CHAT_ID", "CREATED_AT", "AGE", "EXPIRES")
        entries.each do |entry|
          age = age_sec(entry)
          @output.puts format("%-10s %-16s %-25s %-8s %-10s",
                              entry.code, entry.chat_id, entry.created_at.utc.iso8601,
                              human_duration(age), human_duration(expires_in_sec(entry)))
        end
      end

      def pending_entry_payload(entry)
        {
          "code" => entry.code,
          "chat_id" => entry.chat_id,
          "created_at" => entry.created_at.utc.iso8601,
          "age_sec" => age_sec(entry),
          "expires_in_sec" => expires_in_sec(entry)
        }
      end

      def age_sec(entry)
        [ (@now.call - entry.created_at).to_i, 0 ].max
      end

      def expires_in_sec(entry)
        [ Hive::Bot::PairingStore::EXPIRY_SEC - age_sec(entry), 0 ].max
      end

      def human_duration(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60

        minutes = seconds / 60
        return "#{minutes}m" if minutes < 60

        hours = minutes / 60
        return "#{hours}h" if hours < 48

        "#{hours / 24}d"
      end
    end
  end
end
