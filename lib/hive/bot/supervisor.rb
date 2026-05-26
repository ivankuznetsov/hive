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
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"
require "hive/bot/title_formatter"
require "hive/task"

module Hive
  module Bot
    class Supervisor
      def initialize(config:, token:, logger: nil, telegram: nil, status_watcher: nil,
                     notification_dispatcher: nil, router: nil, child_supervisor: nil,
                     conversation_store: nil, dry_run: false)
        @config = config
        @dry_run = dry_run
        @logger = logger || Hive::Bot::Logger.new(
          path: config.fetch("log_file"),
          max_bytes: config.fetch("log_max_bytes"),
          max_files: config.fetch("log_max_files")
        )
        @telegram = telegram || Hive::Bot::Telegram.new(token: token, logger: @logger)
        @status_watcher = status_watcher || Hive::Bot::StatusWatcher.new(logger: @logger)
        @conversation_store = conversation_store ||
          Hive::Bot::ConversationStore.new(ttl_sec: config.fetch("conversation_ttl_sec"))
        @router = router || Hive::Bot::Router.new(
          bot_config: config,
          logger: @logger,
          conversation_store: @conversation_store
        )
        @child_supervisor = child_supervisor ||
          Hive::Bot::ChildSupervisor.new(logger: @logger, dry_run: dry_run)
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

      def status_tick
        result = @status_watcher.fetch
        return result unless result.ok

        @notification_dispatcher.process_rows(result.rows)
        result
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
          rescue StandardError => e
            @logger.event(:fatal, source: "reaper_loop", error_class: e.class.name,
                                   message: e.message, backtrace: Array(e.backtrace).first(10).join("\n"))
          end
          sleep 1
        end
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
        failed = false
        commands.each_with_index do |argv, idx|
          per_command = @router.class::Result.new(
            action: :dispatch_then_reply,
            command_argv: argv,
            project: result.project,
            slug: result.slug
          )
          last_pid = execute_dispatch(per_command, update)
          if idx < commands.length - 1 && last_pid
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

      def project_filter_miss_text(project, rows)
        registered = registered_project_names
        active = rows.map { |row| row.project.to_s }.uniq
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
          if result.project && !result.project.to_s.empty?
            filtered = rows.select { |row| row.project == result.project }
            if filtered.empty?
              safe_send_message(chat_id: update.chat_id, text: project_filter_miss_text(result.project, rows))
              return nil
            end
            rows = filtered
          end
          if result.slug
            safe_send_message(chat_id: update.chat_id, text: render_details(rows, result.project, result.slug))
          else
            safe_send_message(chat_id: update.chat_id, text: render_queue(rows))
          end
          return nil
        end

        if @dry_run
          safe_send_message(chat_id: update.chat_id, text: "Dry run: #{result.command_argv.join(' ')}")
          return nil
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
        safe_send_message(chat_id: update.chat_id, text: "Queued command pid=#{pid}")
        pid
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
          answer_text: result.answer_text
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
                  "Reply with your answer (or send /done when finished)."
          )
        else
          # Conversation state is intentionally NOT cleared here — /done
          # reads it to discover the slug and dispatch `hive run <slug>`,
          # then clears it itself.
          safe_send_message(
            chat_id: update.chat_id,
            text: "Got Q#{answered_n}. All questions answered — send /done to continue the brainstorm."
          )
        end
      end

      def start_answer(result, update)
        path = brainstorm_path_for(result.slug, project: result.project)
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
                                  project: result.project)
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
          "Command completed"
        else
          "Command failed with exit #{child.exit_code || 'unknown'}; see #{child.log_path}"
        end
      end

      QUEUE_DISPLAY_CAP = 10

      def render_queue(rows)
        actionable = actionable_queue_rows(rows)
        return "No active Hive tasks." if actionable.empty?

        lines = actionable.first(QUEUE_DISPLAY_CAP).map do |row|
          "#{Hive::Bot::TitleFormatter.title_from_slug(row.slug)} — " \
            "#{Hive::Bot::TitleFormatter.stage_label(row.stage, logger: @logger)}"
        end
        header = "#{actionable.size} active task#{actionable.size == 1 ? '' : 's'}"
        if actionable.size > QUEUE_DISPLAY_CAP
          lines << "+ #{actionable.size - QUEUE_DISPLAY_CAP} more tasks — open on a laptop for the full list."
        end
        ([ header ] + lines).join("\n")
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
        projects = Hive::Config.registered_projects
        projects = projects.select { |entry| entry["name"] == project } if project && !project.empty?
        projects.each do |entry|
          path = File.join(entry["hive_state_path"], "stages", "2-brainstorm", slug, "brainstorm.md")
          return path if File.exist?(path)
        end
        nil
      end

      def chat_ids
        Array(@config.fetch("chat_id_allowlist"))
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
        @router = Hive::Bot::Router.new(
          bot_config: @config,
          logger: @logger,
          conversation_store: @conversation_store
        )
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
