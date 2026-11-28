require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require_relative "../support/wiki_command_index"

class WikiCommandIndexTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WIKI_ROOT = File.expand_path("../../wiki", __dir__)

  FakeCommand = Struct.new(:usage, :hidden) do
    def hidden?
      hidden
    end
  end

  def test_guard_accepts_one_allowed_architecture_destination_with_authority_links
    documents = {
      "commands/stage_action" => "#{architecture_page("day-to-day-workflow")}\n## Related\n\n[[stages/review]]\n",
      "modules/plan_review" => architecture_page("hive-plan-review-target-show"),
      "modules/worktree" => architecture_page("hive-worktree")
    }
    result = fixture_guard(documents).evaluate(
      help_text: help_for("brainstorm", "plan-review", "worktree"),
      index_text: index_for(
        [ "brainstorm", "[[commands/stage_action]]" ],
        [ "plan-review", "[[modules/plan_review]]" ],
        [ "worktree", "[[modules/worktree]]" ]
      )
    )

    assert result.success?, result.diagnostics.map(&:to_s).join("\n")
    assert_equal documents.keys.sort, result.owner_documents.keys.sort
    assert_equal "commands/stage_action", result.owners.fetch("brainstorm")
    assert_equal "modules/plan_review", result.owners.fetch("plan-review")
    assert_equal "modules/worktree", result.owners.fetch("worktree")
  end

  def test_help_parser_ignores_wrapped_descriptions_and_terminal_banner_variants
    help = <<~HELP
      Commands:
        \e[32m./bin/hive\e[0m alpha TARGET  # first command
                                             wrapped description text
        ./bin/hive beta                     # second command

      Options:
        --help  # help
    HELP

    result = fixture_guard(
      "commands/alpha" => architecture_page,
      "commands/beta" => architecture_page
    ).evaluate(
      help_text: help,
      index_text: index_for(
        [ "alpha", "[[commands/alpha]]" ],
        [ "beta", "[[commands/beta]]" ]
      )
    )

    assert result.success?, result.diagnostics.map(&:to_s).join("\n")
    assert_equal %w[alpha beta], result.help_commands
  end

  def test_guard_reports_duplicate_and_ambiguous_destinations
    documents = {
      "commands/alpha" => architecture_page,
      "modules/alpha" => architecture_page
    }
    result = fixture_guard(documents).evaluate(
      help_text: help_for("alpha"),
      index_text: index_for(
        [ "alpha", "[[commands/alpha]]" ],
        [ "alpha", "[[modules/alpha]]" ]
      )
    )

    assert_diagnostic result, :duplicate_index_command, "alpha"
    assert_diagnostic result, :ambiguous_ownership, "alpha"
  end

  def test_guard_reports_duplicate_rendered_commands
    result = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha", "alpha"),
      index_text: index_for([ "alpha", "[[commands/alpha]]" ])
    )

    assert_diagnostic result, :duplicate_help_command, "alpha"
  end

  def test_guard_fails_closed_when_either_bounded_section_is_absent
    missing_help = fixture_guard.evaluate(
      help_text: "Usage: hive COMMAND\n",
      index_text: index_for
    )
    assert_diagnostic missing_help, :missing_help_commands_section

    missing_index = fixture_guard.evaluate(
      help_text: help_for,
      index_text: "# CLI\n\nSee [docs/cli.md](../docs/cli.md).\n"
    )
    assert_diagnostic missing_index, :missing_index_section
  end

  def test_guard_rejects_missing_multiple_and_decorated_owner_cells
    result = fixture_guard(
      "commands/alpha" => architecture_page,
      "commands/gamma" => architecture_page
    ).evaluate(
      help_text: help_for("alpha", "beta", "gamma"),
      index_text: index_for(
        [ "alpha", "owner pending" ],
        [ "beta", "[[commands/beta]] and [[modules/beta]]" ],
        [ "gamma", "Primary: [[commands/gamma]]" ]
      )
    )

    assert_diagnostic result, :missing_owner_link, "alpha"
    assert_diagnostic result, :multiple_owner_links, "beta"
    assert_diagnostic result, :malformed_owner_cell, "gamma"
  end

  def test_guard_rejects_missing_and_disallowed_destination_targets
    documents = { "stages/review" => architecture_page }
    result = fixture_guard(documents).evaluate(
      help_text: help_for("alpha", "review"),
      index_text: index_for(
        [ "alpha", "[[commands/does-not-exist]]" ],
        [ "review", "[[stages/review]]" ]
      )
    )

    assert_diagnostic result, :unresolved_owner_target, "alpha"
    assert_diagnostic result, :disallowed_owner_target, "review"
  end

  def test_guard_rejects_malformed_index_structure
    index = <<~MARKDOWN
      See [docs/cli.md](../docs/cli.md).

      ## Command index

      | Command | Owner | Notes |
      | --- | --- | --- |
      | alpha | [[commands/alpha]] |
      | `hive beta` | [[commands/beta]] | extra |
    MARKDOWN
    result = fixture_guard.evaluate(
      help_text: help_for("alpha", "beta"),
      index_text: index
    )

    assert_diagnostic result, :malformed_index_header
    assert_diagnostic result, :malformed_command_cell
    assert_diagnostic result, :malformed_index_row
  end

  def test_guard_rejects_separator_rows_that_are_not_exactly_two_columns
    [ "| --- |", "| --- | --- | --- |" ].each do |separator|
      index = index_for([ "alpha", "[[commands/alpha]]" ])
        .sub("| --- | --- |", separator)
      result = fixture_guard("commands/alpha" => architecture_page).evaluate(
        help_text: help_for("alpha"),
        index_text: index
      )

      assert_diagnostic result, :malformed_index_header
    end
  end

  def test_guard_requires_resolvable_authority_links_on_index_and_destination_pages
    no_index_link = index_for([ "alpha", "[[commands/alpha]]" ]).sub("[docs/cli.md](../docs/cli.md)", "docs")
    result = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha"),
      index_text: no_index_link
    )
    assert_diagnostic result, :missing_authority_link, "cli"

    no_dest_link = "# Alpha\n\nInternal controller notes only.\n"
    dest_result = fixture_guard("commands/alpha" => no_dest_link).evaluate(
      help_text: help_for("alpha"),
      index_text: index_for([ "alpha", "[[commands/alpha]]" ])
    )
    assert_diagnostic dest_result, :missing_authority_link, "commands/alpha"
  end

  def test_guard_rejects_broken_authority_link_path_and_anchor_on_disk
    Dir.mktmpdir("wiki-authority-links") do |root|
      docs_dir = File.join(root, "docs")
      wiki_dir = File.join(root, "wiki")
      FileUtils.mkdir_p(File.join(wiki_dir, "commands"))
      FileUtils.mkdir_p(docs_dir)
      File.write(File.join(docs_dir, "cli.md"), "# CLI\n\n### `hive alpha`\n")
      File.write(
        File.join(wiki_dir, "commands/alpha.md"),
        "# Alpha\n\nSee [docs/cli.md](../../docs/cli.md#nonexistent-anchor).\n"
      )
      guard = WikiCommandIndex::Guard.new(wiki_root: wiki_dir, expected_owners: nil)
      result = guard.evaluate(
        help_text: help_for("alpha"),
        index_text: index_for([ "alpha", "[[commands/alpha]]" ])
      )

      assert_diagnostic result, :broken_authority_anchor, "commands/alpha"
    end
  end

  def test_navigation_rejects_contract_tables_and_prose_outside_index_while_allowing_fences
    leaked_contracts = <<~MARKDOWN

      ## Schema versions

      | Schema | Version |
      |---|---:|
      | `hive-alpha.v1` | 1 |

      ## Alpha options

      - `hive alpha --force` emits `hive-alpha.v9`.
    MARKDOWN
    leaked = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha"),
      index_text: index_for([ "alpha", "[[commands/alpha]]" ]) + leaked_contracts
    )
    assert_diagnostic leaked, :command_contract_outside_index

    fenced_example = <<~MARKDOWN

      ## Markdown example

      ```markdown
      | Command | Synopsis |
      |---|---|
      | `hive alpha` | Runs alpha. |
      ```
    MARKDOWN
    fenced = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha"),
      index_text: index_for([ "alpha", "[[commands/alpha]]" ]) + fenced_example
    )
    refute fenced.diagnostics.any? { |diagnostic| diagnostic.kind == :command_contract_outside_index }
  end

  def test_markdown_parser_ignores_commented_and_indented_index_structure
    commented_index = "<!--\n#{index_for([ "alpha", "[[commands/alpha]]" ])}\n-->\n"
    result = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha"),
      index_text: commented_index
    )
    assert_diagnostic result, :missing_index_section

    indented_table = <<~MARKDOWN
      See [docs/cli.md](../docs/cli.md).

      ## Command index

          | Command | Owner |
          | --- | --- |
          | `hive alpha` | [[commands/alpha]] |
    MARKDOWN
    indented = fixture_guard("commands/alpha" => architecture_page).evaluate(
      help_text: help_for("alpha"),
      index_text: indented_table
    )
    assert_diagnostic indented, :missing_index_table
  end

  def test_guard_enforces_pinned_architecture_destinations
    wrong = WikiCommandIndex::Guard.new(
      owner_reader: ->(target) { architecture_page if %w[commands/review commands/stage_action].include?(target) }
    ).evaluate(
      help_text: help_for("review"),
      index_text: index_for([ "review", "[[commands/review]]" ])
    )
    assert_diagnostic wrong, :unexpected_owner, "review"

    missing_pin = WikiCommandIndex::Guard.new(
      owner_reader: ->(_target) { nil },
      expected_owners: { "review" => "commands/stage_action" }
    ).evaluate(help_text: help_for, index_text: index_for, validate_authority_links: false)
    assert_diagnostic missing_pin, :missing_pinned_owner, "review"
  end

  def test_metadata_partition_uses_declared_usage_and_explicit_maps
    commands = {
      "open_pr" => FakeCommand.new("open-pr TARGET", false),
      "visible" => FakeCommand.new("visible", false),
      "__internal" => FakeCommand.new("__internal", true),
      "version" => FakeCommand.new("version", false)
    }
    metadata = fixture_guard.metadata(
      all_commands: commands,
      command_map: {
        "open-pr" => "open_pr",
        "pr" => "open_pr",
        "--version" => "version"
      }
    )

    assert_empty metadata.diagnostics
    assert_equal %w[open-pr version visible], metadata.visible
    assert_equal [ "__internal" ], metadata.hidden
    assert_equal "open-pr", metadata.aliases.fetch("pr")
    assert_equal "version", metadata.aliases.fetch("--version")
    assert_equal "version", metadata.aliases.fetch("-v")
  end

  def test_metadata_map_mismatch_and_alias_collision_fail_closed
    mismatch = fixture_guard.metadata(
      all_commands: { "internal_name" => FakeCommand.new("public-name", false) },
      command_map: { "different-name" => "internal_name" }
    )
    assert_diagnostic mismatch, :metadata_map_mismatch, "internal_name"
    assert_empty mismatch.visible

    collision = fixture_guard.metadata(
      all_commands: {
        "open_pr" => FakeCommand.new("open-pr", false),
        "pr" => FakeCommand.new("pr", false)
      },
      command_map: {
        "open-pr" => "open_pr",
        "pr" => "open_pr"
      }
    )
    assert_diagnostic collision, :alias_canonical_collision, "pr"
  end

  def test_repeated_guard_evaluation_is_deterministic_and_read_only
    Dir.mktmpdir("wiki-command-index") do |root|
      docs_dir = File.join(root, "docs")
      wiki_dir = File.join(root, "wiki")
      FileUtils.mkdir_p(File.join(wiki_dir, "commands"))
      FileUtils.mkdir_p(docs_dir)
      File.write(File.join(docs_dir, "cli.md"), "# CLI\n\n### `hive alpha`\n")
      File.write(File.join(wiki_dir, "commands/alpha.md"), architecture_page("hive-alpha"))
      guard = WikiCommandIndex::Guard.new(wiki_root: wiki_dir, expected_owners: nil)
      help = help_for("alpha")
      index = index_for([ "alpha", "[[commands/alpha]]" ])
      before = tree_snapshot(root)

      first = guard.evaluate(help_text: help, index_text: index)
      second = guard.evaluate(help_text: help, index_text: index)

      assert first.success?, first.diagnostics.map(&:to_s).join("\n")
      assert_equal first, second
      assert_equal first.diagnostics.map(&:sort_key).sort, first.diagnostics.map(&:sort_key)
      assert_equal before, tree_snapshot(root)
    end
  end

  private

  def fixture_guard(documents = {})
    WikiCommandIndex::Guard.new(
      owner_reader: ->(target) { documents[target] },
      expected_owners: nil
    )
  end

  def help_for(*commands)
    rows = commands.map { |command| "  hive #{command}  # #{command}" }.join("\n")
    "Commands:\n#{rows}\n\nOptions:\n  --help  # help\n"
  end

  def index_for(*rows)
    body = rows.map { |command, owner| "| `hive #{command}` | #{owner} |" }.join("\n")
    <<~MARKDOWN
      > **Public CLI authority:** [docs/cli.md](../docs/cli.md).

      ## Command index

      | Command | Owner |
      | --- | --- |
      #{body}

      ## Backlinks
    MARKDOWN
  end

  def architecture_page(anchor = nil)
    link = anchor ? "../../docs/cli.md##{anchor}" : "../../docs/cli.md"
    <<~MARKDOWN
      # Architecture

      > **Public CLI authority:** See [docs/cli.md](#{link}).

      Internal controller and storage notes.
    MARKDOWN
  end

  def assert_diagnostic(result, kind, subject = nil)
    match = result.diagnostics.any? do |diagnostic|
      diagnostic.kind == kind && (subject.nil? || diagnostic.subject == subject)
    end
    assert match, "expected #{kind}: #{subject}; got #{result.diagnostics.map(&:to_s)}"
  end

  def tree_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
      next if File.directory?(path)

      stat = File.stat(path)
      [ path.delete_prefix("#{root}/"), stat.size, stat.mtime.to_r, Digest::SHA256.file(path).hexdigest ]
    end.sort
  end
end
