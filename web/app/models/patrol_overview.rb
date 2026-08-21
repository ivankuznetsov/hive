require "hive/patrol_fix/operational_projection"

# Read-only web adapter over the daemon-owned common Patrol projection.
# It never opens ordinary or Architecture Patrol stores.
class PatrolOverview
  Section = Data.define(
    :enabled, :health, :total, :counts, :items, :last_run_at,
    :truncated, :error
  )

  attr_reader :project

  def initialize(project)
    @project = project
    candidate = project["patrol_fix"]
    @projection = if Hive::PatrolFix::OperationalProjection.valid_document?(
      candidate, project: project.name
    )
      candidate
    end
  end

  def ordinary = section("ordinary")
  def architecture = section("architecture")

  private

  def section(engine)
    return unavailable_section unless @projection

    lane = @projection.dig("discovery", engine)
    return unavailable_section unless lane.is_a?(Hash)

    Section.new(
      enabled: lane.fetch("enabled"), health: lane.fetch("health"),
      total: lane.fetch("total"), counts: lane.fetch("counts"),
      items: lane.fetch("items"), last_run_at: lane["last_run_at"],
      truncated: lane.fetch("truncated"),
      error: lane.fetch("health") == "unavailable" ?
        "Patrol data is temporarily unavailable." : nil
    )
  end

  def unavailable_section
    Section.new(
      enabled: true, health: "unavailable", total: 0, counts: {}, items: [],
      last_run_at: nil, truncated: false,
      error: "Patrol data is temporarily unavailable."
    )
  end
end
