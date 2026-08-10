require "date"
require "json"
require "optparse"
require "hive/bot/logger"
require "hive/bot/notification_builders"
require "hive/bot/status_watcher"
require "hive/bot/telegram"
require "hive/bot/title_formatter"
require "hive/bot/waiting_rows"
require "hive/config"
require "hive/env_file"
require "hive/local_date_window"
require "hive/pr"

module Hive
  module Commands
    class AnswerDigest
      QUEUE_DISPLAY_CAP = 10

      # Per-row caps applied before the single Telegram send so one multi-KB
      # task name can't produce oversized message/button text that Telegram
      # rejects with a 400 (which would fail the whole digest). Generous enough
      # that a normal title is untouched.
      TITLE_DISPLAY_LIMIT = 120
      BUTTON_TEXT_LIMIT = 120

      SCHEMA = "hive-answer-digest".freeze

      # `hive status --json` came back unusable. A distinct, retryable failure
      # so a --json agent can tell a transient upstream outage (retry) from a
      # misconfiguration (fix) by EXIT CODE alone, not just the error_kind
      # string. Inherits Hive::UnavailableError's exit 69 (EX_UNAVAILABLE, "a
      # required service is unavailable") so an exit-code-only consumer can make
      # the retry-vs-fix decision; stays a Hive::Error subclass so the
      # `assert_raises(Hive::Error)` contract is unchanged.
      class StatusUnavailableError < Hive::UnavailableError; end

      # A malformed programmatic invocation (bad flag / unexpected argument via
      # `call(argv)`). Through Thor this path is unreachable — Thor validates
      # flags before dispatch and emits error_kind=usage itself — but a
      # programmatic `call(argv)` caller must get the same usage classification
      # (exit 64) rather than the config code (78) the ConfigError path reserves
      # for a bad --date / missing chat.
      class UsageError < Hive::Error
        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      # The closed vocabulary of suppression reasons. `nil` is a real send;
      # "empty" is nothing waiting; "dry_run" is a previewed-but-unsent digest.
      # `sent` is derived from this, so the illegal `sent:true, reason:"empty"`
      # state is unrepresentable.
      REASONS = [ nil, "empty", "dry_run" ].freeze

      # One waiting task in the JSON envelope's `tasks[]`. Promoted to a Data
      # type (matching the project's RowActions::Resolution/Action idiom) so
      # `Result` can assert every element is a Task rather than trusting an
      # unvalidated Array of string-keyed Hashes whose `{project,slug,id,title,
      # stage,pr}` shape was previously asserted in three disconnected places.
      Task = Data.define(:project, :slug, :id, :title, :stage, :pr) do
        def initialize(project:, slug:, id:, title:, stage:, pr:)
          # The schema pins `title` as a non-null string; enforce it at the type
          # boundary so a nil/non-string title can't reach a consumer (safe today
          # only because display_title always returns a string).
          unless title.is_a?(String)
            raise ArgumentError, "an answer-digest task requires a string title (got #{title.inspect})"
          end

          super
        end
      end

      Result = Data.define(:date, :message, :button_count, :chat_id, :reason, :dry_run, :count, :tasks) do
        def initialize(date:, message:, button_count:, chat_id:, reason:, dry_run:, count:, tasks:)
          unless REASONS.include?(reason)
            raise ArgumentError, "unknown answer-digest reason #{reason.inspect} (expected one of #{REASONS.inspect})"
          end
          # Validate the collection BEFORE any guard reads tasks.size/all?, so a
          # nil (or non-Array) tasks yields the same clean ArgumentError every
          # other invalid input does instead of a NoMethodError from nil.size.
          unless tasks.is_a?(Array) && tasks.all?(Task)
            raise ArgumentError, "answer-digest tasks must be an Array of #{Task} (got #{tasks.inspect})"
          end
          # A real send (reason nil) resolved a chat; an unsent result resolved
          # none — encode that here instead of leaving both representable.
          # Telegram chat ids are never 0, so treat a zero/blank chat as "no
          # chat" rather than a valid destination.
          if reason.nil? && (chat_id.nil? || chat_id.to_s.strip.empty? || chat_id.to_s.strip == "0")
            raise ArgumentError, "a sent answer-digest result requires a non-zero chat_id"
          end
          if !reason.nil? && !chat_id.nil?
            raise ArgumentError,
                  "an unsent answer-digest result (reason=#{reason.inspect}) must not carry a chat_id"
          end
          # `reason` and `dry_run` are two views of the same outcome; pin the two
          # cross-field combinations the reason↔chat_id guards above leave
          # representable: the "dry_run" reason is exactly a previewed-but-unsent
          # digest, and a real send (reason nil) is never a preview.
          if reason == "dry_run" && !dry_run
            raise ArgumentError, %(an answer-digest result with reason "dry_run" must have dry_run: true)
          end
          if reason.nil? && dry_run
            raise ArgumentError, "a sent answer-digest result (reason nil) must not be a dry run"
          end
          unless button_count >= 0 && count >= 0
            raise ArgumentError, "button_count and count must be non-negative (got #{button_count}, #{count})"
          end
          # `count` is the true waiting total and `tasks` carries one entry per
          # waiting task, so the two must agree — a `count: 1, tasks: []`
          # self-contradiction is otherwise representable.
          unless count == tasks.size
            raise ArgumentError, "count (#{count}) must equal tasks.size (#{tasks.size})"
          end
          if button_count > count
            raise ArgumentError, "button_count (#{button_count}) must not exceed count (#{count})"
          end
          # "empty" means nothing was waiting: no count and no digest text.
          # (count == tasks.size above already forces tasks empty when count 0.)
          if reason == "empty" && (count.positive? || !message.to_s.empty?)
            raise ArgumentError, %(an answer-digest result with reason "empty" must have count 0 and a blank message)
          end
          # A "dry_run" previews a NON-empty waiting set; an empty preview
          # collapses to reason "empty", so reason "dry_run" implies count > 0.
          if reason == "dry_run" && count.zero?
            raise ArgumentError, %(an answer-digest result with reason "dry_run" must have a non-empty waiting set (count > 0))
          end

          # Freeze the collection so the value object is not shallowly mutable,
          # matching the sibling RowActions::Resolution discipline.
          super(date: date, message: message, button_count: button_count, chat_id: chat_id,
                reason: reason, dry_run: dry_run, count: count, tasks: tasks.freeze)
        end

        # Fully derived from `reason`: a real send is the only outcome with no
        # suppression reason.
        def sent = reason.nil?
      end

      def initialize(date: nil, dry_run: false, json: false, output: $stdout, cfg: nil,
                     status_watcher: nil, telegram_factory: nil, env_loader: Hive::EnvFile,
                     config_loader: -> { { "bot" => Hive::Config.load_global_bot } },
                     logger: nil, now: -> { Time.now })
        @date = date
        @dry_run = dry_run
        @json = json
        @output = output
        @cfg = cfg
        @status_watcher = status_watcher
        @telegram_factory = telegram_factory || method(:build_telegram)
        @env_loader = env_loader
        @config_loader = config_loader
        @logger = logger
        @now = now
      end

      def call(argv = nil)
        parse_argv(argv) if argv
        date = parse_date
        cfg = @cfg || @config_loader.call
        @env_loader.load! unless @dry_run
        # Build the logger before selection (it was previously built lazily only
        # at send time, after selection). Otherwise on the daemon/CLI path the
        # per-row drop (:poll_failure) and button-build (:status_button_failed)
        # logging never fires, so a silently-dropped human-blocking row leaves no
        # trace — defeating the feature's "never silently forget a waiting task"
        # goal. /waiting already had a real logger; only this path was blind.
        logger(cfg)

        waiting = waiting_rows
        result = if waiting.empty?
                   Result.new(date: date, message: "", button_count: 0, chat_id: nil,
                              reason: "empty", dry_run: @dry_run, count: 0, tasks: [])
        else
                   deliver_waiting_digest(waiting, cfg, date)
        end
        # The Telegram send (when any) happens INSIDE deliver_waiting_digest,
        # after every fallible computation (selection, rendering, chat/token
        # resolution, Result validation). The only post-send statement is this
        # `emit`, which swallows its own EPIPE/JSON faults — so a failure here
        # can never turn a delivered digest into a non-zero exit that would make
        # the scheduler back off and re-send a DUPLICATE digest. No separate
        # `@delivered` flag is needed: there is no post-delivery code path that
        # can raise.
        emit(result)
        result
      rescue Hive::Error => e
        # A typed Hive fault (bad --date → ConfigError 78, status outage →
        # StatusUnavailableError 69, bad flag → UsageError 64) already carries
        # the right exit code; emit the structured envelope for a --json caller
        # and re-raise so bin/hive maps it to that code.
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        # An untyped fault (e.g. a Faraday transport fault from the Telegram
        # send) would otherwise escape bin/hive's Hive::Error/Thor::Error rescue
        # as a raw backtrace and a generic exit 1. Wrap it in Hive::InternalError
        # (exit 70, EX_SOFTWARE) — the same convention EnvelopeEmitter uses — so
        # `internal` is reachable and the schema's "internal → exit 70" contract
        # holds. Re-raise the wrapper so the daemon reads 70.
        wrapped = Hive::InternalError.new("hive answer-digest: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      private

      def parse_argv(argv)
        parser = OptionParser.new do |opts|
          opts.on("--date DATE") { |value| @date = value }
          opts.on("--dry-run") { @dry_run = true }
          opts.on("--json") { @json = true }
        end
        parser.parse!(Array(argv))
        # A bad flag / leftover positional is a malformed invocation (usage,
        # exit 64) — NOT a ConfigError (78), which the contract reserves for a
        # bad --date / missing chat.
        raise UsageError, "hive answer-digest: unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      rescue OptionParser::ParseError => e
        raise UsageError, "hive answer-digest: #{e.message}"
      end

      def parse_date
        raw = @date.to_s
        return Hive::LocalDateWindow.local_today(now: @now.call) if raw.empty?

        unless raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive answer-digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::LocalDateWindow.parse_date(raw)
      rescue ArgumentError
        raise Hive::ConfigError, "hive answer-digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def waiting_rows
        fetch_result = status_watcher.fetch
        unless fetch_result.ok
          message = fetch_result.respond_to?(:error) ? fetch_result.error.to_s : "unknown error"
          raise StatusUnavailableError, "hive status unavailable: #{message.empty? ? 'unknown error' : message}"
        end

        Hive::Bot::WaitingRows.select(fetch_result.rows, daemon_enabled: daemon_enabled_resolver,
                                                         logger: @logger)
      end

      def deliver_waiting_digest(rows, cfg, date)
        visible = rows.first(QUEUE_DISPLAY_CAP)
        text = render_digest(rows, visible)
        buttons = visible.filter_map { |row| Hive::Bot::WaitingRows.button_for(row, logger: @logger) }
                         .map { |button| bound_button(button) }
        keyboard = buttons.map { |button| [ button ] }
        tasks = rows.map { |row| task_descriptor(row) }

        if @dry_run
          return Result.new(date: date, message: text, button_count: buttons.size,
                            chat_id: nil, reason: "dry_run", dry_run: true, count: rows.size, tasks: tasks)
        end

        chat_id = Hive::Config.telegram_chat_id!(cfg.fetch("bot", {}))
        # Validate the Result (chat_id, counts, task types) BEFORE the
        # irreversible send, so a representable-but-invalid state can't surface
        # only AFTER the digest is delivered — which would re-raise and make the
        # scheduler back off and re-send a duplicate.
        result = Result.new(date: date, message: text, button_count: buttons.size,
                            chat_id: chat_id, reason: nil, dry_run: false, count: rows.size, tasks: tasks)
        token = Hive::Config.telegram_bot_token!
        telegram = @telegram_factory.call(token: token, logger: logger(cfg))
        telegram.send_message(chat_id: chat_id, text: text, reply_markup: keyboard)
        result
      end

      # Compact machine-readable descriptor for one waiting task so a --json
      # agent can learn how many and which tasks wait — the JSON `count`
      # reports the true total (not the 10-button display cap) and `tasks`
      # lists every waiting row, even on a real send where `message` is null.
      # Per-row guarded (parity with WaitingRows.select/button_for): a single
      # malformed row that raises in a reader degrades to a placeholder entry so
      # `count == tasks.size` holds and one bad row can't abort the whole
      # pre-send descriptor build.
      def task_descriptor(row)
        Task.new(
          project: (row.project if row.respond_to?(:project)),
          slug: (row.slug if row.respond_to?(:slug)),
          id: (row.id if row.respond_to?(:id)),
          title: Hive::Bot::NotificationBuilders.display_title(row),
          stage: (row.stage.to_s if row.respond_to?(:stage)),
          pr: pr_number(row)
        )
      rescue StandardError => e
        @logger&.event(:poll_failure, source: "answer_digest_task_descriptor",
                                      slug: (row.slug if row.respond_to?(:slug)),
                                      error_class: e.class.name, message: e.message)
        Task.new(project: nil, slug: nil, id: nil, title: "(unavailable)", stage: nil, pr: nil)
      end

      def render_digest(rows, visible)
        lines = [ "⏳ Waiting on you (#{rows.size})" ]
        visible.each do |row|
          line = digest_line(row)
          lines << line if line
        end
        if rows.size > QUEUE_DISPLAY_CAP
          lines << "+ #{rows.size - QUEUE_DISPLAY_CAP} more tasks — open on a laptop for the full list."
        end
        lines.join("\n")
      end

      # One rendered digest line for a row, or nil to drop it. Per-row guarded
      # (parity with button_for) so a single malformed row that raises in a
      # reader drops only its own line instead of aborting the whole pre-send
      # render — which would fail the single Telegram send and re-fetch the same
      # snapshot every retry, stranding the entire waiting set.
      def digest_line(row)
        "#{bounded_title(row)} — #{pr_label(row)} — " \
          "#{Hive::Bot::TitleFormatter.stage_label(row.stage, logger: @logger)}"
      rescue StandardError => e
        @logger&.event(:poll_failure, source: "answer_digest_render_line",
                                      slug: (row.slug if row.respond_to?(:slug)),
                                      error_class: e.class.name, message: e.message)
        nil
      end

      def pr_label(row)
        pr_number(row) || "—"
      end

      # The single source for a row's `#<number>` PR label, shared by the JSON
      # descriptor and the rendered line so the two can't drift.
      def pr_number(row)
        Hive::Pr.number(row.respond_to?(:pr_url) ? row.pr_url : nil)
      end

      # Telegram rejects oversized message/button text with a 400; a single
      # multi-KB task name would otherwise fail the whole digest send and strand
      # the day (the scheduler backs off and re-fetches the same snapshot,
      # failing identically). Bound the rendered title — and the final button
      # text — so one row can't poison the aggregate. The JSON `tasks[].title`
      # keeps the full title (it isn't sent to Telegram).
      def bounded_title(row)
        truncate(Hive::Bot::NotificationBuilders.display_title(row).to_s, TITLE_DISPLAY_LIMIT)
      end

      def bound_button(button)
        text = button.fetch(:text)
        return button if text.length <= BUTTON_TEXT_LIMIT

        button.merge(text: truncate(text, BUTTON_TEXT_LIMIT))
      end

      def truncate(text, limit)
        return text if text.length <= limit

        "#{text[0, limit - 1].rstrip}…"
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif @dry_run && !result.message.empty?
          @output.puts result.message
          @output.puts "Buttons: #{result.button_count}"
        elsif result.sent
          @output.puts "hive answer-digest: sent #{result.count} waiting task#{result.count == 1 ? '' : 's'}"
        end
      rescue Errno::EPIPE, JSON::GeneratorError
        # stdout closed (the reader hung up) or a value didn't encode. This is
        # the ONLY post-send statement, so swallowing here is what prevents a
        # delivered digest from re-raising into a non-zero exit and a duplicate
        # re-send. Sibling `--json` commands carry the same EPIPE/JSON guard.
        nil
      end

      def json_payload(result)
        {
          "schema" => SCHEMA,
          # Sourced from the single SCHEMA_VERSIONS registry so the emitted
          # version can't drift from the published schema.
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "date" => result.date.iso8601,
          "sent" => result.sent,
          "reason" => result.reason,
          "dry_run" => result.dry_run,
          "chat_id" => result.chat_id,
          # The number of inline buttons actually attached (capped at
          # QUEUE_DISPLAY_CAP); `count` is the true waiting total.
          "button_count" => result.button_count,
          "count" => result.count,
          "tasks" => result.tasks.map(&:to_h),
          "message" => digest_message(result)
        }
      end

      # `message` carries the rendered digest text only for a dry-run preview;
      # it is null on a real send (the text went to Telegram) and null on an
      # empty waiting set (there is no digest), matching the schema. Derived
      # from `result` so the empty+dry-run case is null, not "".
      def digest_message(result)
        return nil unless result.dry_run
        return nil if result.reason == "empty"

        result.message
      end

      # Every error reaching here is a Hive::Error (the #call rescue wraps an
      # untyped fault in Hive::InternalError first), so `exit_code` is always
      # defined and the envelope's exit code matches what bin/hive returns.
      def emit_error_envelope(error)
        @output.puts JSON.generate(
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.exit_code,
          "message" => error.message
        )
      rescue Errno::EPIPE, JSON::GeneratorError
        # A broken stdout pipe (or an unencodable message) while reporting the
        # error must not clobber the original error's exit code with a new
        # exception; the caller still re-raises the real fault. Matches the
        # EPIPE/JSON guard sibling `--json` commands carry.
        nil
      end

      def error_kind_for(error)
        return "config" if error.is_a?(Hive::ConfigError)
        return "status_unavailable" if error.is_a?(StatusUnavailableError)
        return "usage" if error.is_a?(UsageError)

        "internal"
      end

      # Delegates to the shared WaitingRows builder so /waiting and the digest
      # resolve daemon-managed plan pauses through one memoizing, fail-open,
      # config-error-logging implementation; only the log `source:` differs.
      # `@logger` is built before selection (see #call), so a broken project
      # config is logged on the digest path too, not invisible.
      def daemon_enabled_resolver
        Hive::Bot::WaitingRows.daemon_enabled_resolver(source: "answer_digest_daemon_check", logger: @logger)
      end

      def status_watcher
        @status_watcher ||= Hive::Bot::StatusWatcher.new(logger: @logger)
      end

      def build_telegram(token:, logger:)
        Hive::Bot::Telegram.new(token: token, logger: logger)
      end

      def logger(cfg)
        @logger ||= Hive::Bot::Logger.new(path: cfg.dig("bot", "log_file"))
      end
    end
  end
end
