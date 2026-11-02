require "test_helper"

class WikiGapsIndexTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  INDEX_PATH = File.join(ROOT, "wiki/gaps.md")

  def test_real_index_links_resolve_independently_of_the_working_directory
    Dir.chdir(File.dirname(ROOT)) do
      assert_empty index_errors(File.read(INDEX_PATH), index_path: INDEX_PATH)
    end
  end

  def test_nested_relative_destination_resolves
    with_index_fixture do |index_path, owner_path|
      File.write(owner_path, "## Known gaps\n\n### A gap\n")

      assert_empty index_errors(index_for("modules/owner.md#a-gap"), index_path: index_path)
    end
  end

  def test_missing_page_fails
    with_index_fixture do |index_path, _owner_path|
      errors = index_errors(index_for("modules/missing.md#a-gap"), index_path: index_path)

      assert_match(/missing page: modules\/missing.md/, errors.join("\n"))
    end
  end

  def test_missing_empty_and_incorrect_fragments_fail
    with_index_fixture do |index_path, owner_path|
      File.write(owner_path, "### A gap\n")

      [ "modules/owner.md", "modules/owner.md#" ].each do |target|
        assert_match(/missing fragment/, index_errors(index_for(target), index_path: index_path).join("\n"))
      end
      assert_match(/missing heading: wrong/, index_errors(index_for("modules/owner.md#wrong"), index_path: index_path).join("\n"))
    end
  end

  def test_malformed_entry_lines_cannot_evade_validation
    [
      "A prose summary.",
      "- [[modules/owner]]",
      "  - [Nested](modules/owner.md#a-gap)",
      "- [Title](modules/owner.md#a-gap) with a summary",
      "- [Title](modules/owner.md#a-gap",
      "### Nested heading",
      "```markdown"
    ].each do |line|
      assert_match(/malformed entry/, index_errors("## Unresolved gaps\n\n#{line}\n").join("\n"), line)
    end
    assert_match(/missing Unresolved gaps section/, index_errors("## Other section\n").join("\n"))
  end

  def test_known_github_anchors_are_literal_expectations
    assert_includes anchors(File.read(File.join(ROOT, "wiki/modules/events.md"))),
      "event-types-hiveeventsevent_types"
    assert_equal [ "event-types-hiveeventsevent_types" ],
      anchors("## Event types (`Hive::Events::EVENT_TYPES`)\n")
    assert_includes anchors(File.read(File.join(ROOT, "wiki/commands/web.md"))),
      "deprecated-native-web-hivebox_-aliases-2026-10-15"
    assert_equal [ "deprecated-native-web-hivebox_-aliases-2026-10-15" ],
      anchors("## Deprecated native-web `HIVEBOX_*` aliases (2026-10-15)\n")
    assert_equal [ "2026-06-1617-refresh-uncertainty" ],
      anchors("## 2026-06-16/17 refresh uncertainty\n")
  end

  def test_inline_markup_keeps_visible_heading_text
    assert_equal [ "read-this-and-literal_name-again" ],
      anchors("## [**Read** _this_](../topic.md) and `literal_name` ~~again~~!\n")
  end

  def test_duplicate_suffixes_skip_already_allocated_anchors
    assert_equal %w[topic-1 topic topic-2 topic-1-1 topic-3],
      anchors("# Topic-1\n## Topic\n### Topic\n## Topic-1\n# Topic\n")
  end

  def test_indexed_heading_must_have_a_unique_base_across_resolved_history
    with_index_fixture do |index_path, owner_path|
      File.write(owner_path, "## Known gaps\n### A gap\n### Resolved\n#### A gap\n")

      assert_match(/ambiguous heading/, index_errors(index_for("modules/owner.md#a-gap"), index_path: index_path).join("\n"))
      assert_match(/duplicate suffix/, index_errors(index_for("modules/owner.md#a-gap-1"), index_path: index_path).join("\n"))
    end
  end

  def test_yaml_and_fenced_heading_examples_are_ignored
    markdown = <<~MARKDOWN
      ---
      title: Example
      # YAML example
      ---
      ## Real
      ```markdown
      ### Backtick example
      ```
      ~~~~text
      ## Tilde example
      ```
      ~~~~
      ### End ###
    MARKDOWN
    assert_equal %w[real end], anchors(markdown)

    with_index_fixture do |index_path, owner_path|
      File.write(owner_path, markdown)

      assert_match(/missing heading: backtick-example/,
        index_errors(index_for("modules/owner.md#backtick-example"), index_path: index_path).join("\n"))
    end
  end

  private

  def index_for(target)
    "## Unresolved gaps\n\n- [A gap](#{target})\n"
  end

  def with_index_fixture
    Dir.mktmpdir("wiki-gaps-index") do |root|
      FileUtils.mkdir_p(File.join(root, "wiki/modules"))
      yield File.join(root, "wiki/gaps.md"), File.join(root, "wiki/modules/owner.md")
    end
  end

  # Deliberately bounded to the hand-authored index grammar. This checks links,
  # not the completeness, ownership, status, or bodies of gaps across the wiki.
  def index_errors(markdown, index_path: INDEX_PATH)
    lines = markdown.lines.drop_while { |line| line.chomp != "## Unresolved gaps" }
    return [ "missing Unresolved gaps section" ] if lines.empty?

    headings_by_page = {}
    lines.drop(1).take_while { |line| !line.start_with?("## ") }.filter_map do |line|
      next if line.strip.empty?

      entry = line.chomp.match(/\A- \[([^\[\]]+)\]\(([^()\s]+)\)\z/)
      next "malformed entry: #{line.chomp}" unless entry

      page, separator, fragment = entry[2].partition("#")
      next "missing fragment: #{entry[2]}" if separator.empty? || fragment.empty?
      next "malformed relative page: #{page}" unless page.match?(%r{\A(?!/)[^:\s]+\.md\z})

      path = File.expand_path(page, File.dirname(index_path))
      next "missing page: #{page}" unless File.file?(path)

      headings = headings_by_page[path] ||= heading_anchors(File.read(path))
      target = headings.find { |heading| heading[:anchor] == fragment }
      next "missing heading: #{fragment} in #{page}" unless target
      next "duplicate suffix: #{fragment} in #{page}" unless target[:base] == fragment
      next "ambiguous heading: #{fragment} in #{page}" unless headings.count { |heading| heading[:base] == fragment } == 1
    end
  end

  def anchors(markdown)
    heading_anchors(markdown).map { |heading| heading[:anchor] }
  end

  # GitHub's rendered heading anchors are normative. This small implementation
  # covers these pages' ATX headings, inline code/emphasis/links, and fences:
  # strip markup, lowercase, delete punctuation except hyphens/underscores,
  # replace spaces with hyphens, then allocate duplicate suffixes in page order.
  # https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#section-links
  def heading_anchors(markdown)
    used = {}
    fence = nil
    frontmatter = false
    markdown.lines.each_with_index.filter_map do |line, index|
      line = line.chomp
      if index.zero? && line == "---"
        frontmatter = true
        next
      end
      if frontmatter
        frontmatter = false if line == "---"
        next
      end

      delimiter = line.match(/\A {0,3}(`{3,}|~{3,})(.*)\z/)
      if fence
        fence = nil if delimiter && delimiter[1][0] == fence[0] && delimiter[1].length >= fence.length && delimiter[2].strip.empty?
        next
      end
      if delimiter
        fence = delimiter[1]
        next
      end

      heading = line.match(/\A {0,3}\#{1,6}[ \t]+(.+?)\s*\z/)
      next unless heading

      visible = heading[1].sub(/[ \t]+\#+[ \t]*\z/, "")
        .gsub(/!?\[([^\]]*)\]\([^)]*\)/, '\1')
      visible = visible.split(/(`+[^`]*`+)/).map do |part|
        if part.start_with?("`")
          part.delete("`")
        else
          part.gsub(/(\*{1,3}|_{1,3}|~~)(.*?)\1/, '\2')
        end
      end.join
      base = visible.downcase.gsub(/[^\p{Alnum}_ -]/, "").tr(" ", "-")
      anchor = base
      suffix = 0
      while used[anchor]
        suffix += 1
        anchor = "#{base}-#{suffix}"
      end
      used[anchor] = true
      { base: base, anchor: anchor }
    end
  end
end
