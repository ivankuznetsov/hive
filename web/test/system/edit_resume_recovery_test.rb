require "application_system_test_case"

class EditResumeRecoveryTest < ApplicationSystemTestCase
  teardown { StatusBroadcaster.stop! }

  test "brainstorm cards show waiting recovery and parked repair without an answer prompt" do
    name = create_hive_project!("edit-recovery-browser")
    sign_in!
    project = Project.find!(name).attributes
    rows = %w[cooldown parked consumed].each_with_index.map do |slug, index|
      binding = { "project" => name, "task_id" => (index + 1).to_s,
        "intended_stage" => "2-brainstorm", "task_locator" => "id:#{index + 1}" }
      recovery = {
        "variant" => "failed_edit", "status" => "cooldown", "owner" => "scheduler",
        "scheduler_status" => "current", "reason" => "spawn failed",
        "next_eligible_at" => "2026-11-03T12:05:00Z", "task_binding" => binding,
        "source_binding" => binding.merge("request_id" => "source-#{index}", "attempt_id" => "failed-#{index}"),
        "input_binding" => { "task_input_epoch" => 1, "progress_token" => "a" * 64 }
      }
      if slug == "parked"
        recovery.merge!("status" => "blocked", "owner" => "operator", "reason" => "deterministic_failure",
          "escalation_tier" => "parked", "remediation" => "edits do not release this park; use the current workflow.retry action")
      end
      { "id" => index + 1, "slug" => slug, "workflow" => "coding", "stage" => "2-brainstorm",
        "marker" => "waiting", "action" => "needs_input", "answers_complete" => true,
        "scheduler_status" => "current", "recovery" => slug == "consumed" ? nil : recovery }
    end
    data = project.merge("tasks" => rows)
    payload = StatusBroadcaster.snapshot_with_version.payload.merge(
      "projects" => [ data ], "board_metadata" => Board.new([ Project.new(data) ]).metadata
    )
    snapshot = StatusBroadcaster::PageSnapshot.new(payload: payload, version: "edit-recovery-browser")

    with_replaced_singleton_method(StatusBroadcaster, :snapshot_with_version, -> { snapshot }) do
      visit board_path(project: name)
      within ".kanban-card[data-task-slug='cooldown']" do
        assert_text "Needs recovery"
        assert_text "2026-11-03T12:05:00Z"
        assert_text "spawn failed"
        assert_button "Retry stage", disabled: false
        assert_selector "input[name=observation_token]", visible: :all
        assert_no_text "Answer questions"
      end
      within ".kanban-card[data-task-slug='parked']" do
        assert_text "Needs execution repair"
        assert_text "edits do not release this park"
        assert_button "Retry stage", disabled: false
        assert_no_text "Answer questions"
      end
      within ".kanban-card[data-task-slug='consumed']" do
        assert_text "Waiting"
        assert_no_button "Retry stage"
        assert_no_text "Answer questions"
      end
    end
  end
end
