require "test_helper"

class StageLiteralGuardTest < Minitest::Test
  STAGE_NAME = /(?:inbox|brainstorm|plan|execute|open-pr|review|artifacts|finalize|done)/

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

  private

  def annotated?(line)
    line.match?(ANNOTATION)
  end

  def stage_literal_hits
    root = File.expand_path("../..", __dir__)
    lib_root = File.join(root, "lib")

    Dir.glob(File.join(lib_root, "**", "*.rb")).sort.flat_map do |path|
      lines = File.readlines(path, chomp: true)
      covered = block_covered_lines(lines)
      lines.filter_map.with_index(1) do |line, line_no|
        next unless line.match?(STAGE_LITERAL)

        { path: path.delete_prefix("#{root}/"), line_no: line_no, line: line,
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
