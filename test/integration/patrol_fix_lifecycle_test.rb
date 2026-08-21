require "test_helper"
require "json"
require "open3"
require "hive/commands/init"
require "hive/daemon/patrol_fix_admission_scheduler"
require "hive/daemon/patrol_fix_candidate_inventory"
require "hive/patrol/fix_admission_outbox"
require "hive/refactor_patrol/fix_admission_outbox"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/cutover_gate"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/stage_transition"
require "hive/patrol_fix/task_materializer"
require "hive/patrol_fix/transition"
require "hive/stages/patrol_fix/inbox"
require "hive/stages/patrol_fix/fix"
require "hive/stages/patrol_fix/validate"
require "hive/stages/patrol_fix/review"
require "hive/stages/patrol_fix/publish"
require "hive/workflows/registry"

class PatrolFixLifecycleIntegrationTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 8, 21, 12)
  CommandResult = Struct.new(
    :name, :command, :stdout, :stderr, :started_at, :finished_at,
    :duration_ms, :exit_code, :timed_out, :output_truncated, :provenance,
    keyword_init: true
  )

  class LocalGit
    attr_reader :pushes

    def initialize
      @delegate = Hive::GithubPublication::GitGateway.new(
        remote: "origin", allow_local_transport: true
      )
      @pushes = 0
    end

    def repository_identity(worktree_path:)
      { "host" => "github.com", "repository" => "example/patrol-fix" }
    end

    def observe(**values) = @delegate.observe(**values)

    def push_exact(**values)
      @pushes += 1
      @delegate.push_exact(**values)
    end
  end

  class FakeGithub
    attr_reader :creates, :records

    def initialize
      @creates = 0
      @records = []
    end

    def authenticate!(**) = true

    def list_pull_requests(cursor:, **)
      raise "unexpected pagination" if cursor
      { "items" => records, "next_cursor" => nil, "has_next_page" => false,
        "complete" => true, "truncated" => false }
    end

    def create_pull_request(request:, **)
      @creates += 1
      records << {
        "number" => 71, "url" => "https://github.com/example/patrol-fix/pull/71",
        "state" => "OPEN", "draft" => true,
        "head_branch" => request.branch, "head_oid" => request.head_oid,
        "head_repository" => request.repository,
        "base_branch" => request.base_branch,
        "base_repository" => request.repository,
        "title" => request.title, "body" => request.published_body
      }
      true
    end
  end

  def test_both_sources_converge_rework_and_publish_while_escalation_stays_parked
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        hive_state = File.join(project, ".hive-state")
        head = git(project, "rev-parse", "HEAD").strip
        gate = Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "u11")
        ordinary = Hive::Patrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "patrol", "patrol-fix-outbox"), gate: gate
        )
        architecture = Hive::RefactorPatrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "refactor-patrol", "patrol-fix-outbox"), gate: gate
        )
        ordinary_entry = ordinary.publish_migration_snapshot!(
          snapshot("ordinary_patrol", "finding-1", head), accepted_at: NOW
        )
        architecture_entry = architecture.publish_migration_snapshot!(
          snapshot("architecture_patrol", "thesis-1", head), accepted_at: NOW
        )
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )

        drive_admission_with_restarts(
          project, [ ordinary, architecture ], admission,
          [ ordinary_entry.fetch("occurrence_id"), architecture_entry.fetch("occurrence_id") ]
        )

        task = one_patrol_fix_task(hive_state)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
        assert_equal %w[architecture_patrol ordinary_patrol],
                     manifest.fetch("sources").map { |source| source.fetch("engine") }.sort
        assert_empty ordinary.pending
        assert_empty architecture.pending

        run_inbox(task)
        task = advance(task, "2-fix")
        runtime_root = Dir.mktmpdir("patrol-fix-lifecycle")
        (@runtime_roots ||= []) << runtime_root
        worktree_root = File.join(runtime_root, "worktrees")
        run_fix(task, worktree_root, "puts :fixed_once\n")
        task = advance(task, "3-validate")
        run_validation(task, worktree_root)
        task = advance(task, "4-review")

        rework = run_review(task, worktree_root, "rework")
        task = Hive::Task.new(rework.fetch(:moved_task_folder))
        assert_equal 2, current_manifest(task).dig("task", "generation")
        run_fix(task, worktree_root, "puts :fixed_twice\n")
        task = advance(task, "3-validate")
        run_validation(task, worktree_root)
        task = advance(task, "4-review")

        run_review(task, worktree_root, "publish")
        task = advance(task, "5-publish")

        remote = File.join(runtime_root, "remote.git")
        capture("git", "init", "--bare", remote)
        git(project, "remote", "add", "origin", remote)
        base_branch = git(project, "branch", "--show-current").strip
        git(project, "push", "origin", base_branch)
        git_gateway = LocalGit.new
        github = FakeGithub.new
        first = Hive::Stages::PatrolFix::Publish.run!(
          task, publish_config(base_branch), git_gateway: git_gateway, github_gateway: github,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )
        replay = Hive::Stages::PatrolFix::Publish.run!(
          task, publish_config(base_branch), git_gateway: git_gateway, github_gateway: github,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )

        assert_equal first.fetch(:receipt), replay.fetch(:receipt)
        assert_equal 1, git_gateway.pushes
        assert_equal 1, github.creates
        assert_equal 71, first.dig(:receipt, "payload", "number")
        task = advance(task, "6-done")
        assert_equal "done", Hive::PatrolFix::Projection.new(
          task_folder: task.folder, stage: "6-done"
        ).to_h.dig("action", "kind")

        escalation_entry = architecture.publish_migration_snapshot!(
          snapshot(
            "architecture_patrol", "thesis-escalate", git(project, "rev-parse", "HEAD").strip,
            title: "Choose a public compatibility policy", lineage: "compatibility-policy"
          ), accepted_at: NOW + 300
        )
        drive_admission_with_restarts(
          project, [ architecture ], admission,
          [ escalation_entry.fetch("occurrence_id") ]
        )
        escalation_task = one_patrol_fix_task(hive_state)
        escalated = run_inbox(escalation_task, route: "escalate")
        replayed = Hive::Stages::PatrolFix::Inbox.run!(
          escalation_task, {},
          agent_runner: ->(**) { flunk "durable escalation must not respawn" }
        )
        assert_equal :parked, escalated.fetch(:status)
        assert_equal escalated.dig(:successor, :slug), replayed.dig(:successor, :slug)
        successor_slug = escalated.dig(:successor, :slug)
        assert_equal 1, Dir.glob(File.join(hive_state, "stages", "*", successor_slug)).size
        assert_equal "1-inbox", File.basename(File.dirname(escalation_task.folder))
        refute File.exist?(File.join(escalation_task.folder, "pr.md"))
      end
    end
  end

  private

  def teardown
    Array(@runtime_roots).each do |root|
      FileUtils.remove_entry(root) if File.exist?(root)
    end
  end

  def snapshot(engine, identity, head, title: "Repair refresh failure", lineage: "refresh-root")
    Hive::PatrolFix::SourceSnapshot.build(
      engine: engine, identity: identity, title: title,
      summary: "Refresh leaves the same durable state inconsistent.", target_revision: head,
      evidence: [ "The refresh assertion fails at lib/example.rb:1." ],
      affected_code: [ "lib/example.rb" ], reproduction_guidance: "Run ruby -c lib/example.rb",
      discovery_run: "u11-run", semantic_lineage: [ lineage ], aliases: [],
      external_issues: [], existing_pull_requests: [], accepted_at: NOW.iso8601
    )
  end

  def drive_admission_with_restarts(project, sources, admission, occurrence_ids)
    services = {}
    observed = []
    12.times do |index|
      scheduler = admission_scheduler(project, sources, admission, services)
      events = scheduler.tick(now: NOW + index)
      observed << events.map { |event| [ event.source, event.status, event.reason ] }
      dispatch = events.find { |event| event.status == :decision_dispatch }
      if dispatch
        services.fetch(dispatch.occurrence_id).run_reserved(
          occurrence_id: dispatch.occurrence_id,
          reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
        )
        scheduler.complete(
          dispatch_token: dispatch.dispatch_token, exit_code: 0,
          envelope: { "ok" => true }, now: NOW + index
        )
      end
      return if sources.zip(occurrence_ids).all? do |source, occurrence_id|
        source.acknowledged?(occurrence_id)
      end
    end
    states = occurrence_ids.map { |id| admission.fetch(id)&.slice("status", "retry") }
    flunk "Patrol Fix handoffs did not converge: events=#{observed.inspect} states=#{states.inspect}"
  end

  def admission_scheduler(project, sources, admission, services)
    hive_state = File.join(project, ".hive-state")
    inventory = Hive::Daemon::PatrolFixCandidateInventory.new(hive_state_path: hive_state)
    current_head = -> { git(project, "rev-parse", "HEAD").strip }
    Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: sources, admission_store: admission, capacity_available: ->(**) { true },
      semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision" },
      semantic_admission_factory: lambda do |store:, entry:, **|
        service = Hive::PatrolFix::SemanticAdmission.new(
          store: store, candidate_provider: inventory.method(:call), current_head: current_head,
          decision_provider: lambda do |input|
            candidate = input.fetch("candidates").first
            force_distinct = input.dig("source", "identity") == "thesis-escalate"
            {
              "decision" => candidate && !force_distinct ? "same_root" : "distinct",
              "candidate_identity" => (candidate&.fetch("identity") unless force_distinct),
              "rationale" => "Both sources identify the same refresh remediation root.",
              "evidence" => [ "Shared affected code and semantic lineage." ],
              "model_receipt" => "fake:u11:semantic"
            }
          end,
          clock: -> { NOW }
        )
        services[entry.fetch("occurrence_id")] = service
      end,
      task_materializer_factory: lambda do |store:, source_acknowledger:, **|
        Hive::PatrolFix::TaskMaterializer.new(
          project_root: project, hive_state: hive_state, store: store,
          workflow_info: {
            descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"), pin: true,
            managed: nil, managed_cfg: {}, authored_digest: nil
          },
          source_acknowledger: source_acknowledger,
          candidate_provider: inventory.method(:call), current_head: current_head,
          clock: -> { NOW }
        )
      end,
      clock: -> { NOW }
    )
  end

  def one_patrol_fix_task(hive_state)
    folders = Dir.glob(File.join(hive_state, "stages", "1-inbox", "*"))
    assert_equal 1, folders.size
    Hive::Task.new(folders.first)
  end

  def run_inbox(task, route: "fix")
    runner = lambda do |output_path:, **|
      File.write(output_path, JSON.generate(
        "schema" => "hive-patrol-fix-inbox-report", "schema_version" => 1,
        "route" => route, "rationale" => "The controller-selected route is #{route}.",
        "evidence" => [ "Both authorities point to lib/example.rb." ],
        "blocker_owner" => (route == "escalate" ? "coding_workflow" : "inbox_gate")
      ))
      { status: :ok, custody: :clean }
    end
    result = Hive::Stages::PatrolFix::Inbox.run!(task, {}, agent_runner: runner)
    assert_equal(route == "fix" ? :complete : :parked, result.fetch(:status))
    result
  end

  def run_fix(task, worktree_root, body)
    runner = lambda do |owner:, output_path:, **|
      FileUtils.mkdir_p(File.join(owner.fetch("worktree"), "lib"))
      File.write(File.join(owner.fetch("worktree"), "lib", "example.rb"), body)
      git(owner.fetch("worktree"), "add", "lib/example.rb")
      git(owner.fetch("worktree"), "commit", "-m", "Fix refresh root")
      File.write(output_path, JSON.generate(
        "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
        "status" => "fixed", "summary" => "Fixed and committed the root cause.",
        "validation_commands" => [ { "identity" => "syntax", "command" => "ruby -c lib/example.rb" } ]
      ))
      { status: :ok, custody: :clean }
    end
    assert_equal :complete, Hive::Stages::PatrolFix::Fix.run!(
      task, {}, agent_runner: runner, worktree_root: worktree_root
    ).fetch(:status)
  end

  def run_validation(task, worktree_root)
    runner = lambda do |_path, commands|
      rows = commands.map do |command|
        CommandResult.new(
          name: command.fetch("identity"), command: command.fetch("command"),
          stdout: "Syntax OK\n", stderr: "", started_at: NOW, finished_at: NOW + 1,
          duration_ms: 1_000, exit_code: 0, timed_out: false,
          output_truncated: false, provenance: command.fetch("provenance")
        )
      end
      { "commands" => rows }
    end
    assert_equal :complete, Hive::Stages::PatrolFix::Validate.run!(
      task, {}, command_runner: runner, worktree_root: worktree_root
    ).fetch(:status)
  end

  def run_review(task, worktree_root, route)
    runner = lambda do |output_path:, **|
      File.write(output_path, JSON.generate(
        "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
        "route" => route, "rationale" => "Independent review selected #{route}.",
        "evidence" => [ "The exact patch and validation receipts were reviewed." ],
        "blocker_owner" => (route == "escalate" ? "coding_workflow" : "review_gate")
      ))
      { status: :ok, custody: :clean }
    end
    Hive::Stages::PatrolFix::Review.run!(
      task, {}, agent_runner: runner, worktree_root: worktree_root,
      transition: Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { true }
      )
    )
  end

  def advance(task, destination)
    target = File.join(task.hive_state_path, "stages", destination, task.slug)
    Hive::PatrolFix::StageTransition.with_lock(task) do |transition|
      transition.begin!(destination)
      FileUtils.mkdir_p(File.dirname(target))
      File.rename(task.folder, target)
      transition.complete!(destination)
    end
    Hive::Task.new(target)
  end

  def current_manifest(task)
    Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
  end

  def publish_config(base_branch)
    {
      "default_branch" => base_branch, "patrol" => { "draft_prs" => true },
      "agent_git_gate" => { "allow_local_transport" => true }
    }
  end

  def git(path, *args)
    output, error, status = Open3.capture3("git", "-C", path, *args)
    raise error unless status.success?
    output
  end

  def capture(*args)
    output, error, status = Open3.capture3(*args)
    raise error unless status.success?
    output
  end
end
