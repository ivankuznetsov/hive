# frozen_string_literal: true

require "support/bench_harness"
require "merge_results"
require "open3"

class BenchHarnessMergeResultsTest < Minitest::Test
  def generation(id, judge, score, kind: "generation")
    binding = { "task_id" => "t", "base_commit" => "base", "patch_sha256" => "a" * 64, "plan_sha256" => "b" * 64 }
    context = { "plan_sha256" => "b" * 64, "reference_mode" => "withheld" }
    evidence = { "generation_id" => id, "artifact_binding" => binding, "evaluation_context" => context }
    { "task_id" => "t", "agent_id" => "A", "generation_id" => id, "record_kind" => kind,
      "artifact_binding" => binding, "evaluation_context" => context, "run_status" => "generated", "mode" => "hive",
      "subset" => "gated", "gate" => { "status" => "pass", "evidence_binding" => evidence },
      "efficiency" => { "cost_usd" => score },
      "judges" => { judge => { "mean" => score, "evidence_binding" => evidence } } }
  end

  def combine(*documents)
    HiveBench::Merge.combine(documents.map { |d| d.is_a?(Array) ? { "cells" => d } : d }, corpus_version: "v", generated_at: "now")
  end

  def test_replacement_uses_last_explicit_snapshot_even_with_identical_patch_bytes
    a = generation("a", "X", 2.0)
    b = generation("b", "Y", 9.0)
    [ [a, b, "Y"], [b, a, "X"] ].each do |first, last, judge|
      out = combine([first], [last])
      assert_equal [judge], out.fetch("cells").first.fetch("judges").keys
      assert_equal last["efficiency"], out.fetch("cells").first.fetch("efficiency")
      assert_equal last["generation_id"], out.fetch("cells").first.fetch("generation_id")
      assert_equal 1, out.fetch("generation_history").size
    end
  end

  def test_same_generation_backfill_is_order_independent_and_retains_gate_and_cost
    a = generation("a", "X", 2.0)
    overlay = generation("a", "Y", 9.0, kind: "judge_only").merge("efficiency" => {}, "gate" => {}, "subset" => "judged")
    outputs = [[a, overlay], [overlay, a]].map { |records| combine(records) }
    assert_equal outputs[0].fetch("cells"), outputs[1].fetch("cells")
    cell = outputs[0].fetch("cells").first
    assert_equal %w[X Y], cell.fetch("judges").keys.sort
    assert_equal a["efficiency"], cell["efficiency"]
    assert_equal "gated", cell["subset"]
    assert_equal 1, outputs[0].dig("agents", "A", "gated", "total")
  end

  def test_stale_overlays_cannot_roll_back_newer_generation
    a = generation("a", "X", 2.0)
    b = generation("b", "Y", 9.0)
    overlay = generation("a", "Z", 8.0, kind: "judge_only")
    outputs = [[overlay, a, b], [a, overlay, b], [a, b, overlay]].map { |records| combine(records) }
    outputs.each do |out|
      assert_equal ["Y"], out.fetch("cells").first.fetch("judges").keys
      assert_equal 2, out.fetch("generation_history").size
    end
  end

  def test_timeout_replacement_and_legacy_never_inherit_ranked_evidence
    a = generation("a", "X", 2.0)
    b = generation("b", "Y", 9.0).merge("run_status" => "timed_out", "judges" => {}, "gate" => {}, "efficiency" => {})
    out = combine([a], [b])
    assert_empty out.fetch("cells").first.fetch("judges")
    assert_nil out.dig("agents", "A", "gated", "pass_rate")
    legacy = a.reject { |key, _| %w[generation_id artifact_binding record_kind].include?(key) }
    assert_equal 0, combine([legacy], [legacy]).dig("agents", "A", "judged", "scored_cells")
  end

  def test_same_id_with_inconsistent_artifacts_is_a_provenance_conflict
    a = generation("a", "X", 2.0)
    forged = generation("a", "Y", 9.0)
    forged["artifact_binding"] = forged["artifact_binding"].merge("patch_sha256" => "c" * 64)
    out = combine([a], [forged])
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
    assert out.fetch("rejudging_needed").any? { |r| r.fetch("reasons").any? { |reason| reason.include?("conflict") } }
  end

  def test_repeated_merge_deduplicates_history_buckets_and_costs
    a = generation("a", "X", 2.0)
    b = generation("b", "Y", 9.0)
    first = combine({ "cells" => [a], "pending" => [a] }, [b])
    second = combine(first, first, { "cells" => [a.merge("record_kind" => "judge_only")] })
    third = combine(second, second)
    assert_equal second.fetch("generation_history"), third.fetch("generation_history")
    assert_equal 1, third.fetch("pending").size
    assert_equal second.dig("agents", "A", "efficiency"), third.dig("agents", "A", "efficiency")
  end
  def test_conflicting_overlay_invalidates_active_identity
    active = generation("a", "X", 2.0)
    overlay = generation("a", "Y", 9.0, kind: "judge_only")
    overlay["artifact_binding"] = overlay["artifact_binding"].merge("patch_sha256" => "c" * 64)
    out = combine([active, overlay])
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
    assert out.fetch("cells").first["provenance_conflict"]
  end

  def test_cli_obeys_snapshot_order_and_preserves_history_on_repeat
    Dir.mktmpdir("bench-merge-cli") do |dir|
      paths = %w[a b].map.with_index do |id, index|
        path = File.join(dir, "#{id}.json")
        File.write(path, JSON.generate("cells" => [generation(id, id.upcase, index + 2.0)]))
        path
      end
      output = File.join(dir, "out.json")
      executable = File.join($LOAD_PATH.find { |path| File.file?(File.join(path, "merge_results.rb")) }, "merge_results.rb")
      [paths, paths.reverse].each do |inputs|
        _out, err, status = Open3.capture3(RbConfig.ruby, executable, "--out", output, *inputs)
        assert status.success?, err
        first = JSON.parse(File.read(output))
        assert_equal File.basename(inputs.last, ".json"), first.fetch("cells").first["generation_id"]
        _out, err, status = Open3.capture3(RbConfig.ruby, executable, "--out", output, output, output)
        assert status.success?, err
        repeated = JSON.parse(File.read(output))
        assert_equal first["generation_history"], repeated["generation_history"]
        assert_equal first["agents"], repeated["agents"]
      end
    end
  end

end
