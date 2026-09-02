require "test_helper"
require_relative "../support/wiki_command_index"

# Semantic preservation checks for the command-owner migration. The index
# parser/completeness cases are added after wiki/cli.md becomes navigation-only;
# these assertions land first so trimming the aggregate cannot erase the known
# fragile contracts.
class WikiCommandIndexTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WIKI_ROOT = File.expand_path("../../wiki", __dir__)

  FakeCommand = Struct.new(:usage, :hidden) do
    def hidden?
      hidden
    end
  end

  def test_guard_accepts_one_allowed_owner_per_help_command
    documents = {
      "commands/stage_action" => "#{complete_owner}\n## Related\n\n[[stages/review]]\n",
      "modules/plan_review" => complete_owner,
      "modules/worktree" => complete_owner
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
      "commands/alpha" => complete_owner,
      "commands/beta" => complete_owner
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

  def test_guard_reports_missing_and_stale_commands_independently
    result = fixture_guard(
      "commands/alpha" => complete_owner,
      "commands/stale" => complete_owner
    ).evaluate(
      help_text: help_for("alpha", "missing"),
      index_text: index_for(
        [ "alpha", "[[commands/alpha]]" ],
        [ "stale", "[[commands/stale]]" ]
      )
    )

    assert_diagnostic result, :missing_index_command, "missing"
    assert_diagnostic result, :stale_index_command, "stale"
  end

  def test_guard_reports_duplicate_and_ambiguous_ownership
    documents = {
      "commands/alpha" => complete_owner,
      "modules/alpha" => complete_owner
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
    result = fixture_guard("commands/alpha" => complete_owner).evaluate(
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
      index_text: "# CLI\n\nNo command table.\n"
    )
    assert_diagnostic missing_index, :missing_index_section
  end

  def test_guard_rejects_missing_multiple_and_decorated_owner_cells
    result = fixture_guard(
      "commands/alpha" => complete_owner,
      "commands/gamma" => complete_owner
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

  def test_guard_rejects_missing_and_disallowed_owner_targets
    documents = { "stages/review" => complete_owner }
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

  def test_every_contract_section_is_required_and_explicit_not_applicable_is_valid
    sections = {
      "Usage" => :syntax,
      "Options" => :options,
      "Behavior" => :behavior,
      "Examples" => :examples,
      "Output and schema" => :schema,
      "Output exceptions" => :output_exceptions,
      "Serialization fallback" => :serialization_fallback,
      "Exit codes" => :exit_codes
    }

    sections.each do |heading, requirement|
      incomplete = remove_section(complete_owner, heading)
      result = fixture_guard("commands/alpha" => incomplete).evaluate(
        help_text: help_for("alpha"),
        index_text: index_for([ "alpha", "[[commands/alpha]]" ])
      )

      assert result.diagnostics.any? { |diagnostic|
        diagnostic.kind == :incomplete_owner_contract &&
          diagnostic.subject == "commands/alpha" && diagnostic.detail == requirement
      }, "removing #{heading.inspect} did not fail #{requirement}: #{result.diagnostics.map(&:to_s)}"
    end

    valid = fixture_guard("commands/alpha" => complete_owner).evaluate(
      help_text: help_for("alpha"),
      index_text: index_for([ "alpha", "[[commands/alpha]]" ])
    )
    assert valid.success?, valid.diagnostics.map(&:to_s).join("\n")
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

  def test_metadata_map_mismatch_fails_closed
    metadata = fixture_guard.metadata(
      all_commands: { "internal_name" => FakeCommand.new("public-name", false) },
      command_map: { "different-name" => "internal_name" }
    )

    assert_diagnostic metadata, :metadata_map_mismatch, "internal_name"
    assert_empty metadata.visible
  end

  def test_repeated_guard_evaluation_is_deterministic_and_read_only
    Dir.mktmpdir("wiki-command-index") do |root|
      owner_dir = File.join(root, "commands")
      FileUtils.mkdir_p(owner_dir)
      File.write(File.join(owner_dir, "alpha.md"), complete_owner)
      guard = WikiCommandIndex::Guard.new(wiki_root: root)
      help = help_for("alpha", "missing")
      index = index_for([ "alpha", "[[commands/alpha]]" ])
      before = tree_snapshot(root)

      first = guard.evaluate(help_text: help, index_text: index)
      second = guard.evaluate(help_text: help, index_text: index)

      assert_equal first, second
      assert_equal first.diagnostics.map(&:sort_key).sort, first.diagnostics.map(&:sort_key)
      assert_equal before, tree_snapshot(root)
    end
  end

  def page(relative)
    File.read(File.join(WIKI_ROOT, relative))
  end

  def test_web_status_schema_sentence_is_contiguous
    assert_includes page("commands/web.md"),
      "`hive web status --json`\nemits `hive-web-status.v1`; `hive web install --json` emits\n" \
      "`hive-web-install.v1`."
  end

  def test_daemon_documents_every_public_json_schema_as_v1
    daemon = page("commands/daemon.md")
    %w[status stop reload install enroll queue].each do |suffix|
      assert_includes daemon, "`hive-daemon-#{suffix}.v1`", suffix
    end
  end

  def test_daemon_exit_table_covers_every_subcommand_family
    daemon = page("commands/daemon.md")
    %w[start stop status reload tail install enable disable queue].each do |subcommand|
      assert_match(/^\| `#{Regexp.escape(subcommand)}(?:`|[^|]*`)/, daemon, subcommand)
    end
  end

  def test_metrics_and_act_document_their_asymmetric_serialization_policies
    metrics = page("commands/metrics.md")
    assert_includes metrics, "intentionally omit\n`error_class`"
    assert_includes metrics, "metrics suppresses that serialization failure"
    assert_includes metrics, "original typed command error"

    status = page("commands/status.md")
    assert_includes status, "that generator exception is raised rather than\nsuppressed"
    assert_includes status, "no fallback JSON document is emitted"
  end

  def test_refactor_patrol_documents_bounded_immutable_pagination
    patrol = page("commands/refactor-patrol.md")
    assert_includes patrol, "default to 100 records"
    assert_includes patrol, "cursor freezes the intake-sequence high-water mark"
    assert_includes patrol, "hive-refactor-patrol-jobs.v2"
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
      ## Command index

      | Command | Owner |
      | --- | --- |
      #{body}

      ## Shared conventions
    MARKDOWN
  end

  def complete_owner
    <<~MARKDOWN
      # Alpha

      ## Usage

      `hive alpha`

      ## Options

      Options: not applicable.

      ## Behavior

      Reads state without mutation.

      ## Output and schema

      Schema: not applicable; output is text-only.

      ## Output exceptions

      Failures are reported on stderr.

      ## Serialization fallback

      Serialization fallback: not applicable.

      ## Exit codes

      Exit code `0` denotes completion; exit code `1` denotes non-completion.

      ## Examples

      The usage form above is the complete example.
    MARKDOWN
  end

  def remove_section(document, heading)
    document.sub(/^## #{Regexp.escape(heading)}\n.*?(?=^## |\z)/m, "")
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
