require "test_helper"
require "json_schemer"
require "hive/refactor_patrol/reviewer"
require "hive/patrol/feature"

class RefactorPatrolReviewerTest < Minitest::Test
  include HiveTestHelper

  def test_valid_agent_json_returns_schema_valid_fingerprinted_thesis
    with_tmp_dir do |dir|
      reviewer = reviewer_for(dir, [ valid_raw_thesis ])
      theses = reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage)

      assert_empty reviewer.review_errors
      assert_equal 1, theses.size
      thesis = theses.first
      refute_empty thesis.fingerprint
      assert thesis.admissible
      assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
    end
  end

  def test_missing_file_or_measurable_signal_marks_inadmissible_but_returns
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge("evidence" => [ { "file" => "lib/checkout.rb", "snippet" => "messy" } ])
      theses = reviewer_for(dir, [ raw ]).call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage)

      assert_equal 1, theses.size
      refute theses.first.admissible
      assert_includes theses.first.admissibility_reason, "missing measurable signal"
      assert_includes theses.first.risk.fetch("flags"), "inadmissible"
    end
  end

  def test_slice_without_tests_prescribes_characterization_and_lowers_high_confidence
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge(
        "confidence" => "high",
        "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
      )
      thesis = reviewer_for(dir, [ raw ]).call([ feature(tests: []) ], leverage_by_feature: leverage).first

      assert_equal true, thesis.required_validation.fetch("characterization_first")
      assert_equal "medium", thesis.confidence
    end
  end

  # Replays the evidence shape the first dogfood run actually produced
  # (plural "files" + "claim" prose, named signal without a value, "refactor"
  # instead of "proposed_refactor", "feature" as an object): file-backed
  # substance must be accepted, not flagged for its spelling.
  def test_dogfood_shaped_file_backed_thesis_is_normalized_and_accepted
    with_tmp_dir do |dir|
      raw = valid_raw_thesis
      raw.delete("proposed_refactor")
      raw = raw.merge(
        "feature" => { "id" => "checkout", "kind" => "command" },
        "refactor" => "Extract the shared prelude into a required library file",
        "evidence" => [
          { "claim" => "byte-identical constants in both binaries", "files" => [ "lib/checkout.rb", "lib/billing.rb" ], "signal" => "churn" },
          { "claim" => "dead copy drift", "files" => [ "lib/checkout.rb" ], "signal" => "repeated_dependency" }
        ],
        "required_validation" => { "commands" => [ "test" ], "characterization_first" => true, "characterization_notes" => "pin argv behavior first" }
      )
      reviewer = reviewer_for(dir, [ raw ])
      theses = reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage)

      assert_empty reviewer.review_errors
      thesis = theses.first
      assert thesis.admissible, thesis.admissibility_reason
      assert_equal "checkout", thesis.feature
      assert_equal "Extract the shared prelude into a required library file", thesis.proposed_refactor
      assert_equal [ "lib/checkout.rb", "lib/billing.rb", "lib/checkout.rb" ], thesis.evidence.map { |e| e["file"] }
      assert_equal 10, thesis.evidence.first["value"] # backfilled from measured churn
      refute thesis.evidence.last.key?("value") # repeated_dependency is not a measured signal here
      assert_equal "pin argv behavior first", thesis.required_validation.fetch("notes")
      assert thesis_schemer.valid?(thesis.to_h), thesis_schemer.validate(thesis.to_h).map { |e| e["error"] }.inspect
    end
  end

  def test_fileless_evidence_naming_owned_file_in_text_is_anchored
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge(
        "evidence" => [ { "snippet" => "lib/checkout.rb:42 duplicates the retry loop", "signal" => "churn", "value" => 10 } ]
      )
      thesis = reviewer_for(dir, [ raw ]).call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage).first

      assert thesis.admissible, thesis.admissibility_reason
      assert_equal "lib/checkout.rb", thesis.evidence.first["file"]
    end
  end

  def test_evidence_without_file_is_flagged_inadmissible_not_dropped
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge("evidence" => [ { "signal" => "churn", "value" => 10 } ])
      reviewer = reviewer_for(dir, [ raw ])
      theses = reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage)

      assert_empty reviewer.review_errors
      assert_equal 1, theses.size
      refute theses.first.admissible
      assert_includes theses.first.admissibility_reason, "missing concrete file path"
      assert_includes theses.first.risk.fetch("flags"), "inadmissible"
    end
  end

  def test_test_rich_slice_with_empty_commands_gets_configured_test_command
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge(
        "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
      )
      thesis = reviewer_for(dir, [ raw ]).call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage).first

      assert_equal [ "test" ], thesis.required_validation.fetch("commands")
      refute thesis.required_validation.fetch("characterization_first")
    end
  end

  def test_agent_supplied_score_does_not_override_measured_leverage
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge("expected_leverage" => { "score" => 999.0, "breakdown" => { "bogus" => 999.0 } })
      thesis = reviewer_for(dir, [ raw ]).call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage).first

      assert_in_delta 0.8, thesis.expected_leverage.fetch("score"), 0.0001
      assert_equal({ "churn" => 0.5, "fan_in" => 0.3 }, thesis.expected_leverage.fetch("breakdown"))
    end
  end

  def test_dry_run_reviewer_does_not_write_theses_or_run_logs
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = lambda do |output_path:, **|
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, JSON.generate("theses" => [ valid_raw_thesis ]))
        {}
      end
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: state, agent_runner: runner, dry_run: true)

      theses = reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage)

      assert_equal 1, theses.size
      assert_empty Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "theses", "*.json"))
      assert_empty Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "runs", "*"))
    end
  end

  def test_malformed_json_records_review_error_and_continues
    with_tmp_dir do |dir|
      runner = lambda do |output_path:, **|
        File.write(output_path, "{")
        {}
      end
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), agent_runner: runner)

      assert_empty reviewer.call([ feature ], leverage_by_feature: leverage)
      assert_equal "malformed_json", reviewer.review_errors.first.fetch("error")
    end
  end

  def test_breakdown_less_thesis_fails_schema_validation_and_is_rejected
    with_tmp_dir do |dir|
      raw = valid_raw_thesis
      raw["expected_leverage"] = { "score" => 0.8, "breakdown" => {} }
      reviewer = reviewer_for(dir, [ raw ])

      assert_empty reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: {})
      assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error")
    end
  end

  def test_runner_error_records_agent_failure_message
    with_tmp_dir do |dir|
      runner = ->(**) { { status: :error, error_message: "agent stopped" } }
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), agent_runner: runner)

      assert_empty reviewer.call([ feature ], leverage_by_feature: leverage)
      assert_equal "agent_failed", reviewer.review_errors.first.fetch("error")
      assert_equal "agent stopped", reviewer.review_errors.first.fetch("message")
    end
  end

  def test_unexpected_runner_exception_records_review_error
    with_tmp_dir do |dir|
      runner = ->(**) { raise ArgumentError, "bad prompt" }
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), agent_runner: runner)

      assert_empty reviewer.call([ feature ], leverage_by_feature: leverage)
      assert_equal "review_error", reviewer.review_errors.first.fetch("error")
      assert_includes reviewer.review_errors.first.fetch("message"), "ArgumentError: bad prompt"
    end
  end

  def test_test_rich_slice_without_known_test_command_requires_characterization
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge(
        "required_validation" => { "commands" => [], "characterization_first" => false, "notes" => "" }
      )
      reviewer = reviewer_for(dir, [ raw ], cfg: cfg.merge("refactor_patrol" => cfg.fetch("refactor_patrol").merge("commands" => {})))

      thesis = reviewer.call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage).first

      assert_equal true, thesis.required_validation.fetch("characterization_first")
      assert_includes thesis.required_validation.fetch("notes"), "Name explicit validation commands"
    end
  end

  def test_evidence_less_thesis_is_retained_as_inadmissible
    with_tmp_dir do |dir|
      raw = valid_raw_thesis.merge("evidence" => [])

      thesis = reviewer_for(dir, [ raw ]).call([ feature(tests: [ "test/checkout_test.rb" ]) ], leverage_by_feature: leverage).first

      refute thesis.admissible
      assert_equal [ { "snippet" => "no evidence supplied; retained as inadmissible" } ],
                   thesis.evidence
    end
  end

  def test_non_dry_run_review_error_writes_run_log
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: state, agent_runner: ->(**) { raise "boom" })

      assert_empty reviewer.call([ feature ], leverage_by_feature: leverage)
      logs = Dir[File.join(state.root, "runs", "review-error-*.json")]

      assert_equal 1, logs.size
      assert_equal "review_error", JSON.parse(File.read(logs.first)).fetch("error")
    end
  end

  def test_run_agent_records_usage_and_profile_fallback
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: state)
      fake_profile = Object.new
      fake_agent = Class.new do
        def initialize(**); end

        def run!
          { usage: { model: "m", input: 1, output: 2, cached: 3 } }
        end
      end
      records = []

      original_lookup = Hive::AgentProfiles.method(:lookup)
      original_record = Hive::UsageDb.method(:record!)
      original_agent = Hive.const_get(:Agent)
      begin
        Hive::AgentProfiles.define_singleton_method(:lookup) { |*| fake_profile }
        Hive::UsageDb.define_singleton_method(:record!) { |**kwargs| records << kwargs }
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, fake_agent)
        reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: state.run_dir("review"))
      ensure
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, original_agent)
        Hive::AgentProfiles.define_singleton_method(:lookup, original_lookup)
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end

      assert_equal 1, records.size
      assert_equal "claude", records.first.fetch(:agent)
      assert_equal "refactor-patrol-review", records.first.fetch(:stage)
    end
  end

  def test_record_usage_warning_is_non_fatal
    with_tmp_dir do |dir|
      reviewer = Hive::RefactorPatrol::Reviewer.new(dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir))
      original_record = Hive::UsageDb.method(:record!)
      begin
        Hive::UsageDb.define_singleton_method(:record!) { |**_kwargs| raise "db down" }

        _out, err = capture_io do
          reviewer.send(:record_usage, { usage: { input: 1 } }, Struct.new(:name).new("claude"), "stage", Time.now.utc)
        end

        assert_includes err, "usage record failed"
      ensure
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end
    end
  end

  private

  def reviewer_for(dir, raw_theses, cfg: self.cfg)
    runner = lambda do |output_path:, **|
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, JSON.generate("theses" => raw_theses))
      {}
    end
    Hive::RefactorPatrol::Reviewer.new(
      dir,
      cfg: cfg,
      state: Hive::RefactorPatrol::StateStore.new(dir),
      agent_runner: runner
    )
  end

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

  def leverage
    {
      "checkout" => {
        "score" => 0.8,
        "breakdown" => { "churn" => 0.5, "fan_in" => 0.3 },
        "signals" => { "churn" => 10, "fan_in" => 4 }
      }
    }
  end

  def cfg
    {
      "budget_usd" => { "patrol" => 100 },
      "timeout_sec" => { "patrol" => 3600 },
      "refactor_patrol" => {
        "agent" => "claude",
        "max_theses_per_feature" => 3,
        "commands" => { "test" => "ruby -Itest test/foo_test.rb", "lint" => nil }
      }
    }
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
