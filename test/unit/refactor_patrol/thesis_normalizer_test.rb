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
          feature: feature,
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
          feature: feature,
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
        feature: mapped_feature,
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
        feature: mapped_feature,
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
    assert_equal "fix", thesis.route
    assert_equal valid_raw_thesis.fetch("architecture_effects"), thesis.architecture_effects
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

  def test_numeric_leverage_output_is_ignored
    raw = valid_raw_thesis.merge(
      "expected_leverage" => { "score" => 999.0, "breakdown" => { "bogus" => 999.0 } }
    )
    thesis = normalize(raw)

    refute thesis.to_h.key?("expected_leverage")
    assert_equal "fix", thesis.route
  end

  def test_architecture_effects_are_trimmed_deduplicated_and_bounded
    raw = valid_raw_thesis.merge(
      "architecture_effects" => [ "  stable owner  ", "stable owner", *9.times.map { |i| "effect #{i}" } ]
    )
    thesis = normalize(raw)

    assert_equal 8, thesis.architecture_effects.size
    assert_equal "stable owner", thesis.architecture_effects.first
    assert thesis.admissible
  end

  def test_missing_architecture_effect_is_retained_and_forced_to_dismiss
    raw = valid_raw_thesis.merge("architecture_effects" => [])
    thesis = normalize(raw)

    refute thesis.admissible
    assert_includes thesis.admissibility_reason, "missing architecture effect"
    assert_includes thesis.risk.fetch("flags"), "invalid_architecture_effect"
    assert_equal "dismiss", thesis.route
    assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
  end

  def test_low_confidence_is_forced_to_dismiss
    thesis = normalize(valid_raw_thesis.merge("confidence" => "low"), min_confidence: "medium")

    assert thesis.admissible
    assert_equal "dismiss", thesis.route
    assert_includes thesis.route_reasons(min_confidence: "medium"), "below_min_confidence"
  end

  def test_raw_contract_impact_waits_for_caps_policy
    raw = valid_raw_thesis
    raw.fetch("risk")["public_api_impact"] = true
    thesis = normalize(raw)

    assert thesis.admissible
    assert_equal "fix", thesis.route
  end

  def test_reviewer_dismissal_is_not_promoted_by_nonfatal_risk
    raw = valid_raw_thesis.merge("route" => "dismiss")
    raw.fetch("risk")["public_api_impact"] = true
    thesis = normalize(raw)

    assert thesis.admissible
    assert_equal "dismiss", thesis.route
    assert_includes thesis.route_reasons, "reviewer_dismissed"
  end

  def test_invalid_reviewer_route_is_retained_as_a_dismissal
    thesis = normalize(valid_raw_thesis.merge("route" => "ship_it"))

    assert thesis.admissible
    assert_equal "dismiss", thesis.route
    assert_includes thesis.risk.fetch("flags"), "invalid_route"
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
    raw["risk"]["public_api_details"] = [ 1 ]
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

  def test_current_schema_strictly_rejects_signal_and_value_on_evidence
    thesis = normalize(valid_raw_thesis)
    payload = thesis.to_h
    payload.fetch("evidence").first["signal"] = "churn"
    payload.fetch("evidence").first["value"] = 10

    refute thesis_schemer.valid?(payload)
  end

  def test_current_thesis_omits_numerical_scoring_fields
    current = normalize(valid_raw_thesis).to_h
    refute current.dig("risk", "caps").key?("est_files")
    refute current.dig("risk", "caps").key?("est_diff_lines")
    refute current.key?("feature_hotspot")
    refute current.key?("expected_leverage")
    assert_equal "fix", current.fetch("route")
    refute_empty current.fetch("architecture_effects")
    assert thesis_schemer.valid?(current), thesis_schemer.validate(current).map { |error| error["error"] }.inspect
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
    assert_equal "discuss", thesis.route
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
    assert_equal "discuss", thesis.route
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

  def test_executable_documentation_format_without_configured_command_is_report_only
    raw = valid_raw_thesis.merge(
      "evidence" => [
        { "file" => "docs/guide.mdx", "line" => 3, "snippet" => "Setup", "claim" => "setup guidance is duplicated" }
      ],
      "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
    )
    thesis = normalize(
      raw,
      feature: documentation_feature(path: "docs/guide.mdx"),
      commands: { "test" => "rake test" }
    )

    assert thesis.admissible
    assert_includes thesis.risk.fetch("flags"), "missing_docs_validation"
    assert_empty thesis.required_validation.fetch("commands")
    assert_includes thesis.required_validation.fetch("notes"), "Configure an executable docs validation command"
  end

  private

  def normalize(raw, feature: self.feature(tests: [ "test/checkout_test.rb" ]),
                commands: { "test" => "rake test" }, min_confidence: "medium")
    with_tmp_dir do |dir|
      materialize_thesis_evidence(dir, raw_theses: [ raw ], feature: feature)
      normalizer = Hive::RefactorPatrol::ThesisNormalizer.new(
        project_root: dir, commands: commands, min_confidence: min_confidence
      )
      return normalizer.call(feature: feature, raw: raw, index: 0)
    end
  end

  def documentation_feature(path: "docs/guide.md")
    Hive::Patrol::Feature.new(
      id: "documentation-docs-root",
      kind: "documentation",
      entrypoints: [ path ],
      owned_files: [ path ],
      context_files: [ "README.md" ],
      tests: []
    )
  end
end
