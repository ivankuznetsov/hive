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
    Dir.mktmpdir("task-answers") do |folder|
      brainstorm = File.join(folder, "brainstorm.md")
      File.write(brainstorm, "### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")
      subject = task("folder" => folder)

      result = subject.answer_questions!("2" => "Green tests", "1" => "Header only", "3" => " ")

      assert_equal [ 1, 2 ], result[:answered]
      parsed = Hive::Bot::BrainstormParser.parse(brainstorm)
      assert_equal "Header only", parsed.find { |question| question.n == 1 }.answer.to_s.strip
      assert_equal "Green tests", parsed.find { |question| question.n == 2 }.answer.to_s.strip

      error = assert_raises(Hive::Error) { subject.answer_questions!("1" => "again") }
      assert_match(/no longer open/, error.message)
    end
  end

  test "records an intervention as the next brainstorm answer" do
    Dir.mktmpdir("task-intervention") do |folder|
      brainstorm = File.join(folder, "brainstorm.md")
      File.write(brainstorm, "### Q1. What is the goal?\n\n### A1.\n\n")
      subject = task("folder" => folder)

      result = subject.intervene!("Ship the box")

      assert_equal 1, result[:question_n]
      assert_equal "Ship the box", Hive::Bot::BrainstormParser.parse(brainstorm).first.answer.to_s.strip
    end
  end

  test "requires a brainstorm before accepting answers or interventions" do
    Dir.mktmpdir("task-no-brainstorm") do |folder|
      subject = task("folder" => folder)

      answers_error = assert_raises(Hive::Error) { subject.answer_questions!("1" => "x") }
      intervention_error = assert_raises(Hive::Error) { subject.intervene!("steer") }

      assert_match(/awaits a brainstorm/, answers_error.message)
      assert_match(/awaits a brainstorm/, intervention_error.message)
    end
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
