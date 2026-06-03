require "time"
require "hive/config"
require "hive/gh"
require "hive/babysitter/events"
require "hive/babysitter/status_writer"
require "hive/babysitter/pr_fixer"

module Hive
  module Babysitter
    module ProjectTick
      module_function

      def run(project_entry, dry_run:, logger:, inflight:)
        started = Time.now
        # Re-read config here (rather than accepting the dispatcher's cached
        # cfg) so a per-tick edit to babysitter.* takes effect on the next
        # tick without restarting the daemon.
        cfg = Hive::Config.load(project_entry.fetch("path"))
        unless cfg.dig("babysitter", "enabled") == true
          logger.event(:project_skipped, project: project_entry["name"], reason: "babysitter_disabled")
          return { total: 0, fixed: 0, untouched: 0, needs_human: 0 }
        end

        prs = Hive::Gh.list_open_prs(project_entry.fetch("path"), cfg: cfg)
        Hive::Babysitter::Events.emit(
          project: project_entry,
          action: "list-prs",
          outcome: "success",
          duration_ms: duration_ms(started),
          count: prs.size
        )

        selected = select_prs(prs, project_entry, cfg, inflight)
        summary = { total: selected.size, fixed: 0, untouched: 0, needs_human: 0 }
        selected.each do |pr|
          outcome =
            begin
              Hive::Babysitter::PrFixer.run(
                pr,
                project_entry,
                cfg,
                dry_run: dry_run,
                logger: logger,
                inflight: inflight
              )
            rescue StandardError => e
              Hive::Babysitter::Events.emit(
                project: project_entry,
                pr: pr["number"],
                action: "agent-fix",
                outcome: "failure",
                message: "#{e.class}: #{e.message}"
              )
              logger.event(:fatal,
                           project: project_entry["name"],
                           pr: pr["number"],
                           message: "PrFixer raised: #{e.class}: #{e.message}")
              :failure
            end

          case outcome
          when :success then summary[:fixed] += 1
          when :already_green, :noop, :dry_run then summary[:untouched] += 1
          when :give_up, :failure, :timeout, :budget_exhausted, :fork_pr then summary[:needs_human] += 1
          end
        end

        Hive::Babysitter::StatusWriter.append(
          project: project_entry,
          pr_count: summary[:total],
          fixed: summary[:fixed],
          untouched: summary[:untouched],
          needs_human: summary[:needs_human]
        )
        summary
      rescue Hive::GhError => e
        Hive::Babysitter::Events.emit(
          project: project_entry,
          action: "list-prs",
          outcome: "gh-error",
          duration_ms: duration_ms(started),
          message: e.message
        )
        logger.event(:fatal, project: project_entry["name"], message: "gh pr list failed: #{e.message}")
        { total: 0, fixed: 0, untouched: 0, needs_human: 0 }
      end

      def select_prs(prs, project_entry, cfg, inflight)
        ignored = Array(cfg.dig("babysitter", "labels_ignore")).map { |label| label.to_s.downcase }
        limit = cfg.dig("babysitter", "max_concurrent_prs").to_i
        prs.filter_map do |pr|
          number = pr["number"]
          labels = Array(pr["labels"]).filter_map { |entry| entry.is_a?(Hash) ? entry["name"] : entry }
          if (labels.map { |label| label.to_s.downcase } & ignored).any?
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "label_ignored"
            )
            next
          end
          next if inflight.include?(inflight_key(project_entry, number))

          pr
        end.sort_by { |pr| parse_time(pr["updatedAt"]) }.first(limit)
      end

      def inflight_key(project_entry, pr_number)
        [ project_entry.fetch("name"), pr_number.to_i ]
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError
        Time.at(0)
      end

      def duration_ms(started)
        ((Time.now - started) * 1000).to_i
      end
    end
  end
end
