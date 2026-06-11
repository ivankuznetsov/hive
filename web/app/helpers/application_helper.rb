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
  # then prefer the operator's ORIGINAL idea text (idea.md front matter) —
  # a de-slugged title truncates mid-phrase ("Add dark mode toggle to").
  # The slug stays the fallback of last resort.
  def task_title(task)
    return task["display_name"] if task["display_name"].present? && task["display_name"] != task["slug"]

    original_idea_line(task) ||
      task["slug"].to_s.sub(/-\d{6}-\h{4}\z/, "").tr("-", " ").upcase_first
  end

  def original_idea_line(task)
    folder = task["folder"]
    return nil unless folder

    path = File.join(folder, "idea.md")
    return nil unless File.file?(path)

    front = File.read(path, 4096).to_s[/\A---\n(.*?)\n---/m, 1]
    return nil unless front

    # permitted_classes: the front matter's unquoted created_at parses as a
    # Time, which plain safe_load rejects wholesale.
    text = YAML.safe_load(front, permitted_classes: [ Time, Date ])&.dig("original_text").to_s
    line = text.gsub(/\[image\d+\]/, "").strip.lines.first.to_s.strip
    line.presence&.truncate(90)
  rescue StandardError
    nil
  end

  # The dispatcher speaks action keys (ready_to_brainstorm…) that map to
  # stage verbs. "Run stage" means "run THIS task's current stage", so the
  # key derives from the stage dir; 1-inbox advances into brainstorm and
  # 9-done has nothing to run.
  STAGE_DISPATCH_ACTIONS = {
    "1" => "ready_to_brainstorm",
    "2" => "ready_to_brainstorm",
    "3" => "ready_to_plan",
    "4" => "ready_to_develop",
    "5" => "ready_to_open_pr",
    "6" => "ready_for_review",
    "7" => "ready_to_artifacts",
    "8" => "ready_to_finalize"
  }.freeze

  def stage_dispatch_action(stage_dir)
    STAGE_DISPATCH_ACTIONS[stage_dir.to_s.split("-", 2).first]
  end

  # "ready_to_open_pr" → "open-pr": the hive verb the dispatch will run,
  # shown on the button so the operator knows exactly what they trigger.
  def stage_run_verb(stage_dir)
    stage_dispatch_action(stage_dir)&.sub(/\Aready_(?:to|for)_/, "")&.tr("_", "-")
  end

  # Color the JSONL log tail by event class so errors jump out of the noise.
  def log_line_class(line)
    if /"type"\s*:\s*"(error|turn\.failed)"|"error"\s*:/.match?(line)
      "log-error"
    elsif /"type"\s*:\s*"(thread|turn)\./.match?(line)
      "log-meta"
    else
      ""
    end
  end

  def relative_age(seconds)
    s = seconds.to_i
    return "just now" if s < 60
    return "#{s / 60}m ago" if s < 3600
    return "#{s / 3600}h ago" if s < 86_400

    "#{s / 86_400}d ago"
  end
end
