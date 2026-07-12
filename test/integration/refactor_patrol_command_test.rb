require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require "digest"
require "hive/cli"
require "hive/commands/refactor_patrol"
require "hive/config"
require "hive/patrol/feature"
require "hive/refactor_patrol/thesis"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/policy"

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
    attr_reader :review_errors, :seen_feature_ids, :feature_results

    def initialize(theses_by_feature, review_errors: [])
      @theses_by_feature = theses_by_feature
      @review_errors = review_errors
      @seen_feature_ids = []
      @feature_results = []
    end

    def call(features, leverage_by_feature:)
      @seen_feature_ids = features.map(&:id)
      theses = features.flat_map { |feature| Array(@theses_by_feature[feature.id]) }
      @feature_results = features.map do |feature|
        errors = @review_errors.select { |error| error["feature_id"].to_s == feature.id.to_s }
        {
          "feature_id" => feature.id.to_s,
          "complete" => errors.empty?,
          "thesis_ids" => theses.select { |thesis| thesis.feature_id.to_s == feature.id.to_s }.map(&:id),
          "errors" => errors
        }
      end
      theses
    end
  end

  class CrashingCheckpointReviewer
    attr_reader :review_errors, :seen_feature_ids, :feature_results

    def initialize(thesis)
      @thesis = thesis
      @review_errors = []
      @seen_feature_ids = []
      @feature_results = []
    end

    def call(features, leverage_by_feature:)
      feature = features.first
      @seen_feature_ids << feature.id
      result = {
        "feature_id" => feature.id.to_s,
        "complete" => true,
        "thesis_ids" => [ @thesis.id ],
        "errors" => []
      }
      @feature_results << result
      yield feature, [ @thesis ], result
      raise "simulated process death after feature checkpoint"
    end
  end

  class MutatingCompleteReviewer
    attr_reader :review_errors, :seen_feature_ids, :feature_results

    def initialize(path, thesis)
      @path = path
      @thesis = thesis
      @review_errors = []
      @seen_feature_ids = []
      @feature_results = []
    end

    def call(features, leverage_by_feature:)
      @seen_feature_ids = features.map(&:id)
      @feature_results = features.map do |feature|
        {
          "feature_id" => feature.id.to_s,
          "complete" => true,
          "thesis_ids" => [ @thesis.id ],
          "errors" => []
        }
      end
      File.write(@path, "reviewer mutated tracked source\n")
      [ @thesis ]
    end
  end

  class FakeManifestResolver
    attr_reader :seen

    def initialize(manifest)
      @manifest = manifest
    end

    def resolve(pr)
      @seen = pr
      @manifest
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

  # Behavior-preserving work inside public-surface files (bin/, cli.rb) is an
  # advisory, not an API change: the thesis still counts as accepted and the
  # advisory is visible on its ranked entry.
  def test_public_surface_thesis_is_accepted_with_advisory
    with_refactor_patrol_project do
      surface = thesis("surface", feature_id: "checkout", fingerprint: "fp-surface", boundary_files: [ "bin/checkout" ])

      out, _err, status = with_captured_exit do
        command_for(
          features: [ feature("checkout", files: [ "bin/checkout" ]) ],
          theses_by_feature: { "checkout" => [ surface ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal 1, payload.fetch("theses"), "surface-touching thesis must count as accepted"
      ranked = payload.fetch("ranked").first
      assert_empty ranked.fetch("flagged")
      assert_equal [ "touches_public_api_surface" ], ranked.fetch("advisories")
      assert_equal false, surface.risk.fetch("public_api_impact")
      assert thesis_schemer.valid?(surface.to_h), thesis_schemer.validate(surface.to_h).map { |e| e["error"] }.inspect
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
      assert_equal 1, payload.fetch("schema_version")
      assert refactor_schemer.valid?(payload), refactor_schemer.validate(payload).map { |e| e["error"] }.inspect
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

  def test_pr_mode_uses_manifest_scope_and_emits_complete_v2
    with_refactor_patrol_project do |repo|
      expected_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(merge_sha: expected_head)
      resolver = FakeManifestResolver.new(manifest)
      reviewer = FakeReviewer.new(
        { "checkout" => [ thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout") ] }
      )

      out, err, status = with_captured_exit do
        command_for(
          pr: "https://github.com/acme/demo/pull/7",
          manifest_resolver: resolver,
          features: [
            feature("checkout", files: [ "lib/checkout.rb" ]),
            feature("search", files: [ "lib/search.rb" ])
          ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status, "#{out}\n#{err}"
      payload = JSON.parse(out)
      assert v2_refactor_schemer.valid?(payload), v2_refactor_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal 2, payload.fetch("schema_version")
      assert_equal manifest.fetch("job_id"), payload.fetch("job_id")
      assert_equal [ "checkout" ], reviewer.seen_feature_ids
      assert_equal [ "checkout" ], payload.fetch("accepted").map { |item| item.fetch("id") }
      assert payload.fetch("complete")
      assert_equal expected_head, payload.fetch("analysis_sha")
      assert_equal "https://github.com/acme/demo/pull/7", resolver.seen
      refute File.exist?(File.join(repo, ".hive-state", "refactor_patrol", "state.json"))
      aggregate = Hive::RefactorPatrol::JobStore.new(repo).read_job(manifest.fetch("job_id"))
      assert aggregate.fetch("complete"), "manual PR replay must checkpoint the authoritative v2 job"
      assert_equal [ "checkout" ], aggregate.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_equal true, aggregate.dig("policy", "discovery")
      claim = aggregate.fetch("attempts").first
      assert_equal "discovery_claim", claim.fetch("kind")
      assert_match(/\Amanual-/, claim.fetch("owner"))
      assert_equal "complete", claim.fetch("state")
    end
  end

  def test_pr_discovery_releases_claim_without_results_when_reviewer_mutates_checkout
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(merge_sha: head)
      item = thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout")
      reviewer = MutatingCompleteReviewer.new(File.join(repo, "README.md"), item)

      out, err, status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: [ feature("checkout", files: [ "lib/checkout.rb" ]) ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SOFTWARE, status, "#{out}\n#{err}"
      payload = JSON.parse(out)
      assert v2_refactor_schemer.valid?(payload),
             v2_refactor_schemer.validate(payload).map { |error| error["error"] }.inspect
      assert_includes payload.fetch("message"), "registered checkout is dirty"

      aggregate = Hive::RefactorPatrol::JobStore.new(repo).read_job(manifest.fetch("job_id"))
      assert_equal "blocked", aggregate.fetch("state")
      assert_empty aggregate.fetch("feature_results")
      Hive::RefactorPatrol::JobStore::DISPOSITIONS.each do |disposition|
        assert_empty aggregate.dig("dispositions", disposition)
      end
      claim = aggregate.fetch("attempts").last
      assert_equal "released", claim.fetch("state")
      assert_equal "command_error", claim.fetch("outcome")
    end
  end

  def test_manual_pr_duplicate_owner_blocks_before_manifest_resolution_or_review
    with_refactor_patrol_project do |repo|
      other = File.join(File.dirname(repo), "duplicate-registration")
      FileUtils.mkdir_p(File.join(other, ".hive-state"))
      FileUtils.cp(
        File.join(repo, ".hive-state", "config.yml"),
        File.join(other, ".hive-state", "config.yml")
      )
      Hive::Config.register_project(name: "duplicate", path: other)
      resolver_called = false
      resolver = Object.new
      resolver.define_singleton_method(:resolve) do |*_args, **_kwargs|
        resolver_called = true
        raise "manifest resolver must not run"
      end
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { Hive::Config.registered_projects },
        config_loader: ->(path) { Hive::Config.load(path) },
        identity_resolver: ->(_entry, _current_cfg) {
          { "repository" => "acme/demo", "host" => "github.com" }
        }
      )

      out, _err, status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: resolver,
          repository_ownership: ownership,
          reviewer: FakeReviewer.new({})
        ).call
      end

      assert_equal Hive::ExitCodes::CONFIG, status
      assert_includes JSON.parse(out).fetch("message"), "duplicate_repository_registration"
      refute resolver_called
    end
  end

  def test_manual_pr_replay_resumes_only_incomplete_features
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(merge_sha: head, changed_paths: [ "lib/checkout.rb", "lib/search.rb" ])
      checkout = thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout")
      first_reviewer = FakeReviewer.new(
        { "checkout" => [ checkout ] },
        review_errors: [ { "feature_id" => "search", "error" => "agent_failed", "message" => "timeout" } ]
      )
      features = [
        feature("checkout", files: [ "lib/checkout.rb" ]),
        feature("search", files: [ "lib/search.rb" ])
      ]

      first_out, first_err, first_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: first_reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, first_status, "#{first_out}\n#{first_err}"
      refute JSON.parse(first_out).fetch("complete")
      stored = Hive::RefactorPatrol::JobStore.new(repo).read_job(manifest.fetch("job_id"))
      assert_equal [ "checkout" ], stored.fetch("feature_results").map { |item| item.fetch("feature_id") }

      search = thesis("search", feature_id: "search", fingerprint: "fp-search")
      retry_reviewer = FakeReviewer.new({ "search" => [ search ] })
      second_out, second_err, second_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: retry_reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, second_status, "#{second_out}\n#{second_err}"
      assert_equal [ "search" ], retry_reviewer.seen_feature_ids
      payload = JSON.parse(second_out)
      assert payload.fetch("complete")
      assert_equal %w[checkout search], payload.fetch("accepted").map { |item| item.fetch("id") }.sort
      assert_equal %w[checkout search], Hive::RefactorPatrol::JobStore.new(repo)
                                                   .read_job(manifest.fetch("job_id"))
                                                   .fetch("feature_results")
                                                   .map { |item| item.fetch("feature_id") }.sort
    end
  end

  def test_partial_discovery_preserves_completed_disposition_across_confidence_change
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(
        merge_sha: head, changed_paths: [ "lib/checkout.rb", "lib/search.rb" ]
      )
      features = [
        feature("checkout", files: [ "lib/checkout.rb" ]),
        feature("search", files: [ "lib/search.rb" ])
      ]
      checkout = thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout")
      first = FakeReviewer.new(
        { "checkout" => [ checkout ] },
        review_errors: [
          { "feature_id" => "search", "error" => "agent_failed", "message" => "timeout" }
        ]
      )

      first_out, first_err, first_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: first,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, first_status, "#{first_out}\n#{first_err}"
      store = Hive::RefactorPatrol::JobStore.new(repo)
      before = JSON.generate(store.read_job(manifest.fetch("job_id")).dig("dispositions", "accepted", 0))

      config_path = File.join(repo, ".hive-state", "config.yml")
      current = YAML.safe_load(File.read(config_path))
      current.fetch("refactor_patrol")["min_confidence"] = "high"
      File.write(config_path, current.to_yaml)
      search = thesis("search", feature_id: "search", fingerprint: "fp-search")
      retry_reviewer = FakeReviewer.new({ "search" => [ search ] })

      second_out, second_err, second_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: retry_reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, second_status, "#{second_out}\n#{second_err}"
      payload = JSON.parse(second_out)
      assert payload.fetch("complete")
      assert_equal [ "checkout" ], payload.fetch("accepted").map { |item| item.fetch("id") }
      assert_equal [ "search" ], payload.fetch("flagged").map { |item| item.fetch("id") }
      assert_equal [ "below_min_confidence" ], payload.fetch("flagged").first.fetch("reasons")
      aggregate = store.read_job(manifest.fetch("job_id"))
      assert_equal before, JSON.generate(aggregate.dig("dispositions", "accepted", 0))
      assert aggregate.fetch("complete")
    end
  end

  def test_process_death_after_feature_checkpoint_resumes_at_the_next_feature
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(
        merge_sha: head,
        changed_paths: [ "lib/checkout.rb", "lib/search.rb" ]
      )
      checkout = thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout")
      crashing = CrashingCheckpointReviewer.new(checkout)
      features = [
        feature("checkout", files: [ "lib/checkout.rb" ]),
        feature("search", files: [ "lib/search.rb" ])
      ]

      first_out, first_err, first_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: crashing,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end

      assert_equal Hive::ExitCodes::SOFTWARE, first_status, "#{first_out}\n#{first_err}"
      aggregate = Hive::RefactorPatrol::JobStore.new(repo).read_job(manifest.fetch("job_id"))
      assert_equal [ "checkout" ], aggregate.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_equal [ "checkout" ], aggregate.dig("dispositions", "accepted").map { |item| item.fetch("id") }
      assert_equal "blocked", aggregate.fetch("state")

      search = thesis("search", feature_id: "search", fingerprint: "fp-search")
      retry_reviewer = FakeReviewer.new({ "search" => [ search ] })
      second_out, second_err, second_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: features, reviewer: retry_reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9, "search" => 0.8)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, second_status, "#{second_out}\n#{second_err}"
      assert_equal [ "search" ], retry_reviewer.seen_feature_ids
      payload = JSON.parse(second_out)
      assert payload.fetch("complete")
      assert_equal %w[checkout search], payload.fetch("accepted").map { |item| item.fetch("id") }.sort
    end
  end

  def test_completed_v2_fingerprint_suppresses_recursive_refactor_pr
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      first_manifest = pr_manifest(merge_sha: head)
      original = thesis("original", fingerprint: "recursive-fp")
      first_out, first_err, first_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(first_manifest),
          features: [ feature("checkout") ], theses_by_feature: { "checkout" => [ original ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, first_status, "#{first_out}\n#{first_err}"

      recursive_manifest = pr_manifest(merge_sha: head).merge(
        "job_id" => "pr-8-recursive",
        "source" => first_manifest.fetch("source").merge(
          "url" => "https://github.com/acme/demo/pull/8", "number" => 8
        )
      )
      duplicate = thesis("recursive", fingerprint: "recursive-fp")
      second_out, second_err, second_status = with_captured_exit do
        command_for(
          pr: "8", manifest_resolver: FakeManifestResolver.new(recursive_manifest),
          features: [ feature("checkout") ], theses_by_feature: { "checkout" => [ duplicate ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, second_status, "#{second_out}\n#{second_err}"
      payload = JSON.parse(second_out)
      assert_empty payload.fetch("accepted")
      assert_equal [ "recursive" ], payload.fetch("suppressed").map { |item| item.fetch("id") }
      assert_equal [ "collision_already_seen" ], payload.fetch("suppressed").flat_map { |item| item.fetch("reasons") }
    end
  end

  def test_explicit_manual_replay_snapshots_new_policy_without_mutating_completed_job
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = pr_manifest(merge_sha: head)
      item = thesis("replayable", fingerprint: "replay-fp")
      first_out, first_err, first_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: [ feature("checkout") ], theses_by_feature: { "checkout" => [ item ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, first_status, "#{first_out}\n#{first_err}"
      store = Hive::RefactorPatrol::JobStore.new(repo)
      original = store.read_job(manifest.fetch("job_id"))
      assert original.fetch("complete")
      original_path = File.join(store.root, "jobs", "#{manifest.fetch('job_id')}.json")
      original_bytes = File.binread(original_path)

      config_path = File.join(repo, ".hive-state", "config.yml")
      config = YAML.safe_load(File.read(config_path))
      config.fetch("refactor_patrol").fetch("auto_fix")["enabled"] = true
      File.write(config_path, config.to_yaml)
      second_out, second_err, second_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: FakeManifestResolver.new(manifest),
          features: [ feature("checkout") ], theses_by_feature: { "checkout" => [ item ] },
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, second_status, "#{second_out}\n#{second_err}"
      replay = store.jobs.find { |job| job.fetch("job_id").include?("-replay-") }
      refute_nil replay
      assert_equal true, replay.dig("policy", "auto_fix")
      assert_equal "classified", replay.fetch("state")
      assert_equal [ "replayable" ], replay.dig("dispositions", "accepted").map { |entry| entry.fetch("id") }
      assert_empty JSON.parse(second_out).fetch("suppressed")
      assert_equal original_bytes, File.binread(original_path)
    end
  end

  def test_job_manifest_mode_emits_the_same_complete_v2_without_github_resolution
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = with_manifest_checksum(pr_manifest(merge_sha: head))
      path = publish_job_manifest(repo, manifest)
      features = [ feature("checkout", files: [ "lib/checkout.rb" ]) ]
      theses = { "checkout" => [ thesis("checkout", feature_id: "checkout", fingerprint: "fp-checkout") ] }

      pr_resolver = FakeManifestResolver.new(manifest)
      pr_out, pr_err, pr_status = with_captured_exit do
        command_for(
          pr: "7", manifest_resolver: pr_resolver, features: features,
          theses_by_feature: theses, leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      forbidden_resolver = FakeManifestResolver.new({})
      result_file = File.join(
        repo, ".hive-state", "refactor_patrol", "v2", "results",
        "#{manifest.fetch('job_id')}-integration.json"
      )
      scheduled_out, scheduled_err, scheduled_status = with_captured_exit do
        command_for(
          job_manifest: path, result_file: result_file,
          manifest_resolver: forbidden_resolver, features: features,
          theses_by_feature: theses, leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, pr_status, "#{pr_out}\n#{pr_err}"
      assert_equal Hive::ExitCodes::SUCCESS, scheduled_status, "#{scheduled_out}\n#{scheduled_err}"
      assert_equal JSON.parse(pr_out), JSON.parse(scheduled_out)
      assert_nil forbidden_resolver.seen, "persisted-manifest mode must not resolve mutable GitHub PR metadata"
      assert v2_refactor_schemer.valid?(JSON.parse(scheduled_out))
      assert_equal JSON.parse(scheduled_out), JSON.parse(File.read(result_file))
    end
  end

  def test_action_mode_resumes_the_authoritative_job_and_emits_a_strict_v2_projection
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = with_manifest_checksum(pr_manifest(merge_sha: head))
      path = publish_job_manifest(repo, manifest)
      source = manifest.fetch("source").merge(
        "changed_paths" => manifest.fetch("changed_paths"),
        "manifest_checksum" => manifest.fetch("manifest_checksum")
      )
      cfg = Hive::Config.load(repo)
      policy = Hive::RefactorPatrol::Policy.capture(cfg, now: Time.utc(2026, 7, 10)).merge(
        "auto_fix" => false, "issue_filing" => false
      )
      item = thesis("report-only", feature_id: "checkout", fingerprint: "fp-report-only")
      accepted = {
        "id" => item.id, "feature_id" => item.feature_id,
        "fingerprint" => item.fingerprint,
        "score" => item.expected_leverage.fetch("score"),
        "admissible" => true, "reasons" => [], "thesis" => item.to_h
      }
      Hive::RefactorPatrol::JobStore.new(repo).write_job!(
        {
          "schema" => "hive-refactor-patrol-job", "schema_version" => 2,
          "job_id" => manifest.fetch("job_id"), "source" => source,
          "analysis_sha" => head, "policy" => policy,
          "state" => "classified", "complete" => false,
          "dispositions" => { "accepted" => [ accepted ], "flagged" => [], "suppressed" => [] },
          "feature_results" => [], "review_errors" => [], "zero_reason" => nil,
          "attempts" => [ { "number" => 1, "outcome" => "classified" } ],
          "actions" => [], "created_at" => "2026-07-10T00:00:00Z",
          "updated_at" => "2026-07-10T00:00:00Z"
        }
      )
      config_path = File.join(repo, ".hive-state", "config.yml")
      current_config = YAML.safe_load(File.read(config_path))
      current_config["default_branch"] = "renamed-main"
      File.write(config_path, current_config.to_yaml)

      out, err, status = with_captured_exit do
        command_for(job_manifest: path, actions: true).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status, "#{out}\n#{err}"
      payload = JSON.parse(out)
      assert v2_refactor_schemer.valid?(payload),
             v2_refactor_schemer.validate(payload).map { |error| error["error"] }.inspect
      assert payload.fetch("complete")
      assert_equal "complete", payload.dig("action_status", "state")
      assert_empty payload.fetch("actions")
      assert Hive::RefactorPatrol::JobStore.new(repo).read_job(manifest.fetch("job_id")).fetch("complete")
    end
  end

  def test_action_mode_counts_completed_feature_with_no_thesis
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      manifest = with_manifest_checksum(pr_manifest(merge_sha: head))
      path = publish_job_manifest(repo, manifest)
      source = manifest.fetch("source").merge(
        "changed_paths" => manifest.fetch("changed_paths"),
        "manifest_checksum" => manifest.fetch("manifest_checksum")
      )
      cfg = Hive::Config.load(repo)
      policy = Hive::RefactorPatrol::Policy.capture(cfg, now: Time.utc(2026, 7, 10)).merge(
        "auto_fix" => false, "issue_filing" => false
      )
      Hive::RefactorPatrol::JobStore.new(repo).write_job!(
        {
          "schema" => "hive-refactor-patrol-job", "schema_version" => 2,
          "job_id" => manifest.fetch("job_id"), "source" => source,
          "analysis_sha" => head, "policy" => policy,
          "state" => "complete", "complete" => true,
          "dispositions" => { "accepted" => [], "flagged" => [], "suppressed" => [] },
          "feature_results" => [
            { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] }
          ],
          "review_errors" => [], "zero_reason" => "no_theses",
          "attempts" => [ { "number" => 1, "outcome" => "complete" } ],
          "actions" => [], "created_at" => "2026-07-10T00:00:00Z",
          "updated_at" => "2026-07-10T00:00:00Z"
        }
      )

      out, err, status = with_captured_exit do
        command_for(job_manifest: path, actions: true).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status, "#{out}\n#{err}"
      payload = JSON.parse(out)
      assert payload.fetch("complete")
      assert_equal 1, payload.fetch("features_mapped")
      assert_empty payload.fetch("accepted")
      assert_empty payload.fetch("flagged")
    end
  end

  def test_pr_mode_review_errors_are_partial_and_never_touch_legacy_state
    with_refactor_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      reviewer = FakeReviewer.new({}, review_errors: [ { "feature_id" => "checkout", "error" => "agent_failed" } ])
      out, err, status = with_captured_exit do
        command_for(
          dry_run: true,
          pr: "7",
          manifest_resolver: FakeManifestResolver.new(pr_manifest(merge_sha: head)),
          features: [ feature("checkout") ],
          reviewer: reviewer,
          leverage_scores: leverage_scores("checkout" => 0.9)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status, "#{out}\n#{err}"
      payload = JSON.parse(out)
      refute payload.fetch("complete")
      assert_equal "agent_failed", payload.fetch("review_errors").first.fetch("error")
      refute File.exist?(File.join(repo, ".hive-state", "refactor_patrol", "state.json"))
    end
  end

  def test_pr_mode_rejects_legacy_scope_flags_and_emits_v2_error
    with_refactor_patrol_project do
      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          pr: "7",
          feature_hint: "checkout",
          manifest_resolver: FakeManifestResolver.new(pr_manifest)
        ).call
      end

      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::CONFIG, status
      assert_equal 2, payload.fetch("schema_version")
      assert_equal false, payload.fetch("complete")
    end
  end

  def test_pr_mode_maps_only_changed_documentation_slice_and_skips_compiled_logs
    with_refactor_patrol_project do |repo|
      FileUtils.mkdir_p(File.join(repo, "docs"))
      FileUtils.mkdir_p(File.join(repo, "pages"))
      FileUtils.mkdir_p(File.join(repo, "wiki"))
      File.write(File.join(repo, "docs", "guide.md"), "guide\n")
      File.write(File.join(repo, "package.json"), JSON.generate("scripts" => { "test" => "node --test" }))
      File.write(File.join(repo, "pages", "home.tsx"), "export default function Home() {}\n")
      File.write(File.join(repo, "wiki", "log.md"), "compiled\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "docs", "--quiet")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      reviewer = FakeReviewer.new({})

      out, err, status = with_captured_exit do
        command_for(
          dry_run: true,
          pr: "7",
          manifest_resolver: FakeManifestResolver.new(
            pr_manifest(merge_sha: head, changed_paths: [ "docs/guide.md" ])
          ),
          use_default_mapper: true,
          reviewer: reviewer,
          leverage_scores: leverage_scores("documentation-docs-root" => 0.5)
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, status, "#{out}\n#{err}"
      assert_equal [ "documentation-docs-root" ], reviewer.seen_feature_ids

      skip_out, skip_err, skip_status = with_captured_exit do
        command_for(
          dry_run: true,
          pr: "7",
          manifest_resolver: FakeManifestResolver.new(
            pr_manifest(merge_sha: head, changed_paths: [ "wiki/log.md" ])
          ),
          use_default_mapper: true,
          reviewer: FakeReviewer.new({})
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, skip_status, "#{skip_out}\n#{skip_err}"
      skipped = JSON.parse(skip_out)
      assert_equal "no_mapped_slice", skipped.fetch("zero_reason")
      assert skipped.fetch("complete")
    end
  end

  def test_pr_mode_maps_architecture_component_for_manifest_only_and_test_only_changes
    with_refactor_patrol_project do |repo|
      FileUtils.mkdir_p(File.join(repo, "packages", "web", "src"))
      FileUtils.mkdir_p(File.join(repo, "packages", "web", "test"))
      File.write(File.join(repo, "packages", "web", "package.json"), JSON.generate("name" => "@acme/web"))
      File.write(File.join(repo, "packages", "web", "src", "index.ts"), "export const web = true\n")
      File.write(File.join(repo, "packages", "web", "test", "index.test.ts"), "import '../src/index'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "web package", "--quiet")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      cases = {
        "packages/web/package.json" => "architecture-manifest-packages-web",
        "packages/web/test/index.test.ts" => "architecture-packages-web"
      }
      cases.each do |changed_path, expected_feature_id|
        reviewer = FakeReviewer.new({})
        out, err, status = with_captured_exit do
          command_for(
            dry_run: true,
            pr: "7",
            manifest_resolver: FakeManifestResolver.new(
              pr_manifest(merge_sha: head, changed_paths: [ changed_path ])
            ),
            use_default_mapper: true,
            reviewer: reviewer,
            leverage_scores: leverage_scores(expected_feature_id => 0.5)
          ).call
        end

        assert_equal Hive::ExitCodes::SUCCESS, status, "#{changed_path}: #{out}\n#{err}"
        assert_equal [ expected_feature_id ], reviewer.seen_feature_ids, changed_path
        assert_equal 1, JSON.parse(out).fetch("features_mapped"), changed_path
      end
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
        assert_equal 1, payload.fetch("schema_version")
        assert refactor_schemer.valid?(payload), refactor_schemer.validate(payload).map { |e| e["error"] }.inspect
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

  def test_claim_liveness_resolver_fails_safe_when_identity_fields_are_missing
    resolver = Hive::Commands::RefactorPatrol::ClaimLivenessResolver.new

    assert_equal :resolved, resolver.call({})
  end

  def test_mode_validation_rejects_ambiguous_or_unsafe_flag_combinations
    cases = [
      [ { result_file: "/tmp/result.json" }, /--result-file requires/ ],
      [ { actions: true, json: false, job_manifest: "/tmp/job.json" }, /--actions requires/ ],
      [ { actions: true, job_manifest: "/tmp/job.json", feature: "checkout" }, /--actions cannot be combined/ ],
      [ { pr: "7", json: false }, /PR-scoped mode requires --json/ ],
      [ { pr: "7", job_manifest: "/tmp/job.json" }, /accepts only one/ ]
    ]

    cases.each do |options, message|
      command = Hive::Commands::RefactorPatrol.new("demo", json: true, **options)
      error = assert_raises(Hive::ConfigError) { command.send(:validate_mode!) }
      assert_match message, error.message
    end
  end

  def test_default_manifest_resolver_receives_authoritative_project_context
    with_refactor_patrol_project do |repo|
      entry = Hive::Config.find_project("demo")
      cfg = Hive::Config.load(repo)
      expected = pr_manifest
      resolver = FakeManifestResolver.new(expected)
      captured = nil
      command = Hive::Commands::RefactorPatrol.new("demo", json: true, dry_run: true, pr: "7")

      with_replaced_singleton_method(
        Hive::RefactorPatrol::PrManifestResolver,
        :new,
        lambda { |**kwargs| captured = kwargs; resolver }
      ) do
        assert_equal expected, command.send(:resolve_manifest, entry, repo, cfg)
      end

      assert_equal repo, captured.fetch(:project_root)
      assert_equal "demo", captured.fetch(:registration)
      assert_equal "master", captured.fetch(:default_branch)
      assert_equal true, captured.fetch(:dry_run)
    end
  end

  def test_collision_factory_compatibility_and_dry_run_terminal_fingerprint_scan
    called = nil
    command = Hive::Commands::RefactorPatrol.new(
      "demo",
      collisions_factory: lambda { |root, state| called = [ root, state ]; :collisions }
    )
    assert_equal :collisions, command.send(:build_collisions, "/repo", :state)
    assert_equal [ "/repo", :state ], called

    store = Object.new
    store.define_singleton_method(:jobs) do
      [
        {
          "job_id" => "job-7", "complete" => true,
          "dispositions" => {
            "accepted" => [ { "fingerprint" => "fp-accepted" } ],
            "flagged" => [ { "fingerprint" => "fp-flagged" } ],
            "suppressed" => []
          }
        }
      ]
    end
    command = Hive::Commands::RefactorPatrol.new(
      "demo", json: true, dry_run: true, pr: "7", job_store_factory: ->(_root) { store }
    )

    assert_equal(
      {
        "fp-accepted" => { "job_id" => "job-7" },
        "fp-flagged" => { "job_id" => "job-7" }
      },
      command.send(:v2_terminal_fingerprints, "/repo")
    )
  end

  def test_existing_durable_lifecycle_short_circuits_discovery_and_projects_terminal_theses
    with_refactor_patrol_project do |repo|
      manifest = pr_manifest
      item = thesis("existing", feature_id: "checkout", fingerprint: "fp-existing")
      action = {
        "canonical_action_id" => "fix-fp-existing", "thesis_id" => item.id,
        "thesis_fingerprint" => item.fingerprint, "kind" => "fix",
        "owner_job_id" => manifest.fetch("job_id"), "outcome" => "pr_opened",
        "terminal" => true, "receipts" => { "pr_url" => "https://github.com/acme/demo/pull/8" }
      }
      aggregate = lifecycle_aggregate(manifest, item, actions: [ action ])
      command = command_for(pr: "7", manifest_resolver: FakeManifestResolver.new(manifest))
      cfg = Hive::Config.load(repo)
      entry = Hive::Config.find_project("demo")
      command.define_singleton_method(:resolve_project!) { [ entry, repo, cfg ] }
      command.define_singleton_method(:validate_mode!) { }
      command.define_singleton_method(:assert_repository_ownership!) { |*| }
      command.define_singleton_method(:resolve_manifest) { |*| manifest }
      command.define_singleton_method(:pin_checkout!) { |*| }
      command.define_singleton_method(:prepare_durable_discovery!) do |*|
        @existing_lifecycle = aggregate
      end

      payload, restored = command.send(:run_cycle)

      assert_equal [ item.id ], restored.map(&:id)
      assert_equal "hive-refactor-patrol", payload.fetch("schema")
      assert_equal [ "fix-fp-existing" ], payload.fetch("actions").map { |entry| entry.fetch("canonical_action_id") }
    end
  end

  def test_durable_discovery_rejects_source_mismatch_and_unavailable_claim_identity
    with_refactor_patrol_project do |repo|
      manifest = pr_manifest
      source = source_context(manifest)
      cfg = Hive::Config.load(repo)
      entry = Hive::Config.find_project("demo")

      mismatch_aggregate = lifecycle_aggregate(manifest, nil).merge(
        "source" => source.merge("repository" => "other/repo")
      )
      mismatch_store = Object.new
      mismatch_store.define_singleton_method(:enqueue_manifest!) do |*, **|
        mismatch_aggregate
      end
      mismatch = Hive::Commands::RefactorPatrol.new(
        "demo", json: true, pr: "7", job_store_factory: ->(_root) { mismatch_store }
      )
      mismatch.instance_variable_set(:@manifest, manifest)
      error = assert_raises(Hive::ConfigError) do
        mismatch.send(:prepare_durable_discovery!, entry, repo, cfg)
      end
      assert_match(/does not match its authoritative job/, error.message)

      existing_aggregate = lifecycle_aggregate(manifest, nil).merge(
        "complete" => false, "state" => "classified", "actions" => []
      )
      existing_store = Object.new
      existing_store.define_singleton_method(:enqueue_manifest!) { |*, **| existing_aggregate }
      existing = Hive::Commands::RefactorPatrol.new(
        "demo", json: true, pr: "7", job_store_factory: ->(_root) { existing_store }
      )
      existing.instance_variable_set(:@manifest, manifest)
      existing.send(:prepare_durable_discovery!, entry, repo, cfg)
      assert_equal existing_aggregate, existing.instance_variable_get(:@existing_lifecycle)

      aggregate = lifecycle_aggregate(manifest, nil).merge(
        "complete" => false, "state" => "queued", "actions" => []
      )
      unavailable_store = Object.new
      unavailable_store.define_singleton_method(:enqueue_manifest!) { |*, **| aggregate }
      unavailable = Hive::Commands::RefactorPatrol.new(
        "demo", json: true, pr: "7", job_store_factory: ->(_root) { unavailable_store }
      )
      unavailable.instance_variable_set(:@manifest, manifest)
      unavailable.instance_variable_set(:@checkout_snapshot, { "analysis_sha" => "head" })
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { nil }) do
        error = assert_raises(Hive::ConfigError) do
          unavailable.send(:prepare_durable_discovery!, entry, repo, cfg)
        end
        assert_match(/cannot verify the current process identity/, error.message)
      end

      unavailable_store.define_singleton_method(:claim_discovery!) { |*, **| nil }
      error = assert_raises(Hive::ConfigError) do
        unavailable.send(:prepare_durable_discovery!, entry, repo, cfg)
      end
      assert_match(/already claimed/, error.message)
    end
  end

  def test_manual_replay_manifest_sequence_advances_without_overwriting_prior_replay
    with_refactor_patrol_project do |repo|
      original = with_manifest_checksum(pr_manifest)
      command = Hive::Commands::RefactorPatrol.new("demo")

      first = command.send(:publish_manual_replay_manifest!, repo, original)
      second = command.send(:publish_manual_replay_manifest!, repo, original)

      assert first.fetch("job_id").end_with?("-replay-1")
      assert second.fetch("job_id").end_with?("-replay-2")
    end
  end

  def test_claim_token_selection_heartbeats_and_release_failures_are_fail_closed
    command = Hive::Commands::RefactorPatrol.new("demo", pr: "7")
    tokens = [ { kind: :action }, { kind: :discovery, generation: 2 } ]
    command.define_singleton_method(:active_claim_tokens) { tokens }
    assert_equal tokens.last, command.send(:current_discovery_claim_token)

    store = Object.new
    renewed = []
    store.define_singleton_method(:renew_discovery_claim!) do |token, **|
      raise Hive::RefactorPatrol::JobStore::StaleClaim, "settled" if token[:generation] == 1

      renewed << token
    end
    store.define_singleton_method(:renew_action_claim!) { |token, **| renewed << token }
    command.instance_variable_set(:@job_store, store)
    now = Time.utc(2026, 7, 10)
    command.instance_variable_set(:@heartbeat_clock, -> { now })
    command.define_singleton_method(:active_claim_tokens) do
      [ { kind: :discovery, generation: 1 }, { kind: :discovery, generation: 2 } ]
    end
    command.send(:heartbeat_active_claims)
    command.send(:renew_claim, { kind: :action, generation: 3 }, now)
    assert_equal [ 2, 3 ], renewed.map { |token| token.fetch(:generation) }

    store.define_singleton_method(:release_discovery!) do |*|
      raise Hive::RefactorPatrol::JobStore::CorruptRecord, "cannot release"
    end
    command.instance_variable_set(:@manual_claim_token, { kind: :discovery })
    assert_nil command.send(:release_manual_claim, "command_error")
    assert_nil command.instance_variable_get(:@manual_claim_token)
  end

  def test_heartbeat_worker_surfaces_durable_store_failure
    store = Object.new
    store.define_singleton_method(:renew_discovery_claim!) do |*, **|
      raise Hive::RefactorPatrol::JobStore::CorruptRecord, "heartbeat failed"
    end
    command = Hive::Commands::RefactorPatrol.new(
      "demo", pr: "7", heartbeat_interval_sec: 0.001,
      heartbeat_lease_sec: 60, job_store_factory: ->(_root) { store }
    )
    command.instance_variable_set(:@job_store, store)
    command.instance_variable_set(:@manifest, { "job_id" => "job-7" })
    command.define_singleton_method(:active_claim_tokens) { [ { kind: :discovery } ] }

    error = assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
      command.send(:with_claim_heartbeat, "job-7") { :complete }
    end
    assert_match(/heartbeat failed/, error.message)
  end

  def test_prior_suppressions_and_reviewer_fallback_results_preserve_feature_identity
    command = Hive::Commands::RefactorPatrol.new("demo")
    item = thesis("prior", feature_id: "checkout", fingerprint: "fp-prior")
    command.instance_variable_set(
      :@durable_aggregate,
      lifecycle_aggregate(pr_manifest, item).merge(
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [ item.id ], "errors" => [] }
        ],
        "dispositions" => {
          "accepted" => [], "flagged" => [],
          "suppressed" => [
            {
              "id" => item.id, "feature_id" => "checkout", "fingerprint" => item.fingerprint,
              "score" => 0.9, "admissible" => true, "reasons" => [ "collision" ],
              "reference" => "issue-7", "thesis" => item.to_h
            }
          ]
        }
      )
    )
    assert_equal(
      [ { "id" => item.id, "reason" => "collision", "reference" => "issue-7" } ],
      command.send(:prior_suppressions)
    )

    reviewer = Object.new
    reviewer.define_singleton_method(:review_errors) do
      [ { "feature_id" => "checkout", "error" => "agent_failed" } ]
    end
    results = command.send(
      :merged_feature_results, {}, reviewer, [ feature("checkout") ], [ item ]
    )
    assert_equal false, results.fetch(0).fetch("complete")
    assert_equal [ item.id ], results.fetch(0).fetch("thesis_ids")

    missing = Object.new
    missing.define_singleton_method(:feature_results) { [] }
    results = command.send(
      :merged_feature_results, {}, missing, [ feature("search") ], []
    )
    assert_equal "missing_feature_result", results.fetch(0).dig("errors", 0, "error")
  end

  def test_v2_payload_error_fallbacks_and_nonterminal_zero_reason
    command = Hive::Commands::RefactorPatrol.new("demo", json: true, dry_run: true, pr: "7")
    manifest = pr_manifest
    command.instance_variable_set(:@manifest, manifest)
    command.instance_variable_set(:@checkout_snapshot, { "analysis_sha" => "head" })
    command.instance_variable_set(:@reporter, Hive::RefactorPatrol::Reporter.new(Hive::Config::DEFAULTS))
    reviewer = Object.new
    reviewer.define_singleton_method(:review_errors) do
      [ { "feature_id" => "checkout", "error" => "agent_failed" } ]
    end

    payload = command.send(
      :build_v2_payload, { "name" => "demo" }, "/repo", [ feature("checkout") ], [], [], reviewer
    )
    assert_equal "agent_failed", payload.fetch("review_errors").fetch(0).fetch("error")

    payload = command.send(
      :build_v2_payload, { "name" => "demo" }, "/repo", [ feature("checkout") ], [], [], Object.new
    )
    assert_empty payload.fetch("review_errors")
    assert_nil command.send(
      :final_zero_reason,
      [ feature("checkout") ], [ thesis("one") ],
      { "accepted" => [], "flagged" => [], "suppressed" => [] }
    )
  end

  def test_job_bound_paths_and_action_aggregate_identity_are_enforced
    with_refactor_patrol_project do |repo|
      manifest = pr_manifest
      command = Hive::Commands::RefactorPatrol.new(
        "demo", json: true, job_manifest: "/tmp/outside.json"
      )
      command.instance_variable_set(:@manifest, manifest)
      error = assert_raises(Hive::ConfigError) do
        command.send(:load_job_manifest!, { "name" => "demo" }, repo, Hive::Config.load(repo))
      end
      assert_match(/must be a published file/, error.message)

      command.instance_variable_set(:@result_file, "/tmp/result.json")
      error = assert_raises(Hive::ConfigError) do
        command.send(:validate_result_file!, repo)
      end
      assert_match(/must be a job-bound file/, error.message)

      aggregate = lifecycle_aggregate(manifest, nil).merge(
        "source" => source_context(manifest).merge("repository" => "other/repo")
      )
      result = Struct.new(:aggregate, :completeness).new(aggregate, {})
      error = assert_raises(Hive::ConfigError) do
        command.send(:build_action_payload, { "name" => "demo" }, repo, result)
      end
      assert_match(/does not match its immutable manifest/, error.message)
    end
  end

  def test_action_payload_projects_only_public_receipt_fields
    manifest = pr_manifest
    item = thesis("action", fingerprint: "fp-action")
    action = {
      "canonical_action_id" => "issue-fp-action", "thesis_id" => item.id,
      "thesis_fingerprint" => item.fingerprint, "kind" => "issue",
      "family_id" => "family-1", "owner_job_id" => manifest.fetch("job_id"),
      "outcome" => "issue_filed", "terminal" => true,
      "receipts" => { "issue_url" => "https://github.com/acme/demo/issues/9" },
      "private_claim" => "must-not-leak"
    }
    aggregate = lifecycle_aggregate(manifest, item, actions: [ action ])
    command = Hive::Commands::RefactorPatrol.new("demo", json: true, job_manifest: "job.json")
    command.instance_variable_set(:@manifest, manifest)
    result = Struct.new(:aggregate, :completeness).new(aggregate, { "state" => "complete" })

    payload = command.send(:build_action_payload, { "name" => "demo" }, "/repo", result)

    projected = payload.fetch("actions").fetch(0)
    assert_equal "issue-fp-action", projected.fetch("canonical_action_id")
    refute projected.key?("private_claim")
  end

  def test_error_result_write_failure_does_not_mask_original_error
    command = Hive::Commands::RefactorPatrol.new("demo", json: true)
    command.define_singleton_method(:write_result_file) { |_payload| raise IOError, "disk full" }

    out, _err = capture_io do
      command.send(:emit_error, Hive::ConfigError.new("bad flags"))
    end

    assert_equal "bad flags", JSON.parse(out).fetch("message")
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
                  pr: nil, job_manifest: nil, actions: false, result_file: nil, manifest_resolver: nil, features: [], theses_by_feature: {}, reviewer: nil, leverage_scores: {},
                  use_default_mapper: false, repository_ownership: nil)
    reviewer ||= FakeReviewer.new(theses_by_feature)
    repository_ownership ||= lambda do |**_arguments|
      Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :full, reason: nil, evidence: {}
      )
    end
    Hive::Commands::RefactorPatrol.new(
      project,
      json: json,
      dry_run: dry_run,
      feature: feature_hint,
      entrypoint: entrypoint_hint,
      path: path_hint,
      changed_since: changed_since,
      pr: pr,
      job_manifest: job_manifest,
      actions: actions,
      result_file: result_file,
      mapper_factory: use_default_mapper ? nil : ->(_root, _cfg, _state) { FakeMapper.new(features) },
      reviewer_factory: ->(_root, _cfg, _state) { reviewer },
      leverage_factory: ->(_root, _cfg) { FakeLeverage.new(leverage_scores) },
      manifest_resolver_factory: manifest_resolver && ->(*) { manifest_resolver },
      repository_ownership: repository_ownership
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
      [
        feature_id,
        {
          "scope" => "feature",
          "score" => score,
          "breakdown" => { "churn" => score },
          "signals" => { "churn" => 10 },
          "normalized" => { "churn" => 1.0 }
        }
      ]
    end
  end

  def thesis(id, feature_id: "checkout", score: 0.9, fingerprint: "fp", est_files: 2,
             admissible: true, admissibility_reason: "evidence cites concrete paths and measurable signals",
             flags: [], boundary_files: nil)
    boundary_files ||= [ "lib/#{feature_id}.rb" ]
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: feature_id,
      feature: feature_id.capitalize,
      problem: "#{feature_id} mixes validation and orchestration",
      cost: "Frequent changes fan out across callers",
      evidence: [
        {
          "file" => boundary_files.first,
          "line" => 1,
          "snippet" => "entrypoint",
          "claim" => "validation and orchestration share one boundary"
        }
      ],
      proposed_refactor: "Extract a #{feature_id} boundary service",
      feature_boundary: { "owned_files" => boundary_files, "entrypoints" => boundary_files },
      feature_hotspot: {
        "scope" => "feature",
        "score" => 1.0,
        "breakdown" => { "churn" => 1.0 },
        "signals" => { "churn" => 10 },
        "normalized" => { "churn" => 1.0 }
      },
      expected_leverage: {
        "score" => score,
        "breakdown" => { "churn" => score },
        "drivers" => [ { "signal" => "churn", "relief" => score, "mechanism" => "isolate recurring edits" } ]
      },
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
    @refactor_schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 1)))
    )
  end

  def v2_refactor_schemer
    @v2_refactor_schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2)))
    )
  end

  def pr_manifest(merge_sha: "7" * 40, changed_paths: [ "lib/checkout.rb" ])
    {
      "schema" => "hive-refactor-patrol-pr-manifest",
      "schema_version" => 2,
      "job_id" => "pr-7-deadbeef",
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "master",
        "base_sha" => "6" * 40,
        "merge_sha" => merge_sha,
        "merged_at" => "2026-07-10T10:00:00Z"
      },
      "files" => changed_paths.map { |path| { "path" => path, "status" => "modified" } },
      "changed_paths" => changed_paths,
      "manifest_checksum" => "checksum"
    }
  end

  def source_context(manifest)
    manifest.fetch("source").merge(
      "changed_paths" => manifest.fetch("changed_paths"),
      "manifest_checksum" => manifest.fetch("manifest_checksum")
    )
  end

  def lifecycle_aggregate(manifest, item, actions: [])
    accepted = if item
      [
        {
          "id" => item.id, "feature_id" => item.feature_id,
          "fingerprint" => item.fingerprint,
          "score" => item.expected_leverage.fetch("score"),
          "admissible" => true, "reasons" => [], "thesis" => item.to_h
        }
      ]
    else
      []
    end
    {
      "job_id" => manifest.fetch("job_id"), "source" => source_context(manifest),
      "analysis_sha" => "head", "state" => "complete", "complete" => true,
      "dispositions" => { "accepted" => accepted, "flagged" => [], "suppressed" => [] },
      "feature_results" => [], "review_errors" => [], "zero_reason" => item ? nil : "no_theses",
      "attempts" => [], "actions" => actions
    }
  end

  def with_manifest_checksum(manifest)
    payload = manifest.reject { |key, _value| key == "manifest_checksum" }
    manifest.merge("manifest_checksum" => ::Digest::SHA256.hexdigest(canonical_json(payload)))
  end

  def publish_job_manifest(repo, manifest)
    root = File.join(repo, ".hive-state", "refactor_patrol", "v2", "manifests")
    FileUtils.mkdir_p(root)
    path = File.join(root, "#{manifest.fetch('job_id')}.json")
    File.write(path, JSON.pretty_generate(manifest))
    path
  end

  def canonical_json(value)
    normalized = case value
    when Hash
      value.keys.sort.to_h { |key| [ key, JSON.parse(canonical_json(value.fetch(key))) ] }
    when Array
      value.map { |item| JSON.parse(canonical_json(item)) }
    else
      value
    end
    JSON.generate(normalized)
  end

  def thesis_schemer
    @thesis_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-thesis"))))
  end
end
