require "test_helper"
require "digest"
require "hive/refactor_patrol/semantic_family"

class RefactorPatrolSemanticFamilyTest < Minitest::Test
  SemanticFamily = Hive::RefactorPatrol::SemanticFamily

  def test_descriptor_normalization_and_id_are_canonical
    left = descriptor(
      repository: " Acme/Demo ",
      component: " CLI\\Wrapper ",
      anchors: [ "./bin/hive-e2e", "bin//hive", "bin/hive" ],
      concepts: [ "JSON argv", "wrapper-contract", "argv" ]
    )
    right = descriptor(
      repository: "acme/demo",
      component: "cli/wrapper",
      anchors: [ "bin/hive", "bin/hive-e2e" ],
      concepts: %w[argv contract json wrapper]
    )

    assert_equal right, left
    assert_equal %w[bin/hive bin/hive-e2e], left.fetch("anchors")
    assert_equal %w[argv contract json wrapper], left.fetch("concepts")
    assert left.frozen?
    assert left.fetch("anchors").frozen?
    assert_match(/\Aaf1-[0-9a-f]{64}\z/, SemanticFamily.id_for(left))
    assert_equal SemanticFamily.id_for(right), SemanticFamily.id_for(left)
  end

  def test_evidence_order_does_not_change_new_family_id
    first = dry_run_descriptor(672)
    reordered = descriptor(
      problem_kind: first.fetch("problem_kind"),
      refactor_kind: first.fetch("refactor_kind"),
      anchors: first.fetch("anchors").reverse,
      concepts: first.fetch("concepts").reverse
    )

    assert_equal first, reordered
    assert_equal SemanticFamily.id_for(first), SemanticFamily.id_for(reordered)
  end

  def test_problem_and_refactor_kinds_are_controlled
    assert_includes SemanticFamily::PROBLEM_KINDS, "mixed_responsibilities"
    assert_includes SemanticFamily::PROBLEM_KINDS, "scattered_contract"
    assert_includes SemanticFamily::REFACTOR_KINDS, "extract_boundary"
    assert_includes SemanticFamily::REFACTOR_KINDS, "consolidate_contract"

    problem_error = assert_raises(ArgumentError) { descriptor(problem_kind: "ruby_god_object") }
    refactor_error = assert_raises(ArgumentError) { descriptor(refactor_kind: "extract_ruby_module") }

    assert_includes problem_error.message, "problem_kind"
    assert_includes refactor_error.message, "refactor_kind"
  end

  def test_occurrence_fingerprint_alias_takes_precedence_over_hint_and_structure
    aliased = family(
      "af1-imported",
      wrapper_descriptor(668),
      occurrence_fingerprints: [ "legacy-fingerprint" ]
    )
    incompatible_hint = family("af1-other", dry_run_descriptor(672))
    candidate = descriptor(
      component: "totally/different",
      problem_kind: "cyclic_dependency",
      refactor_kind: "invert_dependency",
      anchors: [ "src/cycle.go" ],
      concepts: %w[dependency cycle inversion]
    )

    result = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ incompatible_hint, aliased ],
      occurrence_fingerprint: "legacy-fingerprint",
      hinted_family_id: "af1-other"
    )

    assert_equal "matched", result.status
    assert_equal "af1-imported", result.family_id
    assert_equal "occurrence_fingerprint_alias", result.reason
  end

  def test_compatible_exact_hint_resolves_an_otherwise_ambiguous_match
    candidate = dry_run_descriptor(692)
    first = family("af1-first", dry_run_descriptor(672))
    second = family("af1-second", dry_run_descriptor(708))

    ambiguous = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ second, first ],
      occurrence_fingerprint: "fp-692"
    )
    hinted = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ second, first ],
      occurrence_fingerprint: "fp-692",
      hinted_family_id: "af1-second"
    )

    assert_equal "family_ambiguous", ambiguous.status
    assert_equal %w[af1-first af1-second], ambiguous.matched_family_ids
    assert_equal "matched", hinted.status
    assert_equal "af1-second", hinted.family_id
    assert_equal "compatible_family_hint", hinted.reason
  end

  def test_unknown_or_incompatible_exact_hint_fails_closed
    candidate = wrapper_descriptor(707)
    wrapper = family("af1-wrapper", wrapper_descriptor(668))
    dry_run = family("af1-dry-run", dry_run_descriptor(672))

    unknown = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ wrapper ],
      occurrence_fingerprint: "fp-707",
      hinted_family_id: "af1-missing"
    )
    incompatible = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ wrapper, dry_run ],
      occurrence_fingerprint: "fp-707",
      hinted_family_id: "af1-dry-run"
    )

    assert_equal "family_ambiguous", unknown.status
    assert_equal "unknown_family_hint", unknown.reason
    assert_equal "family_ambiguous", incompatible.status
    assert_equal "incompatible_family_hint", incompatible.reason
    assert_equal [ "af1-dry-run" ], incompatible.matched_family_ids
  end

  def test_audited_dry_run_issues_672_692_and_708_are_one_family
    canonical = family(
      SemanticFamily.id_for(dry_run_descriptor(672)),
      dry_run_descriptor(672),
      occurrence_fingerprints: [ "fp-672" ]
    )

    [ 692, 708 ].each do |number|
      result = SemanticFamily.resolve(
        descriptor: dry_run_descriptor(number),
        families: [ canonical ],
        occurrence_fingerprint: "fp-#{number}"
      )

      assert_equal "matched", result.status, "issue ##{number} should reuse issue #672's family"
      assert_equal canonical.fetch("family_id"), result.family_id
      assert_equal "structural_match", result.reason
    end
  end

  def test_audited_wrapper_issues_668_and_707_are_one_family
    canonical = family(
      SemanticFamily.id_for(wrapper_descriptor(668)),
      wrapper_descriptor(668),
      occurrence_fingerprints: [ "fp-668" ]
    )
    result = SemanticFamily.resolve(
      descriptor: wrapper_descriptor(707),
      families: [ canonical ],
      occurrence_fingerprint: "fp-707"
    )

    assert_equal "matched", result.status
    assert_equal canonical.fetch("family_id"), result.family_id
  end

  def test_audited_dry_run_and_wrapper_families_remain_distinct
    dry_run = family(SemanticFamily.id_for(dry_run_descriptor(672)), dry_run_descriptor(672))
    wrapper = family(SemanticFamily.id_for(wrapper_descriptor(668)), wrapper_descriptor(668))

    dry_run_result = SemanticFamily.resolve(
      descriptor: dry_run_descriptor(708),
      families: [ wrapper, dry_run ],
      occurrence_fingerprint: "fp-708"
    )
    wrapper_result = SemanticFamily.resolve(
      descriptor: wrapper_descriptor(707),
      families: [ dry_run, wrapper ],
      occurrence_fingerprint: "fp-707"
    )

    assert_equal dry_run.fetch("family_id"), dry_run_result.family_id
    assert_equal wrapper.fetch("family_id"), wrapper_result.family_id
    refute_equal dry_run_result.family_id, wrapper_result.family_id
  end

  def test_structural_thresholds_require_repo_component_kinds_anchors_and_concepts
    existing = family("af1-existing", descriptor(
      anchors: %w[src/a.rb src/b.ts src/c.py src/d.go],
      concepts: %w[policy classifier boundary side effect adapter runner seam orchestration]
    ))
    at_threshold = descriptor(
      anchors: %w[src/a.rb src/missing.rs],
      concepts: %w[policy classifier boundary alpha beta gamma delta epsilon]
    )
    low_anchor = descriptor(
      anchors: %w[src/a.rb src/x.rs src/y.rs],
      concepts: %w[policy classifier boundary side effect]
    )
    low_concepts = descriptor(
      anchors: %w[src/a.rb src/b.ts],
      concepts: %w[policy unrelated tokens]
    )

    assert_in_delta 0.5, SemanticFamily::MIN_ANCHOR_OVERLAP
    assert_in_delta 0.35, SemanticFamily::MIN_CONCEPT_OVERLAP
    assert SemanticFamily.compatible?(at_threshold, existing.fetch("descriptor")),
           "anchor overlap 0.5 and concept overlap 0.375 must pass"
    refute SemanticFamily.compatible?(low_anchor, existing.fetch("descriptor"))
    refute SemanticFamily.compatible?(low_concepts, existing.fetch("descriptor"))
    refute SemanticFamily.compatible?(
      at_threshold.merge("repository" => "acme/other"), existing.fetch("descriptor")
    )
    refute SemanticFamily.compatible?(
      at_threshold.merge("component" => "another/component"), existing.fetch("descriptor")
    )
    refute SemanticFamily.compatible?(
      at_threshold.merge("problem_kind" => "scattered_contract"), existing.fetch("descriptor")
    )
    refute SemanticFamily.compatible?(
      at_threshold.merge("refactor_kind" => "consolidate_contract"), existing.fetch("descriptor")
    )
  end

  def test_multiple_structural_matches_are_ambiguous_regardless_of_input_order
    candidate = dry_run_descriptor(692)
    first = family("af1-zeta", dry_run_descriptor(672))
    second = family("af1-alpha", dry_run_descriptor(708))

    left = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ first, second ],
      occurrence_fingerprint: "new"
    )
    right = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ second, first ],
      occurrence_fingerprint: "new"
    )

    assert_equal "family_ambiguous", left.status
    assert_equal %w[af1-alpha af1-zeta], left.matched_family_ids
    assert_equal left.to_h, right.to_h
  end

  def test_no_match_returns_a_stable_new_family_result
    existing = family("af1-existing", dry_run_descriptor(672))
    candidate = wrapper_descriptor(668)

    result = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ existing ],
      occurrence_fingerprint: "fp-668"
    )

    assert_equal "new_family", result.status
    assert_equal SemanticFamily.id_for(candidate), result.family_id
    assert_equal candidate, result.descriptor
    assert_empty result.matched_family_ids
    assert_equal "no_compatible_family", result.reason
  end

  def test_existing_family_id_and_descriptor_are_immutable
    existing = family("af1-imported-stable-id", dry_run_descriptor(672), occurrence_fingerprints: [ "old" ])
    before = Marshal.load(Marshal.dump(existing))
    candidate = dry_run_descriptor(692)

    result = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ existing ],
      occurrence_fingerprint: "new"
    )

    assert_equal "af1-imported-stable-id", result.family_id
    refute_equal SemanticFamily.id_for(candidate), result.family_id
    assert_equal before, existing
    assert_equal before.fetch("descriptor"), result.descriptor
  end

  def test_mixed_ruby_typescript_python_and_go_anchors_have_no_language_keying
    anchors = [
      "lib/checkout_policy.rb",
      "src/checkout-policy.ts",
      "checkout/policy.py",
      "internal/checkout/policy.go"
    ]
    canonical_descriptor = descriptor(anchors: anchors)
    canonical = family("af1-mixed-language", canonical_descriptor)

    anchors.each_with_index do |anchor, index|
      candidate = descriptor(
        anchors: [ anchor ],
        concepts: %w[policy classifier boundary side effect]
      )
      result = SemanticFamily.resolve(
        descriptor: candidate,
        families: [ canonical ],
        occurrence_fingerprint: "language-fp-#{index}"
      )

      assert_equal "matched", result.status, "#{anchor} should be treated as a generic anchor"
      assert_equal "af1-mixed-language", result.family_id
    end
  end

  def test_repository_identity_separates_otherwise_identical_families
    candidate = descriptor(repository: "other/demo")
    existing = family("af1-acme", descriptor(repository: "acme/demo"))

    result = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ existing ],
      occurrence_fingerprint: "same-shape-other-repo"
    )

    assert_equal "new_family", result.status
    refute_equal "af1-acme", result.family_id

    other_host = candidate.merge("host" => "github.corp.example")
    refute_equal SemanticFamily.id_for(candidate), SemanticFamily.id_for(other_host)
  end

  def test_duplicate_occurrence_aliases_fail_closed
    candidate = dry_run_descriptor(692)
    first = family("af1-first", dry_run_descriptor(672), occurrence_fingerprints: [ "same" ])
    second = family("af1-second", dry_run_descriptor(708), occurrence_fingerprints: [ "same" ])

    result = SemanticFamily.resolve(
      descriptor: candidate,
      families: [ first, second ],
      occurrence_fingerprint: "same"
    )

    assert_equal "family_ambiguous", result.status
    assert_equal "duplicate_occurrence_fingerprint_alias", result.reason
    assert_equal %w[af1-first af1-second], result.matched_family_ids
  end

  def test_descriptor_and_family_validation_fail_closed_for_malformed_shapes
    canonical = descriptor
    raw_without_host = canonical.reject { |key, _| key == "host" }
    symbolized = canonical.transform_keys(&:to_sym)

    assert_equal SemanticFamily.id_for(canonical), SemanticFamily.id_for(raw_without_host)
    assert_equal SemanticFamily.id_for(canonical), SemanticFamily.id_for(symbolized)
    assert_raises(ArgumentError) { SemanticFamily.id_for("not a descriptor") }
    assert_raises(ArgumentError) { SemanticFamily.id_for(canonical.merge("unknown" => true)) }
    assert_raises(ArgumentError) { SemanticFamily.id_for(canonical.reject { |key, _| key == "repository" }) }
    assert_raises(ArgumentError) { SemanticFamily.id_for(canonical.merge("host" => "[")) }
    assert_raises(ArgumentError) { SemanticFamily.id_for(canonical.merge("anchors" => [ "../escape" ])) }
    assert_raises(ArgumentError) do
      SemanticFamily.resolve(descriptor: canonical, families: [ "bad" ], occurrence_fingerprint: "fp")
    end
    assert_raises(ArgumentError) do
      SemanticFamily.resolve(
        descriptor: canonical,
        families: [ { "family_id" => "af1-incomplete" } ],
        occurrence_fingerprint: "fp"
      )
    end
  end

  private

  def descriptor(repository: "acme/demo", component: "command/bin-hive",
                 problem_kind: "mixed_responsibilities", refactor_kind: "extract_boundary",
                 anchors: %w[bin/hive-babysitter-stub-gh bin/hive-babysitter-stub-git],
                 concepts: %w[babysitter dry run policy classifier exec boundary])
    SemanticFamily.descriptor(
      repository: repository,
      component: component,
      problem_kind: problem_kind,
      refactor_kind: refactor_kind,
      anchors: anchors,
      concepts: concepts
    )
  end

  def family(id, item, occurrence_fingerprints: [])
    SemanticFamily.family(
      family_id: id,
      descriptor: item,
      occurrence_fingerprints: occurrence_fingerprints
    )
  end

  def dry_run_descriptor(issue)
    case issue
    when 672
      descriptor(
        anchors: %w[bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh],
        concepts: %w[babysitter git gh dry run allowlist policy classifier environment exec stub boundary]
      )
    when 692
      descriptor(
        anchors: %w[bin/hive-babysitter-stub-gh bin/hive-babysitter-stub-git lib/hive/babysitter/dry_run_env.rb],
        concepts: %w[babysitter dry run git gh safety classifier policy environment exec gate adapter]
      )
    when 708
      descriptor(
        anchors: %w[bin/hive-babysitter-stub-gh bin/hive-babysitter-stub-git],
        concepts: %w[babysitter git gh dry run allowlist classification policy side effect exec runner boundary]
      )
    else
      raise ArgumentError, "unknown dry-run issue #{issue}"
    end
  end

  def wrapper_descriptor(issue)
    case issue
    when 668
      descriptor(
        problem_kind: "scattered_contract",
        refactor_kind: "consolidate_contract",
        anchors: [ "bin/hive" ],
        concepts: %w[cli wrapper argv normalization help encoding json usage error contract dispatch]
      )
    when 707
      descriptor(
        problem_kind: "scattered_contract",
        refactor_kind: "consolidate_contract",
        anchors: %w[bin/hive bin/hive-e2e],
        concepts: %w[cli pre dispatch argument argv grammar json help encoding version shared contract]
      )
    else
      raise ArgumentError, "unknown wrapper issue #{issue}"
    end
  end
end
