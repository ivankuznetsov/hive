require "test_helper"
require "hive/stages"
require "tmpdir"
require "fileutils"

class StageLiteralGuardTest < Minitest::Test
  # Derived from the coding descriptor (Hive::Stages::NAMES) rather than
  # hardcoded, so a coding-stage rename can't silently shrink the guard's net
  # without this alternation following along. `Regexp.union` builds the
  # `(?:inbox|brainstorm|…)` alternation from the live stage names.
  STAGE_NAME = Regexp.union(Hive::Stages::NAMES).freeze

  # The durable net catches a stage literal in any of the forms code actually
  # uses to spell one. Each alternative requires a real delimiter so prose
  # mentions ("the 3-plan stage") don't trip it:
  #   - quoted (single OR double), interpolation prefix allowed:
  #       "3-plan"   '3-plan'   "#{n}-plan"
  #   - %w / %i word-array element:  %w[4-execute 6-review 8-finalize]
  # `\d+-` (not `\d-`) so a future renumber past single digits (e.g.
  # "10-review") cannot smuggle an unguarded literal past the net. The earlier
  # double-quote-only regex silently passed single-quote, %w, and interpolated
  # vectors (e.g. the live `WORKTREE_OWNING_STAGES = %w[...]` constant).
  STAGE_LITERAL = Regexp.union(
    /(["'])(?:\d+|#\{[^}]*\})-#{STAGE_NAME}\1/,
    /%[wi][\[({<][^\n]*?(?<![\w-])(?:\d+|#\{[^}]*\})-#{STAGE_NAME}(?![\w-])/
  )
  ANNOTATION = /#\s*(?:coding-scoped|not-a-stage-ref):\s*\S+/

  # A block annotation applies one reason to a contiguous run of stage-literal
  # lines so a uniform reason (e.g. a STAGE_LABELS map, a case/when ladder) is
  # stated once instead of restated on every line. A
  # `# coding-scoped (block): <reason>` line opens coverage; the next blank
  # line closes it.
  BLOCK_ANNOTATION = /#\s*(?:coding-scoped|not-a-stage-ref)\s*\(block\):\s*\S+/

  def test_regex_matches_stage_literals_and_rejects_near_misses
    assert_match STAGE_LITERAL, 'stage = "3-plan"'
    assert_match STAGE_LITERAL, 'stage = "8-finalize"'
    # Two-digit stage prefixes must be caught too (was silently unguarded
    # while the prefix was `\d-`).
    assert_match STAGE_LITERAL, 'stage = "10-review"'
    assert_match STAGE_LITERAL, 'stage = "23-plan"'
    # Evasion vectors the double-quote-only net used to miss:
    assert_match STAGE_LITERAL, "stage = '3-plan'"
    assert_match STAGE_LITERAL, "WORKTREE_OWNING_STAGES = %w[4-execute 6-review 8-finalize]"
    assert_match STAGE_LITERAL, "markers = %i[3-plan]"
    assert_match STAGE_LITERAL, 'stage = "#{n}-plan"'
    refute_match STAGE_LITERAL, 'stage = "3-planning"'
    refute_match STAGE_LITERAL, 'stage = "plan"'
    # A bare prose mention (no quote, no %w delimiter) must NOT trip the net.
    refute_match STAGE_LITERAL, "# the 3-plan stage runs the planner"
  end

  def test_annotation_requires_a_non_empty_reason
    assert annotated?('stage = "6-review" # coding-scoped: review-loop stage')
    assert annotated?('stage = "9-done" # not-a-stage-ref: historical fixture')

    refute annotated?('stage = "6-review"')
    refute annotated?('stage = "6-review" # coding-scoped:')
    refute annotated?('stage = "6-review" # not-a-stage-ref:   ')
  end

  def test_block_annotation_covers_a_run_until_a_blank_line
    lines = [
      "# coding-scoped (block): bespoke coding labels",
      'A = "1-inbox"',
      'B = "3-plan"',
      "",
      'C = "6-review"'
    ]
    covered = block_covered_lines(lines)

    assert_equal [ 2, 3 ], covered,
                 "the block covers literals until the blank line closes it (line 5 is uncovered)"
  end

  def test_all_stage_literals_in_lib_are_routed_or_annotated
    offenders = stage_literal_hits.reject { |hit| annotated?(hit.fetch(:line)) || hit.fetch(:block_covered) }

    assert_empty offenders, <<~MSG
      Unrouted stage literals remain in lib/. Replace generic literals with descriptor lookups,
      or annotate intentionally retained literals with one of:
        # coding-scoped: <reason>
        # not-a-stage-ref: <reason>

      Offenders:
      #{offenders.map { |hit| "#{hit[:path]}:#{hit[:line_no]}: #{hit[:line].strip}" }.join("\n")}
    MSG
  end

  # Positive control (U6.2 "Guard fails on an un-annotated literal"): the
  # lib-wide sweep above passes vacuously if a regression breaks the glob root
  # (zero files scanned ⇒ zero offenders ⇒ green) or shrinks STAGE_LITERAL. Two
  # guards against that:
  #   1. The real sweep over `lib/` must find SOME literals (the codebase has
  #      annotated ones), proving the glob root is live.
  #   2. Pointed at a synthetic tree, the same machinery must FLAG an
  #      unannotated planted literal and SPARE a correctly-annotated one.
  def test_sweep_is_not_vacuous_and_flags_a_planted_unannotated_literal
    refute_empty stage_literal_hits,
                 "the lib/ sweep found zero stage literals — the glob root is " \
                 "likely broken, which would let the routing guard pass vacuously"

    Dir.mktmpdir("hive-guard-positive-control") do |dir|
      lib = File.join(dir, "lib", "hive")
      FileUtils.mkdir_p(lib)
      # An unrouted, unannotated stage literal — exactly what the guard exists
      # to catch.
      File.write(File.join(lib, "planted.rb"), %(STAGE = "3-plan"\n))
      # A correctly-annotated literal in the same tree must NOT be flagged.
      File.write(File.join(lib, "annotated.rb"),
                 %(STAGE = "6-review" # coding-scoped: legit\n))

      hits = stage_literal_hits(lib_root: File.join(dir, "lib"))
      offenders = hits.reject { |hit| annotated?(hit.fetch(:line)) || hit.fetch(:block_covered) }

      assert_equal 1, offenders.size,
                   "exactly the unannotated planted literal must be flagged as an offender"
      assert_includes offenders.first.fetch(:line), "3-plan"
    end
  end

  private

  def annotated?(line)
    line.match?(ANNOTATION)
  end

  def default_lib_root
    File.join(File.expand_path("../..", __dir__), "lib")
  end

  def stage_literal_hits(lib_root: default_lib_root)
    Dir.glob(File.join(lib_root, "**", "*.rb")).sort.flat_map do |path|
      lines = File.readlines(path, chomp: true)
      covered = block_covered_lines(lines)
      lines.filter_map.with_index(1) do |line, line_no|
        next unless line.match?(STAGE_LITERAL)

        { path: path.delete_prefix("#{lib_root}/"), line_no: line_no, line: line,
          block_covered: covered.include?(line_no) }
      end
    end
  end

  # 1-based line numbers of stage-literal lines sitting under an open block
  # annotation (see BLOCK_ANNOTATION). A block opens on its annotation line and
  # closes on the next blank line.
  def block_covered_lines(lines)
    covered = []
    open = false
    lines.each_with_index do |line, idx|
      open = true if line.match?(BLOCK_ANNOTATION)
      open = false if line.strip.empty?
      covered << (idx + 1) if open && line.match?(STAGE_LITERAL)
    end
    covered
  end
end
