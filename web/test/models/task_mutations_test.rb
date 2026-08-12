require "test_helper"
require "hive/commands/workflow"
require "hive/workflows/project"

class TaskMutationsTest < ActiveSupport::TestCase
  setup { reset_task_mutation_state }
  teardown { reset_task_mutation_state }

  test "derives queueable actions from the canonical task action vocabulary" do
    expected = Hive::TaskAction::READY_COMMANDS.select do |_action, verb|
      Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS.include?(verb)
    end

    assert_equal expected, TaskMutations::STAGE_VERB_BY_ACTION
  end

  test "maps coding and generic runs to their canonical queue arguments" do
    coding = task("stage" => "6-review", "workflow" => "coding")
    generic = task(
      { "stage" => "2-gather", "workflow" => "research", "action" => "ready_to_run" },
      slug: "generic-task"
    )

    coding_result = coding.run!(expected_action: "ready_for_review", expected_stage: "6-review")
    generic_result = generic.run!(expected_action: "ready_to_run", expected_stage: "2-gather")

    assert_equal %w[hive review demo-task --project demo --from 6-review], coding_result[:argv]
    assert_equal %w[hive run generic-task --project demo --stage 2-gather], generic_result[:argv]
  end

  test "rejects unknown and non-queueable actions before writing" do
    subject = task("stage" => "3-plan", "workflow" => "coding")

    error = assert_raises(Hive::Error) do
      subject.run!(expected_action: "ready_to_advance", expected_stage: "3-plan")
    end

    assert_match(/unknown dispatch action/, error.message)
    assert_empty queue_files
  end

  test "maps queue grammar rejection to a typed task error" do
    subject = task({ "stage" => "3-plan", "workflow" => "coding" }, slug: "x")

    error = assert_raises(Hive::Error) do
      subject.run!(expected_action: "ready_to_plan", expected_stage: "3-plan")
    end

    assert_match(/cannot queue this dispatch/, error.message)
  end

  test "routes recovery through the shared coordinator writer" do
    subject = task(
      "stage" => "6-review",
      "workflow" => "coding",
      "marker" => "review_error",
      "attrs" => {
        "phase" => "triage", "reason" => "merge_conflict", "pass" => "1",
        "marker_id" => "review-generation-1"
      }
    )
    receipt = Hive::Daemon::RecoveryCoordinator::Receipt.new(
      status: "queued", request_id: "recovery-1", attempt_id: nil,
      phase: "admitted", failure_origin: "merge_conflict",
      next_eligible_at: Time.current.iso8601(6), owner: "scheduler",
      reason: nil, remediation: nil, retry_count: 1, provider_hint: nil
    )
    captured = nil
    replacement = proc do |**kwargs|
      captured = kwargs
      receipt
    end

    actual = with_replaced_singleton_method(
      Hive::Recovery::API, :recover!, replacement
    ) { subject.recover! }

    assert_equal receipt, actual
    assert_equal subject, captured.fetch(:row)
    assert_equal "demo", captured.fetch(:project)
    assert_equal "web", captured.fetch(:requestor)
  end

  test "surfaces coordinator writer failure" do
    subject = task(
      "stage" => "6-review",
      "workflow" => "coding",
      "marker" => "review_error",
      "attrs" => { "phase" => "triage", "reason" => "merge_conflict", "pass" => "1" }
    )
    replacement = proc { |**| raise Errno::ENOSPC, "no space left on device" }

    with_replaced_singleton_method(Hive::Recovery::API, :recover!, replacement) do
      assert_raises(Errno::ENOSPC) { subject.recover! }
    end

    assert_empty queue_files
  end

  test "refuses recovery without a failure marker" do
    subject = task("stage" => "6-review", "workflow" => "coding", "marker" => "none")

    error = assert_raises(Hive::Error) { subject.recover! }

    assert_match(/nothing to recover/, error.message)
    assert_empty queue_files
  end

  test "refuses manual-only recovery states" do
    subject = task(
      "stage" => "4-execute",
      "workflow" => "coding",
      "marker" => "execute_stale",
      "attrs" => {}
    )

    error = assert_raises(Hive::Error) { subject.recover! }

    refute_empty error.message
    assert_empty queue_files
  end

  test "routes max pass review recovery through the explicit intervention flow" do
    folder = Pathname(Dir.mktmpdir("hive-web-review-escalation"))
    folder.join("reviews").mkpath
    folder.join("reviews/escalations-02.md").write("# Questions\n")
    subject = task(
      "stage" => "6-review",
      "workflow" => "coding",
      "marker" => "review_stale",
      "attrs" => { "pass" => "2", "marker_id" => "marker-2" },
      "folder" => folder.to_s
    )

    error = assert_raises(Hive::Error) { subject.recover! }

    assert_match(/edit the current review escalation/, error.message)
    assert_empty queue_files
  ensure
    FileUtils.remove_entry(folder) if folder&.exist?
  end

  test "routes a generic workflow recovery through the same writer" do
    subject = task(
      "stage" => "2-gather", "workflow" => "research", "marker" => "error", "attrs" => {}
    )

    captured = nil
    receipt = Struct.new(:status).new("queued")
    replacement = proc do |**kwargs|
      captured = kwargs
      receipt
    end
    actual = with_replaced_singleton_method(
      Hive::Recovery::API, :recover!, replacement
    ) { subject.recover! }

    assert_equal receipt, actual
    assert_equal subject, captured.fetch(:row)
    assert_equal "web", captured.fetch(:requestor)
  end

  test "reject sends a coding task to its immediately prior gate" do
    project, subject = seeded_task("mutation-reject", stage: "6-review")

    capture_io { subject.reject!(from: "6-review") }

    assert stage_dir(project.name, "5-open-pr").join(subject.slug).directory?
    refute stage_dir(project.name, "2-brainstorm").join(subject.slug).directory?
  end

  test "approve and drop load a project-authored workflow" do
    project_name = create_hive_project!("mutation-custom-workflow")
    project = Project.find!(project_name)
    capture_io { Hive::Commands::Workflow.new!("flow", project_root: project.path) }

    approve_slug = create_task!(project_name, "approve custom resource")
    stamp_workflow(stage_dir(project_name, "1-inbox").join(approve_slug), "flow")
    Hive::Workflows::Project.reset!
    capture_io do
      task({ "slug" => approve_slug, "stage" => "1-inbox", "workflow" => "flow" }, project:)
        .approve!(from: "1-inbox", force: true)
    end

    assert stage_dir(project_name, "2-work").join(approve_slug).directory?

    drop_slug = create_task!(project_name, "drop custom resource")
    stamp_workflow(stage_dir(project_name, "1-inbox").join(drop_slug), "flow")
    Hive::Workflows::Project.reset!
    capture_io do
      task({ "slug" => drop_slug, "stage" => "1-inbox", "workflow" => "flow" }, project:).drop!(from: "1-inbox")
    end

    assert_empty Dir[File.join(project.hive_state_path, "stages", "*", drop_slug)]
  end

  test "records numbered answers and refuses a stale question" do
    with_seeded_brainstorm_task(
      "### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n"
    ) do |subject, brainstorm|
      questions = subject.open_questions
      answers = questions.to_h do |question|
        [ question.binding, question.n == 1 ? "Header only" : "Green tests" ]
      end

      result = subject.answer_questions!(answers.merge("ignored" => " "))

      assert_equal [ 1, 2 ], result[:answered]
      parsed = Hive::Bot::BrainstormParser.parse(brainstorm)
      assert_equal "Header only", parsed.find { |question| question.n == 1 }.answer.to_s.strip
      assert_equal "Green tests", parsed.find { |question| question.n == 2 }.answer.to_s.strip

      error = assert_raises(Hive::Error) do
        subject.answer_questions!(questions.first.binding => "again")
      end
      assert_match(/reload the page/, error.message)
    end
  end

  test "rejects a stale answer batch before writing any answer" do
    with_seeded_brainstorm_task(
      "### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n"
    ) do |subject, brainstorm|
      questions = subject.open_questions
      File.write(
        brainstorm,
        "### Q1. Scope?\n\n### A1.\n\n### Q2. Changed acceptance?\n\n### A2.\n\n"
      )

      error = assert_raises(Hive::Error) do
        subject.answer_questions!(
          questions.first.binding => "must not land",
          questions.last.binding => "stale"
        )
      end

      assert_match(/reload the page/, error.message)
      assert_equal [ nil, nil ], Hive::BrainstormParser.parse(brainstorm).map(&:answer)
    end
  end

  test "records an intervention as the next brainstorm answer" do
    with_seeded_brainstorm_task("### Q1. What is the goal?\n\n### A1.\n\n") do |subject, brainstorm|
      binding = subject.open_questions.first.binding

      result = subject.intervene!("Ship the box", binding: binding)

      assert_equal 1, result[:question_n]
      assert_equal "Ship the box", Hive::Bot::BrainstormParser.parse(brainstorm).first.answer.to_s.strip
    end
  end

  test "intervention requires the presented question binding" do
    with_seeded_brainstorm_task("### Q1. What is the goal?\n\n### A1.\n\n") do |subject, brainstorm|
      error = assert_raises(Hive::Error) do
        subject.intervene!("Ship the box", binding: "")
      end

      assert_match(/binding is required/, error.message)
      assert_nil Hive::BrainstormParser.parse(brainstorm).first.answer
    end
  end

  test "lock contention asks for a retry without claiming the question changed" do
    with_seeded_brainstorm_task("### Q1. What is the goal?\n\n### A1.\n\n") do |subject, _brainstorm|
      binding = subject.open_questions.first.binding
      receipt = {
        "outcome" => "lock_busy",
        "reason" => "task_lock_busy",
        "acknowledgement" => "Q1 is locked by another Hive operation; retry later."
      }

      error = with_replaced_singleton_method(
        Hive::Commands::Answer, :write, ->(*_args, **_kwargs) { receipt }
      ) do
        assert_raises(Hive::Error) { subject.intervene!("Ship it", binding: binding) }
      end

      assert_match(/locked by another Hive operation; retry later/, error.message)
      refute_match(/question changed/, error.message)
    end
  end

  test "non-brainstorm task pages skip answer inventory" do
    subject = task("stage" => "6-review", "workflow" => "coding")

    questions = with_replaced_singleton_method(
      Hive::Commands::Answer, :inventory, ->(*_args, **_kwargs) { flunk "inventory should be skipped" }
    ) { subject.open_questions }

    assert_empty questions
  end

  test "rejects a same-number question from a replacement round" do
    with_seeded_brainstorm_task(
      "## Round 1\n### Q1. Original scope?\n### A1.\n<!-- WAITING -->\n"
    ) do |subject, brainstorm|
      binding = subject.open_questions.first.binding
      File.write(
        brainstorm,
        "## Round 2\n### Q1. Replacement scope?\n### A1.\n<!-- WAITING -->\n"
      )

      error = assert_raises(Hive::Error) do
        subject.answer_questions!(binding => "reply to the old question")
      end

      assert_match(/reload the page/, error.message)
      assert_nil Hive::BrainstormParser.parse(brainstorm).first.answer
    end
  end

  test "requires a brainstorm before accepting answers or interventions" do
    Dir.mktmpdir("task-no-brainstorm") do |folder|
      subject = task("folder" => folder)

      answers_error = assert_raises(Hive::Error) { subject.answer_questions!("1" => "x") }
      intervention_error = assert_raises(Hive::Error) do
        subject.intervene!("steer", binding: "invalid")
      end

      assert_match(/awaits a brainstorm/, answers_error.message)
      assert_match(/awaits a brainstorm/, intervention_error.message)
    end
  end

  test "plan review actions delegate exact web authority and resume once" do
    _project, subject = seeded_task("mutation-plan-review", stage: "3-plan")
    projection = Struct.new(:record).new(Struct.new(:state).new("cleared"))
    decision = Struct.new(:action).new("answer_finding")
    captured = nil
    service = Object.new
    service.define_singleton_method(:apply) do |**arguments|
      captured = arguments
      Struct.new(:applied, :decision, :projection).new(true, decision, projection)
    end
    resumed = []
    resumer = lambda do |task, action|
      resumed << [ task.slug, action ]
      projection
    end

    result = with_replaced_singleton_method(
      Hive::PlanReview::Projection, :load, ->(**) { projection }
    ) do
      with_replaced_singleton_method(
        Hive::PlanReview::TransitionGuard, :freshness,
        ->(**) { { "status" => "current", "reason" => nil } }
      ) do
        subject.plan_review_action!(
          action: "answer-finding", review_id: "pr-#{'a' * 64}",
          task_generation: "generation-1", policy_fingerprint: "b" * 64,
          expected_artifact_digest: "c" * 64, target_fingerprint: "prf-#{'d' * 64}",
          answer: "Use the reversible path.", operator: "alice", authorized: true,
          service_factory: ->(_task) { service }, resumer:
        )
      end
    end

    assert result.fetch(:applied)
    assert_equal "answer_finding", captured.fetch(:action)
    assert_equal "web", captured.fetch(:origin)
    assert_equal "alice", captured.fetch(:operator)
    assert captured.fetch(:authorized)
    assert_equal({ "answer" => "Use the reversible path." }, captured.fetch(:value))
    assert_equal [ [ subject.slug, "answer_finding" ] ], resumed
  end

  test "plan review action rejects a stale canonical plan before the decision service" do
    _project, subject = seeded_task("mutation-plan-review-stale", stage: "3-plan")
    projection = Struct.new(:record).new(Struct.new(:state).new("blocked"))

    error = with_replaced_singleton_method(
      Hive::PlanReview::Projection, :load, ->(**) { projection }
    ) do
      with_replaced_singleton_method(
        Hive::PlanReview::TransitionGuard, :freshness,
        ->(**) { { "status" => "stale", "reason" => "canonical plan changed" } }
      ) do
        assert_raises(Hive::PlanReview::StaleDecision) do
          subject.plan_review_action!(
            action: "retry", review_id: "pr-#{'a' * 64}",
            task_generation: "generation-1", policy_fingerprint: "b" * 64,
            expected_artifact_digest: "c" * 64, operator: "alice", authorized: true,
            service_factory: ->(_task) { flunk "stale action reached decision service" }
          )
        end
      end
    end

    assert_match(/refresh the current observation/, error.message)
  end

  private

  def reset_task_mutation_state
    FileUtils.rm_rf(File.join(Hive::Paths.state_home, "dispatch_requests"))
    Hive::Workflows::Project.reset!
  end

  def task(attributes = {}, project: nil, slug: "demo-task", **extra_attributes)
    project ||= Project.new("name" => "demo")
    Task.new(project:, attributes: { "slug" => slug }.merge(attributes).merge(extra_attributes))
  end

  def seeded_task(name, stage:)
    project_name = create_hive_project!(name)
    slug = create_task!(project_name, "resource mutation probe")
    source = stage_dir(project_name, "1-inbox").join(slug)
    destination = stage_dir(project_name, stage).join(slug)
    destination.dirname.mkpath
    FileUtils.mv(source, destination)
    project = Project.find!(project_name)
    [ project, task({ "slug" => slug, "stage" => stage, "folder" => destination.to_s }, project:) ]
  end

  def with_seeded_brainstorm_task(content)
    project_name = create_hive_project!("task-mutations-answers")
    slug = create_task!(project_name, "brainstorm answer #{SecureRandom.hex(4)}")
    source = stage_dir(project_name, "1-inbox").join(slug)
    destination = stage_dir(project_name, "2-brainstorm").join(slug)
    destination.dirname.mkpath
    FileUtils.mv(source, destination)
    brainstorm = destination.join("brainstorm.md")
    File.write(brainstorm, content)
    project = Project.find!(project_name)
    subject = task(
      { "slug" => slug, "stage" => "2-brainstorm", "folder" => destination.to_s },
      project: project,
      slug: slug
    )
    yield subject, brainstorm.to_s
  end

  def stamp_workflow(folder, workflow)
    metadata = Hive::TaskMeta.read(folder.to_s)
    Hive::TaskMeta.write(
      folder.to_s,
      id: metadata.fetch(:id),
      slug: metadata.fetch(:slug),
      display_name: metadata[:display_name],
      workflow:
    )
  end

  def queue_files(request_id = nil)
    pattern = request_id ? "*#{request_id}*" : "*"
    Dir[File.join(Hive::Paths.state_home, "dispatch_requests", pattern)].select { |path| File.file?(path) }
  end
end
