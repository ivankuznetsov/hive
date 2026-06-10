module ApplicationHelper
  NAV_SECTIONS = {
    status: ->(c) { c == "status" || c == "tasks" || c == "ideas" },
    repos: ->(c) { c == "repos" },
    agents: ->(c) { c == "agents" },
    telegram: ->(c) { c == "telegram" }
  }.freeze

  def nav_class(section)
    active = NAV_SECTIONS.fetch(section).call(controller_name)
    class_names("nav-link", "nav-link-active": active)
  end

  # Stage dir ("3-plan") → its short name and a stable color class used by
  # the badge styles (stage-1 … stage-9).
  def stage_badge(stage_dir)
    idx, name = stage_dir.to_s.split("-", 2)
    tag.span(name || stage_dir.to_s, class: "stage-badge stage-#{idx.to_i.clamp(1, 9)}")
  end

  # Liveness dot derived from the task row of Status#json_payload: a live
  # agent pulses green, an error marker is red, an actionable gate is amber.
  def status_dot(task)
    kind =
      if task["marker"] == "error" || task["action"].to_s.include?("error")
        "error"
      elsif task["claude_pid_alive"]
        "running"
      elsif task["action"].present?
        "waiting"
      else
        "idle"
      end
    tag.span("", class: "status-dot status-dot-#{kind}", title: task["action_label"].presence || "idle")
  end

  def registered_project_names
    Hive::Config.registered_projects.map { |p| p["name"] }
  end

  # Pipeline-generated display names arrive later in a task's life; until
  # then derive a readable title from the slug, dropping the date-hash
  # suffix ("add-dark-mode-260610-3c75" → "Add dark mode").
  def task_title(task)
    return task["display_name"] if task["display_name"].present? && task["display_name"] != task["slug"]

    task["slug"].to_s.sub(/-\d{6}-\h{4}\z/, "").tr("-", " ").upcase_first
  end

  def relative_age(seconds)
    s = seconds.to_i
    return "just now" if s < 60
    return "#{s / 60}m ago" if s < 3600
    return "#{s / 3600}h ago" if s < 86_400

    "#{s / 86_400}d ago"
  end
end
