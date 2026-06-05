require "test_helper"
require "hive/cli"
require "hive/commands/wiki"

class WikiCommandTest < Minitest::Test
  include HiveTestHelper

  def test_compile_log_command_writes_generated_log
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n")
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")

      out, _err = capture_io { Hive::Commands::Wiki.new("compile-log", dir).call }

      assert_includes out, "compiled wiki/log.md from 1 fragment"
      assert_includes File.read(File.join(dir, "wiki", "log.md")), "## [2026-06-05T10:00:00Z] fragment"
    end
  end

  def test_compile_log_check_exits_usage_when_stale
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n")
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")

      err = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Wiki.new("compile-log", dir, check: true).call
      end

      assert_match(/wiki\/log\.md is stale/, err.message)
    end
  end

  def test_cli_help_lists_wiki_command
    out, _err = capture_io { Hive::CLI.start([ "help" ]) }

    assert_match(/^\s*\S+\s+wiki SUBCOMMAND\s+# Manage genera/, out)
  end
end
