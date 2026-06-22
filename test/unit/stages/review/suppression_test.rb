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

  def test_key_for_distinguishes_same_file_line_different_descriptions
    # M1 regression: a reviewer line shaped `file:line: description` must
    # not collapse to just the filename. With the title/justification split
    # happening before file refs were stripped, the `:line:` colon was
    # mistaken for the title separator and the title collapsed to "", so two
    # unrelated findings on the same file silently shared a key.
    a = Suppression.key_for("lib/foo.rb:42: null deref", severity: "High")
    b = Suppression.key_for("lib/foo.rb:99: off-by-one", severity: "High")

    refute_equal a, b
  end

  def test_seed_and_strip_keys_match_across_shapes_and_drifted_lines
    # The whole feature pivots on this identity: the RESOLVED/NO-FIX seed
    # shape and the re-emitted unchecked strip shape, at different line
    # numbers, must fingerprint identically so the strip pass recognizes a
    # prior no-fix seed.
    seed = "RESOLVED/NO-FIX: lib/foo.rb:12 leaks stale state: triage accepts risk"
    strip = "lib/foo.rb:88 leaks stale state: re-emitted no-fix"

    assert_equal Suppression.key_for(seed, severity: "high"),
                 Suppression.key_for(strip, severity: "high")
  end

  def test_key_for_excludes_justification_in_file_line_colon_title_shape
    # `file:line: title: justification` — the file ref is immediately
    # followed by the separator, so the title split must skip that artifact
    # colon and still exclude the justification after the real title.
    a = Suppression.key_for("lib/foo.rb:42: null deref: happens on retry", severity: "High")
    b = Suppression.key_for("lib/foo.rb:42: null deref: only under load", severity: "High")

    assert_equal a, b
  end

  def test_parse_section_recognizes_rendered_unknown_heading
    # render_document emits a `## Unknown` section; parse_section must
    # accept it so the canonical severity list round-trips. It formerly
    # reused Findings::KNOWN_SEVERITIES, which omits "unknown".
    assert_equal "unknown", Suppression.parse_section("## Unknown\n")
    assert_equal "high", Suppression.parse_section("## High - prominent active suppressions\n")
    assert_nil Suppression.parse_section("## Detailed Analysis\n")
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

  def test_reset_if_base_changed_recovers_empty_suppression_doc
    with_suppression_task do |ctx|
      FileUtils.touch(Suppression.suppressed_path(ctx))

      assert Suppression.reset_if_base_changed!(ctx, "abc123")
      assert_includes File.read(Suppression.suppressed_path(ctx)), "base=abc123"
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

  def test_read_active_keys_returns_empty_for_unreadable_suppression_doc
    with_suppression_task do |ctx|
      FileUtils.rm_f(Suppression.suppressed_path(ctx))
      FileUtils.mkdir_p(Suppression.suppressed_path(ctx))

      assert_empty Suppression.read_active_keys(ctx)
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

  def test_read_active_keys_uses_section_severity_for_operator_line_without_inline_severity
    with_suppression_task do |ctx|
      expected = Suppression.key_for("lib/foo.rb leaks stale state", severity: "high")
      File.write(Suppression.suppressed_path(ctx), <<~MD)
        <!-- HIVE-SUPPRESS v1 base=abc123 -->

        ## High
        - [x] lib/foo.rb leaks stale state
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

  def test_seed_from_triage_records_high_resolved_no_fix
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, "## High\n- [x] RESOLVED/NO-FIX: lib/foo.rb:12 leaks stale state: accepted risk\n")

      assert_equal 1, Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")

      content = File.read(Suppression.suppressed_path(ctx))
      assert_includes content, "## High - prominent active suppressions"
      assert_match(/- \[x\] High: lib\/foo\.rb:12 leaks stale state: accepted risk <!-- fp=[0-9a-f]{16} first-pass=01 -->/, content)
    end
  end

  def test_seed_from_triage_ignores_auto_fix_lines
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, "## High\n- [x] AUTO-FIX: lib/foo.rb leaks stale state\n")

      assert_equal 0, Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      refute File.exist?(Suppression.suppressed_path(ctx))
    end
  end

  def test_seed_from_triage_dedups_repeated_no_fix_lines
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, <<~MD)
        ## Medium
        - [x] RESOLVED/NO-FIX: lib/foo.rb:12 leaks stale state: first
        - [x] RESOLVED/NO-FIX: lib/foo.rb:44 leaks stale state: second
      MD

      assert_equal 1, Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      assert_equal 0, Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      assert_equal 1, File.read(Suppression.suppressed_path(ctx)).scan("leaks stale state").size
    end
  end

  def test_seed_from_triage_disabled_by_config_is_noop
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, "## High\n- [x] RESOLVED/NO-FIX: lib/foo.rb leaks stale state\n")
      cfg = default_cfg("review" => { "triage" => { "suppress_no_fix" => false } })

      assert_equal 0, Suppression.seed_from_triage!(cfg: cfg, ctx: ctx, base_sha: "abc123")
      refute File.exist?(Suppression.suppressed_path(ctx))
    end
  end

  def test_seed_from_triage_ignores_fenced_no_fix_example
    with_suppression_task do |ctx|
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, <<~MD)
        ## High
        A no-fix line shown only as a fenced example must not be seeded:

        ```
        - [x] RESOLVED/NO-FIX: lib/foo.rb leaks stale state: example only
        ```
      MD

      assert_equal 0, Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      refute File.exist?(Suppression.suppressed_path(ctx))
    end
  end

  def test_strip_suppressed_ignores_fenced_unchecked_line
    with_suppression_task do |ctx|
      Suppression.append_entries!(ctx, "abc123", [
        Entry.new(key: nil, severity: "high", text: "lib/foo.rb leaks stale state", first_pass: 1, active: true)
      ])
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      original = "## High\n```\n- [ ] lib/foo.rb leaks stale state\n```\n"
      File.write(reviewer, original)

      assert_equal 0, Suppression.strip_suppressed!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")
      assert_equal original, File.read(reviewer),
                   "an unchecked line inside a fenced code block must not be suppressed"
    end
  end

  def test_strip_preserves_first_pass_provenance_from_earlier_seed
    with_suppression_task do |ctx|
      fp = Suppression.key_for("lib/foo.rb leaks stale state", severity: "high")
      File.write(Suppression.suppressed_path(ctx), <<~MD)
        <!-- HIVE-SUPPRESS v1 base=abc123 -->

        ## High
        - [x] High: lib/foo.rb leaks stale state <!-- fp=#{fp} first-pass=01 -->
      MD
      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-03.md")
      File.write(reviewer, "## High\n- [ ] lib/foo.rb:88 leaks stale state: re-emitted\n")
      ctx3 = make_ctx(ctx.task_folder, pass: 3)

      assert_equal 1, Suppression.strip_suppressed!(cfg: default_cfg, ctx: ctx3, base_sha: "abc123")

      content = File.read(reviewer)
      assert_includes content, "first-pass=01",
                      "strip must stamp the seed's original first-pass, not the current pass"
      refute_includes content, "first-pass=03"
    end
  end

  def test_out_of_enum_inline_severity_survives_rewrite_under_section
    with_suppression_task do |ctx|
      # An operator hand-adds a `Critical:` entry under ## High. The inline
      # `Critical:` is not a known severity, so split_entry_severity keeps
      # the section severity ("high") and normalize_severity clamps anything
      # stray into the canonical set — so the entry is rendered under ## High
      # on the next rewrite instead of being silently dropped.
      File.write(Suppression.suppressed_path(ctx), <<~MD)
        <!-- HIVE-SUPPRESS v1 base=abc123 -->

        ## High
        - [x] Critical: lib/foo.rb bad
      MD

      refute_empty Suppression.read_active_keys(ctx)

      reviewer = File.join(ctx.task_folder, "reviews", "stub-reviewer-01.md")
      File.write(reviewer, "## High\n- [x] RESOLVED/NO-FIX: lib/other.rb thing: rationale\n")
      Suppression.seed_from_triage!(cfg: default_cfg, ctx: ctx, base_sha: "abc123")

      content = File.read(Suppression.suppressed_path(ctx))
      assert_includes content, "Critical: lib/foo.rb bad",
                      "an out-of-enum inline label must not be dropped on rewrite"
    end
  end

  def test_append_entries_skips_when_doc_present_but_unreadable
    with_suppression_task do |ctx|
      path = Suppression.suppressed_path(ctx)
      Suppression.append_entries!(ctx, "abc123", [
        Entry.new(key: nil, severity: "high", text: "lib/foo.rb leaks stale state", first_pass: 1, active: true)
      ])
      before = File.read(path)

      original_open = File.method(:open)
      raising = lambda do |open_path, *args, **kwargs, &block|
        raise Errno::EACCES, "denied" if File.expand_path(open_path) == File.expand_path(path)

        original_open.call(open_path, *args, **kwargs, &block)
      end

      added = nil
      _out, err = capture_io do
        with_replaced_singleton_method(File, :open, raising) do
          added = Suppression.append_entries!(ctx, "abc123", [
            Entry.new(key: nil, severity: "medium", text: "lib/bar.rb new finding", first_pass: 2, active: true)
          ])
        end
      end

      assert_equal 0, added, "append must skip when the doc is present but unreadable"
      assert_equal before, File.read(path),
                   "a transient read error must not clobber operator-edited suppression state"
      assert_match(/unreadable/, err)
    end
  end
end
