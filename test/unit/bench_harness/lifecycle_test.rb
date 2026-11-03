# frozen_string_literal: true

require "support/bench_harness"
require "open3"

class BenchHarnessLifecycleTest < Minitest::Test
  def test_generation_backfill_replacement_and_repeat_publication
    script = File.expand_path("../../support/bench_evidence_lifecycle.rb", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{BenchHarness::HARNESS_ROOT}", script)
    assert status.success?, out + err
    assert_equal({ "eligible" => 2, "ranked_judged" => 1, "gated" => 2, "diagnostic_judged" => 2,
                   "generations" => 5, "backfill_calls" => 3, "history" => 2 }, JSON.parse(out))
  end
end
