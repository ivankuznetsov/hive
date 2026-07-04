require "json_schemer"
require "hive/patrol/feature"

# Canonical "checkout" thesis fixtures shared by the reviewer and
# thesis-normalizer tests so the example agent payload has one home.
module RefactorPatrolThesisFixtures
  def thesis_schemer
    @thesis_schemer ||= JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol-thesis")))
  end

  def feature(tests: [])
    Hive::Patrol::Feature.new(
      id: "checkout",
      kind: "command",
      entrypoints: [ "lib/checkout.rb" ],
      owned_files: [ "lib/checkout.rb" ],
      context_files: [ "README.md" ],
      tests: tests
    )
  end

  # The measured leverage for one feature, as ThesisNormalizer consumes it.
  # Reviewer tests key it by feature id via +leverage_by_feature+.
  def feature_leverage
    {
      "score" => 0.8,
      "breakdown" => { "churn" => 0.5, "fan_in" => 0.3 },
      "signals" => { "churn" => 10, "fan_in" => 4 }
    }
  end

  def leverage_by_feature
    { "checkout" => feature_leverage }
  end

  def valid_raw_thesis
    {
      "feature" => "Checkout",
      "problem" => "Checkout mixes validation and payment orchestration",
      "cost" => "Frequent changes touch the same file and its callers",
      "evidence" => [ { "file" => "lib/checkout.rb", "signal" => "churn", "value" => 10 } ],
      "proposed_refactor" => "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => { "score" => 0.8, "breakdown" => { "churn" => 0.5, "fan_in" => 0.3 } },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "est_files" => 3, "est_diff_lines" => 120, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => { "commands" => [ "test" ], "characterization_first" => false, "notes" => "Run checkout tests" },
      "follow_up_approval_state" => "pending"
    }
  end
end
