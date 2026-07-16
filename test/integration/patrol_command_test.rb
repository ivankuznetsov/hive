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
    attr_reader :review_errors

    def initialize(findings, review_errors: [])
      @findings = findings
      @review_errors = review_errors
    end

    def call(_features)
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
      assert_equal 1, payload.fetch("findings")
      assert_equal 1, payload.fetch("fix_candidates")
      assert_equal 1, payload.fetch("fixes_attempted")
      assert_equal 1, payload.fetch("fixes_validated")
      assert_equal [ "https://example.com/pull/7" ], payload.fetch("pr_urls")
      assert_equal [], payload.fetch("review_handoff_errors")

      state = JSON.parse(File.read(File.join(repo, ".hive-state", "patrol", "state.json")))
      assert_equal payload.fetch("last_scanned_sha"), state.fetch("last_scanned_sha")
      refute_empty state.fetch("last_run_at")
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
            review_errors: [ { "feature_id" => "route-home", "error" => "agent_failed" } ]
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
      refute_empty state.fetch("last_run_at"), "last_run_at still advances on a partial scan"
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
                  reviewer: FakeReviewer.new([]), fixer: FakeFixer.new(nil),
                  pr_opener: FakePrOpener.new(Hive::Patrol::PrOpener::Result.new(status: :skipped)))
    Hive::Commands::Patrol.new(
      project,
      json: json,
      dry_run: dry_run,
      mapper_factory: ->(_root, _cfg, _state) { mapper },
      reviewer_factory: ->(_root, _cfg, _state) { reviewer },
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
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "user.name" } ]
    )
  end

  def finding_with(id:, fingerprint:)
    Hive::Patrol::Finding.new(
      id: id,
      feature_id: "route-home",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Nil route receiver #{id}",
      description: "The route calls through a nil receiver.",
      recommendation: "Guard the receiver before use.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "user.name" } ],
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
