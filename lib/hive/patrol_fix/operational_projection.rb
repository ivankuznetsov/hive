require "time"
require "json"
require "json_schemer"
require "pathname"
require "hive/patrol_fix"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/projection"

module Hive
  module PatrolFix
    # Closed, bounded project read model for every Patrol operational surface.
    # Source owners translate their stores before entering this core object;
    # this class never opens ordinary Patrol or Architecture Patrol state.
    class OperationalProjection
      SCHEMA = "hive-patrol-fix-operational-projection".freeze
      SCHEMA_VERSION = 1
      MAX_ITEMS_PER_LANE = 25
      MAX_EVIDENCE_PER_ITEM = 3
      MAX_DIAGNOSTICS = 16
      MAX_TEXT_BYTES = 1_024
      MAX_TASKS = 8_192
      MAX_ADMISSIONS = AdmissionStore::MAX_RECORDS
      MAX_DOCUMENT_BYTES = 512 * 1024
      DOCUMENT_KEYS = %w[
        schema schema_version project generated_at completeness diagnostics
        discovery admission workflow migration delivery tokens
      ].sort.freeze
      STAGES = Projection::STAGE_DIRS
      ADMISSION_STATUSES = AdmissionStore::STATUSES

      def self.valid_document?(document, project: nil)
        return false unless document.is_a?(Hash)
        return false if project && document["project"] != project.to_s
        return false unless JSON.generate(document).bytesize <= MAX_DOCUMENT_BYTES

        schema_validator.valid?(document)
      rescue JSON::GeneratorError, TypeError, SystemCallError
        false
      end

      def self.schema_validator
        @schema_validator ||= JSONSchemer.schema(
          Pathname.new(Hive::Schemas.schema_path(SCHEMA, version: SCHEMA_VERSION))
        )
      end

      def self.unavailable(project:, tasks:, now:, source:, code:, summary:)
        unavailable_lane = lambda do |engine|
          {
            "enabled" => true, "health" => "unavailable", "total" => 0,
            "counts" => {}, "last_run_at" => nil, "truncated" => false,
            "allowance" => {
              "engine" => engine, "utc_date" => nil, "limit" => nil,
              "used" => nil, "remaining" => nil, "status" => "unavailable",
              "retry_at" => nil
            },
            "items" => []
          }
        end
        new(
          project: project, tasks: tasks, admissions: [],
          discovery: {
            "ordinary" => unavailable_lane.call("ordinary"),
            "architecture" => unavailable_lane.call("architecture"),
            "post_merge" => {}, "coverage" => {}
          },
          migration: nil,
          tokens: nil,
          diagnostics: [ { "source" => source, "code" => code, "summary" => summary } ],
          now: now
        ).to_h
      end

      def initialize(project:, tasks:, admissions:, discovery:, migration:, tokens: nil,
                     diagnostics: [], now: Time.now.utc)
        @project = text(project, "project", max: 256)
        @tasks = Array(tasks)
        @admissions = Array(admissions)
        raise ArgumentError, "Patrol-fix task projection exceeds its bound" if @tasks.length > MAX_TASKS
        raise ArgumentError, "Patrol-fix admission projection exceeds its bound" if
          @admissions.length > MAX_ADMISSIONS
        @discovery = discovery || {}
        @migration = migration
        @tokens = tokens
        @diagnostics = Array(diagnostics)
        @now = normalize_time(now)
      end

      def to_h
        lanes = {
          "ordinary" => lane("ordinary"),
          "architecture" => lane("architecture")
        }
        roots = root_groups
        task_rows = patrol_fix_tasks
        diagnostics = normalized_diagnostics
        unresolved = unresolved_admissions
        workflow = workflow_projection(task_rows)
        data = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "project" => @project,
          "generated_at" => @now.iso8601,
          "completeness" => completeness(lanes, diagnostics, unresolved, workflow),
          "diagnostics" => diagnostics,
          "discovery" => {
            "ordinary" => lanes.fetch("ordinary"),
            "architecture" => lanes.fetch("architecture"),
            "post_merge" => post_merge,
            "coverage" => coverage
          },
          "admission" => admission_projection(roots, unresolved),
          "workflow" => workflow,
          "migration" => migration_projection,
          "delivery" => delivery_projection(roots, task_rows),
          "tokens" => token_projection
        }
        PatrolFix.deep_freeze(data)
      end

      private

      def lane(engine)
        raw = hash(@discovery[engine], "discovery.#{engine}")
        items = Array(raw["items"])
        normalized = items.first(MAX_ITEMS_PER_LANE).map.with_index do |item, index|
          normalize_item(item, engine: engine, index: index)
        end
        {
          "enabled" => raw["enabled"] == true,
          "health" => enum(raw.fetch("health", "unavailable"),
                           %w[disabled idle healthy running attention unavailable],
                           "discovery.#{engine}.health"),
          "total" => nonnegative_integer(raw.fetch("total", items.length),
                                         "discovery.#{engine}.total"),
          "counts" => count_hash(raw.fetch("counts", {}), "discovery.#{engine}.counts"),
          "last_run_at" => optional_time(raw["last_run_at"], "discovery.#{engine}.last_run_at"),
          "truncated" => raw["truncated"] == true || items.length > MAX_ITEMS_PER_LANE,
          "allowance" => allowance(raw.fetch("allowance", {}), engine),
          "items" => normalized
        }
      end

      def normalize_item(raw, engine:, index:)
        item = hash(raw, "discovery.#{engine}.items[#{index}]")
        {
          "engine" => text(item.fetch("engine"), "discovery item engine", max: 64),
          "identity" => text(item.fetch("identity"), "discovery item identity", max: 2_048),
          "state" => text(item.fetch("state"), "discovery item state", max: 128),
          "title" => optional_text(item["title"], "discovery item title", max: 1_024),
          "summary" => optional_text(item["summary"], "discovery item summary", max: MAX_TEXT_BYTES),
          "route" => optional_text(item["route"], "discovery item route", max: 128),
          "severity" => optional_text(item["severity"], "discovery item severity", max: 128),
          "confidence" => optional_text(item["confidence"], "discovery item confidence", max: 128),
          "feature_id" => optional_text(item["feature_id"], "discovery item feature", max: 1_024),
          "target_revision" => optional_text(item["target_revision"], "discovery item revision", max: 128),
          "source" => item["source"] && normalize_source(item.fetch("source")),
          "updated_at" => optional_time(item["updated_at"], "discovery item updated_at"),
          "evidence" => Array(item["evidence"]).first(MAX_EVIDENCE_PER_ITEM).map do |value|
            text(value, "discovery item evidence", max: MAX_TEXT_BYTES)
          end,
          "blocker" => optional_text(item["blocker"], "discovery item blocker", max: MAX_TEXT_BYTES)
        }
      end

      def normalize_source(raw)
        source = hash(raw, "discovery item source")
        allowed = %w[kind id url number]
        raise ArgumentError, "discovery item source fields are invalid" unless
          (source.keys - allowed).empty?
        {
          "kind" => optional_text(source["kind"], "discovery source kind", max: 64),
          "id" => optional_text(source["id"], "discovery source id", max: 2_048),
          "url" => optional_text(source["url"], "discovery source url", max: 4_096),
          "number" => optional_nonnegative_integer(source["number"], "discovery source number")
        }
      end

      def allowance(raw, engine)
        value = hash(raw, "discovery.#{engine}.allowance")
        {
          "engine" => text(value.fetch("engine", engine), "allowance engine", max: 64),
          "utc_date" => optional_text(value["utc_date"], "allowance utc_date", max: 10),
          "limit" => optional_nonnegative_integer(value["limit"], "allowance limit"),
          "used" => optional_nonnegative_integer(value["used"], "allowance used"),
          "remaining" => optional_nonnegative_integer(value["remaining"], "allowance remaining"),
          "status" => text(value.fetch("status", "unavailable"), "allowance status", max: 128),
          "retry_at" => optional_time(value["retry_at"], "allowance retry_at")
        }
      end

      def post_merge
        raw = hash(@discovery.fetch("post_merge", {}), "discovery.post_merge")
        %w[queued in_flight blocked batches].to_h do |key|
          [ key, nonnegative_integer(raw.fetch(key, 0), "discovery.post_merge.#{key}") ]
        end
      end

      def coverage
        raw = hash(@discovery.fetch("coverage", {}), "discovery.coverage")
        %w[ordinary architecture].to_h do |engine|
          observed = optional_time(raw[engine], "discovery.coverage.#{engine}")
          age = observed && [ (@now - Time.iso8601(observed)).to_i, 0 ].max
          [ engine, { "observed_at" => observed, "age_seconds" => age } ]
        end
      end

      def root_groups
        ids = @admissions.map { |record| hash(record, "admission").fetch("occurrence_id").to_s }
        raise ArgumentError, "Patrol-fix admission occurrence identities are duplicated" unless
          ids.uniq.length == ids.length
        @admissions.each_with_object({}) do |record, groups|
          admission = hash(record, "admission")
          key = root_key(admission)
          next unless key

          group = (groups[key] ||= { "root_key" => key, "records" => [], "created_at" => nil })
          created = required_time(admission.fetch("created_at"), "admission created_at")
          group["created_at"] = [ group["created_at"], created ].compact.min
          group.fetch("records") << admission
        end
      end

      def root_key(record)
        slug = record.dig("task", "slug").to_s
        return "task:#{slug}" unless slug.empty?

        decision = record["decision"]
        return nil unless decision.is_a?(Hash)
        if decision["decision"] == "same_root" && !decision["candidate_identity"].to_s.empty?
          identity = decision.fetch("candidate_identity").to_s
          candidate = Array(record["candidates"]).find { |item| item["identity"] == identity }
          kind = candidate&.fetch("kind", nil).to_s
          return kind == "task" ? "task:#{identity}" : "candidate:#{kind.empty? ? 'unknown' : kind}:#{identity}"
        end
        return "occurrence:#{record.fetch('occurrence_id')}" if decision["decision"] == "distinct"

        nil
      end

      def unresolved_admissions
        @admissions.count { |record| root_key(hash(record, "admission")).nil? }
      end

      def admission_projection(roots, unresolved)
        statuses = ADMISSION_STATUSES.to_h { |status| [ status, 0 ] }
        retry_times = []
        @admissions.each do |record|
          value = hash(record, "admission")
          status = value.fetch("status").to_s
          raise ArgumentError, "admission status is invalid" unless statuses.key?(status)
          statuses[status] += 1
          retry_times << required_time(value.dig("retry", "retry_at"), "admission retry_at") if
            value.dig("retry", "retry_at")
        end
        {
          "total_occurrences" => @admissions.length,
          "unique_roots" => roots.length,
          "unresolved" => unresolved,
          "counts" => statuses,
          "next_retry_at" => retry_times.min
        }
      end

      def patrol_fix_tasks
        tasks = @tasks.filter_map do |task|
          value = hash(task, "task")
          projection = value["patrol_fix"]
          next unless projection.is_a?(Hash)
          value
        end
        slugs = tasks.map { |task| task.fetch("slug").to_s }
        raise ArgumentError, "Patrol-fix task identities are duplicated" unless slugs.uniq.length == slugs.length
        tasks
      end

      def workflow_projection(tasks)
        stages = STAGES.to_h { |stage| [ stage, 0 ] }
        counts = {
          "total" => tasks.length, "active" => 0, "parked" => 0, "provider" => 0,
          "rework" => 0, "rejected" => 0, "blocked" => 0, "escalated" => 0,
          "successors" => 0
        }
        latency = {
          "total_seconds" => 0, "active_seconds" => nil,
          "parked_seconds" => 0, "provider_seconds" => nil,
          "provider_history" => "unavailable",
          "sample_count" => 0,
          "unavailable_count" => 0,
          "current_provider" => { "tasks" => 0, "next_retry_at" => nil },
          "by_stage" => STAGES.to_h do |stage|
            [ stage, { "tasks" => 0, "total_seconds" => 0,
                       "active_seconds" => nil, "parked_seconds" => 0,
                       "provider_seconds" => nil } ]
          end
        }
        tasks.each do |task|
          projection = task.fetch("patrol_fix")
          stage = projection.fetch("stage")
          stages[stage] += 1 if stages.key?(stage)
          outcome = projection["outcome"]
          provider = task["held"].is_a?(Hash)
          if outcome
            counts["parked"] += 1
            kind = outcome["kind"].to_s
            counts[kind] += 1 if counts.key?(kind)
          elsif provider
            counts["provider"] += 1
            latency.dig("current_provider", "tasks").then do |count|
              latency.fetch("current_provider")["tasks"] = count + 1
            end
            retry_at = optional_time(task.dig("held", "retry_after"), "provider retry_after")
            current = latency.dig("current_provider", "next_retry_at")
            latency.fetch("current_provider")["next_retry_at"] = [ current, retry_at ].compact.min
          elsif stage != "6-done" # not-a-stage-ref: Patrol Fix workflow stage
            counts["active"] += 1
          end
          counts["successors"] += 1 if projection["successor"]
          timing = hash(projection.fetch("timing", {}), "patrol_fix.timing")
          counts["rework"] += nonnegative_integer(timing.fetch("rework_count", 0), "rework count")
          add_latency!(latency, task, timing, outcome: !outcome.nil?)
        end
        { "stages" => stages, "counts" => counts, "latency" => latency }
      end

      def add_latency!(totals, task, timing, outcome:)
        started = optional_time(timing["started_at"], "task timing started_at")
        unless started
          totals["unavailable_count"] += 1
          return
        end
        totals["sample_count"] += 1

        projection = task.fetch("patrol_fix")
        finish = if projection.fetch("stage") == "6-done" # not-a-stage-ref: Patrol Fix workflow stage
          optional_time(projection.dig("publication", "observed_at"), "publication observed_at")
        end
        finish_time = finish ? Time.iso8601(finish) : @now
        total = [ (finish_time - Time.iso8601(started)).to_i, 0 ].max
        parked = nonnegative_integer(timing.fetch("parked_seconds", 0), "parked seconds")
        if outcome && timing["parked_since"]
          parked += [ (finish_time - Time.iso8601(required_time(timing["parked_since"], "parked_since"))).to_i, 0 ].max
        end
        totals["total_seconds"] += total
        totals["parked_seconds"] += [ parked, total ].min
        stage = projection.fetch("stage")
        stage_started = optional_time(timing["stage_started_at"], "stage started_at") || started
        stage_total = [ (finish_time - Time.iso8601(stage_started)).to_i, 0 ].max
        bucket = totals.fetch("by_stage").fetch(stage)
        bucket["tasks"] += 1
        bucket["total_seconds"] += stage_total
        bucket["parked_seconds"] += [ parked, stage_total ].min
      end

      def migration_projection
        return unavailable_migration unless @migration.is_a?(Hash)

        {
          "status" => text(@migration.fetch("status"), "migration status", max: 64),
          "candidate_count" => optional_nonnegative_integer(@migration["candidate_count"], "migration candidates"),
          "group_count" => optional_nonnegative_integer(@migration["group_count"], "migration groups"),
          "disposition_count" => optional_nonnegative_integer(@migration["disposition_count"], "migration dispositions"),
          "acknowledgement_count" => optional_nonnegative_integer(@migration["acknowledgement_count"], "migration acknowledgements"),
          "manifest_digest" => optional_text(@migration["manifest_digest"], "migration digest", max: 64)
        }
      end

      def unavailable_migration
        {
          "status" => "unavailable", "candidate_count" => nil, "group_count" => nil,
          "disposition_count" => nil, "acknowledgement_count" => nil, "manifest_digest" => nil
        }
      end

      # Usage is observability only. It is deliberately projected alongside,
      # but never consulted by, discovery allowance or workflow admission.
      def token_projection
        value = @tokens.is_a?(Hash) ? @tokens : {}
        available = value["available"] == true || value[:available] == true
        return {
          "available" => false, "utc_date" => @now.strftime("%Y-%m-%d"),
          "input" => nil, "output" => nil, "cached" => nil, "total" => nil,
          "launches" => nil, "unmetered_launches" => nil
        } unless available

        {
          "available" => true,
          "utc_date" => @now.strftime("%Y-%m-%d"),
          "input" => token_count(value, "input"),
          "output" => token_count(value, "output"),
          "cached" => token_count(value, "cached"),
          "total" => token_count(value, "tokens"),
          "launches" => token_count(value, "agent_spawns"),
          "unmetered_launches" => token_count(value, "unmetered_spawns")
        }
      end

      def token_count(value, key)
        raw = value.key?(key) ? value.fetch(key) : value.fetch(key.to_sym)
        nonnegative_integer(raw, "token telemetry #{key}")
      end

      def delivery_projection(roots, tasks)
        task_index = tasks.to_h { |task| [ "task:#{task.fetch('slug')}", task.fetch("patrol_fix") ] }
        cohorts = roots.values.group_by do |group|
          Time.iso8601(group.fetch("created_at")).utc.strftime("%Y-%m-%d")
        end.sort.map do |date, groups|
          delivery_counts(date, groups, task_index)
        end
        totals = delivery_counts(nil, roots.values, task_index)
        denominator = totals.fetch("roots")
        {
          "cohorts" => cohorts,
          "task_conversion" => conversion(totals.fetch("tasks"), denominator),
          "pr_conversion" => conversion(totals.fetch("pr_created"), denominator),
          "pr_created" => totals.fetch("pr_created"),
          "pr_open" => totals.fetch("pr_open")
        }
      end

      def delivery_counts(date, groups, task_index)
        values = Array(groups).map do |group|
          task = task_index[group.fetch("root_key")]
          publication = task && task["publication"]
          [ !task.nil?, !publication.nil?, publication && publication["state"] == "open" ]
        end
        {
          "utc_date" => date,
          "roots" => values.length,
          "tasks" => values.count(&:first),
          "pr_created" => values.count { |row| row[1] },
          "pr_open" => values.count { |row| row[2] }
        }.compact
      end

      def conversion(numerator, denominator)
        {
          "converted" => numerator,
          "denominator" => denominator,
          "rate" => denominator.zero? ? nil : numerator.to_f / denominator
        }
      end

      def completeness(lanes, diagnostics, unresolved, workflow)
        return "partial" if unresolved.positive? || diagnostics.any?
        return "partial" if workflow.dig("latency", "unavailable_count").positive?
        return "partial" if lanes.values.any? { |value| value["health"] == "unavailable" }
        return "partial" if migration_projection["status"] == "unavailable"

        "complete"
      end

      def normalized_diagnostics
        @diagnostics.first(MAX_DIAGNOSTICS).map.with_index do |raw, index|
          value = hash(raw, "diagnostic #{index}")
          {
            "source" => text(value.fetch("source"), "diagnostic source", max: 128),
            "code" => text(value.fetch("code"), "diagnostic code", max: 128),
            "summary" => text(value.fetch("summary"), "diagnostic summary", max: 512)
          }
        end
      end

      def count_hash(value, label)
        hash(value, label).sort.to_h do |key, count|
          [ text(key, label, max: 128), nonnegative_integer(count, label) ]
        end
      end

      def hash(value, label)
        raise ArgumentError, "#{label} must be an object" unless value.is_a?(Hash)
        value
      end

      def enum(value, allowed, label)
        candidate = value.to_s
        raise ArgumentError, "#{label} is invalid" unless allowed.include?(candidate)
        candidate
      end

      def text(value, label, max:)
        candidate = value.to_s
        unless !candidate.empty? && candidate.bytesize <= max &&
               !candidate.match?(/[\u0000-\u001f\u007f]/)
          raise ArgumentError, "#{label} is invalid"
        end
        candidate
      end

      def optional_text(value, label, max:)
        value.nil? ? nil : text(value, label, max: max)
      end

      def nonnegative_integer(value, label)
        raise ArgumentError, "#{label} is invalid" unless value.is_a?(Integer) && value >= 0
        value
      end

      def optional_nonnegative_integer(value, label)
        value.nil? ? nil : nonnegative_integer(value, label)
      end

      def normalize_time(value)
        value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
      rescue ArgumentError
        raise ArgumentError, "projection time is invalid"
      end

      def required_time(value, label)
        time = Time.iso8601(value.to_s)
        raise ArgumentError, "#{label} must be UTC" unless time.utc? && value.to_s.end_with?("Z")
        time.utc.iso8601
      rescue ArgumentError
        raise ArgumentError, "#{label} is invalid"
      end

      def optional_time(value, label)
        value.nil? ? nil : required_time(value, label)
      end
    end
  end
end
