require "test_helper"
require "hive/wiki_log"

class WikiLogTest < Minitest::Test
  include HiveTestHelper

  def test_compile_preserves_legacy_log_and_prepends_sorted_fragments
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), <<~MARKDOWN)
        # Wiki Changelog

        Append-only log of all wiki operations.

        ## [2026-01-01T00:00:00Z] legacy

        **Action:** Old entry.
      MARKDOWN
      File.write(File.join(dir, "wiki", "log.d", "20260605-aaa.md"), "## [2026-06-05T10:00:00Z] first\n\n**Action:** A.\n")
      File.write(File.join(dir, "wiki", "log.d", "20260606-bbb.md"), "## [2026-06-06T10:00:00Z] second\n\n**Action:** B.\n")

      compiled = Hive::WikiLog.compile(dir)

      assert_includes compiled, Hive::WikiLog::BEGIN_MARKER
      assert_operator compiled.index("second"), :<, compiled.index("first")
      assert_operator compiled.index("first"), :<, compiled.index("legacy")
      assert_includes compiled, "**Action:** Old entry."
    end
  end

  def test_compile_is_idempotent_after_generated_block_exists
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n\n## [2026-01-01T00:00:00Z] legacy\n")
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")

      first = Hive::WikiLog.compile!(dir)
      second = Hive::WikiLog.compile!(dir)

      assert_equal first, second
      assert_equal 1, second.scan("## [2026-06-05T10:00:00Z] fragment").size
      assert_equal 1, second.scan("## [2026-01-01T00:00:00Z] legacy").size
    end
  end

  def test_stale_reports_when_log_is_not_compiled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n")
      File.write(File.join(dir, "wiki", "log.d", "20260605-fragment.md"), "## [2026-06-05T10:00:00Z] fragment\n")

      assert Hive::WikiLog.stale?(dir)
      Hive::WikiLog.compile!(dir)
      refute Hive::WikiLog.stale?(dir)
    end
  end

  def test_compile_uses_project_local_compiler_when_present
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      FileUtils.mkdir_p(File.join(dir, ".llm-wiki"))
      # A project's own bootstrapped copy of the shared compiler is preferred
      # over hive's bundled fallback.
      FileUtils.cp(File.expand_path("../../.llm-wiki/compile-log.sh", __dir__),
                   File.join(dir, ".llm-wiki", "compile-log.sh"))
      File.write(File.join(dir, "wiki", "log.d", "20260605-x.md"), "## [2026-06-05T10:00:00Z] frag\n")

      assert_equal File.join(dir, ".llm-wiki", "compile-log.sh"),
                   Hive::WikiLog.compiler_path(dir),
                   "the project-local compiler copy must be preferred when present"
      assert_includes Hive::WikiLog.compile(dir), "## [2026-06-05T10:00:00Z] frag"
    end
  end

  def test_compile_raises_when_the_compiler_fails
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      FileUtils.mkdir_p(File.join(dir, ".llm-wiki"))
      File.write(File.join(dir, ".llm-wiki", "compile-log.sh"), "#!/usr/bin/env bash\necho boom >&2\nexit 1\n")
      FileUtils.chmod("+x", File.join(dir, ".llm-wiki", "compile-log.sh"))

      assert_raises(Hive::Error) { Hive::WikiLog.compile(dir) }
      assert_raises(Hive::Error) { Hive::WikiLog.compile!(dir) }
    end
  end

  def test_compile_drops_template_prose_without_legacy_entries
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "wiki", "log.d"))
      File.write(File.join(dir, "wiki", "log.md"), <<~MARKDOWN)
        # Wiki Changelog

        Append-only log of meaningful wiki updates. New work is added through
        `wiki/log.d/*.md` fragments and compiled with `hive wiki compile-log`
        after merge or when a local checkout needs refreshed aggregate output.
      MARKDOWN

      compiled = Hive::WikiLog.compile(dir)

      assert_includes compiled, Hive::WikiLog::BEGIN_MARKER
      refute_includes compiled, "`wiki/log.d/*.md` fragments"
      refute_includes compiled, "after merge or when a local checkout needs refreshed aggregate output"
    end
  end
end
