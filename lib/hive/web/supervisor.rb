# Load the full library first so constants like Hive::ConfigError (defined in
# lib/hive.rb and referenced transitively by hive/config → hive/agent_profiles)
# resolve even when this file is required directly as the container entrypoint
# does (`ruby -rhive/web/supervisor`), before any `require "hive"`.
require "hive"
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
        had_supervisor_pid = ENV.key?("HIVEBOX_SUPERVISOR_PID")
        previous_supervisor_pid = ENV["HIVEBOX_SUPERVISOR_PID"]
        previous_signal_handlers = {}
        # Children inherit this so a child (the web tier handling "enable
        # Telegram") can ask the supervisor to (re)start the bot via SIGHUP.
        ENV["HIVEBOX_SUPERVISOR_PID"] = Process.pid.to_s
        previous_signal_handlers = trap_signals
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
        begin
          terminate_all
        ensure
          if had_supervisor_pid
            ENV["HIVEBOX_SUPERVISOR_PID"] = previous_supervisor_pid
          else
            ENV.delete("HIVEBOX_SUPERVISOR_PID")
          end
          previous_signal_handlers.each { |signal, handler| Signal.trap(signal, handler) }
        end
      end

      private

      def trap_signals
        previous = {}
        %w[TERM INT].each do |signal|
          previous[signal] = Signal.trap(signal) { @stopping = true }
        end
        # SIGHUP = reload: re-read config and bring up newly-enabled children
        # (currently the Telegram bot) without recreating the container.
        previous["HUP"] = Signal.trap("HUP") { @reload_requested = true }
        previous
      end

      # A malformed config.yml must never take the supervisor down: the
      # operator hand-edits the bind-mounted file (documented workflow), and
      # a YAML typo plus a SIGHUP — or a container restart — would otherwise
      # crash PID1, killing daemon, web, and bot together and crash-looping
      # the box. Treat unreadable config as "bot disabled" and say so.
      def bot_enabled?
        Hive::Config.load_global_bot["enabled"]
      rescue Hive::Error, Hive::ConfigError => e
        warn "hivebox supervisor: config unreadable (#{e.message}); treating bot as disabled"
        false
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

      # SIGHUP = config changed. Three bot cases:
      #   enabled + not running → start it (first-time enable);
      #   enabled + running     → RESTART it — the running process long-polls
      #     with the credentials it booted with, so a token/allowlist
      #     rotation saved via the web wizard never reaches it otherwise;
      #   disabled + running    → stop it.
      # The restart works by TERMing the group and scheduling an immediate
      # respawn: reap_once collects the signal death and start_due_restarts
      # brings it back up (the pre-seeded @restart_at entry skips backoff).
      def handle_reload
        @reload_requested = false
        bot = child("bot")
        running = bot && bot.pid

        if bot_enabled?
          if running
            signal_group(bot.pid, "TERM")
            @restart_at["bot"] = Time.now
          else
            start_child("bot", %w[hive bot start --foreground])
          end
        elsif running
          @restart_at.delete("bot")
          signal_group(bot.pid, "TERM")
        end
      end

      def signal_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        # Group already gone — a clean no-op (returns nil like any empty
        # rescue; the explicit literal was an uncoverable line under the
        # 100% gate's process-merged accounting).
      end

      def reap_once
        @children.each do |child|
          next unless child.pid

          pid, status = Process.waitpid2(child.pid, Process::WNOHANG)
          next unless pid

          child.pid = nil
          schedule_restart(child) if should_restart?(status)
        rescue Errno::ECHILD
          # Reaped elsewhere — without a log line this child would silently
          # cease to exist as far as the supervisor is concerned.
          warn "hivebox supervisor: child #{child.name} (pid #{child.pid}) reaped elsewhere; clearing"
          child.pid = nil
        end
      end

      # Restart any crashed child (web, daemon, or bot) — a daemon or bot
      # that died must come back, not silently disappear. Only two deaths
      # are NOT respawned: anything reaped while we are stopping, and a
      # clean (success) exit. Signal deaths ARE respawned: the shutdown
      # race the old signal exemption feared is already excluded by the
      # @stopping check (the trap sets it before terminate_all sends any
      # signal), while the exemption's real-world cost was an OOM-killed
      # daemon silently never coming back. Reload-driven bot TERMs are
      # likewise safe: handle_reload pre-seeds @restart_at, and a second
      # schedule here is harmless.
      def should_restart?(status)
        return false if @stopping
        return false if status.success?

        true
      end

      # Defer the actual restart so a crash-looping child backs off instead
      # of respawning in the same tick.
      def schedule_restart(child)
        # A child with no started_at deliberately classifies as a fast
        # failure (gets the backoff) — missing bookkeeping means we cannot
        # prove it ran long enough to deserve an instant respawn.
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
        grace = begin
          Hive::Config.load_global_daemon.fetch("shutdown_grace_sec", 60)
        rescue Hive::Error, Hive::ConfigError
          # Shutdown must drain children even when config.yml is broken —
          # this path runs from `ensure`, possibly BECAUSE config is broken.
          60
        end
        @children.each do |child|
          next unless child.pid

          Process.kill("TERM", -child.pid)
        rescue Errno::ESRCH
          nil
        end
        # Drain children concurrently within ONE grace window. Reaping serially
        # cost up to (children × grace), which on the default 60s grace blows
        # far past Docker's 10s stop timeout and gets the whole container
        # SIGKILLed mid-shutdown. One thread per child shares the window.
        @children
          .select(&:pid)
          .map { |child| Thread.new { reap_with_escalation(child, grace) } }
          .each(&:join)
      end

      # Give *each* child its own grace window — but run them concurrently in
      # terminate_all so the windows overlap into a single wall-clock budget —
      # then SIGKILL the process group of any child that ignored TERM so the
      # container can't hang on `docker stop` or orphan agent processes.
      def reap_with_escalation(child, grace)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
        loop do
          return if Process.waitpid(child.pid, Process::WNOHANG)
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
        force_kill(child)
      rescue Errno::ECHILD
        nil
      end

      def force_kill(child)
        Process.kill("KILL", -child.pid)
        Process.waitpid(child.pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
