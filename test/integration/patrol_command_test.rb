require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require "hive/commands/patrol"
require "hive/config"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/fixer"
require "hive/patrol/pr_opener"

class PatrolCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeMapper
    def initialize(features)
      @features = features
    end

    def call
      @features
    end
  end

  class FakeReviewer
    attr_reader :review_errors, :features

    def initialize(findings, review_errors: [])
      @findings = findings
      @review_errors = review_errors
    end

    def call(features)
      @features = features
      @findings
    end
  end

  class FakeFixer
    attr_reader :attempted

    def initialize(patch)
      @patch = patch
      @attempted = []
    end

    def attempt(finding)
      @attempted << finding.id
      @patch
    end
  end

  class FakePrOpener
    attr_reader :opened

    def initialize(result)
      @result = result
      @opened = []
    end

    def open(finding, patch)
      @opened << [ finding.id, patch.id ]
      @result
    end
  end

  class MappedFixer
    attr_reader :attempted

    def initialize(by_id)
      @by_id = by_id
      @attempted = []
    end

    def attempt(finding)
      @attempted << finding.id
      @by_id.fetch(finding.id)
    end
  end

  class FakeDismissals
    def reconcile
      {}
    end
  end

  def test_patrol_json_cycle_validates_and_records_state
    with_patrol_project do |repo|
      feature = sample_feature
      finding = sample_finding
      patch = sample_patch(repo, finding)
      pr_result = Hive::Patrol::PrOpener::Result.new(status: :opened, pr_url: "https://example.com/pull/7")

      out, err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ feature ]),
          reviewer: FakeReviewer.new([ finding ]),
          fixer: FakeFixer.new(patch),
          pr_opener: FakePrOpener.new(pr_result)
        ).call
      end

      assert_equal "", err
      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal 1, out.lines.count
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload), patrol_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal "demo", payload.fetch("project")
      assert_equal 1, payload.fetch("features_mapped")
      assert_equal 1, payload.fetch("features_review_attempted")
      assert_equal 1, payload.fetch("features_reviewed")
      assert_equal true, payload.fetch("review_complete")
      assert_empty payload.fetch("review_errors")
      assert_equal 1, payload.fetch("findings")
      assert_equal 1, payload.fetch("fix_candidates")
      assert_equal 1, payload.fetch("fixes_attempted")
      assert_equal 1, payload.fetch("fixes_validated")
      assert_equal [ "https://example.com/pull/7" ], payload.fetch("pr_urls")
      assert_equal [], payload.fetch("review_handoff_errors")
      assert_equal "opened", payload.dig("fix_results", 0, "publication_status")

      state = JSON.parse(File.read(File.join(repo, ".hive-state", "patrol", "state.json")))
      assert_equal payload.fetch("last_scanned_sha"), state.fetch("last_scanned_sha")
      refute_empty state.fetch("last_run_at")
      selection_path = Dir[File.join(repo, ".hive-state", "patrol", "runs", "selection-*.json")].first
      refute_nil selection_path
      selection = JSON.parse(File.read(selection_path))
      assert_equal "hive-patrol-selection", selection.fetch("schema")
      assert_equal [ finding.id ], selection.fetch("ranked_candidates").map { |item| item.fetch("finding_id") }
      assert_operator selection.dig("ranked_candidates", 0, "alpha_score"), :>=, 70
    end
  end

  def test_patrol_json_reports_review_handoff_failures
    with_patrol_project do |repo|
      feature = sample_feature
      finding = sample_finding
      patch = sample_patch(repo, finding)
      pr_result = Hive::Patrol::PrOpener::Result.new(
        status: :opened_review_handoff_failed,
        pr_url: "https://example.com/pull/7",
        reason: "review_handoff_failed"
      )

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ feature ]),
          reviewer: FakeReviewer.new([ finding ]),
          fixer: FakeFixer.new(patch),
          pr_opener: FakePrOpener.new(pr_result)
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload), patrol_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal 1, payload.fetch("prs_opened")
      assert_equal [ "https://example.com/pull/7" ], payload.fetch("pr_urls")
      assert_equal [
        { "pr_url" => "https://example.com/pull/7", "reason" => "review_handoff_failed" }
      ], payload.fetch("review_handoff_errors")
    end
  end

  def test_patrol_dry_run_reviews_but_does_not_fix_or_open_pr
    with_patrol_project do |repo|
      set_patrol_commands(repo, "format" => nil, "lint" => nil, "typecheck" => nil, "test" => nil)
      finder = sample_finding
      patch = sample_patch(repo, finder)
      fixer = FakeFixer.new(patch)
      pr_opener = FakePrOpener.new(Hive::Patrol::PrOpener::Result.new(status: :opened, pr_url: "https://example.com/pull/8"))

      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ finder ]),
          fixer: fixer,
          pr_opener: pr_opener
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload), patrol_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal true, payload.fetch("dry_run")
      assert_equal 1, payload.fetch("fix_candidates")
      assert_equal 0, payload.fetch("fixes_attempted")
      assert_equal 0, payload.fetch("prs_opened")
      assert_empty fixer.attempted
      assert_empty pr_opener.opened
    end
  end

  def test_patrol_without_validation_commands_fails_before_agent_work_or_state_mutation
    with_patrol_project do |repo|
      set_patrol_commands(repo, "format" => nil, "lint" => nil, "typecheck" => nil, "test" => nil)
      exploding_mapper = Class.new do
        def call
          raise "mapper must not run"
        end
      end.new

      out, err, status = with_captured_exit do
        command_for(mapper: exploding_mapper).call
      end

      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::CONFIG, status
      assert_equal "config", payload.fetch("error_kind")
      assert_includes payload.fetch("message"), "patrol.commands"
      assert_includes err, "patrol.commands"
      refute Dir.exist?(File.join(repo, ".hive-state", "patrol")),
             "preflight must fail before patrol state is created or watermarks can move"
    end
  end

  # Patrol must never write findings to the 1-inbox intake. Opened patrol
  # PRs may create synthetic 6-review tasks via PrOpener/ReviewHandoff;
  # this command-level test uses a fake opener, so only patrol's own state
  # tree is expected.
  def test_patrol_writes_nothing_under_inbox
    with_patrol_project do |repo|
      feature = sample_feature
      finding = sample_finding
      patch = sample_patch(repo, finding)
      pr_result = Hive::Patrol::PrOpener::Result.new(status: :opened, pr_url: "https://example.com/pull/9")

      _out, err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ feature ]),
          reviewer: FakeReviewer.new([ finding ]),
          fixer: FakeFixer.new(patch),
          pr_opener: FakePrOpener.new(pr_result)
        ).call
      end

      assert_equal "", err
      assert_equal Hive::ExitCodes::SUCCESS, status

      assert_empty Dir.glob(File.join(repo, "**", "1-inbox"), File::FNM_DOTMATCH),
                   "patrol must not create any */1-inbox/ stage folder"
      assert Dir.exist?(File.join(repo, ".hive-state", "patrol")),
             "patrol records scan state under .hive-state/patrol/"
    end
  end

  def test_default_mapper_reviews_language_neutral_components_without_monolithic_test_slices
    with_patrol_project do |repo|
      FileUtils.mkdir_p(File.join(repo, "lib", "acme"))
      FileUtils.mkdir_p(File.join(repo, "test", "acme"))
      File.write(File.join(repo, "lib", "acme", "service.flux"), "import './policy.flux'\n")
      File.write(File.join(repo, "lib", "acme", "policy.flux"), "policy = true\n")
      File.write(
        File.join(repo, "test", "acme", "service_test.flux"),
        "import '../../lib/acme/service.flux'\n"
      )
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "generic component", "--quiet")
      reviewer = FakeReviewer.new([])
      command = Hive::Commands::Patrol.new(
        "demo",
        json: true,
        dry_run: true,
        reviewer_factory: ->(_root, _cfg, _state) { reviewer },
        dismissals_factory: ->(_root, _state) { FakeDismissals.new }
      )

      _out, _err, status = with_captured_exit { command.call }

      assert_equal Hive::ExitCodes::SUCCESS, status
      ids = reviewer.features.map(&:id)
      assert_includes ids, "architecture-lib-acme"
      refute ids.any? { |id| id.start_with?("test-suite-") }
      component = reviewer.features.find { |feature| feature.id == "architecture-lib-acme" }
      assert_includes component.tests, "test/acme/service_test.flux"
    end
  end

  def test_mapper_and_reviewer_use_an_exact_detached_default_branch_checkout
    with_patrol_project do |repo|
      target_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      run!("git", "-C", repo, "switch", "-c", "topic", "--quiet")
      FileUtils.mkdir_p(File.join(repo, "lib"))
      File.write(File.join(repo, "lib", "topic_only.rb"), "TOPIC_ONLY = true\n")
      run!("git", "-C", repo, "add", "lib/topic_only.rb")
      run!("git", "-C", repo, "commit", "-m", "topic-only source", "--quiet")

      scan_roots = []
      mapper_factory = lambda do |root, _cfg, _state|
        scan_roots << root
        assert_equal target_sha, run!("git", "-C", root, "rev-parse", "HEAD").strip
        refute File.exist?(File.join(root, "lib", "topic_only.rb"))
        FakeMapper.new([ sample_feature ])
      end
      reviewer = FakeReviewer.new([])
      reviewer_factory = lambda do |root, _cfg, _state|
        scan_roots << root
        reviewer
      end

      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: mapper_factory,
          reviewer_factory: reviewer_factory
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal repo, payload.fetch("project_root"), "durable state remains anchored to the registered root"
      assert_equal target_sha, payload.fetch("last_scanned_sha")
      assert_equal 1, scan_roots.uniq.size
      refute_equal repo, scan_roots.first
      assert_equal "topic", run!("git", "-C", repo, "branch", "--show-current").strip
      worktrees = run!("git", "-C", repo, "worktree", "list", "--porcelain")
      refute_includes worktrees, scan_roots.first, "the detached scan checkout must be removed"
    end
  end

  def test_new_sweep_fetches_and_reviews_the_exact_remote_default
    with_patrol_project do |repo|
      origin = "#{repo}.origin.git"
      scratch = nil
      begin
        run!("git", "clone", "--bare", repo, origin)
        run!("git", "-C", repo, "remote", "add", "origin", origin)
        local_sha = run!("git", "-C", repo, "rev-parse", "master").strip

        scratch = Dir.mktmpdir("patrol-origin-pusher")
        run!("git", "clone", origin, scratch)
        run!("git", "-C", scratch, "config", "user.email", "test@example.com")
        run!("git", "-C", scratch, "config", "user.name", "Test")
        File.write(File.join(scratch, "fresh-upstream.txt"), "fresh\n")
        run!("git", "-C", scratch, "add", "fresh-upstream.txt")
        run!("git", "-C", scratch, "commit", "-m", "advance remote default", "--quiet")
        run!("git", "-C", scratch, "push", "origin", "master:master")
        remote_sha = run!("git", "-C", scratch, "rev-parse", "HEAD").strip

        scan_sha = nil
        out, _err, status = with_captured_exit do
          command_for(
            dry_run: true,
            mapper_factory: lambda do |root, _cfg, _state|
              scan_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
              assert File.exist?(File.join(root, "fresh-upstream.txt")),
                     "a new patrol sweep must review the freshly fetched remote default"
              FakeMapper.new([ sample_feature ])
            end,
            reviewer: FakeReviewer.new([])
          ).call
        end

        assert_equal Hive::ExitCodes::SUCCESS, status
        assert JSON.parse(out).fetch("ok")
        assert_equal remote_sha, scan_sha
        assert_equal local_sha, run!("git", "-C", repo, "rev-parse", "master").strip,
                     "patrol must not move the operator's local default branch"
      ensure
        FileUtils.rm_rf(scratch) if scratch
        FileUtils.rm_rf(origin)
      end
    end
  end

  def test_new_sweep_fails_closed_when_remote_default_cannot_be_fetched
    with_patrol_project do |repo|
      missing_origin = File.join(File.dirname(repo), "missing-origin.git")
      run!("git", "-C", repo, "remote", "add", "origin", missing_origin)
      reviewer_ran = false

      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          reviewer_factory: lambda do |_root, _cfg, _state|
            reviewer_ran = true
            FakeReviewer.new([])
          end
        ).call
      end

      assert_equal Hive::ExitCodes::SOFTWARE, status
      refute reviewer_ran
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_includes payload.fetch("message"), "cannot fetch fresh patrol scan base"
    end
  end

  def test_unmaterializable_active_snapshot_restarts_from_the_current_default
    with_patrol_project do |repo|
      missing_sha = "f" * 40
      state_dir = File.join(repo, ".hive-state", "patrol")
      FileUtils.mkdir_p(state_dir)
      File.write(
        File.join(state_dir, "state.json"),
        JSON.generate(
          "last_scanned_sha" => "PRIOR",
          "feature_review_active" => true,
          "feature_review_sha" => missing_sha,
          "feature_review_cursor" => 1
        )
      )
      current_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      features = (1..2).map do |index|
        Hive::Patrol::Feature.new(
          id: "feature-#{index}", kind: "architecture", entrypoints: [],
          owned_files: [], context_files: [], tests: []
        )
      end
      reviewer = FakeReviewer.new([])
      scanned_sha = nil

      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: lambda do |root, _cfg, _state|
            scanned_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
            FakeMapper.new(features)
          end,
          reviewer: reviewer
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal current_sha, scanned_sha
      assert_equal %w[feature-1 feature-2], reviewer.features.map(&:id),
                   "a replacement snapshot must restart the feature cursor"
      assert_equal current_sha, JSON.parse(out).fetch("last_scanned_sha")
    end
  end

  def test_scan_checkout_rejects_a_sha_other_than_the_requested_target
    command = command_for(dry_run: true)
    git_calls = []
    command.define_singleton_method(:git_output!) do |root, *args|
      git_calls << [ root, args ]
      args == [ "rev-parse", "HEAD" ] ? "unexpected-sha\n" : ""
    end

    error = assert_raises(Hive::GitError) do
      command.send(:with_scan_checkout, "/project", "expected-sha") { flunk "must not yield" }
    end

    assert_includes error.message, 'resolved "unexpected-sha", expected "expected-sha"'
    assert git_calls.any? { |_root, args| args.first(3) == [ "worktree", "remove", "--force" ] },
           "a mismatched detached checkout must still be removed"
  end

  # Cleanup failure must not mask the scan outcome: a reviewer crash keeps
  # its own exception, and a completed scan keeps its result — a leaked
  # detached checkout (fresh mktmpdir path each cycle) is recoverable, a
  # discarded clean review cycle is not.
  def test_scan_checkout_removal_failure_does_not_mask_a_reviewer_crash
    command = command_for(dry_run: true)
    command.define_singleton_method(:git_output!) do |_root, *args|
      raise Hive::GitError, "removal blocked" if args.first(3) == [ "worktree", "remove", "--force" ]

      args == [ "rev-parse", "HEAD" ] ? "expected-sha\n" : ""
    end

    error = nil
    _out, err = capture_io do
      error = assert_raises(RuntimeError) do
        command.send(:with_scan_checkout, "/project", "expected-sha") { raise "reviewer crashed" }
      end
    end

    assert_equal "reviewer crashed", error.message,
                 "the checkout-removal failure must not replace the reviewer's exception"
    assert_match(/removal blocked/, err)
  end

  def test_scan_checkout_removal_failure_after_success_preserves_the_result
    command = command_for(dry_run: true)
    command.define_singleton_method(:git_output!) do |_root, *args|
      raise Hive::GitError, "removal blocked" if args.first(3) == [ "worktree", "remove", "--force" ]

      args == [ "rev-parse", "HEAD" ] ? "expected-sha\n" : ""
    end

    result = nil
    _out, err = capture_io do
      result = command.send(:with_scan_checkout, "/project", "expected-sha") { :scan_result }
    end

    assert_equal :scan_result, result,
                 "a completed clean scan must not be discarded because only cleanup failed"
    assert_match(/removal blocked/, err)
  end

  def test_git_output_reports_the_command_failure
    Dir.mktmpdir do |root|
      error = assert_raises(Hive::GitError) do
        command_for.send(:git_output!, root, "rev-parse", "HEAD")
      end

      assert_includes error.message, "git rev-parse HEAD failed:"
      assert_match(/not a git repository/i, error.message)
    end
  end

  def test_fresh_scan_base_rejects_unresolved_or_invalid_local_default
    command = command_for
    cfg = { "default_branch" => "master" }
    status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }

    with_replaced_singleton_method(Hive::Worktree, :origin_configured?, ->(_root) { false }) do
      with_replaced_singleton_method(
        Open3, :capture3, ->(*) { [ "", "missing default", status.new(1) ] }
      ) do
        error = assert_raises(Hive::GitError) do
          command.send(:current_default_sha, "/project", cfg)
        end
        assert_includes error.message, "git rev-parse master failed: missing default"
      end

      with_replaced_singleton_method(
        Open3, :capture3, ->(*) { [ "not-an-oid\n", "", status.new(0) ] }
      ) do
        error = assert_raises(Hive::GitError) do
          command.send(:current_default_sha, "/project", cfg)
        end
        assert_includes error.message, "fresh patrol scan base resolved an invalid SHA"
      end
    end
  end

  def test_reviewer_cannot_leave_uncommitted_scan_mutations
    with_patrol_project do |repo|
      scan_root = nil
      reviewer_factory = lambda do |root, _cfg, _state|
        scan_root = root
        reviewer = Object.new
        reviewer.define_singleton_method(:review_errors) { [] }
        reviewer.define_singleton_method(:call) do |_features|
          File.write(File.join(root, "reviewer-uncommitted.txt"), "mutation\n")
          []
        end
        reviewer
      end

      out, err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer_factory: reviewer_factory
        ).call
      end

      refute_equal Hive::ExitCodes::SUCCESS, status
      assert_includes err, "patrol reviewer modified its detached scan checkout"
      assert_equal false, JSON.parse(out).fetch("ok")
      refute_includes run!("git", "-C", repo, "worktree", "list", "--porcelain"), scan_root
    end
  end

  def test_reviewer_cannot_hide_scan_mutation_inside_a_commit
    with_patrol_project do |repo|
      scan_root = nil
      reviewer_factory = lambda do |root, _cfg, _state|
        scan_root = root
        reviewer = Object.new
        reviewer.define_singleton_method(:review_errors) { [] }
        reviewer.define_singleton_method(:call) do |_features|
          File.write(File.join(root, "reviewer-commit.txt"), "mutation\n")
          system("git", "-C", root, "add", "reviewer-commit.txt", exception: true)
          system("git", "-C", root, "commit", "-m", "reviewer mutation", "--quiet", exception: true)
          []
        end
        reviewer
      end

      out, err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer_factory: reviewer_factory
        ).call
      end

      refute_equal Hive::ExitCodes::SUCCESS, status
      assert_includes err, "patrol reviewer changed its detached scan commit"
      assert_equal false, JSON.parse(out).fetch("ok")
      refute_includes run!("git", "-C", repo, "worktree", "list", "--porcelain"), scan_root
    end
  end

  def test_review_errors_do_not_advance_last_scanned_sha
    with_patrol_project do |repo|
      state_dir = File.join(repo, ".hive-state", "patrol")
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, "state.json"), JSON.generate("last_scanned_sha" => "PRIOR"))

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new(
            [],
            review_errors: [
              { "feature_id" => "route-home", "error" => "agent_failed", "message" => "provider failed" }
            ]
          )
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload), patrol_schemer.validate(payload).map { |e| e["error"] }.inspect

      state = JSON.parse(File.read(File.join(state_dir, "state.json")))
      assert_equal "PRIOR", state.fetch("last_scanned_sha"),
                   "a partial scan (a feature errored) must not advance the scanned-SHA watermark"
      assert_equal "PRIOR", payload.fetch("last_scanned_sha")
      assert_equal 1, payload.fetch("features_review_attempted")
      assert_equal 0, payload.fetch("features_reviewed")
      assert_equal false, payload.fetch("review_complete")
      assert_equal [
        { "feature_id" => "route-home", "error" => "agent_failed", "message" => "provider failed" }
      ], payload.fetch("review_errors")
      refute_empty state.fetch("last_run_at"), "last_run_at still advances on a partial scan"
    end
  end

  def test_first_batch_review_error_retries_the_pinned_snapshot_after_default_advances
    with_patrol_project do |repo|
      cfg_path = File.join(repo, ".hive-state", "config.yml")
      cfg = YAML.safe_load_file(cfg_path, aliases: true)
      cfg["patrol"]["max_features_per_cycle"] = 2
      File.write(cfg_path, cfg.to_yaml)
      features = (1..2).map do |index|
        Hive::Patrol::Feature.new(
          id: "feature-#{index}", kind: "architecture", entrypoints: [],
          owned_files: [], context_files: [], tests: []
        )
      end
      first_sweep_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      first_scan_sha = nil
      first_reviewer = FakeReviewer.new(
        [],
        review_errors: [
          { "feature_id" => "feature-1", "error" => "agent_failed", "message" => "provider failed" }
        ]
      )

      first_out, _first_err, first_status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: lambda do |root, _cfg, _state|
            first_scan_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
            FakeMapper.new(features)
          end,
          reviewer: first_reviewer
        ).call
      end
      state_path = File.join(repo, ".hive-state", "patrol", "state.json")
      first_state = JSON.parse(File.read(state_path))
      File.write(File.join(repo, "after-review-error.txt"), "advance default branch\n")
      run!("git", "-C", repo, "add", "after-review-error.txt")
      run!("git", "-C", repo, "commit", "-m", "advance default after review error", "--quiet")
      advanced_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      second_scan_sha = nil
      second_reviewer = FakeReviewer.new([])

      second_out, _second_err, second_status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: lambda do |root, _cfg, _state|
            second_scan_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
            FakeMapper.new(features)
          end,
          reviewer: second_reviewer
        ).call
      end
      second_state = JSON.parse(File.read(state_path))

      assert_equal Hive::ExitCodes::SUCCESS, first_status
      assert_equal Hive::ExitCodes::SUCCESS, second_status
      assert_equal first_sweep_sha, first_scan_sha
      assert_equal true, first_state.fetch("feature_review_active")
      assert_equal first_sweep_sha, first_state.fetch("feature_review_sha")
      assert_equal 0, first_state.fetch("feature_review_cursor")
      refute_equal first_sweep_sha, advanced_sha
      assert_equal first_sweep_sha, second_scan_sha,
                   "a failed first batch must retry its pinned SHA even though its cursor is zero"
      assert_equal %w[feature-1 feature-2], second_reviewer.features.map(&:id)
      assert_equal false, JSON.parse(first_out).fetch("review_complete")
      assert_equal true, JSON.parse(second_out).fetch("review_complete")
      assert_equal false, second_state.fetch("feature_review_active"),
                   "a completed retry must release the pinned snapshot"
    end
  end

  def test_review_error_preserves_the_nonzero_cursor_for_the_same_pinned_snapshot
    with_patrol_project do |repo|
      target_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      state_dir = File.join(repo, ".hive-state", "patrol")
      FileUtils.mkdir_p(state_dir)
      File.write(
        File.join(state_dir, "state.json"),
        JSON.generate(
          "last_scanned_sha" => "PRIOR",
          "feature_review_active" => true,
          "feature_review_sha" => target_sha,
          "feature_review_cursor" => 1
        )
      )
      features = (1..2).map do |index|
        Hive::Patrol::Feature.new(
          id: "feature-#{index}", kind: "architecture", entrypoints: [],
          owned_files: [], context_files: [], tests: []
        )
      end
      reviewer = FakeReviewer.new(
        [], review_errors: [
          { "feature_id" => "feature-2", "error" => "agent_failed", "message" => "provider failed" }
        ]
      )

      _out, _err, status = with_captured_exit do
        command_for(mapper: FakeMapper.new(features), reviewer: reviewer, dry_run: true).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      state = JSON.parse(File.read(File.join(state_dir, "state.json")))
      assert_equal target_sha, state.fetch("feature_review_sha")
      assert_equal 1, state.fetch("feature_review_cursor")
      assert_equal [ "feature-2" ], reviewer.features.map(&:id)
    end
  end

  def test_default_reviewer_and_fixer_builders_receive_the_shared_budget
    with_patrol_project do |repo|
      cfg = Hive::Config.load(repo)
      state = Hive::Patrol::StateStore.new(repo)
      budget = Object.new
      command = Hive::Commands::Patrol.new("demo")

      reviewer = command.send(:build_reviewer, repo, cfg, state, budget)
      fixer = command.send(:build_fixer, repo, cfg, state, budget)

      assert_instance_of Hive::Patrol::Reviewer, reviewer
      assert_instance_of Hive::Patrol::Fixer, fixer
      assert_same budget, reviewer.instance_variable_get(:@token_budget)
      assert_same budget, fixer.instance_variable_get(:@token_budget)
    end
  end

  # max_prs_per_cycle caps PRs *opened*, not fix candidates: a failed
  # validation must not consume the budget, and a fixable later candidate
  # must still be attempted. With the default cap of 3 and four eligible
  # findings where the first fails validation, all four are attempted and
  # three PRs open (the old candidate-cap stopped after three attempts and
  # opened only two).
  def test_max_prs_caps_opened_prs_not_attempted_candidates
    with_patrol_project do |repo|
      findings = (1..4).map { |n| finding_with(id: "finding-#{n}", fingerprint: "fp-#{n}") }
      patches = {
        "finding-1" => failing_patch(findings[0]),
        "finding-2" => sample_patch(repo, findings[1]),
        "finding-3" => sample_patch(repo, findings[2]),
        "finding-4" => sample_patch(repo, findings[3])
      }
      fixer = MappedFixer.new(patches)
      pr_opener = FakePrOpener.new(
        Hive::Patrol::PrOpener::Result.new(status: :opened, pr_url: "https://example.com/pull/1")
      )

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new(findings),
          fixer: fixer,
          pr_opener: pr_opener
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal 4, payload.fetch("fix_candidates")
      assert_equal 4, payload.fetch("fixes_attempted"),
                   "all candidates are attempted until the PR budget is filled"
      assert_equal 3, payload.fetch("prs_opened"), "max_prs_per_cycle caps opened PRs at 3"
      assert_includes fixer.attempted, "finding-4",
                      "a failed early candidate must not starve a fixable later one"
    end
  end

  def test_max_fix_attempts_bounds_failed_or_rejected_agent_work
    with_patrol_project do |repo|
      cfg_path = File.join(repo, ".hive-state", "config.yml")
      cfg = YAML.safe_load_file(cfg_path, aliases: true)
      cfg["patrol"]["max_fix_attempts_per_cycle"] = 2
      File.write(cfg_path, cfg.to_yaml)
      findings = (1..4).map { |n| finding_with(id: "finding-#{n}", fingerprint: "fp-#{n}") }
      fixer = MappedFixer.new(findings.to_h { |finding| [ finding.id, failing_patch(finding) ] })

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new(findings),
          fixer: fixer
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal 4, payload.fetch("fix_candidates")
      assert_equal 2, payload.fetch("fixes_attempted")
      assert_equal %w[finding-1 finding-2], fixer.attempted
      assert_equal 0, payload.fetch("prs_opened")
    end
  end

  def test_feature_review_budget_rotates_and_advances_sha_only_after_full_sweep
    with_patrol_project do |repo|
      cfg_path = File.join(repo, ".hive-state", "config.yml")
      cfg = YAML.safe_load_file(cfg_path, aliases: true)
      cfg["patrol"]["max_features_per_cycle"] = 2
      File.write(cfg_path, cfg.to_yaml)
      features = (1..3).map do |index|
        Hive::Patrol::Feature.new(
          id: "feature-#{index}", kind: "architecture", entrypoints: [],
          owned_files: [], context_files: [], tests: []
        )
      end
      first_reviewer = FakeReviewer.new([])
      second_reviewer = FakeReviewer.new([])
      third_reviewer = FakeReviewer.new([])
      first_sweep_sha = run!("git", "-C", repo, "rev-parse", "master").strip

      first_out, = with_captured_exit do
        command_for(dry_run: true, mapper: FakeMapper.new(features), reviewer: first_reviewer).call
      end
      File.write(File.join(repo, "after-first-batch.txt"), "new default branch commit\n")
      run!("git", "-C", repo, "add", "after-first-batch.txt")
      run!("git", "-C", repo, "commit", "-m", "advance default during patrol sweep", "--quiet")
      advanced_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      second_scan_sha = nil
      second_out, = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: lambda do |root, _cfg, _state|
            second_scan_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
            FakeMapper.new(features)
          end,
          reviewer: second_reviewer
        ).call
      end
      third_scan_sha = nil
      third_out, = with_captured_exit do
        command_for(
          dry_run: true,
          mapper_factory: lambda do |root, _cfg, _state|
            third_scan_sha = run!("git", "-C", root, "rev-parse", "HEAD").strip
            FakeMapper.new(features)
          end,
          reviewer: third_reviewer
        ).call
      end

      first = JSON.parse(first_out)
      second = JSON.parse(second_out)
      third = JSON.parse(third_out)
      assert_equal %w[feature-1 feature-2], first_reviewer.features.map(&:id)
      assert_equal [ "feature-3" ], second_reviewer.features.map(&:id)
      assert_equal %w[feature-1 feature-2], third_reviewer.features.map(&:id)
      assert_equal first_sweep_sha, second_scan_sha,
                   "an active cursor must finish its stored SHA instead of restarting on every new commit"
      assert_equal advanced_sha, third_scan_sha,
                   "the cycle after completion must start a fresh sweep at the new default SHA"
      assert_equal 2, first.fetch("features_review_attempted")
      assert_equal 2, first.fetch("features_reviewed")
      assert_equal false, first.fetch("review_complete")
      assert_equal "", first.fetch("last_scanned_sha")
      assert_equal 1, second.fetch("features_review_attempted")
      assert_equal 1, second.fetch("features_reviewed")
      assert_equal true, second.fetch("review_complete")
      assert_equal first_sweep_sha, second.fetch("last_scanned_sha")
      assert_equal false, third.fetch("review_complete")
      assert_equal first_sweep_sha, third.fetch("last_scanned_sha")
    end
  end

  def test_fixer_rejection_remains_an_attempt_outcome_without_durable_suppression
    with_patrol_project do |repo|
      finding = sample_finding
      finding.fingerprint = "resolved-fp"
      patch = Hive::Patrol::Fixer::PatchAttempt.new(
        id: "patch-rejected", finding: finding, branch: "hive-patrol/rejected",
        worktree_path: nil,
        validation: { "passed" => false, "reason" => "fix_agent_rejected" },
        passed: false, diffstat: "", head_sha: nil
      )

      out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]), reviewer: FakeReviewer.new([ finding ]),
          fixer: FakeFixer.new(patch)
        ).call
      end

      payload = JSON.parse(out)
      assert_equal "fix_agent_rejected", payload.dig("fix_results", 0, "reason")
      assert_equal false, payload.dig("fix_results", 0, "passed")
      fingerprint_path = File.join(repo, ".hive-state", "patrol", "fingerprints.json")
      fingerprints = File.exist?(fingerprint_path) ? JSON.parse(File.read(fingerprint_path)) : {}
      refute fingerprints.key?("resolved-fp"), "a fixer rejection must not permanently suppress the finding"
    end
  end

  def test_unknown_fixer_reason_is_reported_as_a_fix_error
    with_patrol_project do |repo|
      finding = sample_finding
      patch = Hive::Patrol::Fixer::PatchAttempt.new(
        id: "patch-unknown-reason", finding: finding, branch: "hive-patrol/unknown-reason",
        worktree_path: repo,
        validation: { "passed" => false, "reason" => "provider_invented_reason" },
        passed: false, diffstat: "", head_sha: nil
      )

      out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]), reviewer: FakeReviewer.new([ finding ]),
          fixer: FakeFixer.new(patch)
        ).call
      end

      payload = JSON.parse(out)
      assert_equal "fix_error", payload.dig("fix_results", 0, "reason")
      assert_equal 'unrecognized fixer reason "provider_invented_reason"',
                   payload.dig("fix_results", 0, "detail")
    end
  end

  def test_unknown_project_emits_json_config_error
    with_tmp_global_config do
      out, err, status = with_captured_exit { command_for.call }
      payload = JSON.parse(out)

      assert_equal Hive::ExitCodes::CONFIG, status
      assert_match(/unknown project/, err)
      assert patrol_schemer.valid?(payload), patrol_schemer.validate(payload).map { |e| e["error"] }.inspect
      assert_equal false, payload.fetch("ok")
      assert_equal "config", payload.fetch("error_kind")
    end
  end

  def test_non_json_success_and_internal_error_payload
    with_patrol_project do
      out, _err, status = with_captured_exit do
        command_for(
          json: false,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_match(/hive patrol: demo mapped=1 findings=0 fixes=0 prs=0/, out)

      exploding_mapper = Class.new do
        def call
          raise RuntimeError, "boom"
        end
      end.new
      out, _err, status = with_captured_exit do
        command_for(mapper: exploding_mapper).call
      end

      assert_equal Hive::ExitCodes::SOFTWARE, status
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "InternalError", payload.fetch("error_class")
    end
  end

  private

  def set_patrol_commands(repo, commands)
    path = File.join(repo, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(path))
    cfg["patrol"]["commands"] = commands
    File.write(path, cfg.to_yaml)
  end

  def with_patrol_project
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        cfg = Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          {
            "project_name" => "demo",
            "default_branch" => "master",
            "patrol" => {
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

  def command_for(project: "demo", json: true, dry_run: false, mapper: FakeMapper.new([]),
                  reviewer: FakeReviewer.new([]), mapper_factory: nil, reviewer_factory: nil,
                  fixer: FakeFixer.new(nil),
                  pr_opener: FakePrOpener.new(Hive::Patrol::PrOpener::Result.new(status: :skipped)))
    Hive::Commands::Patrol.new(
      project,
      json: json,
      dry_run: dry_run,
      mapper_factory: mapper_factory || ->(_root, _cfg, _state) { mapper },
      reviewer_factory: reviewer_factory || ->(_root, _cfg, _state) { reviewer },
      fixer_factory: ->(_root, _cfg, _state) { fixer },
      pr_opener_factory: ->(_root, _cfg, _state) { pr_opener },
      dismissals_factory: ->(_root, _state) { FakeDismissals.new }
    )
  end

  def sample_feature
    Hive::Patrol::Feature.new(
      id: "route-home",
      kind: "route",
      entrypoints: [ "app.rb" ],
      owned_files: [ "app.rb" ],
      context_files: [],
      tests: [ "test/app_test.rb" ]
    )
  end

  def sample_finding
    Hive::Patrol::Finding.new(
      id: "finding-1",
      feature_id: "route-home",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Nil route receiver",
      description: "The route calls through a nil receiver.",
      recommendation: "Guard the receiver before use.",
      scope: "cross_feature",
      contract: "A missing route record must return not found.",
      impact: "A valid request crashes before returning a response.",
      root_cause: "The shared lookup assumes every id resolves.",
      reproduction: "Request the route with a well-formed unknown id.",
      validation: "Run a focused request regression and the request suite.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "user.name" } ]
    )
  end

  def finding_with(id:, fingerprint:)
    semantics = {
      "finding-1" => [ "Scheduler claim survives rejected launch", "Dispatch rejection never releases the scheduler lease" ],
      "finding-2" => [ "Archive publication loses final rename", "Publication deletes its staging file before atomic replacement" ],
      "finding-3" => [ "Credential cache serves another tenant", "The cache key omits the tenant identity" ],
      "finding-4" => [ "Process watchdog abandons descendants", "The watchdog tracks only the exited group leader" ]
    }.fetch(id)
    Hive::Patrol::Finding.new(
      id: id,
      feature_id: "feature-#{id}",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: semantics.first,
      description: "A reachable operation #{id} loses committed work.",
      recommendation: "Repair the authoritative transition for #{id}.",
      scope: "cross_feature",
      contract: "Committed work #{id} must remain observable.",
      impact: "A real consumer permanently loses operation #{id}.",
      root_cause: semantics.last,
      reproduction: "Interrupt operation #{id} between persistence and acknowledgement.",
      validation: "Run the focused #{id} regression and subsystem suite.",
      evidence: [ { "file" => "lib/#{id}.rb", "line" => 1, "snippet" => "state.delete(:#{id})" } ],
      fingerprint: fingerprint
    )
  end

  def sample_patch(repo, finding)
    Hive::Patrol::Fixer::PatchAttempt.new(
      id: "patch-#{finding.id}",
      finding: finding,
      branch: "hive-patrol/route-home-abcdef12",
      worktree_path: repo,
      validation: { "commands" => [ { "name" => "test", "command" => "true", "exit_code" => 0 } ] },
      passed: true,
      diffstat: " app.rb | 1 +",
      head_sha: "abc123"
    )
  end

  def failing_patch(finding)
    Hive::Patrol::Fixer::PatchAttempt.new(
      id: "patch-failed-#{finding.id}",
      finding: finding,
      branch: "hive-patrol/route-home-failed",
      worktree_path: nil,
      validation: { "passed" => false, "reason" => "validation_failed" },
      passed: false,
      diffstat: "",
      head_sha: nil
    )
  end

  def patrol_schemer
    @patrol_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol"))))
  end
end
