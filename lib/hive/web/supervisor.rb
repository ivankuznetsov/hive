require "hive/config"

module Hive
  module Web
    class Supervisor
      Child = Struct.new(:name, :argv, :pid, :started_at, keyword_init: true)

      # Minimum delay before restarting a child that just exited. Without it,
      # a fast-failing `web` (e.g. a startup crash) spins in a tight restart
      # loop pegging a CPU. The backoff only kicks in when the child died
      # quickly; a long-lived child that crashes is restarted immediately.
      RESTART_BACKOFF_SEC = 5
      # A run shorter than this counts as a fast failure and earns a backoff.
      FAST_FAILURE_SEC = 10

      def initialize
        @children = []
        @stopping = false
        @reload_requested = false
        @restart_at = {}
      end

      def run
        # Children inherit this so a child (the web tier handling "enable
        # Telegram") can ask the supervisor to (re)start the bot via SIGHUP.
        ENV["HIVEBOX_SUPERVISOR_PID"] = Process.pid.to_s
        trap_signals
        start_child("daemon", %w[hive daemon start])
        start_child("web", %w[hive web --bind 0.0.0.0])
        start_child("bot", %w[hive bot start --foreground]) if bot_enabled?
        loop do
          break if @stopping
          handle_reload if @reload_requested
          reap_once
          start_due_restarts
          sleep 1
        end
      ensure
        terminate_all
      end

      private

      def trap_signals
        %w[TERM INT].each do |signal|
          Signal.trap(signal) { @stopping = true }
        end
        # SIGHUP = reload: re-read config and bring up newly-enabled children
        # (currently the Telegram bot) without recreating the container.
        Signal.trap("HUP") { @reload_requested = true }
      end

      def bot_enabled?
        Hive::Config.load_global_bot["enabled"]
      end

      def child(name)
        @children.find { |c| c.name == name }
      end

      def start_child(name, argv)
        pid = Process.spawn(*argv, pgroup: true)
        existing = child(name)
        if existing
          existing.pid = pid
          existing.started_at = Time.now
        else
          @children << Child.new(name: name, argv: argv, pid: pid, started_at: Time.now)
        end
      end

      def handle_reload
        @reload_requested = false
        bot = child("bot")
        return unless bot_enabled? && (bot.nil? || bot.pid.nil?)

        start_child("bot", %w[hive bot start --foreground])
      end

      def reap_once
        @children.each do |child|
          next unless child.pid

          pid, status = Process.waitpid2(child.pid, Process::WNOHANG)
          next unless pid

          child.pid = nil
          schedule_restart(child) if child.name == "web" && !@stopping && !status.success?
        rescue Errno::ECHILD
          child.pid = nil
        end
      end

      # Defer the actual restart so a crash-looping child backs off instead
      # of respawning in the same tick.
      def schedule_restart(child)
        ran_for = child.started_at ? Time.now - child.started_at : RESTART_BACKOFF_SEC
        delay = ran_for < FAST_FAILURE_SEC ? RESTART_BACKOFF_SEC : 0
        @restart_at[child.name] = Time.now + delay
      end

      def start_due_restarts
        return if @stopping

        @restart_at.to_a.each do |name, at|
          next if Time.now < at

          c = child(name)
          next unless c && c.pid.nil?

          start_child(name, c.argv)
          @restart_at.delete(name)
        end
      end

      def terminate_all
        @children.each do |child|
          next unless child.pid

          Process.kill("TERM", -child.pid)
        rescue Errno::ESRCH
          nil
        end
        deadline = Time.now + Hive::Config.load_global_daemon.fetch("shutdown_grace_sec", 60)
        @children.each do |child|
          next unless child.pid

          begin
            sleep 0.2 while Time.now < deadline && Process.waitpid(child.pid, Process::WNOHANG).nil?
          rescue Errno::ECHILD
            nil
          end
        end
      end
    end
  end
end
