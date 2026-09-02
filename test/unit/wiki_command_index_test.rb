require "test_helper"

# Semantic preservation checks for the command-owner migration. The index
# parser/completeness cases are added after wiki/cli.md becomes navigation-only;
# these assertions land first so trimming the aggregate cannot erase the known
# fragile contracts.
class WikiCommandIndexTest < Minitest::Test
  WIKI_ROOT = File.expand_path("../../wiki", __dir__)

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
end
