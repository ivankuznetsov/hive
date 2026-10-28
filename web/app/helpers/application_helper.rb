require "digest"
require "time"

module ApplicationHelper
  NAV_SECTIONS = {
    status: ->(c) { c == "status" || c == "tasks" || c == "ideas" },
    digests: ->(c) { c == "digests" },
    projects: ->(c) { c == "repos" },
    honeycombs: ->(c) { %w[workflows modules].include?(c) },
    patrol: ->(c) { c == "patrol" },
    agents: ->(c) { c == "agents" },
    integrations: ->(c) { c == "telegram" }
  }.freeze

  def nav_class(section)
    active = NAV_SECTIONS.fetch(section).call(controller_path.split("/", 2).first)
    class_names("nav-link", "nav-link-active": active)
  end

  def digest_task_path(destination, anchor: nil)
    options = {}
    options[:source] = destination.fetch(:source) if destination[:source]
    options[:anchor] = anchor if anchor
    task_path(destination.fetch(:project), destination.fetch(:slug), **options)
  end

  def digest_time_tag(value)
    timestamp = value.is_a?(String) ? Time.iso8601(value) : value
    time_tag(timestamp)
  rescue ArgumentError, TypeError
    tag.span("Time unavailable", class: "digest-meta")
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
  def status_dot(task, fresh: true, archived: false)
    display = TaskDisplay.new(task, fresh: fresh, archived: archived)
    kind = { "running" => "running", "attention" => "error", "waiting" => "waiting",
             "ready" => "waiting", "completed" => "idle", "unknown" => "idle", "paused" => "idle" }.fetch(display.state)
    tag.span("", class: "status-dot status-dot-#{kind}", title: display.label)
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
  def render_markdown(text, task: @task)
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: true,
                                  link_attributes: { rel: "noopener noreferrer", target: "_blank" }),
      fenced_code_blocks: true, tables: true, autolink: true,
      strikethrough: true, no_intra_emphasis: true, lax_spacing: true
    )
    body = text.to_s.sub(/\A---\n.*?\n---\n/m, "")
    body = body.gsub(/^[ \t]*#{Hive::Markers::MARKER_RE}[ \t]*(?:\r?\n|\z)/, "")
    html = sanitize(renderer.render(body), tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRS)
    fragment = Nokogiri::HTML.fragment(html)
    fragment.css("h1, h2, h3, h4, h5, h6").each do |heading|
      heading["hidden"] = "hidden" if empty_implementation_heading?(heading)
      task_heading_label(heading, task)
    end
    fragment.to_html.html_safe
  end

  # Primary work products add navigation after the existing renderer has
  # escaped and sanitized the agent-authored Markdown. IDs are derived only
  # from sanitized heading text, and duplicate headings receive a stable
  # ordinal suffix. Four H2 sections is the point where an outline earns its
  # place; short documents still get linkable headings without extra chrome.
  def render_markdown_document(text, task: @task)
    fragment = Nokogiri::HTML.fragment(render_markdown(text, task: nil))
    occurrences = Hash.new(0)
    outline = []

    fragment.css("h1, h2, h3, h4, h5, h6").each do |heading|
      base = heading.text.to_s.parameterize.presence || "section"
      occurrences[base] += 1
      anchor = occurrences[base] == 1 ? base : "#{base}-#{occurrences[base]}"
      heading["id"] = anchor
      task_heading_label(heading, task)
      if heading["hidden"] || repeats_task_title?(heading, task)
        heading["hidden"] = "hidden"
        next
      end
      outline << { id: anchor, label: heading.text.to_s.strip } if heading.name == "h2"
    end

    {
      html: fragment.to_html.html_safe,
      empty: fragment.element_children.none? { |node| node["hidden"].nil? && node.text.strip.present? },
      outline: outline.length >= 4 ? outline.freeze : [].freeze
    }.freeze
  end

  # execute writes a bare "## Implementation" stub into task.md before any
  # output exists. Hide it in the rendered view only; the source file stays
  # byte-for-byte as captured.
  def empty_implementation_heading?(heading)
    following = heading.next_element
    heading.name == "h2" && heading.text.strip == "Implementation" &&
      (following.nil? || following.name.in?(%w[h1 h2]))
  end

  # Stage files open with "# <slug>"; once relabelled it only repeats the
  # page title directly above the panel.
  def repeats_task_title?(heading, task)
    heading.name == "h1" && task&.title.present? &&
      heading.text.strip.in?([ task.title, task.slug ].compact)
  end

  ARTIFACT_LABELS = {
    "idea.md" => "Request", "brainstorm.md" => "Questions and decisions",
    "plan.md" => "Plan", "task.md" => "Implementation", "pr.md" => "Pull request",
    "artifact.md" => "Evidence", "summary.md" => "Summary"
  }.freeze

  # Stage files have generic names (task.md); readers want what the document is.
  def artifact_label(record)
    name = record.to_h["name"].to_s
    ARTIFACT_LABELS.fetch(name) do
      if record.to_h["reference"].to_s.include?("reviews/") || name.include?("review")
        "Review"
      else
        name.presence || "Work product"
      end
    end
  end

  # Publication evidence stores repositories as "host/owner/name"
  # (github.com/acme/demo, or a GitHub Enterprise host). Tolerate URL and
  # .git spellings, but link only a well-formed owner/name.
  def repository_web_url(repository)
    value = repository.to_s.strip.sub(%r{\Ahttps?://}i, "").sub(/\.git\z/i, "").delete_suffix("/")
    value = value.sub(/\Agit@([^:]+):/i, '\1/')
    value = "github.com/#{value}" if value.count("/") == 1
    host, owner, name = value.split("/", 3)
    return unless host.to_s.match?(/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d+)?\z/i) &&
                  "#{owner}/#{name}".match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}) &&
                  [ owner, name ].none? { |part| part.match?(/\A\.+\z/) }

    "https://#{host.downcase}/#{owner}/#{name}"
  end

  def repository_ref_url(repository_url, kind, ref)
    "#{repository_url}/#{kind}/#{ref.to_s.split("/").map { |part| ERB::Util.url_encode(part) }.join("/")}"
  end

  def task_heading_label(heading, task)
    return unless task && task.slug.present? && task.title.present? && task.title != task.slug

    slug = /(?<![[:alnum:]_-])#{Regexp.escape(task.slug)}(?![[:alnum:]_-])/
    heading.traverse do |node|
      node.content = node.content.gsub(slug) { task.title } if node.text?
    end
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
