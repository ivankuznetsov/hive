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

  def test_file_and_snippet_without_claim_marks_inadmissible_but_returns
    thesis = normalize(valid_raw_thesis.merge("evidence" => [ { "file" => "lib/checkout.rb", "snippet" => "messy" } ]))

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing coherent anchored claim"
    assert_includes thesis.risk.fetch("flags"), "inadmissible"
  end

  def test_hallucinated_snippet_and_out_of_range_line_are_unverified
    with_tmp_dir do |dir|
      path = File.join(dir, "lib", "checkout.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "def actual_behavior\nend\n")
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
        project_root: dir, commands: { "test" => "rake test" }
      )
      invalid_items = [
        { "file" => "lib/checkout.rb", "snippet" => "def invented_behavior", "claim" => "invented" },
        { "file" => "lib/checkout.rb", "line" => 99, "claim" => "line does not exist" },
        { "file" => "../outside.rb", "line" => 1, "claim" => "path escapes the repository" }
      ]

      invalid_items.each do |evidence|
        thesis = normalizer.call(
          feature: feature, leverage: feature_leverage,
          raw: valid_raw_thesis.merge("evidence" => [ evidence ]), index: 0
        )

        refute thesis.admissible, evidence.inspect
        assert_includes thesis.risk.fetch("flags"), "unverified_evidence", evidence.inspect
        assert_includes thesis.admissibility_reason, "unverified evidence anchor", evidence.inspect
      end
    end
  end

  def test_verified_line_or_exact_snippet_is_admissible
    with_tmp_dir do |dir|
      path = File.join(dir, "lib", "checkout.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "first\ndef charge_and_validate\n")
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
        project_root: dir, commands: { "test" => "rake test" }
      )

      [
        { "file" => "lib/checkout.rb", "line" => 2, "claim" => "the second line is present" },
        { "file" => "lib/checkout.rb", "snippet" => "def charge_and_validate", "claim" => "method is present" }
      ].each do |evidence|
        thesis = normalizer.call(
          feature: feature, leverage: feature_leverage,
          raw: valid_raw_thesis.merge("evidence" => [ evidence ]), index: 0
        )
        assert thesis.admissible, thesis.admissibility_reason
        refute_includes thesis.risk.fetch("flags"), "unverified_evidence"
      end
    end
  end

  def test_evidence_verification_is_bounded_for_sparse_oversize_sources
    with_tmp_dir do |dir|
      relative_path = "lib/oversize.flux"
      path = File.join(dir, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      cap = Hive::Patrol::SourceReader::MAX_SOURCE_BYTES
      File.open(path, "wb") do |file|
        file.write("inside-cap-anchor\n")
        file.seek(cap + 4096)
        file.write("beyond-cap-anchor\n")
      end
      assert_operator File.size(path), :>, cap

      mapped_feature = Hive::Patrol::Feature.new(
        id: "checkout", kind: "architecture",
        entrypoints: [ relative_path ], owned_files: [ relative_path ],
        context_files: [], tests: [ "test/checkout_test.rb" ]
      )
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
        project_root: dir, commands: { "test" => "rake test" }
      )
      raw = valid_raw_thesis

      inside = normalizer.call(
        feature: mapped_feature, leverage: feature_leverage,
        raw: raw.merge(
          "evidence" => [
            {
              "file" => relative_path, "snippet" => "inside-cap-anchor",
              "claim" => "the bounded prefix contains this anchor"
            }
          ]
        ),
        index: 0
      )
      assert inside.admissible, inside.admissibility_reason

      beyond = normalizer.call(
        feature: mapped_feature, leverage: feature_leverage,
        raw: raw.merge(
          "evidence" => [
            {
              "file" => relative_path, "snippet" => "beyond-cap-anchor",
              "claim" => "an anchor beyond the inspection cap must not be trusted"
            }
          ]
        ),
        index: 0
      )
      refute beyond.admissible
      assert_includes beyond.risk.fetch("flags"), "unverified_evidence"
      assert_includes beyond.admissibility_reason, "unverified evidence anchor"
    end
  end

  def test_evidence_reader_system_failure_is_treated_as_unverified
    reader = Object.new
    reader.define_singleton_method(:regular_file?) { |_path| raise Errno::EIO, "failed" }
    normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
      project_root: "/repo", commands: {}, source_reader: reader
    )

    assert_nil normalizer.send(:verified_evidence_content, "lib/source.rb")
  end

  def test_evidence_without_file_is_flagged_inadmissible_not_dropped
    thesis = normalize(
      valid_raw_thesis.merge(
        "evidence" => [ { "line" => 12, "snippet" => "messy", "claim" => "mixed responsibilities" } ]
      )
    )

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing coherent anchored claim"
    assert_includes thesis.risk.fetch("flags"), "inadmissible"
  end

  def test_evidence_less_thesis_is_retained_as_inadmissible
    thesis = normalize(valid_raw_thesis.merge("evidence" => []))

    refute thesis.admissible
    assert_equal [ { "claim" => "no evidence supplied; retained as inadmissible" } ], thesis.evidence
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
        {
          "claim" => "byte-identical constants",
          "snippet" => "RETRY_LIMIT = 3",
          "files" => [ "lib/checkout.rb", "lib/billing.rb" ],
          "signal" => "churn",
          "value" => 10
        },
        {
          "claim" => "dead copy drift",
          "line" => 27,
          "files" => [ "lib/checkout.rb" ],
          "signal" => "repeated_dependency",
          "value" => 2
        }
      ],
      "required_validation" => { "commands" => [ "test" ], "characterization_first" => true, "characterization_notes" => "pin behavior first" }
    )
    thesis = normalize(raw)

    assert thesis.admissible, thesis.admissibility_reason
    assert_equal "checkout", thesis.feature
    assert_equal "Extract the shared prelude", thesis.proposed_refactor
    assert_equal [ "lib/checkout.rb", "lib/billing.rb", "lib/checkout.rb" ], thesis.evidence.map { |e| e["file"] }
    thesis.evidence.each do |entry|
      refute entry.key?("signal")
      refute entry.key?("value")
    end
    assert_equal 10, thesis.feature_hotspot.dig("signals", "churn")
    assert_equal "feature", thesis.feature_hotspot.fetch("scope")
    assert_equal "pin behavior first", thesis.required_validation.fetch("notes")
    assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
  end

  def test_fileless_evidence_naming_owned_file_in_text_is_anchored
    raw = valid_raw_thesis.merge(
      "evidence" => [
        {
          "snippet" => "lib/checkout.rb:42 duplicates the retry loop",
          "claim" => "the retry loop is duplicated"
        }
      ]
    )
    thesis = normalize(raw)

    assert thesis.admissible, thesis.admissibility_reason
    assert_equal "lib/checkout.rb", thesis.evidence.first["file"]
  end

  def test_agent_supplied_score_is_ignored_and_proposal_score_is_derived_from_drivers
    raw = valid_raw_thesis
    raw["expected_leverage"] = raw.fetch("expected_leverage").merge(
      "score" => 999.0,
      "breakdown" => { "bogus" => 999.0 }
    )
    thesis = normalize(raw)

    assert_in_delta 0.4, thesis.expected_leverage.fetch("score"), 0.0001
    assert_equal({ "churn" => 0.25, "fan_in" => 0.15 }, thesis.expected_leverage.fetch("breakdown"))
    assert_equal 2, thesis.expected_leverage.fetch("drivers").size
  end

  def test_only_valid_unique_drivers_contribute_to_proposal_score
    raw = valid_raw_thesis
    raw["expected_leverage"] = {
      "drivers" => [
        "not a driver",
        { "signal" => "churn", "relief" => 0.5, "mechanism" => "first valid driver" },
        { "signal" => "churn", "relief" => 1.0, "mechanism" => "duplicate" },
        { "signal" => "fan_in", "relief" => 0.25, "mechanism" => "stable boundary" },
        { "signal" => "unknown", "relief" => 1.0, "mechanism" => "unknown signal" },
        { "signal" => "coupling", "relief" => 1.1, "mechanism" => "out of range" },
        { "signal" => "complexity", "relief" => 0.5, "mechanism" => "" }
      ]
    }
    thesis = normalize(raw)

    assert_equal %w[churn fan_in], thesis.expected_leverage.fetch("drivers").map { |driver| driver.fetch("signal") }
    assert_equal({ "churn" => 0.25, "fan_in" => 0.075 }, thesis.expected_leverage.fetch("breakdown"))
    assert_in_delta 0.325, thesis.expected_leverage.fetch("score"), 0.0001
    refute thesis.admissible
    assert_includes thesis.risk.fetch("flags"), "invalid_leverage_driver"
    assert_includes thesis.admissibility_reason, "invalid proposal leverage driver"
  end

  def test_missing_valid_driver_is_retained_and_flagged_inadmissible
    raw = valid_raw_thesis.merge("expected_leverage" => { "drivers" => [] })
    thesis = normalize(raw)

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing valid proposal leverage driver"
    assert_empty thesis.expected_leverage.fetch("drivers")
    assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
  end

  def test_measured_proposal_below_configured_leverage_floor_is_report_only
    thesis = normalize(valid_raw_thesis, min_leverage_score: 0.5)

    assert thesis.admissible
    assert_in_delta 0.4, thesis.expected_leverage.fetch("score"), 0.0001
    assert_includes thesis.risk.fetch("flags"), "below_min_leverage"
  end

  def test_incomplete_feature_measurement_is_retained_and_forces_report_only
    partial = feature_leverage.merge(
      "measurement" => {
        "status" => "incomplete",
        "diagnostics" => [
          {
            "kind" => "architecture_map_failed",
            "error_class" => "ParserUnavailable",
            "message" => "dependency graph measurement failed"
          }
        ]
      }
    )

    thesis = normalize(valid_raw_thesis, leverage: partial)

    refute thesis.admissible
    assert_includes thesis.risk.fetch("flags"), "incomplete_leverage_measurement"
    assert_includes thesis.admissibility_reason, "incomplete feature leverage measurement"
    assert_equal partial.fetch("measurement"), thesis.feature_hotspot.fetch("measurement")
    assert thesis_schemer.valid?(thesis.to_h),
           thesis_schemer.validate(thesis.to_h).map { |error| error["error"] }.inspect
  end

  def test_file_and_metric_in_separate_evidence_items_do_not_form_an_admissible_anchor
    raw = valid_raw_thesis.merge(
      "evidence" => [
        { "file" => "lib/checkout.rb" },
        { "signal" => "churn", "value" => 10 }
      ]
    )
    thesis = normalize(raw)

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing coherent anchored claim"
    thesis.evidence.each do |entry|
      refute entry.key?("signal")
      refute entry.key?("value")
    end
  end

  def test_agent_cannot_override_mapper_owned_feature_boundary
    raw = valid_raw_thesis.merge(
      "feature_boundary" => {
        "owned_files" => [ "lib/checkout.rb", "lib/unrelated.rb" ],
        "entrypoints" => [ "bin/other" ]
      }
    )

    thesis = normalize(raw)

    assert_equal [ "lib/checkout.rb" ], thesis.feature_boundary.fetch("owned_files")
    assert_equal [ "lib/checkout.rb" ], thesis.feature_boundary.fetch("entrypoints")
    assert_includes thesis.risk.fetch("flags"), "boundary_override_attempt"
  end

  def test_string_lines_are_normalized_and_other_line_types_are_discarded
    raw = valid_raw_thesis.merge(
      "evidence" => [
        { "file" => "lib/checkout.rb", "line" => "1", "claim" => "string line" },
        { "file" => "lib/checkout.rb", "line" => 1.5, "snippet" => "messy", "claim" => "float line" }
      ]
    )

    thesis = normalize(raw)

    assert_equal 1, thesis.evidence.first.fetch("line")
    refute thesis.evidence.last.key?("line")
  end

  def test_schema_invalid_normalization_returns_error_details
    raw = valid_raw_thesis
    raw["risk"]["caps"]["est_files"] = -1
    result = normalize(raw)

    assert_instance_of Hive::RefactorPatrol::ThesisNormalizer::Invalid, result
    refute_empty result.errors
  end

  # The thesis schema requires minLength 1 on the narrative fields, matching
  # the report envelope's ThesisSnapshot. A thesis missing `problem` must die
  # here as a recorded schema_invalid slice error, never reach disposition_item
  # as an empty string, and never poison the discovery envelope.
  def test_missing_or_empty_narrative_fields_are_rejected_at_the_normalizer
    %w[problem cost proposed_refactor].each do |field|
      [ nil, "" ].each do |value|
        raw = valid_raw_thesis
        value.nil? ? raw.delete(field) : raw[field] = value

        result = normalize(raw)

        assert_instance_of Hive::RefactorPatrol::ThesisNormalizer::Invalid, result,
                           "#{field}=#{value.inspect} must not normalize into an empty snapshot"
        assert result.errors.any? { |message| message.include?(field) },
               "#{field}: #{result.errors.inspect}"
      end
    end
  end

  def test_v2_schema_strictly_rejects_signal_and_value_on_evidence
    thesis = normalize(valid_raw_thesis)
    payload = thesis.to_h
    payload.fetch("evidence").first["signal"] = "churn"
    payload.fetch("evidence").first["value"] = 10

    refute thesis_schemer.valid?(payload)
    assert_equal 2, Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol-thesis")
  end

  def test_slice_without_tests_prescribes_characterization_and_lowers_high_confidence
    raw = valid_raw_thesis.merge(
      "confidence" => "high",
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw, feature: feature(tests: []))

    assert_equal true, thesis.required_validation.fetch("characterization_first")
    assert_includes thesis.required_validation.fetch("notes"), "Add characterization tests"
    assert_includes thesis.risk.fetch("flags"), "missing_behavior_validation"
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
    assert_includes thesis.risk.fetch("flags"), "missing_behavior_validation"
    assert_includes thesis.required_validation.fetch("notes"), "Name explicit validation commands"
  end

  def test_documentation_thesis_without_configured_command_uses_built_in_validation
    raw = valid_raw_thesis.merge(
      "evidence" => [
        { "file" => "docs/guide.md", "line" => 3, "snippet" => "Setup", "claim" => "setup guidance is duplicated" }
      ],
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw, feature: documentation_feature, commands: { "test" => "rake test" })

    assert thesis.admissible
    refute_includes thesis.risk.fetch("flags"), "missing_docs_validation"
    assert_empty thesis.required_validation.fetch("commands")
    refute thesis.required_validation.fetch("characterization_first")
    assert_includes thesis.required_validation.fetch("notes"), "built-in documentation safety checks"
  end

  def test_documentation_thesis_uses_configured_docs_validation
    raw = valid_raw_thesis.merge(
      "evidence" => [
        { "file" => "docs/guide.md", "line" => 3, "snippet" => "Setup", "claim" => "setup guidance is duplicated" }
      ],
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(raw, feature: documentation_feature, commands: { "docs" => "markdownlint docs" })

    assert_equal [ "docs" ], thesis.required_validation.fetch("commands")
    refute_includes thesis.risk.fetch("flags"), "missing_docs_validation"
    refute thesis.required_validation.fetch("characterization_first")
  end

  private

  def normalize(raw, feature: self.feature(tests: [ "test/checkout_test.rb" ]), leverage: feature_leverage,
                commands: { "test" => "rake test" }, min_leverage_score: 0.0)
    with_tmp_dir do |dir|
      materialize_thesis_evidence(dir, raw_theses: [ raw ], feature: feature)
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
        project_root: dir, commands: commands, min_leverage_score: min_leverage_score
      )
      return normalizer.call(feature: feature, leverage: leverage, raw: raw, index: 0)
    end
  end

  def documentation_feature
    Hive::Patrol::Feature.new(
      id: "documentation-docs-root",
      kind: "documentation",
      entrypoints: [ "docs/guide.md" ],
      owned_files: [ "docs/guide.md" ],
      context_files: [ "README.md" ],
      tests: []
    )
  end
end
