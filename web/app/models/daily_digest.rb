require "json"
require "hive/daily_digest/reader"
require "hive/pr"
require "hive/task_resolver"

# Thin Rails presentation adapter over Hive's pure persisted digest reader.
# It never materializes records or consults live GitHub. Privacy-sensitive
# attention rows are reduced to a closed allowlist before a template sees them.
class DailyDigest
  ATTENTION_KEYS = %w[
    attention_id kind project_id project task_id task_slug stage state
    waiting_since waiting_age_seconds
  ].freeze

  attr_reader :attributes, :requested_date

  def self.find(date:, project: nil, reader: Hive::DailyDigest::Reader.new,
                link_resolver: nil, current_projects: Hive::Config.registered_projects)
    selected_date = date.to_s == "today" ? nil : date
    view = reader.read(date: selected_date, project: project.presence)
    new(
      view, requested_date: date, link_resolver: link_resolver,
      current_projects: current_projects
    )
  end

  def initialize(attributes, requested_date:, link_resolver: nil, current_projects: [])
    @requested_date = requested_date.to_s
    @current_projects = Array(current_projects)
    @link_resolver = link_resolver || method(:resolve_task_destination)
    @destination_cache = {}
    @attributes = deep_copy(attributes)
    sanitize_attention!
  end

  def reader_status = attributes.fetch("reader_status", "ok")
  def ok? = reader_status == "ok"
  def missing? = reader_status == "missing"
  def pruned? = reader_status == "pruned"
  def stale? = attributes.fetch("stale", false) == true
  def local_date = attributes["local_date"] || requested_date.presence || "today"
  def lifecycle = missing? ? "missing" : attributes.fetch("lifecycle", reader_status)

  def completeness
    return "unknown" if missing? || pruned?

    attributes["view_completeness"] || attributes["effective_completeness"] ||
      attributes["completeness"] || "unknown"
  end

  def content
    return "unknown" if missing? || pruned?

    attributes["effective_content"] || attributes["content"] || "unknown"
  end

  def selected_project = attributes["selected_project"]
  def projects = Array(attributes["projects"])
  def attention = Array(attributes["attention"])
  def items = Array(attributes["items"])
  def gaps = Array(attributes["effective_gaps"] || attributes["gaps"])
  def amendments = Array(attributes["amendments"])
  def previous_date = attributes["previous_date"]
  def next_date = attributes["next_date"]

  def grouped_items
    order = projects.each_with_index.to_h { |project, index| [ project.fetch("project_id"), index ] }
    items.group_by { |item| item["project_id"] }
         .sort_by { |project_id, _| [ order.fetch(project_id, order.length), project_id.to_s ] }
         .map do |project_id, rows|
      [ project_for(project_id, rows.first && rows.first["project"]), rows ]
    end
  end

  def project_for(project_id, fallback_name = nil)
    projects.find { |project| project["project_id"] == project_id } ||
      { "project_id" => project_id, "name" => fallback_name.presence || "Historical project" }
  end

  def historical_project?(project)
    current_project_for(project).nil?
  end

  def task_destination(row)
    key = [ row["project_id"], row["task_slug"] ]
    return nil if key.last.to_s.empty?
    return @destination_cache[key] if @destination_cache.key?(key)

    project = project_for(row["project_id"], row["project"])
    @destination_cache[key] = @link_resolver.call(project, row)
  rescue Hive::Error, SystemCallError, IOError
    @destination_cache[key] = nil
  end

  def pr_url(row)
    value = row.dig("pr", "url")
    Hive::Pr.valid_http_url?(value) ? value : nil
  end

  def pr_number(row)
    row.dig("pr", "number") || Hive::Pr.number(pr_url(row))&.delete_prefix("#")
  end

  private

  def sanitize_attention!
    attributes["attention"] = Array(attributes["attention"]).map do |row|
      sanitized_attention(row)
    end
    attributes["amendments"] = Array(attributes["amendments"]).map do |amendment|
      amendment.merge(
        "attention" => Array(amendment["attention"]).map { |row| sanitized_attention(row) }
      )
    end
  end

  def sanitized_attention(row)
    row.slice(*ATTENTION_KEYS).merge("task_destination" => task_destination(row))
  end

  def current_project_for(project)
    @current_projects.find do |current|
      next false unless current["name"].to_s == project["name"].to_s
      next false if project["project_id"].present? &&
                    current["project_id"].to_s != project["project_id"].to_s
      next false if project["registration_id"].present? &&
                    current["registration_id"].to_s != project["registration_id"].to_s

      true
    end
  end

  def resolve_task_destination(project, row)
    current = current_project_for(project)
    return unless current

    task = Hive::TaskResolver.new(
      row.fetch("task_slug"), project_filter: current.fetch("name")
    ).resolve
    {
      project: current.fetch("name"),
      slug: task.slug,
      source: task.stage_index == 9 ? "archive" : nil
    }
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
