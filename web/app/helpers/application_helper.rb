module ApplicationHelper
  NAV_SECTIONS = {
    board: ->(c) { c == "board" || c == "tasks" || c == "ideas" },
    grid: ->(c) { c == "status" },
    repos: ->(c) { c == "repos" },
    agents: ->(c) { c == "agents" },
    telegram: ->(c) { c == "telegram" },
    settings: ->(c) { c == "settings" }
  }.freeze

  def nav_class(section)
    active = if controller_name == "home" && %i[board grid].include?(section)
      section.to_s == default_work_view
    else
      NAV_SECTIONS.fetch(section).call(controller_name)
    end
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

  def dom_id_for(*parts)
    parts.join("_").parameterize(separator: "_")
  end

  def grouped_board_tasks(tasks, group, project_name)
    grouped = case group
    when "agent"
      tasks.group_by do |task|
        task.dig("implementation_identity", "stages", "execute", "provider").presence || "Unassigned"
      end
    when "dependency"
      tasks.group_by { |task| task["blocked_by"].presence || task["depends_on"].presence || "No dependency" }
    when "project"
      { project_name => tasks }
    else
      { "all" => tasks }
    end
    grouped.sort.to_h
  end

  MARKDOWN_TAGS = %w[
    h1 h2 h3 h4 h5 h6 p a ul ol li blockquote pre code em strong del hr br img
    table thead tbody tr th td
  ].freeze
  MARKDOWN_ATTRS = %w[href src alt title rel target].freeze

  # Agent-written .md artifacts render as real markdown (GFM tables, fenced
  # code). Two safety layers for LLM-authored content: escape_html turns raw
  # HTML in the source into visible text (nothing executes), and sanitize
  # strips whatever survives (e.g. javascript: link protocols). Two kinds of
  # machinery are dropped from the rendered view — escape_html would
  # otherwise print both as literal text: leading YAML front matter, and
  # STAGE MARKERS (matched by the gem's own MARKER_RE, not a blanket
  # comment regex — an artifact whose fenced code sample documents
  # "<!-- COMPLETE -->" keeps it; only real marker lines vanish, since the
  # stage badge owns that state). A fresh renderer per call: Redcarpet
  # instances are not thread-safe under Puma.
  def render_markdown(text)
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: true,
                                  link_attributes: { rel: "noopener noreferrer", target: "_blank" }),
      fenced_code_blocks: true, tables: true, autolink: true,
      strikethrough: true, no_intra_emphasis: true, lax_spacing: true
    )
    body = text.to_s.sub(/\A---\n.*?\n---\n/m, "")
    body = body.gsub(/^[ \t]*#{Hive::Markers::MARKER_RE}[ \t]*(?:\r?\n|\z)/, "")
    sanitize(renderer.render(body), tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRS)
  end

  # Mirrors Hive::TaskAction#diagnostic_action? — the three red states the
  # TUI renders under its [Enter] Recover contract.
  def recovery_action?(row)
    %w[recover_execute recover_review error].include?(row["action"].to_s)
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
    text = original_idea_text(task).to_s.gsub(/\[image\d+\]/, "")
    line = text.strip.lines.first.to_s.strip
    line.presence&.truncate(90)
  end

  # The operator's full original idea from idea.md's front matter — shown
  # above the brainstorm questionnaire so answers are written with the
  # source request in view.
  def original_idea_text(task)
    folder = task["folder"]
    return nil unless folder

    path = File.join(folder, "idea.md")
    return nil unless File.file?(path)

    front = File.read(path, 8192).to_s[/\A---\n(.*?)\n---/m, 1]
    return nil unless front

    # permitted_classes: the front matter's unquoted created_at parses as a
    # Time, which plain safe_load rejects wholesale.
    YAML.safe_load(front, permitted_classes: [ Time, Date ])&.dig("original_text").to_s.strip.presence
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

  # Derived from the gem so the promise of exactness is enforced, not
  # asserted: the Approve button renders only when Commands::Approve would
  # actually accept the forward move.
  PASSABLE_MARKERS = Hive::Commands::Approve::VALID_TERMINAL_MARKERS.map(&:to_s).freeze

  def stage_passable?(task)
    PASSABLE_MARKERS.include?(task["marker"].to_s)
  end

  # STAGE_DISPATCH_ACTIONS maps coding stage indexes to coding verbs, so it is
  # gated on the coding workflow: a non-coding row (e.g. content `2-research`)
  # would otherwise queue `hive brainstorm` for a stage that has no such verb.
  # Generic-workflow rows take the dispatcher's single manual path —
  # `ready_to_run` → `hive run --stage` — and only when the row is actually
  # runnable (`ready_to_advance` rows use the Approve button instead).
  def stage_dispatch_action(task)
    unless Hive::Workflows.coding_id?(task["workflow"])
      return task["action"].to_s == "ready_to_run" ? "ready_to_run" : nil
    end

    STAGE_DISPATCH_ACTIONS[task["stage"].to_s.split("-", 2).first]
  end

  # "ready_to_open_pr" → "open-pr": the hive verb the dispatch will run, shown
  # on the button so the operator knows exactly what they trigger. A generic
  # `ready_to_run` row runs the stage agent, labelled "stage".
  def stage_run_verb(task)
    action = stage_dispatch_action(task)
    return nil unless action
    return "stage" if action == "ready_to_run"

    action.sub(/\Aready_(?:to|for)_/, "").tr("_", "-")
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
