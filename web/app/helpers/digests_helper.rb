module DigestsHelper
  # Decorate only sanitized Markdown; retain the portable title in saved prose.
  def render_digest_document(digest)
    fragment = Nokogiri::HTML.fragment(render_markdown(digest.document))
    first = fragment.element_children.first
    first.remove if first&.name == "h1"
    stats = Array(digest.attributes["repository_stats"])
    identities = digest.projects.filter_map { |project| project["repository_identity"]&.delete_prefix("github.com/") }
    repositories = (identities + stats.map { |row| row["name"] }).uniq
    fragment.css("h2").each do |heading|
      section_links = []
      sibling = heading.next_element
      while sibling && sibling.name != "h2"
        section_links.concat(sibling.css("a").map { |link| link["href"].to_s })
        sibling = sibling.next_element
      end
      linked = repositories.select { |slug| section_links.any? { |url| url.start_with?("https://github.com/#{slug}/pull/") } }
      repository = (linked.one? && linked.first) || repositories.find do |slug|
        [ slug, slug.split("/").last ].any? { |name| name.casecmp?(heading.text.strip) }
      end
      next unless repository&.match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z})

      heading.inner_html = link_to(safe_join([ heading.text, digest_project_icon ]),
        "https://github.com/#{repository}", class: "digest-project-link", target: "_blank", rel: "noopener noreferrer")
      if (totals = stats.find { |row| row["name"] == repository })
        heading.add_next_sibling(tag.p(digest_stats_text(totals), class: "digest-project-stats",
          title: "Changes and commits in pull requests merged during this digest’s day"))
      end
    end
    fragment.to_html.html_safe
  end

  def digest_stats_text(stats)
    additions, deletions, commits = stats.values_at("additions", "deletions", "commits")
    lines = if additions.is_a?(Integer) && deletions.is_a?(Integer)
      "#{number_with_delimiter(additions + deletions)} LOC changed (+#{number_with_delimiter(additions)} / −#{number_with_delimiter(deletions)})"
    else
      "LOC unavailable"
    end
    count = commits.is_a?(Integer) ? "#{number_with_delimiter(commits)} #{'commit'.pluralize(commits)} in merged PRs" : "Commit count unavailable"
    "#{pluralize(stats.fetch('pull_requests'), 'PR')} merged · #{count} · #{lines}"
  end

  def digest_project_icon
    tag.svg(viewBox: "0 0 24 24", width: 16, height: 16, fill: "none", stroke: "currentColor",
            "stroke-width": 1.75, "aria-hidden": true, focusable: false) do
      safe_join([ tag.path(d: "M14 3h7v7M21 3 10 14"),
        tag.path(d: "M10 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5") ])
    end
  end
end
