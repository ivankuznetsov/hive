require "digest"

module ApplicationHelper
  NAV_SECTIONS = {
    status: ->(c) { c == "status" || c == "tasks" || c == "ideas" },
    repos: ->(c) { c == "repos" },
    workflows: ->(c) { c == "workflows" },
    agents: ->(c) { c == "agents" },
    telegram: ->(c) { c == "telegram" }
  }.freeze

  def nav_class(section)
    active = NAV_SECTIONS.fetch(section).call(controller_path.split("/", 2).first)
    class_names("nav-link", "nav-link-active": active)
  end

  # Turbo morphs by DOM identity. Use a digest of the full raw tuple so
  # project/workflow names that normalize to the same text cannot collide.
  def stable_dom_id(prefix, *parts)
    digest = Digest::SHA256.hexdigest(JSON.generate(parts.map(&:to_s))).first(24)
    "#{prefix}-#{digest}"
  end

  # Hive owns the status subscription lifecycle because an accepted channel
  # also owns the shared fleet poller. turbo-rails 2.0.23 can finish its async
  # subscription after its element has disconnected; this app-owned source
  # closes that race while retaining Turbo's signed stream-name contract.
  def status_stream_source(**attributes)
    attributes[:channel] = StatusChannel.to_s
    attributes[:"signed-stream-name"] =
      Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    tag.hive_status_stream_source(**attributes)
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

  def hidden_archive_summary(count)
    noun = count == 1 ? "task" : "tasks"
    "… and #{count} older archived #{noun} (hive archive to view)"
  end
end
