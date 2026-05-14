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
        result = @router.handle(update)
        execute_result(result, update)
        write_last_seen_update_id(update.update_id)
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
        text = "Hive is back online, #{count} #{count == 1 ? 'message' : 'messages'} queued"
        chat_ids.each { |chat_id| @telegram.send_message(chat_id: chat_id, text: text) }
        @logger.event(:reconnect_summary, queued_count: count)
      end

      private

      def poll_loop
        first_poll = true
        until @shutdown
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
            process_update(update)
            @next_update_id = update.update_id + 1
          end
        end
      end

      def status_loop
        until @shutdown
          reload_config_if_requested
          status_tick
          interruptible_sleep(@config.fetch("poll_interval_sec"))
        end
      end

      def reaper_loop
        until @shutdown
          reap_children
          sleep 1
        end
      end

      def execute_result(result, update)
        case result.action
        when :noop
          nil
        when :reply
          @telegram.send_message(chat_id: update.chat_id, text: result.text,
                                 reply_markup: result.reply_markup)
        when :dispatch_then_reply
          execute_dispatch(result, update)
        when :dispatch_commands
          result.commands.each { |argv| execute_dispatch(result.dup.tap { |r| r.command_argv = argv }, update) }
        when :start_answer
          start_answer(result, update)
        when :write_answer_then_reply
          execute_answer_write(result, update)
        when :start_codex
          @telegram.send_message(chat_id: update.chat_id, text: "Codex chat is starting for #{result.slug}.")
        when :confirm_codex_draft
          @telegram.send_message(chat_id: update.chat_id, text: "Draft confirmed for #{result.slug}.")
        end
      end

      def execute_dispatch(result, update)
        if result.command_argv == [ "hive", "status", "--json" ]
          rows = @status_watcher.fetch.rows
          @telegram.send_message(chat_id: update.chat_id, text: render_queue(rows))
          return
        end

        if @dry_run
          @telegram.send_message(chat_id: update.chat_id, text: "Dry run: #{result.command_argv.join(' ')}")
          return
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
        @notification_dispatcher.record_dispatch(project: result.project, slug: result.slug) if result.project && result.slug
        @telegram.send_message(chat_id: update.chat_id, text: "Queued command pid=#{pid}")
      end

      def execute_answer_write(result, update)
        path = brainstorm_path_for(result.slug)
        unless path
          @telegram.send_message(chat_id: update.chat_id, text: "Slug not found, was it archived?")
          return
        end

        write_result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: result.question_n,
          answer_text: result.answer_text
        )
        text = case write_result
               when :written
                 "Got Q#{result.question_n}."
               when :already_answered
                 "Question #{result.question_n} was already answered by another device"
               else
                 "Question #{result.question_n} was not found."
               end
        advance_conversation_after_write(result, update, path) if write_result == :written
        @telegram.send_message(chat_id: update.chat_id, text: text)
      end

      def start_answer(result, update)
        path = brainstorm_path_for(result.slug)
        question = if path
                     Hive::Bot::BrainstormParser.next_unanswered_question(
                       Hive::Bot::BrainstormParser.parse(path)
                     )
                   end
        question_n = question&.n || 1
        @conversation_store.start(chat_id: update.chat_id, slug: result.slug,
                                  question_n: question_n, mode: result.mode || :path_b)
        @telegram.send_message(chat_id: update.chat_id,
                               text: "Answer mode started for #{result.slug}. Send Q#{question_n}'s answer as a message.")
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
        text = if child.exit_code == Hive::ExitCodes::WRONG_STAGE
                 "Already advanced by another device"
        elsif child.exit_code == Hive::ExitCodes::TEMPFAIL
                 "Try again - another run holds the lock"
        elsif child.exit_code.zero?
                 "Command completed"
        else
                 "Command failed with exit #{child.exit_code}; see #{child.log_path}"
        end
        @telegram.send_message(chat_id: child.chat_id, text: text)
      end

      def render_queue(rows)
        actionable = Array(rows).reject { |row| %w[archived agent_running].include?(row.action) }
        return "No active Hive tasks." if actionable.empty?

        lines = actionable.first(10).map do |row|
          "#{row.project}/#{row.slug} #{row.stage} #{row.action_label || row.action} #{row.marker}"
        end
        header = "#{actionable.size} active task#{actionable.size == 1 ? '' : 's'}"
        ([ header ] + lines).join("\n")
      end

      def queued_updates(updates)
        last_seen = read_last_seen_update_id
        return [] unless last_seen

        updates.select { |update| update.update_id > last_seen }
      end

      def project_path_for(project_name)
        return nil unless project_name

        Hive::Config.find_project(project_name)&.fetch("path", nil)
      end

      def brainstorm_path_for(slug)
        Hive::Config.registered_projects.each do |project|
          path = File.join(project["hive_state_path"], "stages", "2-brainstorm", slug, "brainstorm.md")
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
      rescue ArgumentError
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
        @logger.event(:config_reloaded)
        @reload = false
      rescue Hive::ConfigError => e
        @logger.event(:fatal, message: "config reload failed: #{e.message}",
                              keeping_previous: true)
        @reload = false
      end

      def install_signal_handlers!
        Signal.trap("TERM") { @shutdown = true }
        Signal.trap("INT") { @shutdown = true }
        Signal.trap("HUP") { @reload = true }
      end

      def interruptible_sleep(seconds)
        deadline = Time.now + seconds
        while Time.now < deadline && !@shutdown && !@reload
          sleep 0.5
        end
      end
    end
  end
end
