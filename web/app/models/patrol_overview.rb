require "hive/patrol/finding_query"
require "hive/refactor_patrol/job_query"
require "hive/refactor_patrol/job_store"
require "digest"

class PatrolOverview
  ITEM_LIMIT = 25
  ARCHITECTURE_DETAIL_LIMIT = 5
  ARCHITECTURE_FINDINGS_PER_JOB = 3
  Section = Data.define(
    :enabled, :health, :total, :counts, :items, :last_run_at,
    :truncated, :error
  )

  attr_reader :project

  def initialize(project, ordinary_query: nil, architecture_query: nil,
                 logger: Rails.logger)
    @project = project
    @logger = logger
    @ordinary_query = ordinary_query || begin
      store = Hive::Patrol::StateStore.new(
        project.path, hive_state_path: project.hive_state_path
      )
      Hive::Patrol::FindingQuery.new(store)
    end
    @architecture_query = architecture_query || begin
      store = Hive::RefactorPatrol::JobStore.new(
        project.path, hive_state_path: project.hive_state_path
      )
      Hive::RefactorPatrol::JobQuery.new(store)
    end
  end

  def ordinary
    return disabled_section unless ordinary_enabled?

    payload = @ordinary_query.list_envelope(
      project: project.name, project_root: project.path
    )
    active = payload.fetch("counts").fetch("active", 0)
    health = if active.positive?
      "attention"
    elsif payload.fetch("feature_review_active")
      "running"
    elsif payload["last_run_at"]
      "healthy"
    else
      "idle"
    end

    Section.new(
      enabled: true,
      health: health,
      total: payload.fetch("count"),
      counts: payload.fetch("counts"),
      items: payload.fetch("findings"),
      last_run_at: payload["last_run_at"],
      truncated: payload.fetch("truncated"),
      error: nil
    )
  rescue StandardError => error
    error_section(error)
  end

  def architecture
    return disabled_section unless architecture_enabled?

    payload = @architecture_query.recent_envelope(
      project: project.name,
      project_root: project.path,
      limit: ITEM_LIMIT
    )
    jobs = architecture_findings(payload.fetch("jobs"))
    counts = jobs.group_by { |job| job.fetch("state") }
                 .transform_values(&:size)
    health = if jobs.any? { |job| job.fetch("state") == "blocked" }
      "attention"
    elsif jobs.any? { |job| %w[queued analyzing classified acting].include?(job.fetch("state")) }
      "running"
    elsif jobs.any?
      "healthy"
    else
      "idle"
    end

    Section.new(
      enabled: true,
      health: health,
      total: payload.fetch("count"),
      counts: counts,
      items: jobs,
      last_run_at: jobs.map { |job| job["updated_at"] }.compact.max,
      truncated: payload.dig("page", "has_more") == true,
      error: nil
    )
  rescue StandardError => error
    error_section(error)
  end

  private

  def ordinary_enabled?
    project.config.dig("patrol", "mode").to_s != "off"
  end

  def architecture_enabled?
    project.config.dig("refactor_patrol", "enabled") == true
  end

  def architecture_findings(jobs)
    remaining = ARCHITECTURE_DETAIL_LIMIT
    jobs.map do |job|
      projected = job.dup
      next projected unless remaining.positive? &&
                            job.dig("counts", "accepted").to_i.positive?

      remaining -= 1
      detail = @architecture_query.show_envelope(
        project: project.name,
        project_root: project.path,
        job_id: job.fetch("job_id"),
        limit: 1
      )
      projected["findings"] = Array(
        detail.dig("job", "dispositions", "accepted")
      ).first(ARCHITECTURE_FINDINGS_PER_JOB).map do |item|
        thesis = item["thesis"].is_a?(Hash) ? item.fetch("thesis") : {}
        {
          "id" => item["id"],
          "score" => item["score"],
          "problem" => thesis["problem"],
          "proposed_refactor" => thesis["proposed_refactor"]
        }
      end
      projected
    end
  end

  def disabled_section
    Section.new(
      enabled: false, health: "disabled", total: 0, counts: {}, items: [],
      last_run_at: nil, truncated: false, error: nil
    )
  end

  def error_section(error)
    diagnostic = Digest::SHA256.hexdigest(
      "#{error.class.name}\0#{error.message}"
    ).first(12)
    @logger.warn(
      "patrol overview unavailable: #{error.class.name} " \
      "diagnostic=#{diagnostic}"
    )
    Section.new(
      enabled: true, health: "unavailable", total: 0, counts: {}, items: [],
      last_run_at: nil, truncated: false,
      error: "Patrol data is temporarily unavailable."
    )
  end
end
