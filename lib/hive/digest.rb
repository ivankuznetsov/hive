require "hive/config"
require "hive/env_file"
require "hive/digest/changelog_generator"
require "hive/digest/collector"
require "hive/digest/errors"
require "hive/digest/london_window"
require "hive/digest/renderer"
require "hive/digest/repo_resolver"
require "hive/digest/sender"
require "hive/digest/stats"

module Hive
  module Digest
    class CollectionError < Hive::GhError; end

    Result = Data.define(
      :status, :date, :dry_run, :resolved_repository_count,
      :collected_repository_count, :projects, :pr_count, :stats,
      :warnings, :message, :delivery
    ) do
      STATUSES = %i[empty sent].freeze

      def initialize(status:, date:, dry_run:, resolved_repository_count:,
                     collected_repository_count:, projects:, pr_count:, stats:,
                     warnings:, message:, delivery:)
        raise ArgumentError, "digest status must be empty or sent" unless STATUSES.include?(status)
        raise ArgumentError, "empty digest must have zero PRs" if status == :empty && !pr_count.to_i.zero?
        raise ArgumentError, "sent digest must have at least one PR" if status == :sent && pr_count.to_i.zero?

        super
      end
    end

    module_function

    def run(date: nil, dry_run: false, repos: [], cfg: nil, clock: -> { Time.now },
            resolver: nil, collector: nil, generator: nil, stats: nil,
            renderer: Renderer, sender: nil)
      local_date = date ? LondonWindow.parse_date(date) : LondonWindow.previous_day(now: clock.call)
      cfg ||= Hive::Config.load_global_digest_config
      Hive::EnvFile.load! unless dry_run
      resolver ||= RepoResolver.new(cfg: cfg)
      resolution = resolver.resolve(repos: repos)
      collector ||= Collector.new(cfg: cfg)
      collection = collector.for_date(local_date, targets: resolution.targets)
      if collection.all_failed?
        repositories = resolution.targets.map(&:repository).join(", ")
        raise CollectionError, "hive digest: GitHub collection failed for every resolved repository: #{repositories}"
      end

      sender ||= Sender.new(cfg: cfg)
      sender.preflight! unless dry_run
      stats ||= Stats.new
      stats_report = stats.for_repositories(collection.repositories)
      represented = collection.repositories.reject { |repository| repository.pull_requests.empty? }
      changelog = if represented.empty?
        Changelog.new(projects: [].freeze, facts: [].freeze, warnings: [].freeze)
      else
        generator ||= ChangelogGenerator.new(cfg: cfg)
        generator.generate(represented, date: local_date)
      end
      warnings = (
        resolution.warnings + collection.warnings + stats_report.warnings + changelog.warnings
      ).freeze
      message = renderer.render(
        changelog: changelog, date: local_date, stats: stats_report, warnings: warnings
      )
      delivery = sender.deliver(message, dry_run: dry_run)
      pr_count = stats_report.overall.pr_count
      status = pr_count.zero? ? :empty : :sent

      Result.new(
        status: status,
        date: local_date,
        dry_run: dry_run,
        resolved_repository_count: resolution.targets.size,
        collected_repository_count: collection.collected_count,
        projects: changelog.projects,
        pr_count: pr_count,
        stats: stats_report,
        warnings: warnings,
        message: message,
        delivery: delivery
      )
    ensure
      collection&.cleanup!
    end
  end
end
