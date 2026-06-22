require "test_helper"
require "hive/stages/review"
require "hive/stages/review/suppression"
require "hive/stages/review/context"

class ReviewSuppressionTest < Minitest::Test
  include HiveTestHelper

  Suppression = Hive::Stages::Review::Suppression
  Entry = Suppression::Entry

  def make_ctx(task_folder, pass: 1)
    Hive::Stages::Review::Context.new(
      worktree_path: task_folder,
      task_folder: task_folder,
      default_branch: "main",
      pass: pass
    )
  end

  def with_suppression_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      yield make_ctx(dir)
    end
  end

  def default_cfg(overrides = {})
    deep_merge_for_test(
      { "review" => { "triage" => { "enabled" => true } } },
      overrides
    )
  end

  def deep_merge_for_test(base, over)
    base.merge(over) do |_key, b, o|
      b.is_a?(Hash) && o.is_a?(Hash) ? deep_merge_for_test(b, o) : o
    end
  end

  def test_key_for_ignores_body_text
    a = Suppression.key_for(
      "AUTO-FIX: lib/foo.rb:12 leaks stale state: first justification",
      severity: "High"
    )
    b = Suppression.key_for(
      "RESOLVED/NO-FIX: lib/foo.rb:12 leaks stale state: a completely different rationale",
      severity: "High"
    )

    assert_equal a, b
  end

  def test_key_for_strips_line_numbers_from_file_refs
    a = Suppression.key_for("lib/foo.rb:12 leaks stale state", severity: "Medium")
    b = Suppression.key_for("lib/foo.rb:88 leaks stale state", severity: "Medium")

    assert_equal a, b
  end

  def test_key_for_distinguishes_different_titles
    a = Suppression.key_for("lib/foo.rb leaks stale state", severity: "High")
    b = Suppression.key_for("lib/foo.rb drops retry state", severity: "High")

    refute_equal a, b
  end

  def test_key_for_strips_disposition_prefixes_checkbox_and_trailing_comments
    expected = Suppression.key_for("lib/foo.rb leaks stale state", severity: "High")

    %w[AUTO-FIX RESOLVED/NO-FIX RESOLVED NO-FIX ESCALATE SUPPRESSED].each do |prefix|
      line = "- [x] #{prefix}: lib/foo.rb leaks stale state <!-- fp=deadbeefdeadbeef -->"
      assert_equal expected, Suppression.key_for(line, severity: "High"), prefix
    end
  end

  def test_reset_if_base_changed_preserves_same_base_and_clears_changed_base
    with_suppression_task do |ctx|
      path = Suppression.suppressed_path(ctx)
      entries = [
        Entry.new(
          key: nil,
          severity: "high",
          text: "lib/foo.rb leaks stale state",
          first_pass: 1,
          active: true
        )
      ]
      Suppression.append_entries!(ctx, "abc123", entries)

      refute Suppression.reset_if_base_changed!(ctx, "abc123")
      assert_includes File.read(path), "leaks stale state"

      assert Suppression.reset_if_base_changed!(ctx, "def456")
      content = File.read(path)
      assert_includes content, "base=def456"
      refute_includes content, "leaks stale state"
    end
  end

  def test_read_active_keys_counts_checked_and_ignores_unchecked_tombstones
    with_suppression_task do |ctx|
      key = Suppression.key_for("lib/foo.rb leaks stale state", severity: "high")
      other = Suppression.key_for("lib/bar.rb stale tombstone", severity: "medium")
      File.write(Suppression.suppressed_path(ctx), <<~MD)
        <!-- HIVE-SUPPRESS v1 base=abc123 -->

        ## High
        - [x] High: lib/foo.rb leaks stale state <!-- fp=#{key} first-pass=01 -->

        ## Medium
        - [ ] Medium: lib/bar.rb stale tombstone <!-- fp=#{other} first-pass=01 -->
      MD

      keys = Suppression.read_active_keys(ctx)

      assert_includes keys, key
      refute_includes keys, other
    end
  end

  def test_read_active_keys_hashes_operator_added_line_without_fp
    with_suppression_task do |ctx|
      expected = Suppression.key_for("lib/foo.rb leaks stale state", severity: "high")
      File.write(Suppression.suppressed_path(ctx), <<~MD)
        <!-- HIVE-SUPPRESS v1 base=abc123 -->

        ## High
        - [x] High: lib/foo.rb leaks stale state
      MD

      assert_includes Suppression.read_active_keys(ctx), expected
    end
  end

  def test_append_entries_dedups_and_routes_high_to_prominent_section
    with_suppression_task do |ctx|
      entry = Entry.new(
        key: nil,
        severity: "high",
        text: "RESOLVED/NO-FIX: lib/foo.rb:12 leaks stale state <!-- ignored -->",
        first_pass: 1,
        active: true
      )

      assert_equal 1, Suppression.append_entries!(ctx, "abc123", [ entry ])
      assert_equal 0, Suppression.append_entries!(ctx, "abc123", [ entry ])

      content = File.read(Suppression.suppressed_path(ctx))
      assert_includes content, "## High - prominent active suppressions"
      assert_equal 1, content.scan("leaks stale state").size
      assert_match(/- \[x\] High: lib\/foo\.rb:12 leaks stale state <!-- fp=[0-9a-f]{16} first-pass=01 -->/, content)
    end
  end

  def test_strip_suppressed_rewrites_matching_unchecked_reviewer_line
    with_suppression_task do |ctx|
      Suppression.append_entries!(ctx, "abc123", [
        Entry.new(
          key: nil,
          severity: "high",
          text: "lib/foo.rb:12 leaks stale state: triage said no fix",
          first_pass: 1,
          active: true
        )
      ])
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, "## High\n- [ ] lib/foo.rb:88 leaks stale state: re-emitted\n")

      assert_equal 1, Suppression.strip_suppressed!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")

      content = File.read(reviewer)
      assert_includes content, "- [x] SUPPRESSED: lib/foo.rb:88 leaks stale state: re-emitted"
      refute Hive::Stages::Review.auto_fix_finding_line?(content.lines.last)
    end
  end

  def test_strip_suppressed_leaves_unmatched_line_untouched
    with_suppression_task do |ctx|
      Suppression.append_entries!(ctx, "abc123", [
        Entry.new(key: nil, severity: "high", text: "lib/foo.rb leaks stale state", first_pass: 1, active: true)
      ])
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      original = "## High\n- [ ] lib/foo.rb drops retry state\n"
      File.write(reviewer, original)

      assert_equal 0, Suppression.strip_suppressed!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      assert_equal original, File.read(reviewer)
    end
  end

  def test_strip_suppressed_disabled_by_config_is_noop
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      original = "## High\n- [ ] lib/foo.rb leaks stale state\n"
      File.write(reviewer, original)
      cfg = default_cfg("review" => { "triage" => { "suppress_no_fix" => false } })

      assert_equal 0, Suppression.strip_suppressed!(cfg: cfg, ctx: ctx, base_sha: "abc123")
      assert_equal original, File.read(reviewer)
      refute File.exist?(Suppression.suppressed_path(ctx))
    end
  end

  def test_strip_suppressed_empty_reviewer_files_is_noop_without_writing_suppressed_doc
    with_suppression_task do |ctx|
      assert_equal 0, Suppression.strip_suppressed!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      refute File.exist?(Suppression.suppressed_path(ctx))
    end
  end
end
