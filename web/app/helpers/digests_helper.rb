module DigestsHelper
  # Mermaid fences are lifted out before Markdown rendering because the
  # sanitizer drops the fence language; each returns as an escaped <pre>.
  MERMAID_FENCE = /^```mermaid[ \t]*\r?\n(.*?)^```[ \t]*$/m
  DIAGRAM_PLACEHOLDER = /\AHIVEDIGESTDIAGRAM(\d+)\z/
  # Cross-project sections the writer is asked for; never repository headings.
  BRIEF_HEADING = /\Athe day in brief\z/i
  NEEDS_YOU_HEADING = /\Aneeds you\z/i

  # Decorate only sanitized Markdown; retain the portable title in saved prose.
  def render_digest_document(digest)
    diagrams = []
    source = digest.document.gsub(MERMAID_FENCE) do
      diagrams << Regexp.last_match(1)
      "\nHIVEDIGESTDIAGRAM#{diagrams.length - 1}\n"
    end
    fragment = Nokogiri::HTML.fragment(render_markdown(source))
    restore_digest_diagrams(fragment, diagrams)
    first = fragment.element_children.first
    first.remove if first&.name == "h1"
    stats = Array(digest.attributes["repository_stats"])
    identities = digest.projects.filter_map { |project| project["repository_identity"]&.delete_prefix("github.com/") }
    repositories = (identities + stats.map { |row| row["name"] }).uniq
    decorated = Set.new
    fragment.css("h2").each do |heading|
      title = heading.text.strip
      if title.match?(NEEDS_YOU_HEADING)
        heading.add_class("digest-needs-you")
        heading.next_element&.add_class("digest-needs-you-list")
      end
      next if title.match?(BRIEF_HEADING) || title.match?(NEEDS_YOU_HEADING)

      section_links = []
      sibling = heading.next_element
      while sibling && sibling.name != "h2"
        section_links.concat(sibling.css("a").map { |link| link["href"].to_s })
        sibling = sibling.next_element
      end
      linked = repositories.select { |slug| section_links.any? { |url| url.start_with?("https://github.com/#{slug}/pull/") } }
      repository = (linked.one? && linked.first) || repositories.find do |slug|
        [ slug, slug.split("/").last ].any? { |name| name.casecmp?(title) }
      end
      next unless repository&.match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z})

      heading.inner_html = link_to(safe_join([ heading.text, digest_project_icon ]),
        "https://github.com/#{repository}", class: "digest-project-link", target: "_blank", rel: "noopener noreferrer")
      # A writer may split one repository across sections; its day totals
      # belong under the first one only.
      if decorated.add?(repository) && (totals = stats.find { |row| row["name"] == repository })
        heading.add_next_sibling(tag.p(digest_stats_text(totals), class: "digest-project-stats",
          title: "Changes and commits in pull requests merged during this digest’s day"))
      end
    end
    fragment.to_html.html_safe
  end

  # Diagram source stays escaped text inside <pre>; the mermaid controller
  # renders it client-side in strict mode, and the text remains the fallback.
  def restore_digest_diagrams(fragment, diagrams)
    fragment.css("p").each do |paragraph|
      index = paragraph.text.strip[DIAGRAM_PLACEHOLDER, 1]
      next unless index && (diagram = diagrams[index.to_i])

      paragraph.replace(tag.figure(class: "digest-diagram",
                                   data: { controller: "mermaid", mermaid_src_value: asset_path("mermaid.min.js") }) do
        tag.pre(diagram.strip, class: "digest-diagram-source", data: { mermaid_target: "source" })
      end.to_s)
    end
  end

  def digest_stats_text(stats)
    additions, deletions, commits = stats.values_at("additions", "deletions", "commits")
    lines = if additions.is_a?(Integer) && deletions.is_a?(Integer)
      safe_join([
        "#{number_with_delimiter(additions + deletions)} LOC changed (",
        tag.span("+#{number_with_delimiter(additions)}", class: "digest-loc-added"), " / ",
        tag.span("−#{number_with_delimiter(deletions)}", class: "digest-loc-deleted"), ")"
      ])
    else
      "LOC unavailable"
    end
    count = commits.is_a?(Integer) ? "#{number_with_delimiter(commits)} #{'commit'.pluralize(commits)} in merged PRs" : "Commit count unavailable"
    safe_join([ "#{pluralize(stats.fetch('pull_requests'), 'PR')} merged · #{count} · ", lines ])
  end

  def digest_project_icon
    tag.svg(viewBox: "0 0 24 24", width: 16, height: 16, fill: "none", stroke: "currentColor",
            "stroke-width": 1.75, "aria-hidden": true, focusable: false) do
      safe_join([ tag.path(d: "M14 3h7v7M21 3 10 14"),
        tag.path(d: "M10 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5") ])
    end
  end
end
