require "test_helper"

class StageLiteralGuardTest < Minitest::Test
  STAGE_LITERAL = /"\d-(?:inbox|brainstorm|plan|execute|open-pr|review|artifacts|finalize|done)"/
  ANNOTATION = /#\s*(?:coding-scoped|not-a-stage-ref):\s*\S+/

  def test_regex_matches_stage_literals_and_rejects_near_misses
    assert_match STAGE_LITERAL, 'stage = "3-plan"'
    assert_match STAGE_LITERAL, 'stage = "8-finalize"'
    refute_match STAGE_LITERAL, 'stage = "3-planning"'
    refute_match STAGE_LITERAL, 'stage = "23-plan"'
  end

  def test_annotation_requires_a_non_empty_reason
    assert annotated?('stage = "6-review" # coding-scoped: review-loop stage')
    assert annotated?('stage = "9-done" # not-a-stage-ref: historical fixture')

    refute annotated?('stage = "6-review"')
    refute annotated?('stage = "6-review" # coding-scoped:')
    refute annotated?('stage = "6-review" # not-a-stage-ref:   ')
  end

  def test_all_stage_literals_in_lib_are_routed_or_annotated
    offenders = stage_literal_hits.reject { |hit| annotated?(hit.fetch(:line)) }

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
      File.readlines(path, chomp: true).filter_map.with_index(1) do |line, line_no|
        next unless line.match?(STAGE_LITERAL)

        { path: path.delete_prefix("#{root}/"), line_no: line_no, line: line }
      end
    end
  end
end
