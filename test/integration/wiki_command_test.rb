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

  def test_compile_log_check_reports_when_up_to_date
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")
      Hive::WikiLog.compile!(dir)

      out, _err = capture_io { Hive::Commands::Wiki.new("compile-log", dir, check: true).call }

      assert_includes out, "wiki/log.md is up to date"
    end
  end

  def test_unknown_subcommand_exits_usage
    err = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Wiki.new("wat", Dir.pwd).call
    end

    assert_match(/unknown subcommand "wat"/, err.message)
  end

  def test_missing_wiki_directory_exits_usage
    with_tmp_dir do |dir|
      err = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Wiki.new("compile-log", dir).call
      end

      assert_match(/not a wiki project/, err.message)
    end
  end

  def test_cli_dispatches_wiki_command
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n")
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")

      out, _err = capture_io { Hive::CLI.start([ "wiki", "compile-log", dir ]) }

      assert_includes out, "compiled wiki/log.md from 1 fragment"
      assert_includes File.read(File.join(dir, "wiki", "log.md")), "## [2026-06-05T10:00:00Z] fragment"
    end
  end

  def test_cli_help_lists_wiki_command
    out, _err = capture_io { Hive::CLI.start([ "help" ]) }

    assert_match(/^\s*\S+\s+wiki SUBCOMMAND\s+#/, out)
  end
end
