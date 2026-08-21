require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require "hive/commands/patrol"
require "hive/config"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/state_store"

class PatrolCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeMapper
    def initialize(features)
      @features = features
    end

    def call = @features
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

  def test_patrol_records_findings_for_the_workflow_without_local_fix_or_publication
    with_patrol_project do |repo|
      finding = sample_finding

      out, err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ finding ])
        ).call
      end

      assert_equal "", err
      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload),
             patrol_schemer.validate(payload).map { |failure| failure["error"] }.inspect
      assert_equal 1, payload.fetch("findings")
      assert_equal 1, payload.fetch("fix_candidates")
      assert_equal 0, payload.fetch("fixes_attempted")
      assert_equal 0, payload.fetch("fixes_validated")
      assert_equal 0, payload.fetch("prs_opened")
      assert_empty payload.fetch("pr_urls")
      assert_empty payload.fetch("fix_results")

      store = patrol_store(repo)
      pending = store.patrol_fix_admission_adapter.store.pending
      assert_equal 1, pending.length
      assert_equal finding.id, pending.first.dig("source", "identity")
      assert_empty Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")]
    end
  end

  def test_validation_commands_are_no_longer_a_discovery_precondition
    with_patrol_project do |repo|
      config_path = File.join(repo, ".hive-state", "config.yml")
      config = YAML.safe_load_file(config_path, aliases: true)
      config["patrol"]["commands"] = {
        "docs" => nil, "format" => nil, "lint" => nil,
        "public_contract" => nil, "typecheck" => nil, "test" => nil
      }
      File.write(config_path, config.to_yaml)

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ sample_finding ])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal 1, JSON.parse(out).fetch("findings")
      assert_equal 1, patrol_store(repo).patrol_fix_admission_adapter.store.pending.length
    end
  end

  def test_semantic_duplicate_does_not_duplicate_workflow_admission
    with_patrol_project do |repo|
      first = sample_finding
      duplicate = sample_finding
      duplicate.id = "finding-duplicate"

      first_out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ first ])
        ).call
      end
      second_out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ duplicate ])
        ).call
      end

      assert_equal 1, JSON.parse(first_out).fetch("findings")
      second_payload = JSON.parse(second_out)
      assert_equal 1, second_payload.fetch("findings")
      assert_equal 1, patrol_store(repo).findings.length
      assert_equal 1, patrol_store(repo).patrol_fix_admission_adapter.store.pending.length
    end
  end

  def test_review_error_keeps_the_scanned_sha_unadvanced
    with_patrol_project do |repo|
      state_path = File.join(repo, ".hive-state", "patrol", "state.json")
      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new(
            [], review_errors: [ { "feature_id" => "route-home", "error" => "agent failed" } ]
          )
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      refute payload.fetch("review_complete")
      state = JSON.parse(File.read(state_path))
      assert_equal "", state.fetch("last_scanned_sha", "")
      assert_equal true, state.fetch("feature_review_active")
    end
  end

  def test_clean_partial_feature_batch_persists_the_next_cursor
    with_patrol_project do |repo|
      config_path = File.join(repo, ".hive-state", "config.yml")
      config = YAML.safe_load_file(config_path, aliases: true)
      config["patrol"]["max_features_per_cycle"] = 1
      File.write(config_path, config.to_yaml)
      second = sample_feature
      second.id = "search"

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature, second ]),
          reviewer: FakeReviewer.new([])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      refute JSON.parse(out).fetch("review_complete")
      state = patrol_store(repo).state
      assert_equal "", state.fetch("last_scanned_sha", "")
      assert_equal true, state.fetch("feature_review_active")
      assert_equal 1, state.fetch("feature_review_cursor")
    end
  end

  def test_dry_run_never_materializes_a_workflow_admission
    with_patrol_project do |repo|
      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ sample_finding ])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal true, JSON.parse(out).fetch("dry_run")
      assert_empty patrol_store(repo).patrol_fix_admission_adapter.store.pending
    end
  end

  def test_unknown_project_emits_json_config_error
    out, err, status = with_captured_exit do
      Hive::Commands::Patrol.new("missing", json: true).call
    end

    assert_equal Hive::ExitCodes::CONFIG, status
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("ok")
    assert_equal "config", payload.fetch("error_kind")
    assert_includes err, "unknown project"
  end

  def test_non_coding_default_workflow_is_rejected
    with_patrol_project do |repo|
      config_path = File.join(repo, ".hive-state", "config.yml")
      config = YAML.safe_load_file(config_path, aliases: true)
      config["default_workflow"] = "patrol-fix"
      File.write(config_path, config.to_yaml)

      out, _err, status = with_captured_exit { command_for.call }

      assert_equal Hive::ExitCodes::CONFIG, status
      assert_includes JSON.parse(out).fetch("message"), "non-coding default_workflow"
    end
  end

  def test_internal_errors_are_wrapped_and_non_json_success_is_human_readable
    with_patrol_project do
      broken = Object.new
      broken.define_singleton_method(:call) { raise "mapper exploded" }
      out, _err, status = with_captured_exit do
        command_for(mapper: broken).call
      end
      assert_equal Hive::ExitCodes::SOFTWARE, status
      assert_equal "InternalError", JSON.parse(out).fetch("error_class")

      command = Hive::Commands::Patrol.new(
        "demo", mapper_factory: ->(*) { FakeMapper.new([]) },
        reviewer_factory: ->(*) { FakeReviewer.new([]) }
      )
      human, = capture_io { command.call }
      assert_match(/hive patrol: demo mapped=0/, human)
    end
  end

  def test_unattributable_review_error_reports_zero_successes
    batch = Struct.new(:features).new([ sample_feature ])
    reviewer = FakeReviewer.new([], review_errors: [ { "error" => "unknown feature" } ])

    result = command_for.send(:review_outcome, batch, reviewer)

    assert_equal 0, result.fetch("features_reviewed")
  end

  def test_default_mapper_and_reviewer_are_constructed
    with_patrol_project do |repo|
      cfg = Hive::Config.load(repo)
      state = patrol_store(repo)
      command = Hive::Commands::Patrol.new("demo")
      mapper = command.instance_variable_get(:@mapper_factory).call(repo, cfg, state)
      budget = Hive::Patrol::LaunchBudget.new(repo, cfg: cfg, charge_discovery: false)

      assert_instance_of Hive::Patrol::Mapper, mapper
      assert_instance_of Hive::Patrol::Reviewer,
                         command.send(:build_reviewer, repo, cfg, state, budget)
    end
  end

  def test_active_materializable_snapshot_is_reused
    with_patrol_project do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      state = patrol_store(repo)
      state.update_state(
        "feature_review_active" => true,
        "feature_review_sha" => head,
        "feature_review_cursor" => 1
      )

      assert_equal head, command_for.send(
        :sweep_target_sha, repo, Hive::Config.load(repo), state
      )
      refute command_for.send(:materializable_commit?, repo, "invalid")
    end
  end

  def test_scan_checkout_rejects_a_sha_other_than_the_requested_target
    command = command_for(dry_run: true)
    calls = []
    command.define_singleton_method(:git_output!) do |root, *args|
      calls << [ root, args ]
      args == [ "rev-parse", "HEAD" ] ? "unexpected-sha\n" : ""
    end

    error = assert_raises(Hive::GitError) do
      command.send(:with_scan_checkout, "/project", "expected-sha") { flunk "must not yield" }
    end

    assert_includes error.message, "unexpected-sha"
    assert calls.any? { |_root, args| args.first(3) == [ "worktree", "remove", "--force" ] }
  end

  def test_scan_cleanup_failure_does_not_mask_result
    command = command_for(dry_run: true)
    command.define_singleton_method(:git_output!) do |_root, *args|
      raise Hive::GitError, "removal blocked" if
        args.first(3) == [ "worktree", "remove", "--force" ]
      args == [ "rev-parse", "HEAD" ] ? "expected-sha\n" : ""
    end

    result = nil
    _out, err = capture_io do
      result = command.send(:with_scan_checkout, "/project", "expected-sha") { :scan_result }
    end

    assert_equal :scan_result, result
    assert_match(/removal blocked/, err)
  end

  def test_git_output_and_fresh_scan_base_fail_closed
    Dir.mktmpdir do |root|
      error = assert_raises(Hive::GitError) do
        command_for.send(:git_output!, root, "rev-parse", "HEAD")
      end
      assert_match(/not a git repository/i, error.message)
    end

    command = command_for
    cfg = { "default_branch" => "master" }
    status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
    with_replaced_singleton_method(Hive::Worktree, :origin_configured?, ->(_root) { false }) do
      with_replaced_singleton_method(
        Open3, :capture3, ->(*) { [ "not-an-oid\n", "", status.new(0) ] }
      ) do
        error = assert_raises(Hive::GitError) do
          command.send(:current_default_sha, "/project", cfg)
        end
        assert_match(/invalid SHA/, error.message)
      end
    end

    with_replaced_singleton_method(Hive::Worktree, :origin_configured?, ->(_root) { true }) do
      with_replaced_singleton_method(
        Hive::Worktree, :fetch_origin_branch,
        ->(_root, _branch) { [ "", "network unavailable", status.new(1) ] }
      ) do
        error = assert_raises(Hive::GitError) do
          command.send(:current_default_sha, "/project", cfg)
        end
        assert_match(/cannot fetch fresh patrol scan base/, error.message)
      end
    end

    with_replaced_singleton_method(Hive::Worktree, :origin_configured?, ->(_root) { true }) do
      with_replaced_singleton_method(
        Hive::Worktree, :fetch_origin_branch,
        ->(_root, _branch) { [ "", "", status.new(0) ] }
      ) do
        with_replaced_singleton_method(
          Open3, :capture3, ->(*) { [ "#{'a' * 40}\n", "", status.new(0) ] }
        ) do
          assert_equal "a" * 40, command.send(:current_default_sha, "/project", cfg)
        end
      end
    end

    with_replaced_singleton_method(Hive::Worktree, :origin_configured?, ->(_root) { false }) do
      with_replaced_singleton_method(
        Open3, :capture3, ->(*) { [ "", "missing ref", status.new(1) ] }
      ) do
        error = assert_raises(Hive::GitError) do
          command.send(:current_default_sha, "/project", cfg)
        end
        assert_match(/git rev-parse master failed: missing ref/, error.message)
      end
    end
  end

  def test_scan_checkout_rejects_committed_and_uncommitted_mutation
    command = command_for
    assert_raises(Hive::GitError) do
      command.send(:assert_clean_scan_checkout!, Dir.pwd, "0" * 40)
    end

    head = run!("git", "rev-parse", "HEAD").strip
    command.define_singleton_method(:git_output!) do |_root, *args|
      args == [ "rev-parse", "HEAD" ] ? "#{head}\n" : " M changed.rb\n"
    end
    assert_raises(Hive::GitError) do
      command.send(:assert_clean_scan_checkout!, Dir.pwd, head)
    end
  end

  private

  def with_patrol_project
    previous_usage_path = Hive::UsageDb.instance_variable_get(:@path)
    with_tmp_global_config do |global_home|
      Hive::UsageDb.path = File.join(global_home, "usage.db")
      with_tmp_git_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        config = Hive::Config.deep_merge(
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
        File.write(File.join(repo, ".hive-state", "config.yml"), config.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)
        yield repo
      end
    end
  ensure
    Hive::UsageDb.path = previous_usage_path
  end

  def command_for(dry_run: false, mapper: FakeMapper.new([]), reviewer: FakeReviewer.new([]))
    Hive::Commands::Patrol.new(
      "demo",
      json: true,
      dry_run: dry_run,
      mapper_factory: ->(_root, _cfg, _state) { mapper },
      reviewer_factory: ->(_root, _cfg, _state) { reviewer }
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
      root_cause: "A route can resolve without a receiver.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "route.call" } ]
    )
  end

  def patrol_schemer
    @patrol_schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    )
  end

  def patrol_store(repo)
    entry = Hive::Config.find_project("demo")
    Hive::Patrol::StateStore.new(
      repo, hive_state_path: entry.fetch("hive_state_path")
    )
  end
end
