require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require "hive/cli"
require "hive/commands/refactor_patrol"
require "hive/config"
require "hive/patrol/feature"
require "hive/refactor_patrol/thesis"

class RefactorPatrolCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeMapper
    def initialize(features)
      @features = features
    end

    def call
      @features
    end
  end

  class FakeLeverage
    def initialize(scores)
      @scores = scores
    end

    def score(feature, **)
      @scores.fetch(feature.id)
    end
  end

  class FakeReviewer
    attr_reader :review_errors, :seen_feature_ids

    def initialize(theses_by_feature, review_errors: [])
      @theses_by_feature = theses_by_feature
      @review_errors = review_errors
      @seen_feature_ids = []
    end

    def call(features, leverage_by_feature:)
      @seen_feature_ids = features.map(&:id)
      features.flat_map { |feature| Array(@theses_by_feature[feature.id]) }
    end
  end

  def test_json_run_ranks_flags_persists_and_rerun_suppresses_seen_theses
    with_refactor_patrol_project do |repo|
      features = [ feature("checkout"), feature("search") ]
      clean = thesis("clean", feature_id: "checkout", score: 0.9, fingerprint: "fp-clean")
      cap = thesis("cap", feature_id: "checkout", score: 0.8, fingerprint: "fp-cap", est_files: 12)
      inadmissible = thesis(
        "inadmissible",
        feature_id: "search",
        score: 0.7,
        fingerprint: "fp-bad",
        admissible: false,
        admissibility_reason: "missing measurable signal",
        flags: [ "inadmissible" ]
      )

      out, _err, status = with_captured_exit do
        command_for(
          features: features,
          theses_by_feature: { "checkout" => [ clean, cap ], "search" => [ inadmissible ] },
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.7)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert refactor_schemer.valid?(payload), refactor_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal [ "clean", "cap", "inadmissible" ], payload.fetch("ranked").map { |item| item.fetch("id") }
      assert_equal 1, payload.fetch("theses"), "only clean admissible unflagged theses count as accepted"
      assert_includes payload.fetch("flagged_theses").map { |item| item.fetch("id") }, "cap"
      assert_includes payload.fetch("flagged_theses").map { |item| item.fetch("id") }, "inadmissible"
      assert_empty payload.fetch("suppressed")
      payload.fetch("ranked").each do |item|
        refute_empty item.fetch("breakdown")
      end
      [ clean, cap, inadmissible ].each do |item|
        assert thesis_schemer.valid?(item.to_h), thesis_schemer.validate(item.to_h).map { |e| e["error"] }.inspect
      end

      refute Dir.exist?(File.join(repo, ".hive-state", "stages", "6-review")),
             "refactor-patrol v1 must not enqueue review tasks"

      out, _err, status = with_captured_exit do
        command_for(
          features: features,
          theses_by_feature: { "checkout" => [ clean ], "search" => [] },
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.7)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, status
      rerun = JSON.parse(out)
      assert_equal [ { "id" => "clean", "reason" => "collision_already_seen", "reference" => "fp-clean" } ],
                   rerun.fetch("suppressed")
    end
  end

  def test_dry_run_does_not_write_state_or_theses
    with_refactor_patrol_project do |repo|
      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          features: [ feature("checkout") ],
          theses_by_feature: { "checkout" => [ thesis("clean", fingerprint: "fp-clean") ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal true, JSON.parse(out).fetch("dry_run")
      refute File.exist?(File.join(repo, ".hive-state", "refactor_patrol", "state.json"))
      assert_empty Dir.glob(File.join(repo, ".hive-state", "refactor_patrol", "theses", "*.json"))
    end
  end

  def test_feature_scope_precedence_beats_path
    with_refactor_patrol_project do
      reviewer = FakeReviewer.new({ "checkout" => [ thesis("clean", feature_id: "checkout", fingerprint: "fp-clean") ] })
      out, _err, status = with_captured_exit do
        command_for(
          feature_hint: "checkout",
          path_hint: "lib/search",
          features: [ feature("checkout", files: [ "lib/checkout.rb" ]), feature("search", files: [ "lib/search/index.rb" ]) ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.1)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal [ "checkout" ], reviewer.seen_feature_ids
      assert_equal 1, JSON.parse(out).fetch("features_mapped")
    end
  end

  def test_entrypoint_scope_is_used_when_feature_hint_absent
    with_refactor_patrol_project do
      reviewer = FakeReviewer.new({ "search" => [ thesis("search", feature_id: "search", fingerprint: "fp-search") ] })
      out, _err, status = with_captured_exit do
        command_for(
          entrypoint_hint: "bin/search",
          features: [
            feature("checkout", files: [ "lib/checkout.rb" ]),
            feature("search", files: [ "lib/search.rb" ], entrypoints: [ "bin/search" ])
          ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.1, "search" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal [ "search" ], reviewer.seen_feature_ids
      assert_equal 1, JSON.parse(out).fetch("features_mapped")
    end
  end

  def test_path_scope_can_be_further_restricted_to_changed_files
    with_refactor_patrol_project do |repo|
      FileUtils.mkdir_p(File.join(repo, "lib", "checkout"))
      File.write(File.join(repo, "lib", "checkout", "flow.rb"), "initial\n")
      FileUtils.mkdir_p(File.join(repo, "lib", "search"))
      File.write(File.join(repo, "lib", "search", "index.rb"), "initial\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "baseline", "--quiet")
      baseline = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      File.write(File.join(repo, "lib", "checkout", "flow.rb"), "changed\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "checkout change", "--quiet")

      reviewer = FakeReviewer.new({ "checkout" => [ thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout") ] })
      out, _err, status = with_captured_exit do
        command_for(
          path_hint: "lib",
          changed_since: baseline,
          features: [
            feature("checkout", files: [ "lib/checkout/flow.rb" ]),
            feature("search", files: [ "lib/search/index.rb" ])
          ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.1)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal [ "checkout" ], reviewer.seen_feature_ids
      assert_equal 1, JSON.parse(out).fetch("features_mapped")
    end
  end

  def test_changed_since_git_failure_keeps_scoped_features
    with_refactor_patrol_project do
      reviewer = FakeReviewer.new({ "checkout" => [ thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout") ] })
      out, _err, status = with_captured_exit do
        command_for(
          path_hint: "lib",
          changed_since: "missing-ref",
          features: [ feature("checkout", files: [ "lib/checkout.rb" ]) ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal [ "checkout" ], reviewer.seen_feature_ids
      assert_equal 1, JSON.parse(out).fetch("features_mapped")
    end
  end

  def test_text_output_includes_ranked_thesis_details
    with_refactor_patrol_project do
      out, _err, status = with_captured_exit do
        command_for(
          json: false,
          features: [ feature("checkout") ],
          theses_by_feature: { "checkout" => [ thesis("clean", fingerprint: "fp-clean") ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_includes out, "hive refactor-patrol: demo"
      assert_includes out, "1. Checkout"
      assert_includes out, "problem:"
      assert_includes out, "validation:"
      assert_includes out, "flagged=0 suppressed=0"
    end
  end

  def test_internal_error_emits_json_error_envelope
    with_refactor_patrol_project do
      bad_mapper = ->(_root, _cfg, _state) { raise "boom" }
      out, _err, status = with_captured_exit do
        Hive::Commands::RefactorPatrol.new(
          "demo",
          json: true,
          mapper_factory: bad_mapper
        ).call
      end

      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::SOFTWARE, status
      assert_equal false, payload.fetch("ok")
      assert_equal "InternalError", payload.fetch("error_class")
      assert_equal "error", payload.fetch("error_kind")
    end
  end

  def test_cli_dispatches_refactor_patrol_command
    with_refactor_patrol_project do
      out, _err, status = with_captured_exit do
        Hive::CLI.start(%w[refactor-patrol demo --dry-run --feature checkout --json])
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("dry_run")
      assert_equal "demo", payload.fetch("project")
    end
  end

  def test_project_without_refactor_patrol_block_errors_clearly
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        File.write(File.join(repo, ".hive-state", "config.yml"), { "project_name" => "demo", "default_branch" => "master" }.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)

        out, err, status = with_captured_exit { command_for(features: []).call }
        payload = JSON.parse(out)

        assert_equal Hive::ExitCodes::CONFIG, status
        assert_match(/refactor_patrol.enabled/, err)
        assert_equal false, payload.fetch("ok")
        assert_equal "config", payload.fetch("error_kind")
      end
    end
  end

  def test_review_errors_do_not_advance_last_scanned_sha
    with_refactor_patrol_project do |repo|
      state_dir = File.join(repo, ".hive-state", "refactor_patrol")
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, "state.json"), JSON.generate("last_scanned_sha" => "PRIOR"))
      reviewer = FakeReviewer.new({}, review_errors: [ { "feature_id" => "checkout", "error" => "agent_failed" } ])

      out, _err, status = with_captured_exit do
        command_for(features: [ feature("checkout") ], reviewer: reviewer, leverage_scores: leverage_scores("checkout" => 0.9)).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal "PRIOR", JSON.parse(out).fetch("last_scanned_sha")
      assert_equal "PRIOR", JSON.parse(File.read(File.join(state_dir, "state.json"))).fetch("last_scanned_sha")
    end
  end

  def test_changed_since_exception_keeps_scoped_features
    with_refactor_patrol_project do |repo|
      reviewer = FakeReviewer.new({ "checkout" => [ thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout") ] })
      command = command_for(
        dry_run: true,
        path_hint: "lib",
        changed_since: "HEAD",
        features: [ feature("checkout", files: [ "lib/checkout.rb" ]) ],
        reviewer: reviewer,
        leverage_scores: leverage_scores("checkout" => 0.9)
      )
      original_capture3 = Open3.method(:capture3)
      begin
        Open3.define_singleton_method(:capture3) do |*args|
          if args[0, 4] == [ "git", "-C", repo, "diff" ]
            raise "git unavailable"
          end

          original_capture3.call(*args)
        end
        out, _err, status = with_captured_exit { command.call }
      ensure
        Open3.define_singleton_method(:capture3, original_capture3)
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal [ "checkout" ], reviewer.seen_feature_ids
      assert_equal 1, JSON.parse(out).fetch("features_mapped")
      refute File.exist?(File.join(repo, ".hive-state", "refactor_patrol", "state.json"))
    end
  end

  def test_mapper_cfg_deep_copies_refactor_patrol_settings
    with_refactor_patrol_project do
      cfg = {
        "patrol" => { "review" => { "max_owned_files" => 99 } },
        "refactor_patrol" => {
          "include" => [ "lib/**" ],
          "exclude" => [ "vendor/**" ],
          "review" => { "max_owned_files" => 3 }
        }
      }
      mapped = command_for.send(:mapper_cfg, cfg)

      assert_equal [ "lib/**" ], mapped.dig("patrol", "include")
      assert_equal [ "vendor/**" ], mapped.dig("patrol", "exclude")
      assert_equal({ "max_owned_files" => 3 }, mapped.dig("patrol", "review"))
      refute_same cfg, mapped
    end
  end

  private

  def with_refactor_patrol_project
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        cfg = Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          {
            "project_name" => "demo",
            "default_branch" => "master",
            "refactor_patrol" => {
              "enabled" => true,
              "commands" => { "test" => "true" }
            }
          }
        )
        File.write(File.join(repo, ".hive-state", "config.yml"), cfg.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)
        yield repo
      end
    end
  end

  def command_for(project: "demo", json: true, dry_run: false, feature_hint: nil, entrypoint_hint: nil, path_hint: nil, changed_since: nil,
                  features: [], theses_by_feature: {}, reviewer: nil, leverage_scores: {})
    reviewer ||= FakeReviewer.new(theses_by_feature)
    Hive::Commands::RefactorPatrol.new(
      project,
      json: json,
      dry_run: dry_run,
      feature: feature_hint,
      entrypoint: entrypoint_hint,
      path: path_hint,
      changed_since: changed_since,
      mapper_factory: ->(_root, _cfg, _state) { FakeMapper.new(features) },
      reviewer_factory: ->(_root, _cfg, _state) { reviewer },
      leverage_factory: ->(_root, _cfg) { FakeLeverage.new(leverage_scores) }
    )
  end

  def feature(id, files: [ "lib/#{id}.rb" ], entrypoints: files)
    Hive::Patrol::Feature.new(
      id: id,
      kind: "command",
      entrypoints: entrypoints,
      owned_files: files,
      context_files: [],
      tests: [ "test/#{id}_test.rb" ]
    )
  end

  def leverage_scores(scores)
    scores.to_h do |feature_id, score|
      [ feature_id, { "score" => score, "breakdown" => { "churn" => score }, "signals" => { "churn" => 10 } } ]
    end
  end

  def thesis(id, feature_id: "checkout", score: 0.9, fingerprint: "fp", est_files: 2,
             admissible: true, admissibility_reason: "evidence cites concrete paths and measurable signals",
             flags: [])
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: feature_id,
      feature: feature_id.capitalize,
      problem: "#{feature_id} mixes validation and orchestration",
      cost: "Frequent changes fan out across callers",
      evidence: [ { "file" => "lib/#{feature_id}.rb", "signal" => "churn", "value" => 10 } ],
      proposed_refactor: "Extract a #{feature_id} boundary service",
      feature_boundary: { "owned_files" => [ "lib/#{feature_id}.rb" ], "entrypoints" => [ "lib/#{feature_id}.rb" ] },
      expected_leverage: { "score" => score, "breakdown" => { "churn" => score } },
      confidence: "medium",
      risk: {
        "caps" => { "est_files" => est_files, "est_diff_lines" => 120, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => flags
      },
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "Run tests" },
      admissible: admissible,
      admissibility_reason: admissibility_reason,
      follow_up_approval_state: "pending",
      fingerprint: fingerprint
    )
  end

  def refactor_schemer
    @refactor_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol"))))
  end

  def thesis_schemer
    @thesis_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-thesis"))))
  end
end
