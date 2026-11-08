require "hive/web/status_feed"
require "hive/daemon/status_report"

# Enrich the existing saved status frame on its background poller. Keeping
# history, column definitions and the banner in that frame also reuses its
# semantic change token, reconnect catch-up and latest-good failure handling.
class StatusPageFeed < Hive::Web::StatusFeed
  def initialize(daemon_report: Hive::Daemon::StatusReport.new, **options)
    @daemon_report = daemon_report
    super(**options)
  end

  private

  def compute_snapshot(projects)
    payload = super
    previous = current_state&.payload || {}
    histories = payload.fetch("projects").each_with_object({}) do |attributes, out|
      name = attributes.fetch("name")
      history = previous.dig("project_archives", name)
      history = nil unless history && ProjectArchive.identity(history) == ProjectArchive.identity(attributes)
      history = refresh_history(attributes, history) if ProjectArchive.requested?(attributes)
      out[name] = history if history
    end
    display_projects = payload.fetch("projects").map do |attributes|
      Project.new(attributes).with_history(histories[attributes.fetch("name")])
    end

    payload.merge(
      "project_archives" => histories,
      "board_metadata" => board_metadata(display_projects, previous),
      "daemon_status" => daemon_snapshot
    )
  end

  def board_metadata(projects, previous)
    metadata = Board.new(projects).metadata
    previous_projects = previous.fetch("projects", []).index_by { |project| project["name"] }
    projects.each do |project|
      old_project = previous_projects[project.name]
      next unless old_project && ProjectArchive.identity(old_project) == ProjectArchive.identity(project.attributes)

      board = metadata.fetch(project.name)
      board.fetch("unavailable_workflows").each do |id|
        stages = previous.dig("board_metadata", project.name, "workflows", id)
        board.fetch("workflows")[id] = stages if stages
      end
    end
    metadata
  end

  def refresh_history(attributes, previous)
    history = ProjectArchive.snapshot(Project.new(attributes)).fetch("projects").first
    return previous unless history
    if history["error"]
      ProjectArchive.request(attributes)
      return previous ? previous.merge("error" => history["error"]) : history
    end

    ProjectArchive.refreshed(attributes)
    history
  rescue StandardError => e
    ProjectArchive.request(attributes)
    Rails.logger.warn("project history refresh failed for #{attributes['name']}: #{e.class}")
    (previous || attributes.merge("tasks" => [])).merge("error" => "completed_history_unavailable")
  end

  def daemon_snapshot
    state = @daemon_report.running_state
    identity = state.values_at(:running, :pid)
    if @daemon_checked_at.nil? || @clock.call >= @daemon_checked_at + 60 || identity != @daemon_identity
      @daemon_payload = @daemon_report.safe_payload.slice("running", "service_installed", "binary_drift")
      @daemon_checked_at = @clock.call
      @daemon_identity = identity
    end
    @daemon_payload
  rescue StandardError => e
    Rails.logger.warn("daemon status refresh failed: #{e.class}")
    {}
  end
end
