require "json"
require "fileutils"
require "time"
require "hive"
require "hive/config"
require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/bot/status_watcher"
require "hive/bot/notification_dispatcher"
require "hive/bot/conversation_store"
require "hive/bot/router"
require "hive/bot/child_supervisor"
require "hive/bot/dispatch_request_writer"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/dispatch_result_queue"
require "hive/paths"
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"
require "hive/bot/title_formatter"
require "hive/task"
require "hive/update_check/state"

module Hive
  module Bot
    class Supervisor
      BOT_COMMANDS = [
        { command: "idea",    description: "Capture a new idea" },
        { command: "status",  description: "Show active tasks" },
        { command: "queue",   description: "Show queued and waiting tasks" },
        { command: "answer",  description: "Answer brainstorm questions: /answer <slug>" },
        { command: "approve", description: "Approve a task at its current stage: /approve <slug>" },
        { command: "autofix", description: "Retry a stuck task: /autofix <slug>" },
        { command: "details", description: "Show diagnostic detail: /details <slug>" },
        { command: "done",    description: "Mark a brainstorm as done after answering" },
        { command: "help",    description: "Show available commands" }
      ].freeze

      def initialize(config:, token:, logger: nil, telegram: nil, status_watcher: nil,
                     notification_dispatcher: nil, router: nil, child_supervisor: nil,
                     conversation_store: nil, dry_run: false, update_state: nil,
                     dispatch_request_writer: nil, dispatch_result_state_home: nil)
        @config = config
        @dry_run = dry_run
        # ADV-1: where the daemon drops dispatch-result failure notices.
        # Tests inject a sandbox; production resolves Hive::Paths.state_home.
        @dispatch_result_state_home = dispatch_result_state_home
        # Shared update-check state (written by the daemon). The bot owns the
        # once-per-version push; the daemon never touches last_notified_version.
        @update_state = update_state || Hive::UpdateCheck::State.new
        # Process-lifetime latch of versions already pushed. Backs up the
        # persisted dedup: if record_notified! can't write (read-only/full
        # state dir), this still stops the status loop re-pushing every tick.
        @nudged_versions = {}
        @logger = logger || Hive::Bot::Logger.new(
          path: config.fetch("log_file"),
          max_bytes: config.fetch("log_max_bytes"),
          max_files: config.fetch("log_max_files")
        )
        @telegram = telegram || Hive::Bot::Telegram.new(token: token, logger: @logger)
        @status_watcher = status_watcher || Hive::Bot::StatusWatcher.new(logger: @logger)
        @conversation_store = conversation_store ||
          Hive::Bot::ConversationStore.new(ttl_sec: config.fetch("conversation_ttl_sec"))
        @router = router || build_router(config)
        @child_supervisor = child_supervisor ||
          Hive::Bot::ChildSupervisor.new(logger: @logger, dry_run: dry_run)
        # Producer-only handle to the daemon's dispatch-request queue.
        # Tests inject a fake; production uses the module's module_function
        # interface directly. `nil` is acceptable for dry-run / no-op modes
        # where the writer is intentionally unused. Plan 2026-05-28-002.
        @dispatch_request_writer = dispatch_request_writer || Hive::Bot::DispatchRequestWriter
        @notification_dispatcher = notification_dispatcher ||
          Hive::Bot::NotificationDispatcher.new(
            telegram: @telegram,
            logger: @logger,
            bot_config: config
          )
        @shutdown = false
        @reload = false
        last_seen = read_last_seen_update_id
        @next_update_id = last_seen ? last_seen + 1 : nil
        @started_at = Time.now
        emit_deprecated_config_events!
      end

      def run_forever
        install_signal_handlers!
        @logger.event(:bot_started, pid: Process.pid, dry_run: @dry_run, version: Hive::VERSION)
        register_bot_commands
        threads = [
          Thread.new { poll_loop },
          Thread.new { status_loop },
          Thread.new { reaper_loop }
        ]
        threads.each(&:join)
      ensure
        @logger.event(:bot_stopping, in_flight: @child_supervisor.in_flight_count,
                                      grace_sec: @config.fetch("shutdown_grace_sec", 60))
        @child_supervisor.terminate_all(grace_sec: @config.fetch("shutdown_grace_sec", 60))
        @logger.close
      end

      def request_shutdown!
        @shutdown = true
      end

      def request_reload!
        @reload = true
      end

      def process_update(update)
        # Telegram requires answerCallbackQuery on every callback_query
        # update to dismiss the spinner on the tapped button. Ack first so
        # the spinner clears even if subsequent dispatch is slow; the call
        # is silent (no toast) by design.
        ack_callback_query(update) if callback_update?(update)
        result = @router.handle(update)
        execute_result(result, update)
        write_last_seen_update_id(update.update_id)
      end

      def callback_update?(update)
        return update.callback_query? if update.respond_to?(:callback_query?)

        update.respond_to?(:callback_data) && !update.callback_data.nil?
      end

      def ack_callback_query(update)
        id = update.respond_to?(:callback_query_id) ? update.callback_query_id : nil
        return unless id

        @telegram.answer_callback_query(callback_query_id: id)
      rescue StandardError => e
        @logger.event(:send_failure, source: "answer_callback_query",
                                      callback_query_id: id, error_class: e.class.name,
                                      message: e.message)
      end

      # One-shot RPC at bot start. Intentionally not re-called on SIGHUP/
      # config reload — commands don't change with config.
      def register_bot_commands
        @telegram.set_my_commands(commands: BOT_COMMANDS)
      rescue StandardError => e
        @logger.event(:send_failure, source: "set_my_commands",
                                      error_class: e.class.name, message: e.message)
      end

      def status_tick
        result = @status_watcher.fetch
        return result unless result.ok

        @latest_status_rows = result.rows
        @notification_dispatcher.process_rows(notification_inputs_for(result))
        result
      end

      # Read-only snapshot of the most recent successful StatusWatcher
      # fetch, populated by status_tick on the status_loop thread. Used by
      # /autofix and /details to resolve a slug to its current row.
      #
      # Returns nil until the first successful tick — callers treat nil as
      # "status not loaded yet" (the status_loop ticks immediately on bot
      # start, so this window is brief). We deliberately do NOT fall back to
      # a synchronous @status_watcher.fetch here: that fetch shells out via
      # Open3.capture3 with no timeout, and running it on the poll thread
      # would let a hung `hive status` stall the long-poll loop, after which
      # Telegram redelivers the un-acked update and the same /autofix
      # double-fires the recovery sequence. status_tick only assigns on a
      # successful fetch, so a transient failure never poisons this cache.
      def latest_status_rows
        @latest_status_rows
      end

      def reap_children
        @child_supervisor.reap_all.each { |child| reply_for_child(child) }
      end

      def send_reconnect_summary(updates)
        return if updates.empty?

        count = updates.size
        text = "👋 Hive is back online, #{count} #{count == 1 ? 'message' : 'messages'} queued"
        chat_ids.each { |chat_id| safe_send_message(chat_id: chat_id, text: text) }
        @logger.event(:reconnect_summary, queued_count: count)
      end

      private

      # Single construction point for the Router so the boot path and the
      # SIGHUP reload path cannot drift. The status_snapshot_provider wiring
      # used to live only in the constructor; reload_config_if_requested
      # rebuilt the Router without it, silently breaking /autofix and
      # /details (every slug replied "Slug not found") after any
      # `hive bot reload` until a full restart.
      def build_router(config)
        Hive::Bot::Router.new(
          bot_config: config,
          logger: @logger,
          conversation_store: @conversation_store,
          status_snapshot_provider: -> { latest_status_rows }
        )
      end

      def notification_inputs_for(result)
        Array(result.rows) + (result.respond_to?(:legacy_stage_dirs) ? Array(result.legacy_stage_dirs) : [])
      end

      def poll_loop
        first_poll = true
        until @shutdown
          begin
            reload_config_if_requested
            updates = @telegram.poll_updates(
              timeout: @config.fetch("long_poll_timeout_sec"),
              since_update_id: @next_update_id
            )
            if first_poll
              queued = queued_updates(updates)
              send_reconnect_summary(queued)
              first_poll = false
            end
            updates.each do |update|
              begin
                process_update(update)
              rescue StandardError => e
                @logger.event(:fatal, source: "process_update", error_class: e.class.name,
                                       message: e.message, backtrace: Array(e.backtrace).first(10).join("\n"))
              end
              @next_update_id = update.update_id + 1
            end
          rescue StandardError => e
            @logger.event(:fatal, source: "poll_loop", error_class: e.class.name,
                                   message: e.message, backtrace: Array(e.backtrace).first(10).join("\n"))
            interruptible_sleep(1)
          end
        end
      end

      def status_loop
        until @shutdown
          begin
            reload_config_if_requested
            status_tick
            push_update_nudge
          rescue StandardError => e
            @logger.event(:fatal, source: "status_loop", error_class: e.class.name,
                                   message: e.message, backtrace: Array(e.backtrace).first(10).join("\n"))
          end
          interruptible_sleep(@config.fetch("poll_interval_sec"))
        end
      end

      def reaper_loop
        until @shutdown
          begin
            reap_children
            drain_dispatch_results
          rescue StandardError => e
            @logger.event(:fatal, source: "reaper_loop", error_class: e.class.name,
                                   message: e.message, backtrace: Array(e.backtrace).first(10).join("\n"))
          end
          sleep 1
        end
      end

      # Max individual failure messages relayed per drain. A larger
      # backlog (e.g. the bot was down while many runs failed) is
      # collapsed into one summary line so a reconnect can't flood the
      # chat or trip Telegram's per-chat rate limit (ADV-1 / #6).
      DISPATCH_RESULT_SEND_CAP = 10

      # ADV-1: drain the daemon's failure-notice channel and relay each
      # notice to the chat that initiated the run. The daemon is the
      # single dispatcher and has no Telegram handle, so this is the only
      # surface that turns a non-zero daemon-spawned exit into
      # operator-visible feedback (beyond the marker-driven status alert).
      #
      # Reliability contract:
      #   - A notice is removed ONLY after the relay is confirmed sent. If
      #     Telegram is down, `safe_send_message` returns nil and the
      #     notice stays on disk to retry on the next reaper tick (#1) —
      #     never a silent drop.
      #   - Stale notices (older than EXPIRY_SEC) are removed WITHOUT
      #     sending: an hour-old "failed" ping is noise, and this bounds
      #     directory growth alongside the daemon's prune (#6).
      #   - Malformed notices are removed quietly so they can't wedge the
      #     drain.
      # Public + `now:`-injectable so tests can drive one drain
      # deterministically.
      def drain_dispatch_results(now: Time.now)
        notices = Hive::Daemon::DispatchResultQueue.pending(
          state_home: dispatch_result_state_home,
          bad_handler: ->(path:, reason:) { FileUtils.rm_f(path) }
        )
        fresh = notices.reject do |notice|
          next false unless Hive::Daemon::DispatchResultQueue.expired?(notice, now: now)

          remove_dispatch_result(notice) # stale: drop without relaying
          true
        end

        fresh.first(DISPATCH_RESULT_SEND_CAP).each do |notice|
          sent = safe_send_message(chat_id: notice.chat_id, text: dispatch_failure_text(notice))
          remove_dispatch_result(notice) if sent
        end

        relay_dispatch_result_overflow(fresh.drop(DISPATCH_RESULT_SEND_CAP))
      end

      # Collapse a too-large backlog tail into a single summary message
      # per chat, removing those notices only if the summary actually
      # sent (same no-silent-drop contract as the individual path).
      def relay_dispatch_result_overflow(overflow)
        return if overflow.empty?

        overflow.group_by(&:chat_id).each do |chat_id, group|
          sent = safe_send_message(
            chat_id: chat_id,
            text: "⚠️ +#{group.size} more dispatch failures suppressed (see daemon.log)."
          )
          group.each { |notice| remove_dispatch_result(notice) } if sent
        end
      end

      def remove_dispatch_result(notice)
        Hive::Daemon::DispatchResultQueue.remove(
          notice.result_id, state_home: dispatch_result_state_home
        )
      end

      def dispatch_failure_text(notice)
        verb = Array(notice.command.to_s.split).fetch(1, "run")
        # A timeout/signal-killed child has a nil exit_code (Process::Status
        # #exitstatus is nil when terminated by a signal) — render it as a
        # kill rather than "exit ".
        status = notice.exit_code.nil? ? "killed (signal/timeout)" : "exit #{notice.exit_code}"
        "⚠️ #{notice.slug}: `hive #{verb}` failed (#{status}). " \
          "Check the task or retry — open it on a laptop if it keeps failing."
      end

      def dispatch_result_state_home
        @dispatch_result_state_home || Hive::Paths.state_home
      end

      def safe_send_message(chat_id:, text:, reply_markup: nil)
        @telegram.send_message(chat_id: chat_id, text: text, reply_markup: reply_markup)
      rescue StandardError => e
        @logger.event(:send_failure, chat_id: chat_id, error_class: e.class.name, message: e.message)
        nil
      end

      ALLOWED_RESULT_ACTIONS = %i[
        noop reply dispatch_then_reply dispatch_commands start_answer
        write_answer_then_reply
      ].freeze

      def execute_result(result, update)
        case result.action
        when :noop
          nil
        when :reply
          safe_send_message(chat_id: update.chat_id, text: result.text,
                            reply_markup: result.reply_markup)
        when :dispatch_then_reply
          execute_dispatch(result, update)
        when :dispatch_commands
          dispatch_command_sequence(result, update)
        when :start_answer
          start_answer(result, update)
        when :write_answer_then_reply
          execute_answer_write(result, update)
        else
          raise "Supervisor cannot execute unknown action #{result.action.inspect}"
        end
      end

      def dispatch_command_sequence(result, update)
        clear_inline_keyboard(update) if result.respond_to?(:clear_keyboard) && result.clear_keyboard
        commands = Array(result.commands)
        reset_pending = !@dry_run && needs_alert_reset?(result)

        # If every command in the sequence is queue-routable (the
        # common case post-refactor: `markers clear` + `develop`/`review`/`pr`),
        # write all requests in arrival order and let the daemon's
        # per-slug in-flight gate serialise execution. There is no
        # bot-side PID to wait on, so the prior "wait for first to
        # succeed before dispatching the next" semantics is replaced
        # by the daemon's per-slug serialisation. Plan 2026-05-28-002.
        if commands.all? { |argv| queue_routable?(argv) }
          return enqueue_command_sequence(commands, result, update)
        end

        failed = false
        commands.each_with_index do |argv, idx|
          per_command = @router.class::Result.new(
            action: :dispatch_then_reply,
            command_argv: argv,
            project: result.project,
            slug: result.slug
          )
          last_pid = execute_dispatch(per_command, update)
          # last_pid is an Integer (spawned) or a String request_id
          # (queue-routed). Only Integer PIDs can be waited on. A
          # mixed sequence (one queue command, one spawned) falls
          # through to the legacy path; today's mixes don't exist but
          # the guard documents the contract for future surfaces.
          if idx < commands.length - 1 && last_pid.is_a?(Integer)
            unless wait_for_child_success(last_pid, deadline: Time.now + (@config.fetch("clear_retry_grace_sec", 30)))
              safe_send_message(chat_id: update.chat_id, text: "Stopped because the previous command failed.")
              failed = true
              break
            end
            # First non-final command (typically `markers clear`) succeeded.
            # Clear the alert NOW so the row no longer carries a recovery marker
            # before the retry verb dispatches and before the next status tick.
            # This closes the race window where reset-before-dispatch would let
            # process_current re-alert the same fingerprint within seconds of
            # the Autofix tap.
            if reset_pending
              reset_alert_for_result(result)
              reset_pending = false
            end
          end
        end
        # Single-command paths (e.g., AGENT_WORKING markers that skip
        # markers-clear) reach here without ever hitting the between-command
        # sync point above. Reset the alert post-dispatch — only if we did not
        # bail out of the loop on a failed precursor.
        reset_alert_for_result(result) if reset_pending && !failed
      end

      # Queue path for `dispatch_command_sequence`: write each request
      # in arrival order and return. If any write raises,
      # `enqueue_dispatch_request` has already surfaced a corrective
      # Telegram reply and logged.
      #
      # AC-05 (PR #241 ce-code-review): this path deliberately does NOT
      # reset the alert. Unlike the spawn path — which waits for
      # `markers clear` to succeed and only then resets, so the marker
      # is already gone when the fingerprint is removed — the queue path
      # has no completion signal to wait on. Resetting at enqueue time
      # removes the alert-store fingerprint while the error marker is
      # still on disk (the daemon hasn't run `markers clear` yet), so
      # the next status tick sees `entry.nil?` in
      # NotificationDispatcher#process_current and RE-FIRES the same
      # alert — a duplicate ⚠ within seconds of the Autofix tap. Leaving
      # the fingerprint in place keeps the persistent dedupe intact;
      # state-driven recovery (`process_recoveries`) removes the alert
      # naturally once the daemon clears the marker (or the row goes
      # live-running and leaves the alerting set). The inline keyboard is
      # already cleared on tap via `clear_inline_keyboard`, so the
      # operator still sees immediate acknowledgement of their action.
      def enqueue_command_sequence(commands, result, update)
        commands.each do |argv|
          per_command = @router.class::Result.new(
            action: :dispatch_then_reply,
            command_argv: argv,
            project: result.project,
            slug: result.slug
          )
          enqueue_dispatch_request(per_command, update)
        end
        nil
      end

      def needs_alert_reset?(result)
        reset = result.alert_reset
        reset ? true : false
      end

      def reset_alert_for_result(result)
        reset = result.alert_reset
        return unless reset

        @notification_dispatcher.reset_task(project: reset[:project], slug: reset[:slug],
                                            stage: reset[:stage], marker: reset[:marker],
                                            match_attr: reset[:match_attr])
      end

      def render_status_json(envelope, project_filter)
        return "{}" if envelope.nil?

        if project_filter && !project_filter.to_s.empty?
          filtered = envelope.merge(
            "projects" => Array(envelope["projects"]).select { |p| p["name"] == project_filter }
          )
          ::JSON.pretty_generate(filtered)
        else
          ::JSON.pretty_generate(envelope)
        end
      end

      def project_filter_miss_text(project, rows, legacy_stage_dirs = [])
        registered = registered_project_names
        active = (Array(rows) + Array(legacy_stage_dirs)).map { |row| row.project.to_s }.uniq
        if registered.include?(project.to_s) || active.include?(project.to_s)
          "No tasks for project #{project}."
        else
          known = (registered + active).uniq.sort
          known_list = known.empty? ? "(none registered)" : known.join(", ")
          "Unknown project #{project}. Known: #{known_list}."
        end
      end

      def registered_project_names
        Array(Hive::Config.registered_projects).map { |entry| entry.is_a?(Hash) ? entry["name"].to_s : entry.to_s }
      rescue StandardError
        []
      end

      def clear_inline_keyboard(update)
        return unless update.respond_to?(:message_id) && update.message_id && update.chat_id

        @telegram.edit_message_reply_markup(chat_id: update.chat_id, message_id: update.message_id,
                                            reply_markup: nil)
      rescue StandardError => e
        @logger.event(:send_failure, source: "edit_message_reply_markup",
                                      chat_id: update.chat_id, message_id: update.message_id,
                                      error_class: e.class.name, message: e.message)
      end

      def wait_for_child_success(pid, deadline:)
        loop do
          match = @child_supervisor.completed_exit(pid) if @child_supervisor.respond_to?(:completed_exit)
          unless match
            completed = @child_supervisor.reap_all
            completed.each { |child| reply_for_child(child) }
            match = completed.find { |child| child.pid == pid }
          end
          if match
            return match.exit_code.to_i.zero?
          end

          break if Time.now >= deadline

          sleep 0.1
        end
        false
      end

      def execute_dispatch(result, update)
        if status_command?(result.command_argv)
          fetch_result = @status_watcher.fetch
          unless fetch_result.ok
            error = fetch_result.error.to_s.strip
            error = "unknown error" if error.empty?
            safe_send_message(chat_id: update.chat_id, text: "hive status unavailable: #{error}")
            return nil
          end

          if result.respond_to?(:format) && result.format == :json
            safe_send_message(chat_id: update.chat_id,
                              text: render_status_json(fetch_result.envelope, result.project))
            return nil
          end

          rows = fetch_result.rows
          legacy_stage_dirs = status_legacy_stage_dirs(fetch_result)
          if result.project && !result.project.to_s.empty?
            filtered_rows = rows.select { |row| row.project == result.project }
            filtered_legacy_stage_dirs = legacy_stage_dirs.select { |row| row.project == result.project }
            if filtered_rows.empty? && filtered_legacy_stage_dirs.empty?
              safe_send_message(
                chat_id: update.chat_id,
                text: project_filter_miss_text(result.project, rows, legacy_stage_dirs)
              )
              return nil
            end
            rows = filtered_rows
            legacy_stage_dirs = filtered_legacy_stage_dirs
          end
          if result.slug
            safe_send_message(chat_id: update.chat_id, text: render_details(rows, result.project, result.slug))
          else
            safe_send_message(chat_id: update.chat_id,
                              text: render_queue(rows, legacy_stage_dirs: legacy_stage_dirs),
                              reply_markup: status_keyboard(rows))
          end
          return nil
        end

        if @dry_run
          safe_send_message(chat_id: update.chat_id, text: "Dry run: #{result.command_argv.join(' ')}")
          return nil
        end

        # State-mutating `hive` verbs (run/develop/brainstorm/plan/
        # review/open-pr/artifacts/finalize/archive/markers) route
        # through the daemon's dispatch-request queue so there is one
        # writer of those verbs — the daemon — and the
        # post-completion mtime baseline stays current. Plan
        # 2026-05-28-002. Read-only verbs (status/--diagnose, new,
        # approve) keep the in-process spawn path because they don't
        # bump task state-file mtime and don't cause the dual-writer
        # bug.
        if queue_routable?(result.command_argv)
          return enqueue_dispatch_request(result, update)
        end

        project_path = project_path_for(result.project)
        pid = @child_supervisor.dispatch(
          command_argv: result.command_argv,
          cwd: project_path || Dir.pwd,
          chat_id: update.chat_id,
          update_id: update.update_id,
          project: result.project,
          slug: result.slug
        )
        # No "Queued command pid=..." ack — that's operational chatter the
        # operator does not need. The reaper still surfaces failures (and
        # diagnose replies still fire for Show details), so silence here
        # is signal-preserving.
        pid
      end

      # True iff argv[1] is in the daemon's queue allowlist. The bot
      # rewrites this kind of dispatch into a request-file write; the
      # daemon picks the request up on its next tick and spawns the
      # child. See plan 2026-05-28-002 for why.
      def queue_routable?(argv)
        Hive::Daemon::DispatchRequestQueue.valid_argv?(Array(argv))
      end

      # Write a dispatch request for `result.command_argv` and log
      # `:dispatched_command` with `via=queue` so an operator tailing
      # bot.log can tell the two dispatch surfaces apart. Returns the
      # request_id so callers that previously held onto a PID can
      # still chain. Existing chain points (dispatch_command_sequence's
      # `wait_for_child_success`) now degrade: there is no PID to
      # wait on. The retry verb is enqueued anyway and the per-slug
      # in-flight gate on the daemon side serialises the two.
      def enqueue_dispatch_request(result, update)
        request_id = @dispatch_request_writer.write!(
          project: result.project,
          slug: result.slug,
          argv: Array(result.command_argv),
          chat_id: update.chat_id,
          update_id: update.update_id,
          trigger: trigger_for_result(result)
        )
        @logger.event(:dispatched_command,
                      project: result.project,
                      slug: result.slug,
                      command: Array(result.command_argv).join(" "),
                      update_id: update.update_id,
                      via: "queue",
                      request_id: request_id)
        request_id
      rescue StandardError => e
        # A producer-side failure (read-only state dir, ENOSPC, an
        # invalid argv slipped past the router) must not crash the
        # poll loop. Surface a corrective reply and log so an operator
        # can recover.
        @logger.event(:send_failure, source: "enqueue_dispatch_request",
                                      chat_id: update.chat_id,
                                      slug: result.slug,
                                      error_class: e.class.name,
                                      message: e.message)
        safe_send_message(
          chat_id: update.chat_id,
          text: "Couldn't queue the request (#{e.class}). Try again, or open this on a laptop."
        )
        nil
      end

      # A coarse trigger label for telemetry. The router doesn't carry
      # a fine-grained reason today; "slash" vs. "callback" is the
      # best we can do without invasive Router changes. The daemon
      # only reads this for log lines.
      def trigger_for_result(result)
        intent = result.respond_to?(:intent) ? result.intent : nil
        case intent
        when :slash_done then "slash_done"
        when :callback_autofix, :callback_clear_and_retry then "autofix"
        when :callback_approve then "callback_approve"
        when :callback_findings_accept_all then "findings_accept"
        when :callback_findings_reject_all then "findings_reject"
        else "bot_dispatch"
        end
      end

      def execute_answer_write(result, update)
        path = brainstorm_path_for(result.slug, project: result.project)
        unless path
          safe_send_message(chat_id: update.chat_id, text: "Slug not found, was it archived?")
          return
        end

        question_n = result.question_n || next_unanswered_question_n(path)
        unless question_n
          safe_send_message(chat_id: update.chat_id, text: "No unanswered questions remain for #{result.slug}.")
          return
        end

        write_result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: question_n,
          answer_text: result.answer_text,
          logger: @logger
        )
        case write_result
        when :written
          @logger.event(:answer_written, slug: result.slug, question_n: question_n,
                                         project: result.project)
          advance_conversation_after_write(result, update, path)
          prompt_next_question_or_complete(result, update, path, question_n)
        when :already_answered
          @logger.event(:answer_skipped_already_answered, slug: result.slug,
                                                         question_n: question_n,
                                                         project: result.project)
          safe_send_message(chat_id: update.chat_id,
                            text: "Question #{question_n} was already answered by another device")
        when :lock_busy
          safe_send_message(chat_id: update.chat_id, text: "Try again - another run holds the lock")
        when :answer_slot_missing
          # Q{n} IS in the brainstorm file but no empty `### A{n}.`
          # slot was locatable, even via the by-position fallback. The
          # agent likely emitted a mis-numbered header (e.g. `### A2.`
          # right after `### Q1.` for a fresh Round 2 — observed on
          # explore-the-simplest-way-to-260528-2503). The user used to
          # get "Question N was not found" here, which is misleading
          # because the question IS there.
          @logger.event(:answer_slot_missing, slug: result.slug,
                                              question_n: question_n,
                                              project: result.project)
          expected_a = Hive::Bot::BrainstormParser.answer_header(question_n)
          expected_q = Hive::Bot::BrainstormParser.question_header(question_n)
          safe_send_message(
            chat_id: update.chat_id,
            text: "Question #{question_n}'s answer slot is missing or malformed " \
                  "in brainstorm.md. The brainstorm agent likely emitted a " \
                  "mis-numbered `### A.` header. Ensure exactly one empty " \
                  "`#{expected_a}` sits immediately after `#{expected_q}` " \
                  "(remove any stale mis-numbered `### A.` header in between), " \
                  "then try again."
          )
        else
          safe_send_message(chat_id: update.chat_id, text: "Question #{question_n} was not found.")
        end
      end

      # After a successful answer write, fetch the NEXT unanswered question
      # from disk and send it to the operator so the Q-by-Q flow continues
      # without the operator having to know what to answer next. When no
      # questions remain, clear the conversation state and confirm with one
      # "Brainstorm complete" message.
      def prompt_next_question_or_complete(result, update, brainstorm_path, answered_n)
        next_question = Hive::Bot::BrainstormParser.next_unanswered_question(
          Hive::Bot::BrainstormParser.parse(brainstorm_path)
        )
        if next_question
          safe_send_message(
            chat_id: update.chat_id,
            text: "Got Q#{answered_n}.\n\nQ#{next_question.n}: #{next_question.text.to_s.strip}\n\n" \
                  "Reply with your answer."
          )
        else
          finalize_completed_brainstorm(result, update, answered_n)
        end
      end

      # All questions answered. Acknowledge the final answer and auto-dispatch
      # `hive run <slug>` so the daemon picks up the completed brainstorm
      # without the operator having to send /done.
      def finalize_completed_brainstorm(result, update, answered_n)
        if @dry_run
          # Dry-run never dispatches; say so instead of promising a run that
          # won't happen. Leave the conversation intact so /done still works.
          safe_send_message(
            chat_id: update.chat_id,
            text: "Got Q#{answered_n}.\n\n✅ All questions answered. " \
                  "Dry-run: not dispatching `hive run` — send /done to dispatch for real."
          )
          return
        end

        safe_send_message(
          chat_id: update.chat_id,
          text: "Got Q#{answered_n}.\n\n✅ All questions answered — brainstorm Q&A complete. " \
                "Running the next round automatically; I'll ping you when there's something to do."
        )
        auto_run_after_answers(result, update)
      end

      def auto_run_after_answers(result, update)
        per_command = @router.class::Result.new(
          action: :dispatch_then_reply,
          command_argv: [ "hive", "run", result.slug, "--json" ],
          project: result.project,
          slug: result.slug
        )
        dispatched_request_id = execute_dispatch(per_command, update)
        # C2 from PR #241 ce-code-review: ONLY clear the conversation
        # after a successful enqueue. `enqueue_dispatch_request`
        # rescues internally and returns nil on failure (write to a
        # read-only state dir, ENOSPC, ArgumentError on invalid argv
        # slipped past the router). Without the nil-check the
        # conversation would be cleared while the request was never
        # queued — the operator's `/done` backstop would then find
        # no conversation to re-dispatch.
        return unless dispatched_request_id

        @conversation_store.clear(chat_id: update.chat_id, slug: result.slug)
      rescue StandardError => e
        @logger.event(:send_failure, source: "auto_run_after_answers",
                                      slug: result.slug, error_class: e.class.name,
                                      message: e.message)
        safe_send_message(
          chat_id: update.chat_id,
          text: "I couldn't start the next round automatically (#{e.class}). " \
                "Send /done to retry."
        )
      end

      def start_answer(result, update)
        # Backfill project from the on-disk brainstorm path. The
        # `/answer <slug>` slash command doesn't carry project (slugs
        # are unique enough in practice), but downstream the queue
        # writer needs project for `find_project` lookup, so we infer
        # it once here and stash it on the conversation state.
        resolved_project = result.project || brainstorm_project_for(result.slug)
        path = brainstorm_path_for(result.slug, project: resolved_project)
        question =
          if path
            Hive::Bot::BrainstormParser.next_unanswered_question(
              Hive::Bot::BrainstormParser.parse(path)
            )
          end

        unless question
          safe_send_message(chat_id: update.chat_id,
                            text: "No unanswered questions for #{result.slug}.")
          return
        end

        @conversation_store.start(chat_id: update.chat_id, slug: result.slug,
                                  question_n: question.n, mode: result.mode || :path_b,
                                  project: resolved_project)
        safe_send_message(
          chat_id: update.chat_id,
          text: "Q#{question.n}: #{question.text.to_s.strip}\n\nReply with your answer."
        )
      end

      def advance_conversation_after_write(result, update, brainstorm_path)
        state = @conversation_store.get(chat_id: update.chat_id, slug: result.slug)
        return unless state

        next_question = Hive::Bot::BrainstormParser.next_unanswered_question(
          Hive::Bot::BrainstormParser.parse(brainstorm_path)
        )
        if next_question
          @conversation_store.update(chat_id: update.chat_id, slug: result.slug,
                                     question_n: next_question.n)
        else
          @conversation_store.update(chat_id: update.chat_id, slug: result.slug,
                                     question_n: result.question_n + 1)
        end
      end

      def reply_for_child(child)
        text = diagnose_reply_for_child(child) || child_completion_text(child)
        return if text.nil?

        @telegram.send_message(chat_id: child.chat_id, text: text)
      end

      def diagnose_reply_for_child(child)
        envelope = child.json_envelope
        return nil unless envelope.is_a?(Hash) && envelope["schema"] == "hive-status-diagnose"
        if envelope["ok"] == true
          diagnostic = envelope["diagnostic"].is_a?(Hash) ? envelope["diagnostic"] : {}
          slug = envelope["slug"] || child.slug
          return "No diagnostic available for #{slug}." if diagnostic.empty? && envelope["path"].to_s.strip.empty?

          return "Diagnosis is available for \"#{Hive::Bot::TitleFormatter.title_from_slug(slug)}\". " \
                 "Tap Show details to dump it here."
        end

        kind = envelope["error_kind"].to_s.strip
        message = envelope["message"].to_s.strip
        exit_code = envelope["exit_code"] || child.exit_code
        prefix = "Diagnosis failed"
        prefix += " (#{kind})" unless kind.empty?
        text = "#{prefix}: #{message.empty? ? "exit #{exit_code}" : message}"
        child.log_path ? "#{text}; see #{child.log_path}" : text
      end

      def child_completion_text(child)
        if child.exit_code == Hive::ExitCodes::WRONG_STAGE
          "Already advanced by another device"
        elsif child.exit_code == Hive::ExitCodes::TEMPFAIL
          "Try again - another run holds the lock"
        elsif child.exit_code == 0
          # Clean success — no message for most commands. Operators see the
          # signal via the next status row (or its absence). The lone
          # exception is `hive new`: idea capture is fire-and-forget with no
          # status row the operator is watching, so silence made a successful
          # capture look like a dead button — and because the picker token is
          # consumed on tap, a confused re-tap then reported "idea picker
          # expired". Acknowledge it so the operator knows the idea landed.
          new_capture_text(child)
        else
          "Command failed with exit #{child.exit_code || 'unknown'}; see #{child.log_path}"
        end
      end

      # argv[0] is rewritten to the resolved hive binary by
      # ChildSupervisor#normalize_hive_bin, so key on the verb at argv[1].
      def new_capture_text(child)
        argv = Array(child.command_argv)
        return nil unless argv[1].to_s == "new"

        project = child.project || argv[2]
        suffix = project ? " in #{project}" : ""
        "Captured your idea#{suffix}. It's in the inbox — move it to 2-brainstorm to start."
      end

      QUEUE_DISPLAY_CAP = 10

      def render_queue(rows, legacy_stage_dirs: [])
        actionable = actionable_queue_rows(rows)
        legacy_lines = legacy_stage_dirs.map do |row|
          Hive::Bot::NotificationBuilders.legacy_stage_dirs(row).text
        end
        return (legacy_lines + [ "No active Hive tasks." ]).join("\n") if actionable.empty?

        lines = actionable.first(QUEUE_DISPLAY_CAP).map do |row|
          "#{Hive::Bot::TitleFormatter.title_from_slug(row.slug)} — " \
            "#{Hive::Bot::TitleFormatter.stage_label(row.stage, logger: @logger)}"
        end
        header = "#{actionable.size} active task#{actionable.size == 1 ? '' : 's'}"
        if actionable.size > QUEUE_DISPLAY_CAP
          lines << "+ #{actionable.size - QUEUE_DISPLAY_CAP} more tasks — open on a laptop for the full list."
        end
        (legacy_lines + [ header ] + lines).join("\n")
      end

      # Inline keyboard for the /status (and /queue) reply: one button per
      # actionable row that has a Telegram-side next step, capped to match
      # the text body. Returns nil when no row is actionable, so the reply
      # stays text-only.
      #
      # Why buttons and not text "/command <slug>" links: Telegram's
      # bot_command message entity covers only the "/command" token, NOT the
      # argument after it. Tapping a rendered "/answer <slug>" sends just
      # "/answer", which hits the usage hint — the slug never rides along.
      # Inline callback buttons carry the full payload on tap, in-chat. The
      # callbacks are built via NotificationBuilders so they are byte-
      # identical to (and compaction/registry-consistent with) the push-
      # notification buttons.
      def status_keyboard(rows)
        buttons = actionable_queue_rows(rows).first(QUEUE_DISPLAY_CAP)
                                             .filter_map { |row| status_action_button(row) }
        buttons.empty? ? nil : buttons.map { |btn| [ btn ] }
      end

      # One primary action button for a row, or nil when the row has no
      # Telegram-side next step. Mirrors the push-notification surface:
      #   needs_input + 2-brainstorm + waiting → Answer  (answer: callback)
      #   ready_to_*                            → Approve (approve: callback)
      #   recover_* AND retryable_recovery?     → Autofix (autofix: callback)
      #   recover_* AND manual_only_recovery?   → Details (details: callback)
      #   else                                  → nil
      # Labels carry the task title so the operator can tell rows apart.
      def status_action_button(row)
        nb = Hive::Bot::NotificationBuilders
        title = Hive::Bot::TitleFormatter.title_from_slug(row.slug)
        action = row.action.to_s

        if action == "needs_input" && row.stage.to_s == "2-brainstorm" && row.marker.to_s == "waiting"
          nb.button("✏️ #{title}", "answer:#{row.project}:#{row.slug}")
        elsif action.start_with?("ready_to_")
          verb = nb.verb_for_action(row.action)
          nb.button("✅ #{title}", "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}") if verb
        elsif nb.recovery?(row)
          if nb.retryable_recovery?(row)
            nb.button("🔧 #{title}", nb.autofix_callback(row))
          else
            nb.button("🔍 #{title}", nb.details_callback(row))
          end
        end
      end

      def render_details(rows, project, slug)
        row = Array(rows).find { |candidate| candidate.project == project && candidate.slug == slug }
        return "No active row found for #{project}/#{slug}." unless row

        attrs = row.attrs.to_h.transform_keys(&:to_s).to_a.sort_by(&:first)
                   .map { |key, value| "#{key}=#{value}" }
        [
          "#{row.project}/#{row.slug} (#{row.stage})",
          "Action: #{row.action_label || row.action}",
          "Marker: #{row.marker || 'none'}",
          ("Attrs: #{attrs.join(' ')}" unless attrs.empty?)
        ].compact.join("\n")
      end

      def actionable_queue_rows(rows)
        Array(rows).reject { |row| %w[archived agent_running].include?(row.action) }
      end

      def status_legacy_stage_dirs(fetch_result)
        return [] unless fetch_result.respond_to?(:legacy_stage_dirs)

        Array(fetch_result.legacy_stage_dirs)
      end

      def status_command?(argv)
        Array(argv) == [ "hive", "status", "--json" ]
      end

      def next_unanswered_question_n(brainstorm_path)
        Hive::Bot::BrainstormParser.next_unanswered_question(
          Hive::Bot::BrainstormParser.parse(brainstorm_path)
        )&.n
      end

      def queued_updates(updates)
        last_seen = read_last_seen_update_id
        return [] unless last_seen

        allowed = chat_ids
        updates.select do |update|
          update.update_id > last_seen && allowed.include?(update.chat_id)
        end
      end

      def project_path_for(project_name)
        return nil unless project_name

        Hive::Config.find_project(project_name)&.fetch("path", nil)
      end

      def brainstorm_path_for(slug, project: nil)
        entry = brainstorm_project_entry_for(slug, project: project)
        entry ? File.join(entry["hive_state_path"], "stages", "2-brainstorm", slug, "brainstorm.md") : nil
      end

      # Resolve the project name a brainstorm slug currently lives in.
      # Returns nil when nothing matches. Used by `start_answer` to
      # backfill `state.project` so the daemon's dispatch-request
      # consumer can `Hive::Config.find_project(project)` on `/done`
      # — the answer flow's slash handlers don't carry project but
      # the on-disk brainstorm file does.
      def brainstorm_project_for(slug, project: nil)
        brainstorm_project_entry_for(slug, project: project)&.fetch("name", nil)
      end

      def brainstorm_project_entry_for(slug, project: nil)
        projects = Hive::Config.registered_projects
        projects = projects.select { |entry| entry["name"] == project } if project && !project.empty?
        projects.find do |entry|
          path = File.join(entry["hive_state_path"], "stages", "2-brainstorm", slug, "brainstorm.md")
          File.exist?(path)
        end
      end

      def chat_ids
        Array(@config.fetch("chat_id_allowlist"))
      end

      # Push the daemon-written update nudge to the allowlist exactly once per
      # newly-seen version. De-duped by BOTH the persisted state (survives a
      # restart) and an in-memory latch (survives a failed state write). Records
      # "notified" only after a send succeeds, so an all-failed push retries
      # next tick. Resilient: any error is logged and never breaks the loop.
      def push_update_nudge
        nudge = @update_state.nudge
        return unless nudge
        return if @nudged_versions[nudge.latest]
        return unless @update_state.should_notify?(nudge.latest)

        text = update_nudge_message(nudge)
        delivered = chat_ids.map { |chat_id| safe_send_message(chat_id: chat_id, text: text) }
        return unless delivered.any?

        @nudged_versions[nudge.latest] = true
        @update_state.record_notified!(nudge.latest)
        @logger.event(:update_nudge_pushed, latest: nudge.latest, channel: nudge.channel)
      rescue StandardError => e
        @logger.event(:update_nudge_error, error_class: e.class.name, message: e.message)
      end

      def update_nudge_message(nudge)
        "hive #{nudge.latest} is available (current #{Hive::VERSION}).\nUpdate: #{nudge.command}"
      end

      def read_last_seen_update_id
        path = @config["last_seen_state_file"]
        return nil unless path && File.exist?(path)

        Integer(File.read(path).strip)
      rescue ArgumentError, SystemCallError, IOError
        nil
      end

      def write_last_seen_update_id(update_id)
        path = @config["last_seen_state_file"]
        return unless path

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, update_id.to_s)
      end

      def reload_config_if_requested
        return unless @reload

        @config = Hive::Config.load_global_bot(require_runtime: true)
        @router = build_router(@config)
        @notification_dispatcher = Hive::Bot::NotificationDispatcher.new(
          telegram: @telegram,
          logger: @logger,
          bot_config: @config
        )
        @conversation_store.update_ttl(@config.fetch("conversation_ttl_sec")) if @conversation_store.respond_to?(:update_ttl)
        # Drop the once-per-process unknown-stage-log cache so SIGHUP can
        # re-surface stage_dir values that the previous instance had
        # already logged about.
        Hive::Bot::TitleFormatter.reset_unknown_stage_log_cache!
        @logger.event(:config_reloaded)
        emit_deprecated_config_events!
        @reload = false
      rescue Hive::ConfigError => e
        @logger.event(:fatal, message: "config reload failed: #{e.message}",
                              keeping_previous: true)
        @reload = false
      end

      def emit_deprecated_config_events!
        Hive::Config.deprecated_bot_keys(@config).each do |entry|
          @logger.event(:deprecated_config, key: entry[:key], replacement: entry[:replacement])
        end
      end

      def install_signal_handlers!
        Signal.trap("TERM") { @shutdown = true }
        Signal.trap("INT") { @shutdown = true }
        Signal.trap("HUP") { @reload = true }
      end

      def interruptible_sleep(seconds)
        # Signal traps run on Ruby's main thread between bytecodes on MRI;
        # these flags are intentionally simple cross-loop wakeups.
        deadline = Time.now + seconds
        while Time.now < deadline && !@shutdown && !@reload
          sleep 0.5
        end
      end
    end
  end
end
