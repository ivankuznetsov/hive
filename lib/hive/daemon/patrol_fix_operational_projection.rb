require "hive/patrol/finding_query"
require "hive/patrol/launch_budget"
require "hive/patrol/state_store"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/operational_projection"
require "hive/refactor_patrol/job_query"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/post_merge_batch_store"
require "hive/refactor_patrol/scheduled_slice_producer"
require "hive/usage_db"

module Hive
  module Daemon
    # Edge-owned source translator for the closed PatrolFix read model.
    # Interfaces consume its result; they never open either discovery store.
    class PatrolFixOperationalProjection
      ARCHITECTURE_DETAIL_LIMIT = 5
      ARCHITECTURE_FINDINGS_PER_JOB = 3
      ARCHITECTURE_PAGE_LIMIT = Hive::RefactorPatrol::JobQuery::MAX_LIMIT

      def initialize(ordinary_reader: nil, architecture_reader: nil,
                     allowance_reader: nil, admissions_reader: nil,
                     migration_reader: nil, batches_reader: nil,
                     scheduled_results_reader: nil, usage_reader: nil,
                     architecture_query_factory: nil)
        @ordinary_reader = ordinary_reader || method(:read_ordinary)
        @architecture_reader = architecture_reader || method(:read_architecture)
        @allowance_reader = allowance_reader || method(:read_allowance)
        @admissions_reader = admissions_reader || method(:read_admissions)
        @migration_reader = migration_reader || method(:read_migration)
        @batches_reader = batches_reader || method(:read_batches)
        @scheduled_results_reader = scheduled_results_reader || method(:read_scheduled_results)
        @usage_reader = usage_reader || method(:read_usage)
        @architecture_query_factory = architecture_query_factory || lambda do |store|
          Hive::RefactorPatrol::JobQuery.new(store)
        end
      end

      def call(project:, config:, tasks:, now: Time.now.utc)
        diagnostics = []
        ordinary = lane_with_diagnostic("ordinary", diagnostics) do
          ordinary_lane(project, config, now)
        end
        architecture, architecture_stats = lane_with_diagnostic("architecture", diagnostics) do
          architecture_lane(project, config, now)
        end
        admissions = read_with_diagnostic("admission", diagnostics, []) do
          @admissions_reader.call(project: project, config: config, now: now)
        end
        migration = read_with_diagnostic("migration", diagnostics, nil) do
          @migration_reader.call(project: project, config: config, now: now)
        end
        batches = read_with_diagnostic("post_merge_batches", diagnostics, []) do
          @batches_reader.call(project: project, config: config, now: now)
        end
        scheduled_results = read_with_diagnostic("architecture_coverage", diagnostics, []) do
          @scheduled_results_reader.call(project: project, config: config, now: now)
        end
        tokens = read_with_diagnostic("token_telemetry", diagnostics, nil) do
          @usage_reader.call(project: project, config: config, now: now)
        end
        unless tokens.is_a?(Hash) && (tokens["available"] == true || tokens[:available] == true)
          diagnostics << {
            "source" => "token_telemetry", "code" => "token_telemetry_unavailable",
            "summary" => "Patrol token telemetry is unavailable"
          } unless diagnostics.any? { |entry| entry["source"] == "token_telemetry" }
          tokens = nil
        end

        Hive::PatrolFix::OperationalProjection.new(
          project: project.fetch("name"), tasks: tasks, admissions: admissions,
          discovery: {
            "ordinary" => ordinary,
            "architecture" => architecture,
            "post_merge" => post_merge(architecture_stats, batches),
            "coverage" => {
              "ordinary" => ordinary["last_run_at"],
              "architecture" => architecture_coverage(architecture_stats, scheduled_results)
            }
          },
          migration: migration, tokens: tokens, diagnostics: diagnostics, now: now
        ).to_h
      end

      def unavailable(project:, tasks:, now:, source:, code:, error:)
        Hive::PatrolFix::OperationalProjection.unavailable(
          project: project.fetch("name"), tasks: tasks, now: now,
          source: source, code: code,
          summary: diagnostic(source, code, error).fetch("summary")
        )
      end

      private

      def ordinary_lane(project, config, now)
        enabled = config.dig("patrol", "mode").to_s != "off"
        return disabled_lane("ordinary", project, config, now) unless enabled

        payload = @ordinary_reader.call(project: project, config: config, now: now)
        active = payload.fetch("counts", {}).fetch("active", 0).to_i
        health = if active.positive?
          "attention"
        elsif payload["feature_review_active"]
          "running"
        elsif payload["last_run_at"]
          "healthy"
        else
          "idle"
        end
        lane(
          engine: "ordinary", health: health, payload: payload,
          allowance: allowance(project, config, "ordinary", now),
          items: Array(payload.fetch("findings")).map { |finding| ordinary_item(finding) }
        )
      end

      def architecture_lane(project, config, now)
        enabled = config.dig("refactor_patrol", "enabled") == true
        return [
          disabled_lane("architecture", project, config, now),
          { "counts" => {}, "last_run_at" => nil }
        ] unless enabled

        payload = @architecture_reader.call(project: project, config: config, now: now)
        jobs = Array(payload.fetch("jobs"))
        counts = payload.fetch("counts")
        health = if counts.fetch("blocked", 0).positive?
          "attention"
        elsif %w[queued analyzing classified acting].any? { |state| counts.fetch(state, 0).positive? }
          "running"
        elsif payload.fetch("count").positive?
          "healthy"
        else
          "idle"
        end
        [ lane(
          engine: "architecture", health: health, payload: payload,
          allowance: allowance(project, config, "architecture", now),
          items: jobs.map { |job| architecture_item(job) }
        ), { "counts" => counts, "last_run_at" => payload["last_run_at"] } ]
      end

      def lane(engine:, health:, payload:, allowance:, items:)
        {
          "enabled" => true, "health" => health,
          "total" => Integer(payload.fetch("count")),
          "counts" => payload.fetch("counts", {}),
          "last_run_at" => payload["last_run_at"] ||
            Array(payload["jobs"]).map { |job| job["updated_at"] }.compact.max,
          "truncated" => payload["truncated"] == true,
          "allowance" => allowance,
          "items" => items
        }
      end

      def disabled_lane(engine, project, config, now)
        {
          "enabled" => false, "health" => "disabled", "total" => 0,
          "counts" => {}, "last_run_at" => nil, "truncated" => false,
          "allowance" => allowance(project, config, engine, now).merge("status" => "disabled"),
          "items" => []
        }
      end

      def unavailable_lane(engine)
        {
          "enabled" => true, "health" => "unavailable", "total" => 0,
          "counts" => {}, "last_run_at" => nil, "truncated" => false,
          "allowance" => {
            "engine" => engine, "utc_date" => nil, "limit" => nil,
            "used" => nil, "remaining" => nil, "status" => "unavailable", "retry_at" => nil
          },
          "items" => []
        }
      end

      def lane_with_diagnostic(engine, diagnostics)
        yield
      rescue StandardError => error
        diagnostics << diagnostic(engine, "#{engine}_discovery_unavailable", error)
        engine == "architecture" ? [
          unavailable_lane(engine), { "counts" => {}, "last_run_at" => nil }
        ] : unavailable_lane(engine)
      end

      def read_with_diagnostic(source, diagnostics, fallback)
        yield
      rescue StandardError => error
        diagnostics << diagnostic(source, "#{source}_unavailable", error)
        fallback
      end

      def diagnostic(source, code, error)
        {
          "source" => source,
          "code" => code,
          "summary" => "#{source.tr('_', ' ')} data is unavailable (#{error.class.name})"
        }
      end

      def allowance(project, config, engine, now)
        @allowance_reader.call(
          project: project, config: config, engine: engine, now: now
        ).transform_keys(&:to_s).slice(
          "engine", "utc_date", "limit", "used", "remaining", "status", "retry_at"
        )
      end

      def ordinary_item(finding)
        description = finding["description"]
        {
          "engine" => "ordinary_patrol",
          "identity" => finding.fetch("id").to_s,
          "state" => finding.fetch("lifecycle_state", "active").to_s,
          "title" => finding["title"] || finding["category"],
          "summary" => description,
          "route" => finding["route"],
          "severity" => finding["severity"],
          "confidence" => finding["confidence"],
          "feature_id" => finding["feature_id"],
          "target_revision" => finding["analysis_sha"],
          "source" => { "kind" => "finding", "id" => finding.fetch("id").to_s },
          "updated_at" => finding["updated_at"] || finding["created_at"],
          "evidence" => description ? [ description ] : [],
          "blocker" => finding["blocked_reason"]
        }
      end

      def architecture_item(job)
        source = job.fetch("source", {})
        findings = Array(job["findings"])
        evidence = findings.flat_map do |finding|
          [ finding["problem"], finding["proposed_refactor"] ]
        end.compact.uniq.first(Hive::PatrolFix::OperationalProjection::MAX_EVIDENCE_PER_ITEM)
        blockers = Array(job["blockers"]).filter_map { |blocker| blocker["reason"] }.uniq
        number = source["number"]
        routes = findings.map { |finding| finding["route"] }.compact.uniq.join(",")
        {
          "engine" => "architecture_patrol",
          "identity" => job.fetch("job_id").to_s,
          "state" => job.fetch("state").to_s,
          "title" => number ? "Architecture Patrol PR ##{number}" : "Architecture Patrol #{job.fetch('job_id')}",
          "summary" => evidence.first || blockers.first,
          "route" => routes.empty? ? nil : routes,
          "severity" => nil, "confidence" => nil, "feature_id" => nil,
          "target_revision" => job["analysis_sha"],
          "source" => {
            "kind" => "pull_request", "id" => number&.to_s,
            "url" => source["url"], "number" => number
          },
          "updated_at" => job["updated_at"],
          "evidence" => evidence,
          "blocker" => blockers.empty? ? nil : blockers.join(", ")
        }
      end

      def post_merge(stats, batches)
        counts = stats.fetch("counts", {})
        {
          "queued" => counts.fetch("queued", 0),
          "in_flight" => %w[analyzing classified acting].sum { |state| counts.fetch(state, 0) },
          "blocked" => counts.fetch("blocked", 0),
          "batches" => Array(batches).length
        }
      end

      def architecture_coverage(stats, results)
        ([ stats["last_run_at"] ] +
          Array(results).map { |result| result["created_at"] }).compact.max
      end

      def read_ordinary(project:, **)
        store = Hive::Patrol::StateStore.new(
          project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
        )
        Hive::Patrol::FindingQuery.new(store).list_envelope(
          project: project.fetch("name"), project_root: project.fetch("path")
        )
      end

      def read_architecture(project:, **)
        store = Hive::RefactorPatrol::JobStore.new(
          project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
        )
        query = @architecture_query_factory.call(store)
        payload = complete_architecture_projection(query, project)
        remaining = ARCHITECTURE_DETAIL_LIMIT
        payload.fetch("jobs").each do |job|
          next unless remaining.positive? &&
                      %w[fix discuss].sum { |route| job.dig("counts", route).to_i }.positive?
          remaining -= 1
          detail = query.show_envelope(
            project: project.fetch("name"), project_root: project.fetch("path"),
            job_id: job.fetch("job_id"), limit: 1
          ).fetch("job")
          dispositions = detail.fetch("dispositions", {})
          job["findings"] = %w[fix discuss].flat_map do |route|
            Array(dispositions[route]).map do |item|
              thesis = item["thesis"].is_a?(Hash) ? item.fetch("thesis") : {}
              {
                "id" => item["id"], "route" => route,
                "problem" => thesis["problem"],
                "proposed_refactor" => thesis["proposed_refactor"]
              }
            end
          end.first(ARCHITECTURE_FINDINGS_PER_JOB)
        end
        payload
      end

      def complete_architecture_projection(query, project)
        cursor = nil
        total = nil
        counts = Hash.new(0)
        latest = nil
        recent = []
        loop do
          page = query.list_envelope(
            project: project.fetch("name"), project_root: project.fetch("path"),
            limit: ARCHITECTURE_PAGE_LIMIT, cursor: cursor
          )
          page_total = page.fetch("count")
          total ||= page_total
          unless page_total == total
            raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                  "architecture projection membership changed"
          end
          page.fetch("jobs").each do |job|
            counts[job.fetch("state").to_s] += 1
            updated_at = job["updated_at"]
            latest = updated_at if updated_at && (!latest || updated_at > latest)
            recent << job
          end
          recent = recent.sort_by do |job|
            [ job.fetch("updated_at").to_s, job.fetch("job_id").to_s ]
          end.last(Hive::PatrolFix::OperationalProjection::MAX_ITEMS_PER_LANE)
          break unless page.dig("page", "has_more") == true

          cursor = page.dig("page", "next_cursor")
          unless cursor
            raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                  "architecture projection cursor is missing"
          end
        end
        unless counts.values.sum == (total || 0)
          raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                "architecture projection is incomplete"
        end
        {
          "project" => project.fetch("name"),
          "project_root" => project.fetch("path"),
          "count" => total || 0,
          "counts" => counts.to_h,
          "last_run_at" => latest,
          "truncated" => (total || 0) > recent.length,
          "jobs" => recent.reverse
        }
      end

      def read_allowance(project:, config:, engine:, now:)
        Hive::Patrol::LaunchBudget.new(
          project.fetch("path"), cfg: config,
          project_id: project.fetch("project_id"),
          project_name: project.fetch("name"), engine: engine.to_sym,
          clock: -> { now }
        ).allowance_snapshot
      end

      def read_admissions(project:, **)
        Hive::PatrolFix::AdmissionStore.new(
          root: File.join(project.fetch("hive_state_path"), "patrol-fix", "admissions")
        ).operational_records
      end

      def read_migration(project:, **)
        store = Hive::PatrolFix::Migration::CutoverState.new(
          root: File.join(project.fetch("hive_state_path"), "patrol-fix", "migration")
        )
        state = store.read
        return {
          "status" => "not_started", "candidate_count" => 0, "group_count" => 0,
          "disposition_count" => 0, "acknowledgement_count" => 0,
          "manifest_digest" => nil
        } unless state

        manifest = store.manifest.to_h
        {
          "status" => state.fetch("status"),
          "candidate_count" => manifest.dig("integrity", "inventory_count"),
          "group_count" => manifest.fetch("semantic_groups").length,
          "disposition_count" => manifest.dig("integrity", "disposition_count"),
          "acknowledgement_count" => state.fetch("acknowledgement_count"),
          "manifest_digest" => state.fetch("manifest_digest")
        }
      end

      def read_batches(project:, **)
        Hive::RefactorPatrol::PostMergeBatchStore.new(
          root: File.join(
            project.fetch("hive_state_path"), "refactor_patrol", "v2", "post-merge-batches"
          )
        ).each_record.to_a
      end

      def read_scheduled_results(project:, config:, **)
        Hive::RefactorPatrol::ScheduledSliceProducer.new(
          entry: project, cfg: config
        ).each_result.to_a
      end

      def read_usage(project:, now:, **)
        Hive::UsageDb.patrol_activity(
          scope: { project_slug: project.fetch("name") }, now: now
        )
      end
    end
  end
end
