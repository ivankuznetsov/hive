require "date"
require "hive/config"
require "hive/env_file"
require "hive/digest/window"
require "hive/digest/sender"
require "hive/digest/stats"
require "hive/digest/merged_pr/record"
require "hive/digest/merged_pr/repo_resolver"
require "hive/digest/merged_pr/hive_matcher"
require "hive/digest/merged_pr/collector"
require "hive/digest/merged_pr/renderer"

module Hive
  module Digest
    module MergedPr
      Result = Data.define(:date, :repos, :prs, :count, :dry_run, :warnings, :message, :delivery)

      module_function

      def run(date: nil, dry_run: false, repos: [], cfg: nil, clock: -> { Time.now },
              resolver: nil, collector: nil, sender: nil, stats: nil)
        local_date = date ? Window.parse_date(date) : Window.previous_local_day(now: clock.call)
        cfg ||= Hive::Config.load_global_digest_config
        Hive::EnvFile.load! unless dry_run

        resolver ||= RepoResolver.new(cfg: cfg)
        resolved = resolver.resolve(repos: repos)
        collector ||= Collector.new(cfg: cfg)
        prs = collector.for_date(local_date, repos: resolved.repos)
        stats ||= Hive::Digest::Stats.new
        totals = stats.for_items(prs)
        message = Renderer.render(prs, date: local_date, totals: totals)
        sender ||= Sender.new(cfg: cfg)
        sender.preflight! unless dry_run
        delivery = sender.deliver(message, dry_run: dry_run)

        Result.new(
          date: local_date,
          repos: resolved.repos,
          prs: prs,
          count: prs.size,
          dry_run: dry_run,
          warnings: resolved.warnings + collector.warnings,
          message: message,
          delivery: delivery
        )
      end
    end
  end
end
