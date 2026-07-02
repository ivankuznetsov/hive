require "test_helper"
require "hive/refactor_patrol/collisions"
require "hive/refactor_patrol/state_store"

class RefactorPatrolCollisionsTest < Minitest::Test
  include HiveTestHelper

  def test_active_refactor_fingerprint_is_suppressed
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      thesis = sample_thesis(fingerprint: "abc")
      store.write_fingerprints("abc" => { "state" => "seen", "feature_id" => thesis.feature_id })

      result = Hive::RefactorPatrol::Collisions.new(dir, state: store).check(thesis)

      assert result.suppressed
      assert_equal "collision_already_seen", result.reason
    end
  end

  def test_dismissed_refactor_fingerprint_is_suppressed
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      thesis = sample_thesis(fingerprint: "abc")
      store.write_dismissed("abc" => { "state" => "dismissed", "feature_id" => thesis.feature_id })

      result = Hive::RefactorPatrol::Collisions.new(dir, state: store).check(thesis)

      assert result.suppressed
      assert_equal "collision_dismissed", result.reason
    end
  end

  def test_open_patrol_fingerprint_flags_but_does_not_modify_patrol_state
    with_tmp_dir do |dir|
      patrol_dir = File.join(dir, ".hive-state", "patrol")
      FileUtils.mkdir_p(patrol_dir)
      path = File.join(patrol_dir, "fingerprints.json")
      original = {
        "patrol-fp" => {
          "state" => "open",
          "feature_id" => "checkout",
          "pr_url" => "https://example.com/pull/1"
        }
      }
      File.write(path, JSON.pretty_generate(original))

      result = Hive::RefactorPatrol::Collisions.new(dir, state: Hive::RefactorPatrol::StateStore.new(dir))
                                             .check(sample_thesis)

      refute result.suppressed
      assert_equal "collision_patrol_pr", result.reason
      assert_includes result.thesis.risk.fetch("flags"), "collision_patrol_pr"
      assert_equal original, JSON.parse(File.read(path))
    end
  end

  def test_no_prior_activity_has_no_collision
    with_tmp_dir do |dir|
      result = Hive::RefactorPatrol::Collisions.new(dir, state: Hive::RefactorPatrol::StateStore.new(dir))
                                             .check(sample_thesis)

      refute result.suppressed
      assert_nil result.reason
      assert_nil result.thesis.collision
    end
  end

  private

  def sample_thesis(fingerprint: "fp")
    Hive::RefactorPatrol::Thesis.new(
      id: "t1",
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes concerns",
      cost: "Churn is high",
      evidence: [ { "file" => "lib/checkout.rb", "signal" => "churn", "value" => 7 } ],
      proposed_refactor: "Extract service",
      feature_boundary: { "owned_files" => [ "lib/checkout.rb" ], "entrypoints" => [ "lib/checkout.rb" ] },
      expected_leverage: { "score" => 0.5, "breakdown" => { "churn" => 0.5 } },
      confidence: "medium",
      risk: {
        "caps" => { "est_files" => 2, "est_diff_lines" => 80, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "" },
      admissible: true,
      admissibility_reason: "ok",
      follow_up_approval_state: "pending",
      fingerprint: fingerprint
    )
  end
end
