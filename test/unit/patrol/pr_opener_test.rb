require "test_helper"
require "yaml"
require "hive/config"
require "hive/markers"
require "hive/modules/migration/evidence_store"
require "hive/patrol/pr_opener"
require "hive/patrol/finding"
require "hive/task"

class HivePatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  def test_custom_hive_state_path_is_used_for_evidence_and_effect_admission
    with_tmp_dir do |root|
      custom_state = File.join(root, "external-state")
      state = Hive::Patrol::StateStore.new(
        root, hive_state_path: custom_state
      )
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: {
          "project_id" => "project-custom",
          "name" => "custom",
          "repository" => "owner/custom"
        },
        trigger: { "kind" => "manual", "id" => "custom-state" },
        reservation: { "kind" => "ordinary", "id" => "custom-state" },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "operation",
          "operation" => "custom-state-test"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "patrol", rationale: "due"
          ),
        outcome_class: nil,
        outcome: nil,
        occurred_at: Time.at(0).utc,
        recorded_at: Time.at(0).utc
      )
      options = nil
      gateway = Object.new
      factory = lambda do |**attributes|
        options = attributes
        gateway
      end
      opener = pr_opener(
        root,
        cfg: cfg,
        state: state,
        capture: capture,
        effect_gateway_factory: factory
      )

      assert_same gateway, opener.send(:effect_gateway)
      assert_equal custom_state, options.fetch(:hive_state_path)
      evidence = options.fetch(:evidence_store)
      assert evidence.root.start_with?(
        File.join(custom_state, "module-runtime")
      )
    end
  end

  def test_initializer_requires_an_admitted_capture_and_configured_state
    with_tmp_dir do |root|
      assert_raises(ArgumentError) do
        Hive::Patrol::PrOpener.new(
          root, cfg: cfg, gh: FakeGh.new
        )
      end

      state = Hive::Patrol::StateStore.new(root)
      capture = admitted_capture(root)
      gh = FakeGh.new
      opener = Hive::Patrol::PrOpener.new(
        root,
        cfg: cfg,
        state: state,
        capture: capture,
        gh: gh
      )

      error = assert_raises(Hive::ConfigError) do
        opener.open(finding, patch(worktree_path: root))
      end
      assert_match(/effect gateway is unavailable/, error.message)
      assert_empty gh.pushed
      assert_nil gh.created_args
    end
  end

  def test_live_configuration_and_capabilities_can_revoke_publication
    denied_cases = {
      "configuration_disabled" => {
        live_config:
          Hive::Config.deep_merge(
            Hive::Config.deep_dup(cfg),
            "patrol" => { "enabled" => false }
          )
      },
      "capability_revoked" => {
        capability_checker: ->(**) { false }
      }
    }
    denied_cases.each do |reason, options|
      with_tmp_dir do |root|
        gh = FakeGh.new
        result = pr_opener(
          root, cfg: cfg, gh: gh, **options
        ).open(finding, patch(worktree_path: root))

        assert_equal :error, result.status
        assert_equal "gh_error", result.reason
        assert_includes result.detail, reason
        assert_empty gh.pushed
        assert_nil gh.created_args
      end
    end
  end

  def test_publication_requires_an_exact_capture_repository
    with_tmp_dir do |root|
      gh = FakeGh.new
      result = pr_opener(
        root,
        cfg: cfg,
        gh: gh,
        capture: admitted_capture(root, repository: nil)
      ).open(finding, patch(worktree_path: root))

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/requires an exact repository identity/,
                   result.detail)
      assert_empty gh.pushed
      assert_nil gh.created_args
    end
  end

  def test_recovery_precedes_the_first_fingerprint_read
    with_tmp_dir do |root|
      state = Hive::Patrol::StateStore.new(root)
      gh = FakeGh.new
      gh.define_singleton_method(:ensure_authenticated!) do |_cfg|
        raise Hive::GhError, "stop after predecessor check"
      end
      opener = pr_opener(root, cfg: cfg, state: state, gh: gh)
      events = []
      original_recovery = state.method(
        :recover_pending_fingerprint_effects!
      )
      state.define_singleton_method(
        :recover_pending_fingerprint_effects!
      ) do
        events << :recover
        original_recovery.call
      end
      original_fingerprints = state.method(:fingerprints)
      state.define_singleton_method(:fingerprints) do
        events << :fingerprints
        original_fingerprints.call
      end

      result = opener.open(finding, patch(worktree_path: root))

      assert_equal :error, result.status
      assert_equal :recover, events.fetch(0)
      assert_operator events.index(:recover), :<, events.index(:fingerprints)
      assert_empty gh.pushed
    end
  end

  BASE_SHA = "a" * 40
  HEAD_SHA = "b" * 40

  FakePatch = Struct.new(:id, :finding, :branch, :worktree_path, :validation,
                         :passed, :diffstat, :base_sha, :head_sha, keyword_init: true)
  GatewayResult = Struct.new(:outcome, keyword_init: true)

  class ReconcilingGateway
    attr_reader :reconciliations, :effect_calls

    def initialize
      @reconciliations = []
      @effect_calls = 0
    end

    def perform!(reconcile:, **)
      reconciliation = reconcile.call({})
      @reconciliations << reconciliation
      outcome = if reconciliation.fetch("status") == "matched"
        reconciliation.fetch("outcome")
      else
        @effect_calls += 1
        yield
      end
      GatewayResult.new(outcome: outcome)
    end
  end

  class FakeGh
    attr_reader :pushed, :push_options, :created_args, :git_commands
    attr_accessor :prs, :diff, :diff_status, :head_sha, :status_output,
                  :remote_oid, :base_remote_oid, :created_base_oid, :push_updates_remote

    def initialize
      @prs = []
      @diff = "diff --git a/app.rb b/app.rb\n+puts 'ok'\n"
      @diff_status = 0
      @head_sha = HivePatrolPrOpenerTest::HEAD_SHA
      @status_output = ""
      @remote_oid = nil
      @base_remote_oid = HivePatrolPrOpenerTest::BASE_SHA
      @push_updates_remote = true
      @pushed = []
      @push_options = []
      @created_args = nil
      @git_commands = []
    end

    def lookup_prs_for_branch(_path, _branch, cfg: nil)
      return @prs unless @created_args

      @prs + [
        {
          "state" => "OPEN", "url" => "https://example.com/pr/2",
          "headRefOid" => @head_sha, "baseRefOid" => (@created_base_oid || @base_remote_oid),
          "baseRefName" => "master"
        }
      ]
    end

    def ensure_authenticated!(_cfg = nil)
      true
    end

    def push_branch!(path, branch, cfg: nil, expected_remote_oid: nil, expected_remote_absent: false)
      @pushed << [ path, branch ]
      @push_options << {
        expected_remote_oid: expected_remote_oid,
        expected_remote_absent: expected_remote_absent
      }
      @remote_oid = @head_sha if @push_updates_remote
    end

    def remote_branch_oid(_path, branch, cfg: nil)
      branch == "master" ? @base_remote_oid : @remote_oid
    end

    def capture3(*cmd, chdir: nil, cfg: nil)
      if cmd[0] == "git"
        @git_commands << cmd
        operation = cmd[3]
        case operation
        when "rev-parse"
          return [ "#{@head_sha}\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
        when "status"
          return [ @status_output, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
        when "diff"
          return [ @diff, "diff failed", Hive::Gh::CommandStatus.new(exitstatus: @diff_status) ]
        end
      end

      @created_args = cmd
      [ "https://example.com/pr/2\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
  end

  class FailingReviewHandoff
    def enqueue(**)
      raise "disk full"
    end
  end

  class RecordingReviewHandoff
    attr_reader :calls

    def initialize
      @calls = []
    end

    def enqueue(**attributes)
      @calls << attributes
      "/tmp/review-task"
    end
  end

  def before_setup
    super
    original = Hive::TaskCounter.method(:next!)
    counter = 40
    @restore_task_counter = lambda do
      Hive::TaskCounter.define_singleton_method(:next!, original)
    end
    Hive::TaskCounter.define_singleton_method(:next!) do
      counter += 1
    end
  end

  def after_teardown
    @restore_task_counter&.call
    super
  end

  def cfg(draft: true)
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      { "default_branch" => "master", "patrol" => { "draft_prs" => draft } }
    )
  end

  def pr_opener(project_root, cfg:, gh: Hive::Gh, state: nil,
                capture: nil, review_handoff: nil,
                effect_gateway_factory: nil, live_config: nil,
                capability_checker: nil, module_execution: nil)
    state ||= Hive::Patrol::StateStore.new(project_root)
    state.ensure!
    capture ||= admitted_capture(project_root)
    admitted_config = live_config || Hive::Config.deep_merge(
      Hive::Config.deep_dup(cfg),
      "patrol" => { "enabled" => true }
    )
    evidence_store = Hive::Modules::Migration::EvidenceStore.new(
      root: File.join(
        state.hive_state_path, "module-runtime", "migration",
        "patrol-evidence"
      )
    )
    state.configure_effect_gateway!(
      capture: capture,
      evidence_store: evidence_store,
      config_loader: ->(_root) { admitted_config },
      capability_checker: capability_checker || ->(**) { true },
      module_execution: module_execution,
      gateway_factory: effect_gateway_factory
    )
    Hive::Patrol::PrOpener.new(
      project_root,
      cfg: cfg,
      state: state,
      capture: capture,
      gh: gh,
      review_handoff: review_handoff
    )
  end

  def admitted_capture(
    project_root,
    repository:
      "owner/#{File.basename(File.expand_path(project_root))}"
  )
    @capture_counter = @capture_counter.to_i + 1
    identity = "pr-opener-test-#{@capture_counter}"
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "pr-opener-test",
        "name" => File.basename(File.expand_path(project_root)),
        "repository" => repository
      },
      trigger: { "kind" => "manual", "id" => identity },
      reservation: { "kind" => "ordinary", "id" => identity },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "validated_patch"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol", rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: Time.at(0).utc,
      recorded_at: Time.at(0).utc
    )
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "f1",
      feature_id: "feature",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Fix bug",
      description: "bug details",
      recommendation: "fix it",
      scope: "cross_feature",
      contract: "Every accepted job must eventually be delivered.",
      impact: "Accepted jobs disappear without an error.",
      root_cause: "The handoff clears durable state before acknowledgement.",
      reproduction: "Interrupt the handoff after dequeue and before acknowledgement.",
      validation: "Run the handoff interruption regression and delivery suite.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      alpha_score: 88,
      fingerprint: "fp1"
    )
  end

  def patch(worktree_path: Dir.pwd, passed: true)
    FakePatch.new(
      id: "patch-fp1-000001",
      finding: finding,
      branch: "hive-patrol/feature-fp1",
      worktree_path: worktree_path,
      passed: passed,
      validation: { "commands" => [ { "name" => "test", "command" => "rake", "exit_code" => 0 } ] },
      diffstat: " app.rb | 1 +",
      base_sha: BASE_SHA,
      head_sha: HEAD_SHA
    )
  end

  def seed_publication_binding(opener, state, validated_patch,
                               pr_url: "https://example.com/pr/2")
    capture = opener.instance_variable_get(:@capture)
    gateway = opener.send(:effect_gateway)
    scope = opener.send(
      :publication_scope, finding, validated_patch, gateway
    )
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: capture.owner,
      owner_epoch: capture.owner_epoch,
      sink: "pull_request",
      target: [
        scope.fetch("repository"), validated_patch.branch
      ].join(":"),
      idempotency_key:
        "#{finding.fingerprint}:#{validated_patch.id}:pull_request",
      capability: "github_pull_requests",
      scope: scope,
      created_at: Time.at(0).utc
    )
    state.prepare_effect!(intent, now: Time.at(0).utc)
    state.mark_dispatch_uncertain!(
      intent, now: Time.at(0).utc
    )
    state.settle_effect!(
      intent,
      status: "committed",
      outcome: {
        "pr_url" => pr_url,
        "state" => "OPEN",
        "head_oid" => validated_patch.head_sha,
        "base_oid" => validated_patch.base_sha
      },
      now: Time.at(0).utc
    )
    state.drain_publication_outbox!(capture.occurrence_id)
    JSON.parse(JSON.generate(
      state.fingerprints.fetch(finding.fingerprint)
    ))
  end

  def matching_pr(state: "OPEN", url: "https://example.com/pr/1")
    {
      "state" => state,
      "url" => url,
      "headRefOid" => HEAD_SHA,
      "baseRefOid" => BASE_SHA,
      "baseRefName" => "master"
    }
  end

  def test_validated_patch_opens_draft_pr_records_mapping_and_enqueues_review_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_equal [ [ dir, "hive-patrol/feature-fp1" ] ], gh.pushed
      assert_equal [ { expected_remote_oid: nil, expected_remote_absent: true } ], gh.push_options
      assert_includes gh.created_args, "--draft"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "https://example.com/pr/2", fingerprints["fp1"]["pr_url"]
      assert_equal "open", fingerprints["fp1"]["state"]
      assert_equal "feature", fingerprints["fp1"]["feature_id"]

      refute_nil result.review_task_path
      task = Hive::Task.new(result.review_task_path)
      assert_equal "review", task.stage_name
      assert_equal "patrol-feature-fp1", task.slug
      assert task.id, "patrol-created review tasks must get normal task ids"
      assert_equal "Patrol: Fix bug", task.display_name
      assert_equal :none, Hive::Markers.current(task.state_file).name
      assert File.directory?(task.reviews_dir)

      pointer = YAML.safe_load(File.read(task.worktree_yml_path))
      assert_equal dir, pointer.fetch("path")
      assert_equal "hive-patrol/feature-fp1", pointer.fetch("branch")
      assert_equal HEAD_SHA, pointer.fetch("execute_base_head")

      pr_md = File.read(File.join(task.folder, "pr.md"))
      assert_includes pr_md, "pr_url: https://example.com/pr/2"
      assert_includes File.read(task.state_file), "# Patrol: Fix bug"
    end
  end

  def test_publication_orders_remote_effects_mapping_receipts_and_review_handoff
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      operations = []
      gh = FakeGh.new
      original_push = gh.method(:push_branch!)
      gh.define_singleton_method(:push_branch!) do |*args, **options|
        operations << :push
        original_push.call(*args, **options)
      end
      original_capture = gh.method(:capture3)
      gh.define_singleton_method(:capture3) do |*command, chdir: nil, cfg: nil|
        operations << :create_pr unless command.first == "git"
        original_capture.call(*command, chdir: chdir, cfg: cfg)
      end

      state = Hive::Patrol::StateStore.new(dir)
      state.ensure!
      original_prepare = state.method(:prepare_effect!)
      state.define_singleton_method(:prepare_effect!) do |intent, **options|
        operations << "effect:#{intent.sink}:intent"
        original_prepare.call(intent, **options)
      end
      original_settle = state.method(:settle_effect!)
      state.define_singleton_method(:settle_effect!) do |intent, **options|
        operations << "effect:#{intent.sink}:#{options.fetch(:status)}"
        original_settle.call(intent, **options)
      end
      original_mutate = state.method(:mutate_fingerprints!)
      state.define_singleton_method(:mutate_fingerprints!) do |**attributes|
        previous = fingerprints.dig("fp1", "state")
        result = original_mutate.call(**attributes)
        current = fingerprints.dig("fp1", "state")
        operations << "mapping:#{current}" if
          current && current != previous
        result
      end
      original_publication_drain =
        state.method(:drain_publication_outbox!)
      state.define_singleton_method(
        :drain_publication_outbox!
      ) do |occurrence_id|
        result = original_publication_drain.call(occurrence_id)
        operations << "mapping:reconciliation_pending"
        result
      end

      handoff = RecordingReviewHandoff.new
      original_enqueue = handoff.method(:enqueue)
      handoff.define_singleton_method(:enqueue) do |**attributes|
        operations << :review_handoff
        original_enqueue.call(**attributes)
      end

      result = pr_opener(
        dir, cfg: cfg, state: state, gh: gh, review_handoff: handoff
      ).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_equal(
        [
          "effect:branch:intent",
          :push,
          "effect:branch:committed",
          "effect:pull_request:intent",
          :create_pr,
          "effect:pull_request:committed",
          "mapping:reconciliation_pending",
          "effect:review_handoff:intent",
          :review_handoff,
          "effect:review_handoff:committed",
          "effect:state:intent",
          "effect:state:committed",
          "mapping:open"
        ],
        operations
      )
    end
  end

  def test_terminal_pr_is_bound_before_later_state_admission_can_close
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      state = Hive::Patrol::StateStore.new(dir)
      capture = admitted_capture(dir)
      gh = FakeGh.new
      created = 0
      original_capture = gh.method(:capture3)
      gh.define_singleton_method(:capture3) do |*command, chdir: nil, cfg: nil|
        answer = original_capture.call(
          *command, chdir: chdir, cfg: cfg
        )
        created += 1 unless command.first == "git"
        answer
      end
      admissions = []
      capability_checker = lambda do |sink:, capability:, **|
        allowed = !(created.positive? && sink == "state")
        admissions << [ sink, capability, allowed ]
        allowed
      end
      review_handoff = RecordingReviewHandoff.new
      opener = pr_opener(
        dir,
        cfg: cfg,
        state: state,
        capture: capture,
        gh: gh,
        capability_checker: capability_checker,
        review_handoff: review_handoff
      )
      cleaned = []
      opener.define_singleton_method(:cleanup_worktree) do |value|
        cleaned << value.worktree_path
      end

      result = opener.open(finding, patch(worktree_path: dir))

      record = state.occurrence(capture.occurrence_id)
      pr_cell = record.fetch("effects").values.find do |cell|
        cell.fetch("authorizations").values.any? do |intent|
          intent.fetch("sink") == "pull_request"
        end
      end
      receipt = state.effect_receipt(
        pr_cell.fetch("terminal_receipt_id"),
        occurrence_id: capture.occurrence_id
      )
      assert_equal 1, created
      assert_equal "committed", receipt.status
      assert_equal(
        "https://example.com/pr/2", receipt.outcome.fetch("pr_url")
      )
      assert_includes admissions, [ "state", "filesystem_write", false ]
      assert_equal(
        [ 0, true ],
        [ cleaned.length, state.fingerprints.key?("fp1") ],
        "a terminal remote PR must retain its worktree until a durable " \
        "product binding exists"
      )
      binding = state.fingerprints.fetch("fp1")
      assert_equal "https://example.com/pr/2", binding.fetch("pr_url")
      assert_equal "reconciliation_pending", binding.fetch("state")
      assert_equal(
        receipt.receipt_id,
        binding.fetch("publication_binding").fetch("receipt_id")
      )
      assert_equal 1, review_handoff.calls.size
      assert_equal :error, result.status
      assert_match(/capability_revoked/, result.detail)
    end
  end

  def test_pr_body_preserves_alpha_and_root_cause_evidence
    opener = pr_opener(Dir.pwd, cfg: cfg, gh: FakeGh.new)

    body = opener.send(:body_for, finding, patch)

    assert_includes body, "Alpha: `88`"
    assert_includes body, "Scope: `cross_feature`"
    assert_includes body, "## Contract and impact"
    assert_includes body, finding.contract
    assert_includes body, finding.impact
    assert_includes body, "## Root cause"
    assert_includes body, finding.root_cause
    assert_includes body, "## Reproduction"
    assert_includes body, finding.reproduction
    assert_includes body, finding.validation
  end

  def test_pr_body_preserves_machine_observed_fix_proof
    observed = patch
    observed.validation["fix_proof"] = {
      "root_cause" => "Confirmed queue deletion before acknowledgement.",
      "audited_paths" => %w[app.rb lib/queue.rb],
      "configured_command" => "bundle exec ruby test/queue_test.rb",
      "before" => { "exit_code" => 1, "timed_out" => false },
      "after" => { "exit_code" => 0, "timed_out" => false }
    }

    body = pr_opener(Dir.pwd, cfg: cfg, gh: FakeGh.new).send(:body_for, finding, observed)

    assert_includes body, "## Observed fix proof"
    assert_includes body, "Agent-reported root cause"
    assert_includes body, "Confirmed queue deletion"
    assert_includes body, "exit=1"
    assert_includes body, "exit=0"
  end

  def test_secret_in_agent_authored_title_blocks_before_push
    with_tmp_dir do |dir|
      gh = FakeGh.new
      unsafe = finding
      unsafe.title = "Fix sk-#{'x' * 24}"

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        unsafe, patch(worktree_path: dir)
      )

      assert_equal :blocked, result.status
      assert_equal "secret_detected", result.reason
      assert_empty gh.pushed
    end
  end

  def test_diff_acquisition_failure_blocks_publication
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.diff_status = 1

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/secret scan failed/, result.detail)
      assert_empty gh.pushed
    end
  end

  def test_review_handoff_failure_is_visible_and_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = pr_opener(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))

      assert_equal :opened_review_handoff_failed, result.status
      assert result.opened?
      assert result.review_handoff_failed?
      assert_equal "review_handoff_failed", result.reason
      assert_nil result.review_task_path

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
      refute Hive::Patrol::Fingerprint.known_active?(fingerprints, "fp1"),
             "failed review handoff must remain retryable instead of becoming an active PR skip"
    end
  end

  def test_review_handoff_frontmatter_handles_yaml_sensitive_values
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      unsafe = finding
      unsafe.id = "finding: one\nsecond"
      unsafe.fingerprint = "fp: one\nsecond"

      result = pr_opener(dir, cfg: cfg, gh: gh).open(unsafe, patch(worktree_path: dir))

      assert result.opened?
      task = Hive::Task.new(result.review_task_path)
      task_frontmatter = YAML.safe_load(File.read(task.state_file).match(/\A---\s*\n(.*?)\n---/m)[1])
      pr_frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))

      assert_equal unsafe.id, task_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, task_frontmatter.fetch("patrol_fingerprint")
      assert_equal "https://example.com/pr/2", pr_frontmatter.fetch("pr_url")
      assert_equal unsafe.id, pr_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, pr_frontmatter.fetch("patrol_fingerprint")
    end
  end

  def test_existing_open_pr_skips_duplicate
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr ]
      gh.remote_oid = HEAD_SHA

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      refute_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_existing_open_pr_with_failed_handoff_is_skipped_and_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr ]
      gh.remote_oid = HEAD_SHA

      result = pr_opener(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "review_handoff_failed", result.reason
      assert_nil result.review_task_path
      assert_empty gh.pushed

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
      refute Hive::Patrol::Fingerprint.known_active?(fingerprints, "fp1"),
             "an existing-PR handoff failure must stay retryable, not become an active skip"
    end
  end

  def test_failed_handoff_retry_does_not_enqueue_after_the_remote_base_advances
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      failed = pr_opener(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))
      assert_equal :opened_review_handoff_failed, failed.status

      gh.base_remote_oid = "d" * 40
      handoff = RecordingReviewHandoff.new
      retried = pr_opener(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: handoff
      ).open(finding, patch(worktree_path: dir))

      assert_equal :error, retried.status
      assert_equal "gh_error", retried.reason
      assert_match(/existing PR identity mismatch/, retried.detail)
      assert_empty handoff.calls, "an old-base patrol PR must never create a review task"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
    end
  end

  def test_remote_base_is_rechecked_immediately_before_review_handoff
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      handoff = RecordingReviewHandoff.new
      lookup_count = 0
      original_lookup = gh.method(:lookup_prs_for_branch)
      gh.define_singleton_method(:lookup_prs_for_branch) do |*args, **kwargs|
        result = original_lookup.call(*args, **kwargs)
        lookup_count += 1
        @base_remote_oid = "d" * 40 if lookup_count == 2
        result
      end

      result = pr_opener(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: handoff
      ).open(finding, patch(worktree_path: dir))

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/remote patrol base identity mismatch/, result.detail)
      assert_empty handoff.calls
    end
  end

  def test_existing_merged_pr_does_not_enqueue_review_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr(state: "MERGED") ]

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      assert_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_review_handoff_can_be_disabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      config = cfg(draft: false)
      config["patrol"]["review_prs"] = false

      result = pr_opener(dir, cfg: config, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_nil result.review_task_path
      refute Dir.exist?(File.join(dir, ".hive-state", "stages", "6-review"))
    end
  end

  def test_secret_in_diff_blocks_pr
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.diff = "+api_key=#{'a' * 24}\n"

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :blocked, result.status
      assert_equal "secret_detected", result.reason
      assert_empty gh.pushed
    end
  end

  def test_diff_is_scanned_against_the_exact_validated_base_and_head
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      captured = nil
      gh.define_singleton_method(:capture3) do |*cmd, chdir: nil, cfg: nil|
        captured = cmd if cmd[0] == "git" && cmd[3] == "diff"
        operation = cmd[3]
        output = case operation
        when "rev-parse" then "#{@head_sha}\n"
        when "status" then @status_output
        else @diff
        end
        [ output, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      end

      pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_includes captured, "#{BASE_SHA}..#{HEAD_SHA}",
                      "secret scan must bind to the exact validated patch identity"
    end
  end

  def test_gh_error_during_pr_stage_cleans_up_and_returns_structured_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.define_singleton_method(:push_branch!) do |_path, _branch, cfg: nil, **|
        raise Hive::GhError, "push rejected"
      end

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_equal "push rejected", result.detail
      refute result.opened?
    end
  end

  def test_diff_for_gh_error_fails_closed
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.define_singleton_method(:capture3) do |*|
        raise Hive::GhError, "git diff failed"
      end

      opener = pr_opener(dir, cfg: cfg, gh: gh)
      error = assert_raises(Hive::GhError) { opener.send(:diff_for, patch(worktree_path: dir)) }
      assert_includes error.message, "git diff failed"
    end
  end


  def test_local_patch_head_and_cleanliness_are_verified_before_remote_calls
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.head_sha = "c" * 40

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/validated patch head changed/, result.detail)
      assert_empty gh.pushed
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.status_output = "?? unvalidated.txt\n"

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/worktree is dirty/, result.detail)
      assert_empty gh.pushed
    end
  end

  def test_invalid_patch_identity_and_local_git_failures_fail_closed
    with_tmp_dir do |dir|
      gh = FakeGh.new
      invalid = patch(worktree_path: dir)
      invalid.head_sha = "short"

      result = pr_opener(dir, cfg: cfg, gh: gh).open(finding, invalid)

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/not a full Git object id/, result.detail)
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      original = gh.method(:capture3)
      gh.define_singleton_method(:capture3) do |*cmd, chdir: nil, cfg: nil|
        if cmd[0] == "git" && cmd[3] == "rev-parse"
          [ "", "cannot inspect HEAD", Hive::Gh::CommandStatus.new(exitstatus: 2) ]
        else
          original.call(*cmd, chdir: chdir, cfg: cfg)
        end
      end

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/cannot inspect HEAD/, result.detail)
    end
  end

  def test_existing_pr_requires_the_exact_validated_identity
    mismatches = {
      "head" => { "headRefOid" => "c" * 40 },
      "base name" => { "baseRefName" => "main" }
    }

    mismatches.each do |label, override|
      with_tmp_dir do |dir|
        gh = FakeGh.new
        gh.prs = [ matching_pr.merge(override) ]

        result = pr_opener(dir, cfg: cfg, gh: gh).open(
          finding, patch(worktree_path: dir)
        )

        assert_equal :error, result.status, label
        assert_equal "gh_error", result.reason, label
        assert_match(/existing PR identity mismatch/, result.detail, label)
        assert_empty gh.pushed, label
      end
    end
  end

  def test_new_pr_requires_the_remote_base_to_remain_at_the_validated_sha
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.base_remote_oid = "d" * 40

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/remote patrol base identity mismatch/, result.detail)
      assert_empty gh.pushed
      assert_nil gh.created_args
    end
  end

  def test_created_pr_is_reconciled_against_the_validated_base
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.created_base_oid = "d" * 40

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/could not be reconciled/, result.detail)
      refute_nil gh.created_args, "the simulated base race occurs during PR creation"
    end
  end

  # A read-after-write miss after `gh pr create` must leave an explicit,
  # retryable receipt. The next cycle reconciles that exact PR and hands its
  # exact validated patch to review without creating or fixing anything again.
  def test_reconciliation_miss_recovers_the_exact_pr_and_review_handoff_next_cycle
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      lookup_count = 0
      gh.define_singleton_method(:lookup_prs_for_branch) do |*_args, **|
        lookup_count += 1
        if lookup_count <= 2
          []
        else
          [
            {
              "state" => "OPEN", "url" => "https://example.com/pr/2",
              "headRefOid" => @head_sha, "baseRefOid" => @base_remote_oid,
              "baseRefName" => "master"
            }
          ]
        end
      end
      review_handoff = RecordingReviewHandoff.new
      state = Hive::Patrol::StateStore.new(dir)
      opener = pr_opener(
        dir, cfg: cfg, state: state, gh: gh,
        review_handoff: review_handoff
      )
      cleanup_count = 0
      opener.define_singleton_method(:cleanup_worktree) do |_patch|
        cleanup_count += 1
      end
      validated_patch = patch(worktree_path: dir)

      first = opener.open(finding, validated_patch)

      assert_equal :error, first.status
      assert_equal "gh_error", first.reason
      assert_includes first.detail, "could not be reconciled"
      assert_includes first.detail, "https://example.com/pr/2",
                      "the error must name the created PR so an operator can find it"
      assert_nil state.fingerprints["fp1"]
      pr_cell = state.occurrence(
        opener.instance_variable_get(:@capture).occurrence_id
      ).fetch("effects").values.find do |cell|
        cell.dig("semantic", "sink") == "pull_request"
      end
      assert_equal "dispatch_uncertain",
                   pr_cell.fetch("state")
      assert_equal 0, cleanup_count, "pending reconciliation must retain the exact worktree"
      assert_empty review_handoff.calls

      second = opener.open(finding, validated_patch)

      assert_equal :skipped, second.status
      assert_equal "existing_pr", second.reason
      assert_equal "https://example.com/pr/2", second.pr_url
      assert_equal "/tmp/review-task", second.review_task_path
      assert_equal 1, review_handoff.calls.size
      assert_equal validated_patch, review_handoff.calls.first.fetch(:patch)
      assert_equal 0, cleanup_count
      assert_equal 1, gh.pushed.size, "retry must not push the branch again"
      assert_equal "open", JSON.parse(
        File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json"))
      ).fetch("fp1").fetch("state")
      assert state.fingerprints.dig(
        "fp1", "publication_binding"
      ).is_a?(Hash)
    end
  end

  def test_identity_mismatch_after_pr_creation_keeps_the_ledger_mapping
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.created_base_oid = "d" * 40
      state = Hive::Patrol::StateStore.new(dir)
      opener = pr_opener(dir, cfg: cfg, state: state, gh: gh)
      cleaned = false
      opener.define_singleton_method(
        :cleanup_worktree
      ) { |_patch| cleaned = true }

      result = opener.open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/could not be reconciled/, result.detail)
      assert_includes result.detail, "https://example.com/pr/2",
                      "the error must name the created PR so an operator can find it"
      assert_nil state.fingerprints["fp1"]
      refute cleaned
      assert state.each_recovery_active_occurrence.any? do |occurrence|
        occurrence.fetch("effects").values.any? do |cell|
          cell["state"] == "dispatch_uncertain" &&
            cell.dig("semantic", "sink") == "pull_request"
        end
      end
    end
  end

  def test_pending_reconciliation_keeps_the_worktree_when_auth_is_temporarily_unavailable
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      validated_patch = patch(worktree_path: dir)
      predecessor = pr_opener(
        dir, cfg: cfg, state: state, gh: FakeGh.new
      )
      seed_publication_binding(
        predecessor, state, validated_patch
      )
      gh = FakeGh.new
      gh.define_singleton_method(:ensure_authenticated!) do |_cfg|
        raise Hive::GhError, "authentication temporarily unavailable"
      end
      opener = pr_opener(dir, cfg: cfg, state: state, gh: gh)
      cleaned = false
      opener.define_singleton_method(:cleanup_worktree) { |_patch| cleaned = true }

      result = opener.open(finding, validated_patch)

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/authentication temporarily unavailable/, result.detail)
      refute cleaned, "a transient pre-reconciliation error must retain the receipted worktree"
      assert_equal "reconciliation_pending", state.fingerprints.fetch("fp1").fetch("state")
    end
  end

  def test_successor_cycle_uses_predecessor_binding_without_second_pr_effect
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      validated_patch = patch(worktree_path: dir)
      predecessor = pr_opener(
        dir, cfg: cfg, state: state, gh: FakeGh.new
      )
      seeded = seed_publication_binding(
        predecessor, state, validated_patch
      )
      receipt_id =
        seeded.fetch("publication_binding").fetch("receipt_id")
      gh = FakeGh.new
      gh.remote_oid = HEAD_SHA
      gh.prs = [
        matching_pr(url: "https://example.com/pr/2")
      ]
      successor = pr_opener(
        dir, cfg: cfg, state: state, gh: gh,
        review_handoff: RecordingReviewHandoff.new
      )

      result = successor.open(finding, validated_patch)

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      assert_equal receipt_id,
                   state.fingerprints.dig(
                     "fp1", "publication_binding", "receipt_id"
                   )
      successor_occurrence = state.occurrence(
        successor.instance_variable_get(:@capture).occurrence_id
      )
      refute successor_occurrence.fetch("effects").values.any? {
        |cell| cell.dig("semantic", "sink") == "pull_request"
      }
    end
  end

  def test_pending_reconciliation_requires_the_exact_durable_binding
    cases = {
      "missing its publication binding" => lambda { |entry, _binding|
        entry.delete("publication_binding")
      },
      "publication binding mismatch" => lambda { |entry, binding|
        entry["publication_binding"] =
          binding.merge("head_sha" => "d" * 40)
      },
      "missing its exact branch or URL identity" => lambda { |entry, binding|
        entry["publication_binding"] = binding
        entry["pr_url"] = ""
      }
    }

    cases.each do |message, mutate|
      with_tmp_dir do |dir|
        state = Hive::Patrol::StateStore.new(dir)
        validated_patch = patch(worktree_path: dir)
        opener = pr_opener(dir, cfg: cfg, state: state, gh: FakeGh.new)
        entry = seed_publication_binding(
          opener, state, validated_patch
        )
        binding = entry.fetch("publication_binding")
        mutate.call(entry, binding)
        state.send(:raw_write_fingerprints, "fp1" => entry)

        error = assert_raises(Hive::GhError, message) do
          opener.send(:reconciliation_pending_entry, finding, validated_patch)
        end
        assert_includes error.message, message
      end
    end
  end

  def test_pending_reconciliation_fails_closed_when_the_receipted_pr_is_still_missing
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      validated_patch = patch(worktree_path: dir)
      opener = pr_opener(dir, cfg: cfg, state: state, gh: FakeGh.new)
      seed_publication_binding(opener, state, validated_patch)
      opener.instance_variable_get(:@gh).define_singleton_method(:lookup_prs_for_branch) { |*| [] }

      result = opener.open(finding, validated_patch)

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_includes result.detail, "created patrol PR https://example.com/pr/2 could not be reconciled"
      assert_equal "reconciliation_pending", state.fingerprints.fetch("fp1").fetch("state")
    end
  end

  def test_existing_remote_branch_is_replaced_only_with_an_exact_lease
    with_tmp_dir do |dir|
      gh = FakeGh.new
      previous = "c" * 40
      gh.remote_oid = previous

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert result.opened?
      assert_equal [ { expected_remote_oid: previous, expected_remote_absent: false } ], gh.push_options
    end
  end

  def test_remote_head_must_match_before_pr_creation_and_handoff
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.push_updates_remote = false

      result = pr_opener(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/remote patrol branch identity mismatch/, result.detail)
      assert_nil gh.created_args
    end
  end

  def test_result_status_and_reason_contracts_are_closed
    assert_equal %i[blocked error opened opened_review_handoff_failed skipped],
                 Hive::Patrol::PrOpener::RESULT_STATUSES
    assert_equal [
      nil, "existing_pr", "gh_error", "review_handoff_failed",
      "secret_detected", "validation_failed"
    ], Hive::Patrol::PrOpener::RESULT_REASONS

    assert_raises(ArgumentError) do
      Hive::Patrol::PrOpener::Result.new(status: :unknown)
    end
    assert_raises(ArgumentError) do
      Hive::Patrol::PrOpener::Result.new(status: :error, reason: "free-form error")
    end
  end

  def test_review_handoff_effect_reconciles_existing_task_and_supports_legacy_absence
    validated_patch = patch
    gh = FakeGh.new
    gh.remote_oid = HEAD_SHA
    reconciled_handoff = RecordingReviewHandoff.new
    reconciled_handoff.define_singleton_method(:reconcile) do |**|
      {
        "status" => "matched",
        "outcome" => { "task_path" => "/tmp/reconciled-review-task" }
      }
    end
    opener = pr_opener(
      Dir.pwd, cfg: cfg, gh: gh, review_handoff: reconciled_handoff
    )
    gateway = ReconcilingGateway.new

    task_path = opener.send(
      :enqueue_review_task, gateway, finding, validated_patch,
      "https://example.com/pr/7", Time.at(0)
    )

    assert_equal "/tmp/reconciled-review-task", task_path
    assert_equal 0, gateway.effect_calls
    assert_empty reconciled_handoff.calls

    legacy_handoff = RecordingReviewHandoff.new
    legacy_opener = pr_opener(
      Dir.pwd, cfg: cfg, gh: gh, review_handoff: legacy_handoff
    )
    legacy_gateway = ReconcilingGateway.new

    task_path = legacy_opener.send(
      :enqueue_review_task, legacy_gateway, finding, validated_patch,
      "https://example.com/pr/8", Time.at(0)
    )

    assert_equal "/tmp/review-task", task_path
    assert_equal(
      [ { "status" => "absent", "outcome" => {} } ],
      legacy_gateway.reconciliations
    )
    assert_equal 1, legacy_gateway.effect_calls
    assert_equal 1, legacy_handoff.calls.size
  end

  def test_branch_effect_reconciles_matching_remote_and_retries_confirmed_absence
    validated_patch = patch
    gh = FakeGh.new
    opener = pr_opener(Dir.pwd, cfg: cfg, gh: gh)

    gh.remote_oid = HEAD_SHA
    matched_gateway = ReconcilingGateway.new
    result = opener.send(
      :perform_branch_effect!, matched_gateway, finding, validated_patch
    )

    assert_equal HEAD_SHA, result.outcome.fetch("remote_oid")
    assert_equal "matched", matched_gateway.reconciliations.first.fetch("status")
    assert_equal 0, matched_gateway.effect_calls
    assert_empty gh.pushed

    gh.remote_oid = nil
    absent_gateway = ReconcilingGateway.new
    result = opener.send(
      :perform_branch_effect!, absent_gateway, finding, validated_patch
    )

    assert_equal HEAD_SHA, result.outcome.fetch("remote_oid")
    assert_equal(
      {
        "status" => "absent",
        "outcome" => { "observed_oid" => nil }
      },
      absent_gateway.reconciliations.first
    )
    assert_equal 1, absent_gateway.effect_calls
    assert_equal [ [ Dir.pwd, validated_patch.branch ] ], gh.pushed
  end

  def test_pull_request_effect_reconciles_the_exact_existing_pr
    opener = pr_opener(Dir.pwd, cfg: cfg, gh: FakeGh.new)
    gateway = ReconcilingGateway.new

    result = opener.send(
      :perform_pull_request_effect!, gateway, finding, patch, "unused body",
      observed_prs: [ matching_pr ]
    )

    assert_equal "https://example.com/pr/1",
                 result.outcome.fetch("pr_url")
    assert_equal "matched", gateway.reconciliations.first.fetch("status")
    assert_equal 0, gateway.effect_calls
  end

  def test_effect_gateway_failures_are_normalized_as_github_errors
    errors = [
      Hive::Patrol::EffectGateway::Denied.new("authority revoked", nil),
      Hive::Patrol::EffectGateway::ReconciliationRequired.new("outcome unknown")
    ]
    opener = pr_opener(Dir.pwd, cfg: cfg, gh: FakeGh.new)

    errors.each do |gateway_error|
      error = assert_raises(Hive::GhError) do
        opener.send(:perform_effect) { raise gateway_error }
      end

      assert_equal gateway_error.message, error.message
    end
  end
end
