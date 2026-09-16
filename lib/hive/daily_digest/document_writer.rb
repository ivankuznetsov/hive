require "digest"
require "json"
require "hive/config"
require "hive/daily_digest/calendar"
require "hive/daily_digest/coordinator"
require "hive/daily_digest/store"
require "hive/daily_digest/prdigest_source"
require "hive/daily_digest/document_generator"

module Hive
  module DailyDigest
    # PRDigest supplies the evidence and writing contract. Hive persists one
    # document for Web, CLI and delivery; task journals are not digest inputs.
    class DocumentWriter
      def initialize(config_loader: Config.method(:load_global_daily_digest),
                     projects_loader: Config.method(:registered_projects),
                     store: Store.new, facts_loader: PrdigestSource.new,
                     generator: DocumentGenerator.new, clock: -> { Time.now.utc })
        @config_loader, @projects_loader, @store = config_loader, projects_loader, store
        @facts_loader, @generator, @clock = facts_loader, generator, clock
      end

      def refresh(date: nil)
        config = @config_loader.call
        raise Coordinator::Disabled, "daily digest is disabled" unless config["enabled"]
        calendar = Calendar.new(time_zone: config.fetch("time_zone"))
        today = calendar.local_date_at(@clock.call)
        dates = date ? [ Date.iso8601(date.to_s) ] : [ today.prev_day ]
        dates.map do |day|
          raise Coordinator::FutureDate, "digest date is in the future" if day > today

          write_day(day, calendar: calendar)
        end
      rescue Date::Error
        raise InvalidRecord, "invalid digest local date #{date.inspect}"
      end

      private

      def write_day(day, calendar:)
        # Serialize generation without holding the store lock during network or
        # agent calls: readers keep serving the last saved document.
        with_generation_lock do
          date = day.iso8601
          existing = read_optional(date)
          raise PrunedRecord, "digest #{date} was pruned" if existing && existing["lifecycle"] == "pruned"
          return result(existing, "unchanged") if existing && existing["lifecycle"] == "closed"

          projects = @projects_loader.call
          interval = existing ? existing.slice(
            "interval_id", "local_date", "sequence", "time_zone", "starts_at", "ends_at",
            "duration_seconds", "boundary_kind", "cutover"
          ) : calendar.interval_for(day)
          collection_started_at = @clock.call.utc
          facts = JSON.parse(JSON.generate(@facts_loader.call(
            date: date, time_zone: interval.fetch("time_zone"), projects: projects
          )))
          evidence_id = Record.content_id(facts)
          now = @clock.call.utc
          lifecycle = collection_started_at >= Time.iso8601(interval.fetch("ends_at")) ? "closed" : "open"
          if existing && existing["evidence_id"] == evidence_id
            record = existing.reject { |key, _| key.start_with?("effective_") || key == "amendments" }
            record.merge!("lifecycle" => lifecycle, "closed_at" => lifecycle == "closed" ? now.iso8601(6) : nil,
                          "last_materialized_at" => now.iso8601(6))
          else
            repositories = facts.fetch("digest").fetch("repositories")
            empty = repositories.all? { |repository| repository.fetch("pull_requests").empty? }
            text = empty ? "No pull requests were merged on #{date}." : generate(facts)
            batch = batch_for(repositories, projects)
            record = Projector.new(clock: -> { now }).base(interval: interval, batch: batch, lifecycle: lifecycle)
            record.merge!("document" => text, "evidence_id" => evidence_id)
          end
          result(@store.write_base(record), lifecycle)
        end
      end

      def generate(facts)
        require "prdigest"
        Prdigest::Document.generate(facts: facts, generator: @generator)
      end

      def batch_for(repositories, projects)
        selected = repositories.map do |repository|
          slug = repository.fetch("name")
          projects.find { |project| project["repository_identity"] == "github.com/#{slug}" } ||
            { "name" => slug, "project_id" => "github.com/#{slug}", "repository_identity" => "github.com/#{slug}" }
        end
        items = repositories.each_with_index.flat_map do |repository, index|
          project = selected.fetch(index)
          repository.fetch("pull_requests").map do |pull|
            {
              "fact_id" => pull.fetch("url"), "kind" => "pr_merged", "category" => "completed",
              "summary" => pull.fetch("title"), "project_id" => project.fetch("project_id"),
              "registration_id" => project["registration_id"], "project" => project.fetch("name"),
              "occurred_at" => pull.fetch("merged_at"), "source" => "prdigest",
              "pr" => { "number" => pull.fetch("number"), "url" => pull.fetch("url") }
            }
          end
        end
        Coordinator::Batch.new(projects: selected, facts: items, attention: [], gaps: [], frontiers: {})
      end

      def with_generation_lock
        FileUtils.mkdir_p(@store.root, mode: 0o700)
        File.open(File.join(@store.root, ".generation.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def read_optional(date)
        @store.read(date)
      rescue MissingRecord
        nil
      end

      def result(record, status)
        { "local_date" => record.fetch("local_date"), "status" => status, "record_id" => record.fetch("record_id") }
      end
    end
  end
end
