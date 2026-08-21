require "test_helper"
require "tmpdir"
require "hive/commands/init"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/task_materializer"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/source_snapshot"
require "hive/workflows/registry"

class PatrolFixTaskMaterializerTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 8, 20, 12)

  def test_crash_after_task_creation_replays_one_task_and_acknowledges_admission_last
    with_initialized_project do |project_root|
      store = admission_store(project_root, klass: OneShotAcknowledgementFailureStore)
      decide_distinct(store, "ordinary-finding-1-v1", source_snapshot)

      assert_raises(RuntimeError) do
        materializer(project_root, store).call("ordinary-finding-1-v1")
      end
      assert_equal "bound", store.fetch("ordinary-finding-1-v1").fetch("status")
      assert_equal 1, patrol_fix_tasks(project_root).length

      result = materializer(project_root, store).call("ordinary-finding-1-v1")

      assert_equal false, result.created
      assert_equal true, result.acknowledged
      assert_equal "acknowledged", store.fetch("ordinary-finding-1-v1").fetch("status")
      assert_equal 1, patrol_fix_tasks(project_root).length
    end
  end

  def test_same_root_attaches_provenance_and_material_change_advances_generation
    with_initialized_project do |project_root|
      store = admission_store(project_root)
      first = source_snapshot
      decide_distinct(store, "ordinary-finding-1-v1", first)
      created = materializer(project_root, store).call("ordinary-finding-1-v1")

      architecture = source_snapshot(
        engine: "architecture_patrol", identity: "thesis-7",
        title: "Consolidate refresh failure handling"
      )
      decide_same_root(store, "architecture-thesis-7-v1", architecture, created.slug)
      equivalent = materializer(project_root, store).call("architecture-thesis-7-v1")
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: equivalent.task_folder).read

      assert_equal 1, manifest.dig("task", "generation")
      assert_equal %w[architecture_patrol ordinary_patrol],
                   manifest.fetch("sources").map { |source| source.fetch("engine") }.sort

      changed = source_snapshot(
        identity: "finding-1", summary: "Refresh now also corrupts the session cache.",
        evidence: [ "Reachable failure", "The session cache is left corrupt." ]
      )
      decide_same_root(store, "ordinary-finding-1-v2", changed, created.slug)
      advanced = materializer(project_root, store).call("ordinary-finding-1-v2")
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: advanced.task_folder).read

      assert_equal 2, manifest.dig("task", "generation")
      assert_equal changed.evidence_digest, manifest.dig("evidence_revision", "digest")
    end
  end

  def test_exact_pull_request_gets_current_generation_receipt_and_issue_is_read_only_provenance
    with_initialized_project do |project_root|
      store = admission_store(project_root)
      snapshot = source_snapshot(
        external_issues: [ { "url" => "https://github.com/acme/demo/issues/9", "number" => 9 } ],
        existing_pull_requests: [ exact_publication(number: 7) ]
      )
      decide_same_root(
        store, "ordinary-finding-pr-v1", snapshot, "github:acme/demo#7",
        kind: "pull_request"
      )

      result = materializer(project_root, store).call("ordinary-finding-pr-v1")
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: result.task_folder).read
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: result.task_folder).read_all

      assert_equal [ 9 ], manifest.dig("relations", "issues").map { |issue| issue.fetch("number") }
      publication = receipts.find { |receipt| receipt.fetch("kind") == "publication" }
      assert_equal "https://github.com/acme/demo/pull/7", publication.dig("payload", "url")
      assert_equal "pub-#{'7' * 32}", publication.dig("payload", "publication_id")
      assert_equal 1, publication.dig("task", "generation")
    end
  end

  def test_cross_source_empty_candidate_race_redecides_and_converges_on_one_task
    with_initialized_project do |project_root|
      store = admission_store(project_root)
      ordinary = source_snapshot
      architecture = source_snapshot(
        engine: "architecture_patrol", identity: "thesis-7",
        title: "Consolidate refresh failure handling"
      )
      decide_distinct(store, "ordinary-race-v1", ordinary)
      decide_distinct(store, "architecture-race-v1", architecture)
      provider = candidate_provider(project_root)
      head = -> { "2" * 40 }

      first = materializer(
        project_root, store, candidate_provider: provider, current_head: head
      ).call("ordinary-race-v1")
      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        materializer(
          project_root, store, candidate_provider: provider, current_head: head
        ).call("architecture-race-v1")
      end
      assert_equal "pending", store.fetch("architecture-race-v1").fetch("status")

      semantic = Hive::PatrolFix::SemanticAdmission.new(
        store: store, candidate_provider: provider, current_head: head,
        decision_provider: lambda do |input|
          {
            "decision" => "same_root",
            "candidate_identity" => input.fetch("candidates").first.fetch("identity"),
            "rationale" => "Same refresh root", "evidence" => [ "Same failing contract" ],
            "model_receipt" => "fake:same-root"
          }
        end,
        clock: -> { NOW }
      )
      semantic.call(occurrence_id: "architecture-race-v1", snapshot: architecture)
      materializer(
        project_root, store, candidate_provider: provider, current_head: head
      ).call("architecture-race-v1")

      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: first.task_folder).read
      assert_equal 1, patrol_fix_tasks(project_root).length
      assert_equal %w[architecture_patrol ordinary_patrol],
                   manifest.fetch("sources").map { |source| source.fetch("engine") }.sort
    end
  end

  def test_replays_intent_when_first_task_capture_fails_before_creating_the_task
    with_initialized_project do |project_root|
      store = admission_store(project_root)
      decide_distinct(store, "ordinary-create-retry-v1", source_snapshot)
      failing_factory = lambda do |**_args|
        Object.new.tap do |capture|
          capture.define_singleton_method(:call) { raise "capture unavailable" }
        end
      end

      error = assert_raises(RuntimeError) do
        materializer(
          project_root, store, task_capture_factory: failing_factory
        ).call("ordinary-create-retry-v1")
      end
      assert_equal "capture unavailable", error.message
      assert_equal "materializing", store.fetch("ordinary-create-retry-v1").fetch("status")
      assert_empty patrol_fix_tasks(project_root)

      result = materializer(project_root, store).call("ordinary-create-retry-v1")

      assert_equal true, result.created
      assert_equal "acknowledged", store.fetch("ordinary-create-retry-v1").fetch("status")
      assert_equal 1, patrol_fix_tasks(project_root).length
    end
  end

  def test_replays_intent_when_existing_task_update_fails_before_commit
    with_initialized_project do |project_root|
      store = admission_store(project_root)
      decide_distinct(store, "ordinary-update-base-v1", source_snapshot)
      first = materializer(project_root, store).call("ordinary-update-base-v1")
      architecture = source_snapshot(
        engine: "architecture_patrol", identity: "thesis-retry",
        title: "Consolidate refresh failure handling"
      )
      decide_same_root(store, "architecture-update-retry-v1", architecture, first.slug)
      failing_git = OneShotFailingGitOps.new(project_root)

      assert_raises(RuntimeError) do
        materializer(
          project_root, store, git_ops: failing_git
        ).call("architecture-update-retry-v1")
      end
      assert_equal "materializing", store.fetch("architecture-update-retry-v1").fetch("status")

      result = materializer(project_root, store).call("architecture-update-retry-v1")
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: result.task_folder).read

      assert_equal %w[architecture_patrol ordinary_patrol],
                   manifest.fetch("sources").map { |source| source.fetch("engine") }.sort
      assert_equal "acknowledged", store.fetch("architecture-update-retry-v1").fetch("status")
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io do
          Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call
        end
        yield project_root
      end
    end
  end

  def admission_store(project_root, klass: Hive::PatrolFix::AdmissionStore)
    klass.new(
      root: File.join(project_root, ".hive-state", "patrol-fix", "admissions")
    )
  end

  def materializer(project_root, store, candidate_provider: nil, current_head: nil,
                   task_capture_factory: nil, git_ops: nil)
    Hive::PatrolFix::TaskMaterializer.new(
      project_root: project_root,
      hive_state: File.join(project_root, ".hive-state"),
      store: store,
      workflow_info: {
        descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
        pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
      },
      candidate_provider: candidate_provider, current_head: current_head,
      task_capture_factory: task_capture_factory, git_ops: git_ops,
      clock: -> { NOW }
    )
  end

  def decide_distinct(store, occurrence_id, snapshot)
    store.reserve!(occurrence_id: occurrence_id, snapshot: snapshot, now: NOW)
    prepared = store.prepare_decision!(
      occurrence_id, candidates: [], current_head: "2" * 40, now: NOW
    )
    store.record_decision!(
      occurrence_id, candidate_digest: prepared.fetch("candidate_digest"),
      reservation_id: prepared.dig("decision_reservation", "reservation_id"),
      decision: "distinct", rationale: "Different root", evidence: [ "No exact candidate" ],
      model_receipt: "fake:distinct", now: NOW
    )
  end

  def decide_same_root(store, occurrence_id, snapshot, identity, kind: "task")
    candidate = {
      "kind" => kind, "identity" => identity,
      "evidence_digest" => "a" * 64, "target_revision" => "1" * 40
    }
    store.reserve!(occurrence_id: occurrence_id, snapshot: snapshot, now: NOW)
    prepared = store.prepare_decision!(
      occurrence_id, candidates: [ candidate ], current_head: "2" * 40, now: NOW
    )
    store.record_decision!(
      occurrence_id, candidate_digest: prepared.fetch("candidate_digest"),
      reservation_id: prepared.dig("decision_reservation", "reservation_id"),
      decision: "same_root", candidate_identity: identity, rationale: "Same root",
      evidence: [ "Same failure" ], model_receipt: "fake:same", now: NOW
    )
  end

  def source_snapshot(engine: "ordinary_patrol", identity: "finding-1",
                      title: "Repair refresh", summary: "Refresh fails",
                      evidence: [ "Reachable failure" ], external_issues: [],
                      existing_pull_requests: [])
    Hive::PatrolFix::SourceSnapshot.build(
      engine: engine, identity: identity, title: title, summary: summary,
      target_revision: "1" * 40, evidence: evidence,
      affected_code: [ "lib/demo.rb" ], reproduction_guidance: "Run focused test",
      discovery_run: "run-1", semantic_lineage: [ "refresh" ], aliases: [],
      external_issues: external_issues, existing_pull_requests: existing_pull_requests,
      accepted_at: NOW.iso8601
    )
  end

  def exact_publication(number:)
    {
      "id" => "github:acme/demo##{number}",
      "publication_id" => "pub-#{number.to_s * 32}",
      "number" => number,
      "url" => "https://github.com/acme/demo/pull/#{number}",
      "host" => "github.com", "repository" => "acme/demo",
      "base_branch" => "main", "creation_base_revision" => "1" * 40,
      "branch" => "patrol/fix-#{number}", "head_revision" => "3" * 40,
      "diff_digest" => "4" * 64, "title_digest" => "5" * 64,
      "body_digest" => "6" * 64, "marker_digest" => "7" * 64,
      "state" => "open", "observed_at" => NOW.iso8601
    }
  end

  def patrol_fix_tasks(project_root)
    Dir.glob(File.join(project_root, ".hive-state", "stages", "*", "*", "meta.yml")).select do |path|
      Hive::TaskMeta.read(File.dirname(path))[:workflow] == "patrol-fix"
    end
  end

  def candidate_provider(project_root)
    lambda do |_snapshot|
      patrol_fix_tasks(project_root).map do |meta_path|
        folder = File.dirname(meta_path)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
        {
          "kind" => "task", "identity" => File.basename(folder),
          "evidence_digest" => manifest.dig("evidence_revision", "digest"),
          "target_revision" => manifest.fetch("target_revision")
        }
      end
    end
  end

  class OneShotFailingGitOps
    def initialize(project_root)
      @delegate = Hive::GitOps.new(project_root)
      @failed = false
    end

    def hive_commit(**)
      unless @failed
        @failed = true
        raise "commit unavailable"
      end
      @delegate.hive_commit(**)
    end

    def run_git!(*args) = @delegate.run_git!(*args)
  end

  class OneShotAcknowledgementFailureStore < Hive::PatrolFix::AdmissionStore
    def acknowledge!(...)
      unless defined?(@failed_once)
        @failed_once = true
        raise "crash before admission acknowledgement"
      end
      super
    end
  end
end
