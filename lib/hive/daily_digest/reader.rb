require "date"
require "json"
require "time"
require "hive/config"
require "hive/daily_digest/materiality"
require "hive/daily_digest/store"

module Hive
  module DailyDigest
    # Pure shared reader for CLI, Web, Telegram, and agent JSON. It only reads
    # persisted projection bytes; stale diagnostics are virtual view data.
    class Reader
      class UnknownProject < DailyDigest::Error; end

      def initialize(store: Store.new,
                     config_loader: Hive::Config.method(:load_global_daily_digest),
                     clock: -> { Time.now.utc })
        @store = store
        @config_loader = config_loader
        @clock = clock
      end

      def read(date: nil, project: nil)
        config = @config_loader.call
        selected_date = date ? normalize_date(date) : covering_date(@clock.call)
        return missing(selected_date, config) unless selected_date

        record = @store.read(selected_date)
        if record.fetch("lifecycle") == "pruned"
          return record.merge(
            "reader_status" => "pruned", "stale" => false,
            "selected_project" => project, **navigation_for(selected_date)
          )
        end

        view = project ? filter_project(record, project) : deep_copy(record)
        stale = stale?(record, config)
        if stale
          stale_gap = Materiality.build_gap(
            source: "daily_digest_materializer", scope: "global",
            reason_code: "materializer_stale",
            reason: "daily digest materialization exceeded its freshness budget",
            observed_at: @clock.call, freshness_at: record.fetch("last_materialized_at")
          )
          view["effective_gaps"] = (
            Array(view["effective_gaps"] || view["gaps"]) + [ stale_gap ]
          ).uniq { |gap| gap.fetch("gap_id") }
          view["view_completeness"] = "partial"
        else
          view["view_completeness"] = view["effective_completeness"] || view["completeness"]
        end
        navigation = navigation_for(selected_date)
        view.merge(
          "reader_status" => "ok", "stale" => stale,
          "selected_project" => project, **navigation
        )
      rescue DailyDigest::MissingRecord
        missing(selected_date || date&.to_s, config)
      end

      def previous_date(date)
        navigation_for(normalize_date(date))["previous_date"]
      end

      def next_date(date)
        navigation_for(normalize_date(date))["next_date"]
      end

      private

      def covering_date(value)
        now = utc(value)
        interval = @store.intervals.find do |candidate|
          utc(candidate.fetch("starts_at")) <= now && now < utc(candidate.fetch("ends_at"))
        end
        interval && interval.fetch("local_date")
      end

      def navigation_for(date)
        labels = @store.intervals.map { |interval| interval.fetch("local_date") }
        index = labels.index(date)
        {
          "previous_date" => index && index.positive? ? labels[index - 1] : nil,
          "next_date" => index && index < labels.length - 1 ? labels[index + 1] : nil
        }
      end

      def filter_project(record, project)
        identity = Array(record.fetch("projects")).find do |candidate|
          candidate["name"] == project.to_s || candidate["project_id"] == project.to_s
        end
        raise UnknownProject, "project #{project.inspect} is not present in this digest" unless identity

        project_id = identity.fetch("project_id")
        copy = deep_copy(record)
        copy["items"] = Array(copy["items"]).select { |item| item["project_id"] == project_id }
        copy["attention"] = Array(copy["attention"]).select { |item| item["project_id"] == project_id }
        %w[gaps effective_gaps].each do |key|
          next unless copy[key]

          copy[key] = Array(copy[key]).select do |gap|
            gap["project_id"].nil? || gap["project_id"] == project_id
          end
        end
        copy["amendments"] = Array(copy["amendments"]).map do |amendment|
          amendment.merge(
            "items" => Array(amendment["items"]).select { |item| item["project_id"] == project_id },
            "attention" => Array(amendment["attention"]).select { |item| item["project_id"] == project_id },
            "gaps" => Array(amendment["gaps"]).select do |gap|
              gap["project_id"].nil? || gap["project_id"] == project_id
            end
          )
        end
        copy
      end

      def stale?(record, config)
        return false unless record.fetch("lifecycle") == "open"

        budget = Integer(config.fetch("freshness_budget_sec", 900))
        utc(@clock.call) - utc(record.fetch("last_materialized_at")) > budget
      rescue ArgumentError, TypeError
        true
      end

      def missing(date, config)
        coverage = config["coverage_started_at"]
        precoverage = begin
          date && coverage && Date.iso8601(date.to_s) < utc(coverage).to_date
        rescue Date::Error, ArgumentError, TypeError
          false
        end
        {
          "reader_status" => "missing", "local_date" => date,
          "coverage_started_at" => coverage,
          "precoverage" => precoverage, "stale" => false,
          **missing_navigation(date)
        }
      end

      def missing_navigation(date)
        return { "previous_date" => nil, "next_date" => nil } unless date

        target = Date.iso8601(date.to_s)
        labels = @store.intervals.map { |interval| Date.iso8601(interval.fetch("local_date")) }
        {
          "previous_date" => labels.select { |label| label < target }.max&.iso8601,
          "next_date" => labels.select { |label| label > target }.min&.iso8601
        }
      rescue Date::Error, TypeError
        { "previous_date" => nil, "next_date" => nil }
      end

      def normalize_date(value)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error, TypeError
        raise DailyDigest::InvalidRecord, "invalid digest local date #{value.inspect}"
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end
    end
  end
end
