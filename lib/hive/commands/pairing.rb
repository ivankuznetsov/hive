require "json"
require "time"
require "yaml"
require "hive"
require "hive/config"
require "hive/paths"
require "hive/bot/pairing_store"
require "hive/bot/pairing_approval_queue"

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
        entries = @store.pending
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

        validate_current_bot_config!
        chat_id = resolve_code!(code)
        already_allowlisted = append_allowlist(chat_id)
        reloaded = signal_bot_reload
        notice_id = @approval_queue.write!(chat_id: chat_id)
        payload = approve_payload(
          code: code,
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

      def validate_current_bot_config!
        @config.load_global_bot
      end

      def resolve_code!(code)
        resolved = @store.resolve_and_consume(code: code)
        case resolved
        when Integer
          resolved
        when :expired
          raise ApprovalError.new("pairing code #{code} expired; ask the user to run /start again",
                                  error_kind: "expired_code")
        else
          raise ApprovalError.new("pairing code #{code} was not found", error_kind: "unknown_code")
        end
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
        pid = pid_file_payload(pid_file)["pid"]
        return false unless pid && pid_alive?(pid)

        @process.kill("HUP", pid)
        true
      rescue Errno::ESRCH, Errno::EPERM, Psych::Exception, SystemCallError, IOError
        false
      end

      def bot_config
        @bot_config ||= @config.load_global_bot
      end

      def pid_file_payload(path)
        return {} unless File.exist?(path)

        data = YAML.safe_load(File.read(path)) || {}
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception, SystemCallError, IOError
        {}
      end

      def pid_alive?(pid)
        @process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
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
