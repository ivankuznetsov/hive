require "test_helper"
require "hive/patrol/candidate_selector"
require "hive/patrol/finding"

class HivePatrolCandidateSelectorTest < Minitest::Test
  def finding(id:, feature_id: "feature-#{id}", **overrides)
    attributes = {
      id: id,
      feature_id: feature_id,
      category: "bug",
      severity: "high",
      confidence: "high",
      title: "Queued work is lost after dispatch failure #{id}",
      description: "A failed dispatch permanently suppresses queued work.",
      recommendation: "Release the claim when dispatch does not start.",
      evidence: [
        { "file" => "lib/#{id}/dispatcher.rb", "line" => 12, "snippet" => "pending[id] = true" },
        { "file" => "lib/#{id}/scheduler.rb", "line" => 31, "snippet" => "next if pending?(id)" }
      ],
      fingerprint: "fp-#{id}",
      scope: "cross_feature",
      contract: "Every queued item remains dispatchable after a failed attempt.",
      impact: "All later work for the affected project is silently skipped.",
      root_cause: "The pending claim is not released when dispatch is gated.",
      reproduction: "Gate the first dispatch and tick twice; the second tick never dispatches.",
      validation: "A regression test fails before the fix and passes after it.",
      alpha_score: nil
    }.merge(overrides)
    Hive::Patrol::Finding.new(**attributes)
  end

  def selector(cfg: {}, fingerprints: {}, dismissed: {})
    Hive::Patrol::CandidateSelector.new(
      cfg: { "patrol" => cfg },
      fingerprints: fingerprints,
      dismissed: dismissed
    )
  end

  def skipped_reason(skipped, id)
    skipped.find { |entry| entry["finding_id"] == id }&.fetch("reason")
  end

  def test_ranks_high_value_findings_globally
    broad_security = finding(
      id: "security",
      category: "security",
      severity: "critical",
      title: "Unauthenticated request exposes all project secrets"
    )
    bounded_bug = finding(id: "bug", scope: "feature")

    candidates, skipped = selector.call([ bounded_bug, broad_security ])

    assert_empty skipped
    assert_equal %w[security bug], candidates.map(&:id)
    assert_operator broad_security.alpha_score, :>, bounded_bug.alpha_score
    assert_includes 0..100, broad_security.alpha_score
    assert_includes 0..100, bounded_bug.alpha_score
  end

  def test_skips_findings_below_the_default_alpha_threshold
    weak = finding(
      id: "weak",
      category: "performance",
      severity: "medium",
      confidence: "medium",
      scope: "local",
      contract: nil,
      impact: nil,
      root_cause: nil,
      reproduction: nil,
      validation: "Run the existing suite.",
      evidence: [ { "file" => "lib/cache.rb", "line" => 4 } ]
    )

    candidates, skipped = selector.call([ weak ])

    assert_empty candidates
    assert_equal "low_alpha", skipped_reason(skipped, "weak")
    assert_operator weak.alpha_score, :<, 70
  end

  def test_skips_non_production_categories
    docs = finding(id: "docs", category: "documentation")
    maintainability = finding(id: "cleanup", category: "maintainability")

    candidates, skipped = selector.call([ docs, maintainability ])

    assert_empty candidates
    assert_equal "non_production", skipped_reason(skipped, "docs")
    assert_equal "non_production", skipped_reason(skipped, "cleanup")
  end

  def test_keeps_highest_scoring_semantic_duplicate_across_features
    winner = finding(
      id: "winner",
      feature_id: "scheduler",
      severity: "critical",
      title: "Pending claim prevents every later dispatch",
      root_cause: "A pending claim remains after a dispatch gate",
      evidence: [ { "file" => "lib/dispatch.rb", "line" => 10 } ]
    )
    duplicate = finding(
      id: "duplicate",
      feature_id: "daemon",
      severity: "high",
      title: "Pending claim prevents later dispatch attempts",
      root_cause: "The pending claim remains after dispatch is gated",
      evidence: [ { "file" => "lib/daemon.rb", "line" => 20 } ]
    )

    candidates, skipped = selector.call([ duplicate, winner ])

    assert_equal [ "winner" ], candidates.map(&:id)
    assert_equal "duplicate_in_run", skipped_reason(skipped, "duplicate")
  end

  def test_does_not_collapse_unrelated_root_causes_that_share_a_file
    scheduler = finding(
      id: "scheduler",
      feature_id: "scheduler-entrypoint",
      title: "Rejected launch leaves the queue permanently claimed",
      root_cause: "The scheduler lease is not released after launch rejection",
      evidence: [ { "file" => "lib/runtime.rb", "line" => 10 } ]
    )
    parser = finding(
      id: "parser",
      feature_id: "parser-entrypoint",
      title: "Truncated payload is accepted as a complete record",
      root_cause: "The parser treats end of file as a valid record terminator",
      evidence: [ { "file" => "lib/runtime.rb", "line" => 90 } ]
    )

    candidates, skipped = selector.call([ parser, scheduler ])

    assert_empty skipped
    assert_equal %w[parser scheduler], candidates.map(&:id).sort
  end

  def test_caps_fixes_per_feature_after_global_ranking
    better = finding(id: "better", feature_id: "daemon", severity: "critical")
    lower = finding(
      id: "lower",
      feature_id: "daemon",
      title: "Timeout drops a completed child status",
      root_cause: "The watcher clears status before persisting it",
      evidence: [ { "file" => "lib/watcher.rb", "line" => 8 } ]
    )

    candidates, skipped = selector.call([ lower, better ])

    assert_equal [ "better" ], candidates.map(&:id)
    assert_equal "feature_limit", skipped_reason(skipped, "lower")
  end

  def test_feature_limit_above_one_keeps_only_distinct_root_causes
    winner = finding(
      id: "winner",
      feature_id: "daemon",
      severity: "critical",
      title: "Pending lease prevents every later dispatch",
      root_cause: "The pending lease remains after a dispatch gate"
    )
    duplicate = finding(
      id: "duplicate",
      feature_id: "daemon",
      title: "Pending lease prevents later dispatch attempts",
      root_cause: "A pending lease remains when dispatch is gated"
    )
    distinct = finding(
      id: "distinct",
      feature_id: "daemon",
      title: "Truncated payload is accepted as a complete record",
      root_cause: "The parser treats end of file as a valid record terminator",
      evidence: [ { "file" => "lib/parser.rb", "line" => 90 } ]
    )

    candidates, skipped = selector(
      cfg: { "max_fixes_per_feature_per_cycle" => 2 }
    ).call([ duplicate, distinct, winner ])

    assert_equal %w[winner distinct], candidates.map(&:id)
    assert_equal "duplicate_in_run", skipped_reason(skipped, "duplicate")
  end

  def test_blocks_feature_with_an_existing_open_patrol_branch
    fingerprints = {
      "old-fp" => {
        "state" => "open",
        "branch" => "hive-patrol/route-users-deadbeef"
      }
    }
    candidate = finding(id: "new", feature_id: "route-users")

    candidates, skipped = selector(fingerprints: fingerprints).call([ candidate ])

    assert_empty candidates
    assert_equal "active_feature", skipped_reason(skipped, "new")
  end

  def test_blocks_grouped_manifest_for_an_open_legacy_script_slice
    fingerprints = {
      "old-fp" => {
        "state" => "open",
        "branch" => "hive-patrol/command-npm-script-test-deadbeef"
      }
    }
    candidate = finding(
      id: "scripts",
      feature_id: "command-package-json-scripts",
      evidence: [ { "file" => "package.json", "line" => 8 } ]
    )

    candidates, skipped = selector(fingerprints: fingerprints).call([ candidate ])

    assert_empty candidates
    assert_equal "active_feature", skipped_reason(skipped, "scripts")
  end

  def test_legacy_route_and_package_slices_match_only_their_current_component
    fingerprints = {
      "route-fp" => {
        "state" => "open",
        "branch" => "hive-patrol/route-pages-users-tsx-deadbeef"
      },
      "package-fp" => {
        "state" => "open",
        "feature_id" => "package-gemfile"
      }
    }
    route = finding(
      id: "route",
      feature_id: "architecture-pages",
      evidence: [ { "file" => "pages/users.tsx", "line" => 9 } ]
    )
    package = finding(
      id: "package",
      feature_id: "architecture-manifest-project",
      evidence: [ { "file" => "Gemfile", "line" => 4 } ]
    )
    unrelated = finding(
      id: "unrelated",
      feature_id: "architecture-services-billing",
      evidence: [ { "file" => "services/billing/charge.rb", "line" => 4 } ]
    )

    candidates, skipped = selector(fingerprints: fingerprints).call([ route, package, unrelated ])

    assert_equal [ "unrelated" ], candidates.map(&:id)
    assert_equal "active_feature", skipped_reason(skipped, "route")
    assert_equal "active_feature", skipped_reason(skipped, "package")
  end

  def test_penalizes_only_prior_dismissed_work_on_the_same_feature
    fresh = finding(id: "fresh", feature_id: "busy-feature")
    fresh_candidates, = selector(cfg: { "min_alpha_to_fix" => 80 }).call([ fresh ])

    history = {
      "merged-fp" => { "state" => "merged", "feature_id" => "busy-feature" },
      "closed-fp" => { "state" => "dismissed", "feature_id" => "busy-feature" }
    }
    dismissed = {
      "dismissed-fp" => { "branch" => "hive-patrol/busy-feature-cafebabe" }
    }
    repeated = finding(id: "repeated", feature_id: "busy-feature")
    repeated_candidates, skipped = selector(
      cfg: { "min_alpha_to_fix" => 80 },
      fingerprints: history,
      dismissed: dismissed
    ).call([ repeated ])

    assert_equal [ "fresh" ], fresh_candidates.map(&:id)
    assert_empty repeated_candidates
    assert_equal "low_alpha", skipped_reason(skipped, "repeated")
    assert_operator repeated.alpha_score, :<, fresh.alpha_score
  end

  def test_merged_history_does_not_starve_a_successful_feature
    without_history = finding(id: "without", feature_id: "busy-feature")
    with_history = finding(id: "with", feature_id: "busy-feature")
    history = {
      "merged-one" => { "state" => "merged", "feature_id" => "busy-feature" },
      "merged-two" => { "state" => "merged", "feature_id" => "busy-feature" }
    }

    selector(cfg: { "min_alpha_to_fix" => 100 }).call([ without_history ])
    selector(cfg: { "min_alpha_to_fix" => 100 }, fingerprints: history).call([ with_history ])

    assert_equal without_history.alpha_score, with_history.alpha_score
  end

  def test_legacy_dismissal_history_penalizes_the_current_component
    current = finding(
      id: "current",
      feature_id: "architecture-pages",
      evidence: [ { "file" => "pages/users.tsx", "line" => 9 } ]
    )
    dismissed = {
      "old-one" => { "feature_id" => "route-pages-users-tsx" },
      "old-two" => { "branch" => "hive-patrol/route-pages-users-tsx-cafebabe" }
    }

    candidates, skipped = selector(
      cfg: { "min_alpha_to_fix" => 80 },
      dismissed: dismissed
    ).call([ current ])

    assert_empty candidates
    assert_equal "low_alpha", skipped_reason(skipped, "current")
    assert_equal 55, current.alpha_score
  end

  def test_scores_explicit_scope_and_evidence_breadth
    local = finding(id: "local", scope: "local", evidence: [])
    broad_evidence = finding(
      id: "broad",
      scope: "system",
      evidence: [
        { "file" => "lib/a.rb", "line" => 1 },
        { "file" => "lib/b.rb", "line" => 2 },
        { "file" => "lib/c.rb", "line" => 3 }
      ]
    )

    selector(cfg: { "min_alpha_to_fix" => 100 }).call([ local ])
    selector(cfg: { "min_alpha_to_fix" => 100 }).call([ broad_evidence ])

    assert_equal 12, broad_evidence.alpha_score - local.alpha_score
  end

  def test_missing_structured_proof_fails_the_defensive_alpha_gate
    complete = finding(id: "complete")
    incomplete = finding(
      id: "incomplete",
      contract: nil,
      impact: nil,
      root_cause: nil,
      reproduction: nil,
      validation: nil
    )

    selector(cfg: { "min_alpha_to_fix" => 100 }).call([ complete ])
    selector(cfg: { "min_alpha_to_fix" => 100 }).call([ incomplete ])

    assert_equal 60, complete.alpha_score - incomplete.alpha_score
    assert_operator incomplete.alpha_score, :<, 70
  end

  def test_invalid_numeric_config_uses_safe_defaults
    first = finding(id: "first", feature_id: "shared")
    second = finding(
      id: "second",
      feature_id: "shared",
      title: "Worker timeout leaves a stale result",
      root_cause: "The result is cleared before timeout recovery",
      evidence: [ { "file" => "lib/result.rb", "line" => 3 } ]
    )

    candidates, skipped = selector(
      cfg: {
        "min_alpha_to_fix" => "invalid",
        "max_fixes_per_feature_per_cycle" => "invalid"
      }
    ).call([ second, first ])

    assert_equal [ "first" ], candidates.map(&:id)
    assert_equal "feature_limit", skipped_reason(skipped, "second")
  end

  def test_indexes_similarity_and_history_ledgers_before_scoring_findings
    fingerprints = {
      "known" => {
        "state" => "merged",
        "category" => "bug",
        "feature_id" => "busy",
        "title_tokens" => %w[queue loses pending work]
      }
    }
    dismissed = {
      "dismissed" => {
        "feature_id" => "busy",
        "category" => "security",
        "title_tokens" => %w[unrelated security issue]
      }
    }
    indexed_selector = Hive::Patrol::CandidateSelector.new(
      cfg: { "patrol" => { "min_alpha_to_fix" => 70 } },
      fingerprints: fingerprints,
      dismissed: dismissed
    )
    [ fingerprints, dismissed ].each do |ledger|
      ledger.define_singleton_method(:each) { raise "ledger rescanned" }
      ledger.define_singleton_method(:each_value) { raise "ledger rescanned" }
      ledger.define_singleton_method(:values) { raise "ledger rescanned" }
    end
    similar = finding(id: "similar", title: "Queue loses pending work during retry")
    busy = finding(
      id: "busy",
      feature_id: "busy",
      title: "Worker clears a completed result before delivery",
      root_cause: "The result slot is erased before its consumer acknowledges delivery"
    )

    candidates, skipped = indexed_selector.call([ similar, busy ])

    assert_equal "similar_to_existing", skipped_reason(skipped, "similar")
    assert_nil skipped_reason(skipped, "busy")
    assert_equal [ "busy" ], candidates.map(&:id)
  end

  def test_uses_a_deterministic_tie_breaker_independent_of_input_order
    alpha = finding(
      id: "alpha",
      feature_id: "a",
      title: "Alpha queue loses state",
      root_cause: "The queue erases its checkpoint after acknowledgment"
    )
    beta = finding(
      id: "beta",
      feature_id: "b",
      title: "Beta parser loses state",
      root_cause: "The parser truncates its payload at end of file"
    )

    forward, = selector.call([ beta, alpha ])
    reverse, = selector.call([ alpha, beta ])

    assert_equal %w[alpha beta], forward.map(&:id)
    assert_equal forward.map(&:id), reverse.map(&:id)
  end

  def test_applies_existing_fingerprint_confidence_and_severity_gates
    exact = finding(id: "exact", fingerprint: "exact-fp")
    dismissed_exact = finding(id: "dismissed", fingerprint: "dismissed-fp")
    similar = finding(
      id: "similar",
      title: "Queue loses pending work during retry",
      root_cause: "A distinct cause"
    )
    low_confidence = finding(id: "uncertain", confidence: "low")
    low_severity = finding(id: "minor", severity: "low")
    fingerprints = {
      "exact-fp" => { "state" => "open" },
      "known" => {
        "state" => "merged",
        "category" => "bug",
        "title_tokens" => %w[queue loses pending work]
      }
    }

    candidates, skipped = selector(
      fingerprints: fingerprints,
      dismissed: { "dismissed-fp" => {} }
    ).call([ exact, dismissed_exact, similar, low_confidence, low_severity ])

    assert_empty candidates
    assert_equal "existing_pr", skipped_reason(skipped, "exact")
    assert_equal "dismissed", skipped_reason(skipped, "dismissed")
    assert_equal "similar_to_existing", skipped_reason(skipped, "similar")
    assert_equal "low_confidence", skipped_reason(skipped, "uncertain")
    assert_equal "low_severity", skipped_reason(skipped, "minor")
  end
end
