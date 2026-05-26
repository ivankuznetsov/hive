require "set"
require "time"
require "hive/config"
require "hive/babysitter/interval"
require "hive/babysitter/logger"
require "hive/babysitter/project_tick"

module Hive
  module Babysitter
    class Dispatcher
      DEFAULT_INTERVAL_SEC = 600

      attr_reader :logger, :inflight

      def initialize(logger:, dry_run: false, project_name: nil, max_ticks: nil)
        @logger = logger
        @dry_run = dry_run
        @project_name = project_name
        @max_ticks = max_ticks
        @shutdown = false
        @reload = false
        @poll_interval_sec = DEFAULT_INTERVAL_SEC
        @inflight = Set.new
      end

      def tick(now: Time.now)
        @logger.event(:tick_begin, now: now.utc.iso8601)
        enabled = enabled_projects
        @poll_interval_sec = next_interval(enabled.map { |entry| entry[:cfg] })

        enabled.each do |entry|
          Hive::Babysitter::ProjectTick.run(
            entry[:project],
            entry[:cfg],
            dry_run: @dry_run || entry[:cfg].dig("babysitter", "dry_run") == true,
            logger: @logger,
            inflight: @inflight
          )
          @logger.event(:project_tick,
                        project: entry[:project]["name"],
                        path: entry[:project]["path"])
        rescue StandardError => e
          @logger.event(:fatal,
                        project: entry[:project]["name"],
                        message: "project tick failed: #{e.class}: #{e.message}")
        end

        @logger.event(:tick_end, now: Time.now.utc.iso8601,
                                 projects: enabled.size,
                                 next_interval_sec: @poll_interval_sec)
        enabled.size
      end

      def run_forever
        install_signal_handlers!
        @logger.event(:dispatcher_started, version: Hive::VERSION,
                                           dry_run: @dry_run,
                                           pid: Process.pid,
                                           project: @project_name)
        ticks = 0
        until @shutdown
          if @reload
            @logger.event(:config_reloaded)
            @reload = false
          end

          tick
          ticks += 1
          break if @max_ticks && ticks >= @max_ticks

          interruptible_sleep(@poll_interval_sec)
        end
      ensure
        @logger.event(:dispatcher_stopping, in_flight: @inflight.size) if @logger
        @logger&.close
      end

      def request_shutdown!
        @shutdown = true
      end

      def request_reload!
        @reload = true
      end

      private

      def enabled_projects
        projects = selected_projects
        projects.filter_map do |project|
          cfg = Hive::Config.load(project.fetch("path"))
          unless cfg.dig("babysitter", "enabled") == true
            @logger.event(:project_skipped,
                          project: project["name"],
                          reason: "babysitter_disabled")
            next
          end

          { project: project, cfg: cfg }
        rescue Hive::ConfigError => e
          @logger.event(:project_skipped,
                        project: project["name"],
                        reason: "config_error",
                        message: e.message)
          nil
        end
      end

      def selected_projects
        projects = Hive::Config.registered_projects
        return projects unless @project_name

        projects.select { |entry| entry["name"] == @project_name }
      end

      def next_interval(configs)
        intervals = configs.map { |cfg| Hive::Babysitter::Interval.parse(cfg.dig("babysitter", "interval")) }
        intervals.min || DEFAULT_INTERVAL_SEC
      end

      def install_signal_handlers!
        trap("TERM") { request_shutdown! }
        trap("INT")  { request_shutdown! }
        trap("HUP")  { request_reload! }
      end

      def interruptible_sleep(seconds)
        deadline = Time.now + seconds
        until @shutdown || Time.now >= deadline
          sleep [ deadline - Time.now, 0.5 ].min
        end
      end
    end
  end
end
