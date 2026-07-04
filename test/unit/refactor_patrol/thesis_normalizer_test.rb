require "test_helper"
require "json_schemer"
require "hive/refactor_patrol/thesis_normalizer"
require_relative "thesis_fixtures"

class RefactorPatrolThesisNormalizerTest < Minitest::Test
  include HiveTestHelper
  include RefactorPatrolThesisFixtures

  def test_non_hash_raw_returns_nil
    assert_nil normalize(nil)
    assert_nil normalize("not a thesis")
  end

  def test_missing_file_or_measurable_signal_marks_inadmissible_but_returns
    thesis = normalize(valid_raw_thesis.merge("evidence" => [ { "file" => "lib/checkout.rb", "snippet" => "messy" } ]))

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing measurable signal"
    assert_includes thesis.risk.fetch("flags"), "inadmissible"
  end

  def test_evidence_without_file_is_flagged_inadmissible_not_dropped
    thesis = normalize(valid_raw_thesis.merge("evidence" => [ { "signal" => "churn", "value" => 10 } ]))

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing concrete file path"
    assert_includes thesis.risk.fetch("flags"), "inadmissible"
  end

  def test_evidence_less_thesis_is_retained_as_inadmissible
    thesis = normalize(valid_raw_thesis.merge("evidence" => []))

    refute thesis.admissible
    assert_equal [ { "snippet" => "no evidence supplied; retained as inadmissible" } ], thesis.evidence
  end

  # The evidence drift shapes the first dogfood run actually produced:
  # plural "files" + "claim" prose, a named signal without a value, and the
  # "refactor"/"characterization_notes"/object-"feature" aliases.
  def test_dogfood_evidence_drift_is_repaired_and_accepted
    raw = valid_raw_thesis
    raw.delete("proposed_refactor")
    raw = raw.merge(
      "feature" => { "id" => "checkout", "kind" => "command" },
      "refactor" => "Extract the shared prelude",
      "evidence" => [
        { "claim" => "byte-identical constants", "files" => [ "lib/checkout.rb", "lib/billing.rb" ], "signal" => "churn" },
        { "claim" => "dead copy drift", "files" => [ "lib/checkout.rb" ], "signal" => "repeated_dependency" }
      ],
      "required_validation" => { "commands" => [ "test" ], "characterization_first" => true, "characterization_notes" => "pin behavior first" }
    )
    thesis = normalize(raw)

    assert thesis.admissible, thesis.admissibility_reason
    assert_equal "checkout", thesis.feature
    assert_equal "Extract the shared prelude", thesis.proposed_refactor
    assert_equal [ "lib/checkout.rb", "lib/billing.rb", "lib/checkout.rb" ], thesis.evidence.map { |e| e["file"] }
    assert_equal 10, thesis.evidence.first["value"] # backfilled from measured churn
    refute thesis.evidence.last.key?("value") # repeated_dependency is not measured here
    assert_equal "pin behavior first", thesis.required_validation.fetch("notes")
    assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
  end

  def test_fileless_evidence_naming_owned_file_in_text_is_anchored
    raw = valid_raw_thesis.merge(
      "evidence" => [ { "snippet" => "lib/checkout.rb:42 duplicates the retry loop", "signal" => "churn", "value" => 10 } ]
    )
    thesis = normalize(raw)

    assert thesis.admissible, thesis.admissibility_reason
    assert_equal "lib/checkout.rb", thesis.evidence.first["file"]
  end

  def test_agent_supplied_score_does_not_override_measured_leverage
    raw = valid_raw_thesis.merge("expected_leverage" => { "score" => 999.0, "breakdown" => { "bogus" => 999.0 } })
    thesis = normalize(raw)

    assert_in_delta 0.8, thesis.expected_leverage.fetch("score"), 0.0001
    assert_equal({ "churn" => 0.5, "fan_in" => 0.3 }, thesis.expected_leverage.fetch("breakdown"))
  end

  def test_breakdown_less_thesis_returns_invalid_with_schema_errors
    result = normalize(valid_raw_thesis, leverage: {})

    assert_instance_of Hive::RefactorPatrol::ThesisNormalizer::Invalid, result
    refute_empty result.errors
  end

  def test_slice_without_tests_prescribes_characterization_and_lowers_high_confidence
    raw = valid_raw_thesis.merge(
      "confidence" => "high",
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw, feature: feature(tests: []))

    assert_equal true, thesis.required_validation.fetch("characterization_first")
    assert_includes thesis.required_validation.fetch("notes"), "Add characterization tests"
    assert_equal "medium", thesis.confidence
  end

  def test_test_rich_slice_with_empty_commands_gets_configured_test_command
    raw = valid_raw_thesis.merge(
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw)

    assert_equal [ "test" ], thesis.required_validation.fetch("commands")
    refute thesis.required_validation.fetch("characterization_first")
  end

  def test_test_rich_slice_without_known_test_command_requires_characterization
    raw = valid_raw_thesis.merge(
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw, commands: {})

    assert_equal true, thesis.required_validation.fetch("characterization_first")
    assert_includes thesis.required_validation.fetch("notes"), "Name explicit validation commands"
  end

  private

  def normalize(raw, feature: self.feature(tests: [ "test/checkout_test.rb" ]), leverage: feature_leverage, commands: { "test" => "rake test" })
    with_tmp_dir do |dir|
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(project_root: dir, commands: commands)
      return normalizer.call(feature: feature, leverage: leverage, raw: raw, index: 0)
    end
  end
end
