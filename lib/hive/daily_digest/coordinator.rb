require "date"
require "digest"
require "time"
require "hive/config"
require "hive/daily_digest/calendar"
require "hive/daily_digest/collector"
require "hive/daily_digest/coverage"
require "hive/daily_digest/projector"
require "hive/daily_digest/store"

module Hive
  module DailyDigest
    # Sole materialization owner. Reads stay in Reader; this object performs
    # chronological catch-up, close, late amendment, gap recovery, and pruned
    # frontier acknowledgement.
    class Coordinator
      class Disabled < DailyDigest::Error
        def exit_code = Hive::ExitCodes::CONFIG
      end
      class NotInitialized < DailyDigest::Error
        def exit_code = Hive::ExitCodes::CONFIG
      end
      class FutureDate < DailyDigest::Error
        def exit_code = Hive::ExitCodes::USAGE
      end
      MAX_CATCH_UP_INTERVALS = 10_000

      Batch = Data.define(:projects, :facts, :attention, :gaps, :frontiers)

      def initialize(
        config_loader: Hive::Config.method(:load_global_daily_digest),
        history_loader: Hive::Config.method(:load_global_project_membership_history),
        store: Store.new,
        collector_factory: ->(**options) { Collector.new(**options) },
        clock: -> { Time.now.utc }
      )
        @config_loader = config_loader
        @history_loader = history_loader
        @store = store
        @collector_factory = collector_factory
        @clock = clock
      end

      def refresh(date: nil, attempted_gap_ids: nil)
        config = @config_loader.call
        validate_config!(config)
        now = utc(@clock.call)
        intervals = intervals_through(config, now: now, selected_date: date)
        selected = if date
          target = Date.iso8601(date.to_s).iso8601
          target_index = intervals.index { |candidate| candidate.fetch("local_date") == target }
          interval = target_index && intervals[target_index]
          raise DailyDigest::MissingRecord, "digest interval #{target} does not exist" unless interval

          intervals.first(target_index + 1).select do |candidate|
            candidate.equal?(interval) || read_optional(candidate.fetch("local_date")).nil?
          end
        else
          intervals.select { |interval| due_for_materialization?(interval) }
        end
        coverage = Coverage.new(
          daily_config: config, membership_history: @history_loader.call,
          observed_at: @clock
        )
        selected.map do |interval|
          materialize(
            interval, config: config, coverage: coverage, now: now,
            attempted_gap_ids: attempted_gap_ids
          )
        end
      rescue Date::Error
        raise DailyDigest::InvalidRecord, "invalid digest local date #{date.inspect}"
      end

      private

      def validate_config!(config)
        raise Disabled, "daily digest is disabled" unless config["enabled"] == true
        required = %w[time_zone coverage_started_at initial_membership first_interval]
        missing = required.select { |key| config[key].nil? }
        return if missing.empty?

        raise NotInitialized,
              "daily digest is not initialized (missing #{missing.join(', ')}); run `hive migrate --all`"
      end

      def intervals_through(config, now:, selected_date:)
        persisted = @store.intervals
        intervals = coverage_intervals(config, persisted)
        target_date = selected_date && Date.iso8601(selected_date.to_s)
        first_date = Date.iso8601(intervals.first.fetch("local_date"))
        raise DailyDigest::MissingRecord, "digest date predates durable coverage" if target_date && target_date < first_date

        limit = 0
        loop do
          last = intervals.last
          enough = if target_date
            Date.iso8601(last.fetch("local_date")) >= target_date
          else
            contains?(last, now) || utc(last.fetch("starts_at")) > now
          end
          break if enough

          raise FutureDate, "digest date is in the future" if target_date && utc(last.fetch("ends_at")) > now
          limit += 1
          raise DailyDigest::Error, "daily digest catch-up exceeds safety bound" if limit > MAX_CATCH_UP_INTERVALS

          intervals << next_interval(last, config)
        end
        if target_date && !intervals.any? { |entry| entry.fetch("local_date") == target_date.iso8601 }
          raise DailyDigest::MissingRecord, "digest interval #{target_date.iso8601} was skipped by a zone boundary"
        end
        if target_date
          selected = intervals.find { |entry| entry.fetch("local_date") == target_date.iso8601 }
          raise FutureDate, "digest date is in the future" if utc(selected.fetch("starts_at")) > now
        end
        intervals
      end

      def coverage_intervals(config, persisted)
        authoritative = Array(persisted).sort_by { |entry| utc(entry.fetch("starts_at")) }
        first = normalize_first_interval(config.fetch("first_interval"))
        return [ first ] if authoritative.empty?
        return authoritative if utc(authoritative.first.fetch("starts_at")) <= utc(first.fetch("starts_at"))

        intervals = [ first ]
        while utc(intervals.last.fetch("ends_at")) < utc(authoritative.first.fetch("starts_at"))
          intervals << next_interval(intervals.last, config)
        end
        unless utc(intervals.last.fetch("ends_at")) == utc(authoritative.first.fetch("starts_at"))
          raise DailyDigest::InvalidRecord, "daily digest persisted coverage has a boundary hole"
        end
        intervals.concat(authoritative)
      end

      def normalize_first_interval(value)
        interval = value.to_h.transform_keys(&:to_s).dup
        interval["sequence"] ||= 1
        interval["boundary_kind"] ||= "calendar_day"
        interval["duration_seconds"] ||= (
          utc(interval.fetch("ends_at")) - utc(interval.fetch("starts_at"))
        ).to_i
        interval["cutover"] = nil unless interval.key?("cutover")
        interval["interval_id"] ||= Digest::SHA256.hexdigest(
          Record.canonical_json(interval.reject { |key, _| key == "interval_id" })
        )
        interval.freeze
      rescue KeyError, NoMethodError
        raise NotInitialized, "daily digest first interval is invalid"
      end

      def next_interval(previous, config)
        sequence = previous.fetch("sequence", 0).to_i + 1
        configured_zone = config.fetch("time_zone")
        if configured_zone != previous.fetch("time_zone")
          return Calendar.cutover_interval(
            previous: previous, time_zone: configured_zone,
            requested_at: config["time_zone_requested_at"] || @clock.call,
            sequence: sequence
          )
        end

        calendar = Calendar.new(time_zone: configured_zone)
        label = Date.iso8601(previous.fetch("local_date")).next_day
        skipped = []
        loop do
          interval = calendar.interval_for(label, sequence: sequence)
          if interval.fetch("duration_seconds").positive?
            unless utc(interval.fetch("starts_at")) == utc(previous.fetch("ends_at"))
              raise DailyDigest::InvalidRecord, "daily digest intervals are not continuous"
            end
            return interval if skipped.empty?

            return interval.merge("skipped_labels" => skipped).freeze
          end
          skipped << label.iso8601
          label = label.next_day
        end
      end

      def materialize(interval, config:, coverage:, now:, attempted_gap_ids: nil)
        date = interval.fetch("local_date")
        existing = read_optional(date)
        membership = coverage.projects_for(
          starts_at: interval.fetch("starts_at"), ends_at: interval.fetch("ends_at")
        )
        collection_start = [
          utc(interval.fetch("starts_at")), utc(config.fetch("coverage_started_at"))
        ].max
        collected = @collector_factory.call(
          projects: membership.projects,
          starts_at: collection_start,
          ends_at: utc(interval.fetch("ends_at")),
          prior_frontiers: existing && existing.fetch("effective_source_frontiers", {})
        ).collect
        batch = Batch.new(
          projects: collected.projects,
          facts: collected.facts,
          attention: collected.attention,
          gaps: (Array(collected.gaps) + membership.gaps).uniq { |gap| gap.fetch("gap_id") },
          frontiers: collected.frontiers
        )
        attempted_gap_ids ||= Array(existing && (existing["effective_gaps"] || existing["gaps"]))
                              .map { |gap| gap.fetch("gap_id") }
        confirmed_gap_ids = confirmed_resolutions(
          existing, batch, attempted_gap_ids: attempted_gap_ids,
          membership_gaps: membership.gaps,
          membership_recovery_scopes: membership.respond_to?(:recovery_scopes) ?
            membership.recovery_scopes : []
        )
        if existing&.fetch("lifecycle") == "pruned"
          discarded = discard_entries(
            batch, resolved_gaps: resolved_pruned_gaps(
              existing, batch, attempted_gap_ids: confirmed_gap_ids
            ), observed_at: now
          )
          @store.discard_pruned(
            date, entries: discarded, source_frontiers: batch.frontiers,
            discarded_at: now
          ) unless discarded.empty? && batch.frontiers.empty?
          return result_row(date, "pruned", discarded: discarded.length)
        end

        lifecycle = now >= utc(interval.fetch("ends_at")) ? "closed" : "open"
        projector = Projector.new(clock: -> { now })
        if existing.nil? || existing.fetch("lifecycle") == "open"
          batch = merge_open_batch(existing, batch, confirmed_gap_ids: confirmed_gap_ids) if existing
          base = projector.base(interval: interval, batch: batch, lifecycle: lifecycle)
          begin
            written = @store.write_base(base)
            return result_row(date, written.fetch("lifecycle"), record_id: written.fetch("record_id"))
          rescue Store::ImmutableRecord
            existing = @store.read(date)
          end
        end

        amendment = projector.amendment(
          existing: existing, batch: batch, attempted_gap_ids: confirmed_gap_ids
        )
        if amendment
          begin
            written = @store.append_amendment(date, amendment)
            result_row(date, "amended", amendment_id: written.fetch("amendment_id"))
          rescue Store::Conflict
            # A concurrent writer may have admitted the same semantic delta
            # with a different wall-clock amended_at. Re-read and accept only
            # when no delta remains.
            latest = @store.read(date)
            retry_amendment = projector.amendment(
              existing: latest, batch: batch, attempted_gap_ids: confirmed_gap_ids
            )
            raise if retry_amendment

            result_row(date, "unchanged")
          end
        else
          @store.advance_frontiers(date, batch.frontiers)
          result_row(date, "unchanged")
        end
      end

      def read_optional(date)
        @store.read(date)
      rescue DailyDigest::MissingRecord
        nil
      end

      def discard_entries(batch, resolved_gaps: [], observed_at:)
        Array(batch.facts).map do |fact|
          {
            "identity" => fact.fetch("fact_id"), "kind" => fact.fetch("kind"),
            "source" => fact.fetch("source", "task_journal"),
            "observed_at" => fact.fetch("observed_at"), "reason" => "digest projection was pruned"
          }
        end + Array(batch.gaps).map do |gap|
          {
            "identity" => gap.fetch("gap_id"), "kind" => "gap",
            "source" => gap.fetch("source"), "observed_at" => gap.fetch("observed_at"),
            "reason" => "digest projection was pruned"
          }
        end + Array(resolved_gaps).map do |gap|
          {
            "identity" => gap.fetch("gap_id"), "kind" => "gap_resolution",
            "source" => gap.fetch("source"), "observed_at" => timestamp(observed_at),
            "reason" => "digest projection was pruned before source recovery"
          }
        end
      end

      def due_for_materialization?(interval)
        existing = read_optional(interval.fetch("local_date"))
        existing.nil? || %w[open closed pruned].include?(existing.fetch("lifecycle"))
      end

      def merge_open_batch(existing, batch, confirmed_gap_ids:)
        confirmed = confirmed_gap_ids.to_h { |id| [ id, true ] }
        current_gaps = Array(existing["effective_gaps"] || existing["gaps"])
        retained_gaps = current_gaps.reject { |gap| confirmed[gap.fetch("gap_id")] }
        changed_tasks = changed_task_slugs(existing.fetch("effective_source_frontiers", {}), batch.frontiers)
        refreshed_projects = batch.frontiers.keys.to_h { |project_id| [ project_id, true ] }
        retained_attention = Array(existing["attention"]).reject do |item|
          refreshed_projects[item["project_id"]] && changed_tasks.include?(
            [ item["project_id"], item["task_slug"] ]
          )
        end
        Batch.new(
          projects: batch.projects,
          facts: (Array(existing["items"]) + Array(batch.facts)).uniq { |fact| fact.fetch("fact_id") },
          attention: (retained_attention + Array(batch.attention)).uniq do |item|
            item.fetch("attention_id")
          end,
          gaps: (retained_gaps + Array(batch.gaps)).uniq { |gap| gap.fetch("gap_id") },
          frontiers: existing.fetch("effective_source_frontiers", {}).merge(batch.frontiers)
        )
      end

      def changed_task_slugs(prior_frontiers, current_frontiers)
        current_frontiers.each_with_object([]) do |(project_id, frontier), changed|
          prior = prior_frontiers.dig(project_id, "fingerprints")
          current = frontier["fingerprints"]
          next unless current.is_a?(Hash)

          current.each do |key, signature|
            next if prior.is_a?(Hash) && prior[key] == signature

            changed << [ project_id, fingerprint_task_slug(key) ]
          end
        end
      end

      def confirmed_resolutions(existing, batch, attempted_gap_ids:, membership_gaps:,
                                membership_recovery_scopes: [])
        return [] unless existing

        attempted = Array(attempted_gap_ids).to_h { |id| [ id.to_s, true ] }
        observed_gaps = Array(batch.gaps).to_h { |gap| [ gap.fetch("gap_id"), true ] }
        membership_gap_ids = Array(membership_gaps).to_h { |gap| [ gap.fetch("gap_id"), true ] }
        Array(existing["effective_gaps"] || existing["gaps"]).filter_map do |gap|
          id = gap.fetch("gap_id")
          next unless attempted[id] && !observed_gaps[id]
          next unless positive_recovery_evidence?(
            gap, batch.frontiers, membership_gap_ids, membership_recovery_scopes
          )

          id
        end
      end

      def positive_recovery_evidence?(gap, frontiers, membership_gap_ids, membership_recovery_scopes)
        if gap["source"] == "project_registry"
          return !membership_gap_ids[gap.fetch("gap_id")] &&
            Array(membership_recovery_scopes).include?(gap.fetch("scope"))
        end

        project_id = gap["project_id"]
        frontier = project_id && frontiers[project_id]
        return false unless frontier.is_a?(Hash)
        return true if gap["task_slug"].to_s.empty?

        fingerprints = frontier["fingerprints"]
        fingerprints.is_a?(Hash) && fingerprints.keys.any? do |key|
          fingerprint_task_slug(key) == gap.fetch("task_slug")
        end
      end

      def fingerprint_task_slug(key)
        parts = key.to_s.split("/", 3)
        parts.length == 3 ? parts.fetch(1) : parts.fetch(0)
      end

      def resolved_pruned_gaps(existing, batch, attempted_gap_ids:)
        current = Array(existing["effective_gaps"])
        attempted = attempted_gap_ids && Array(attempted_gap_ids).to_h { |id| [ id.to_s, true ] }
        observed = Array(batch.gaps).to_h { |gap| [ gap.fetch("gap_id"), true ] }
        current.select do |gap|
          (!attempted || attempted[gap.fetch("gap_id")]) && !observed[gap.fetch("gap_id")]
        end
      end

      def timestamp(value)
        utc(value).iso8601(6)
      end

      def result_row(date, status, **attributes)
        { "local_date" => date, "status" => status, **attributes.transform_keys(&:to_s) }
      end

      def contains?(interval, instant)
        utc(interval.fetch("starts_at")) <= instant && instant < utc(interval.fetch("ends_at"))
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end
    end
  end
end
