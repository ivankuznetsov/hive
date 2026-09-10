require "application_system_test_case"
require "hive/daily_digest/store"

class DigestFlowTest < ApplicationSystemTestCase
  setup do
    FileUtils.rm_rf(Hive::Paths.daily_digest_root)
    @project = create_hive_project!("digest-browser-app")
    @slug = create_task!(@project, "Answer from the native task page")
    brainstorm = stage_dir(@project, "2-brainstorm").join(@slug)
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug), brainstorm)
    brainstorm.join("brainstorm.md").write("### Q1. PRIVATE QUESTION\n\n### A1.\n\n<!-- WAITING -->\n")
    @date = "2026-08-30"
    write_digest!
  end

  teardown do
    FileUtils.rm_rf(Hive::Paths.daily_digest_root)
    StatusBroadcaster.stop!
  end

  test "operator filters an accessible day and follows the native answer handoff" do
    sign_in!
    click_link "Digest"

    assert_current_path digest_path("today")
    visit digest_path(@date)
    assert_selector "h1", text: @date
    assert_selector "article.digest-page[data-record-id='#{@record_id}']"
    assert_selector ".digest-record-reference", text: @record_id.first(12)
    assert_selector "nav[aria-label='Digest date']"
    assert_link "← Previous", href: digest_path("2026-08-29")
    assert_link "Next →", href: digest_path("2026-08-31")
    assert_selector ".digest-attention", text: "Needs attention"
    assert_selector ".digest-activity", text: "Project activity"
    assert_selector ".digest-amendments", text: "Late amendments"
    assert_text "Recovered: Github · digest-browser-app"
    assert_text "Attention resolved: removed-project:resolved-task"
    assert_no_text "PRIVATE QUESTION"
    attention_rect = find(".digest-attention").rect
    activity_rect = find(".digest-activity").rect
    attention_y = attention_rect["y"] || attention_rect[:y]
    activity_y = activity_rect["y"] || activity_rect[:y]
    assert_operator attention_y, :<, activity_y

    find_link("← Previous").send_keys(:tab)
    assert_equal "Current", page.evaluate_script("document.activeElement.textContent.trim()")
    assert_equal "solid", page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")

    click_link "← Previous"
    assert_current_path digest_path("2026-08-29")
    click_link "Next →"
    assert_current_path digest_path(@date)
    assert_selector "h1", text: @date

    select @project, from: "Project"
    click_button "Apply"
    assert_current_path digest_path(@date, project: @project)
    assert_selector ".digest-project-group[data-project='#{@project}']"
    assert_no_selector ".digest-project-group[data-project='removed-project']"

    click_link "Open answer flow"
    assert_current_path task_path(@project, @slug)
    assert_equal "task-questions", URI.parse(page.current_url).fragment
    assert_selector "#task-questions"
    page.go_back
    assert_current_path digest_path(@date, project: @project)

    page.current_window.resize_to(390, 844)
    metrics = page.evaluate_script(<<~JS)
      (() => ({
        viewport: document.documentElement.clientWidth,
        page: document.documentElement.scrollWidth,
        filterHeight: document.querySelector("#digest-project-filter").getBoundingClientRect().height,
        actionHeight: document.querySelector(".digest-action-link").getBoundingClientRect().height
      }))()
    JS
    assert_operator metrics.fetch("page"), :<=, metrics.fetch("viewport") + 1
    assert_operator metrics.fetch("filterHeight"), :>=, 44
    assert_operator metrics.fetch("actionHeight"), :>=, 44
  end

  private

  def write_digest!
    current = Hive::Config.find_project(@project)
    store = Hive::DailyDigest::Store.new
    store.write_base(empty_record("2026-08-29", sequence: 1, interval_id: "9" * 64))
    start = Time.utc(2026, 8, 30)
    stored = store.write_base(
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => "a" * 64,
      "local_date" => @date, "sequence" => 2,
      "time_zone" => "UTC", "starts_at" => start.iso8601,
      "ends_at" => (start + 86_400).iso8601, "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "closed", "closed_at" => (start + 86_401).iso8601,
      "completeness" => "partial", "content" => "non_empty",
      "last_materialized_at" => (start + 86_401).iso8601,
      "projects" => [
        current.slice("project_id", "registration_id", "name"),
        { "project_id" => "removed", "registration_id" => "old", "name" => "removed-project" }
      ],
      "items" => [ item(current.fetch("project_id"), @project, @slug,
                        registration_id: current.fetch("registration_id")),
                   item("removed", "removed-project", "historical-task",
                        registration_id: "old") ],
      "attention" => [ {
        "attention_id" => "waiting:#{@slug}", "kind" => "unanswered",
        "project_id" => current.fetch("project_id"),
        "registration_id" => current.fetch("registration_id"), "project" => @project,
        "task_id" => 1, "task_slug" => @slug, "stage" => "2-brainstorm", "state" => "waiting",
        "waiting_since" => "2026-08-30T08:00:00Z", "waiting_age_seconds" => 3_600,
        "question" => "PRIVATE QUESTION"
      }, resolved_attention_record ],
      "gaps" => [ recovered_gap ], "source_frontiers" => {}
    )
    store.append_amendment(@date, recovery_amendment)
    store.write_base(empty_record("2026-08-31", sequence: 3, interval_id: "b" * 64))
    @record_id = stored.fetch("record_id")
  end

  def item(project_id, project, slug, registration_id: nil)
    {
      "fact_id" => "fact:#{project_id}", "kind" => "stage_transition",
      "category" => "progress", "summary" => "Task stage changed",
      "project_id" => project_id, "registration_id" => registration_id,
      "project" => project, "task_id" => 1,
      "task_slug" => slug, "stage" => "2-brainstorm", "occurred_at" => "2026-08-30T09:00:00Z",
      "observed_at" => "2026-08-30T09:00:01Z", "source" => "task_journal", "details" => {}
    }.compact
  end

  def empty_record(date, sequence:, interval_id:)
    start = Time.iso8601("#{date}T00:00:00Z")
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => interval_id, "local_date" => date, "sequence" => sequence,
      "time_zone" => "UTC", "starts_at" => start.iso8601,
      "ends_at" => (start + 86_400).iso8601, "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "closed", "closed_at" => (start + 86_401).iso8601,
      "completeness" => "complete", "content" => "empty",
      "last_materialized_at" => (start + 86_401).iso8601,
      "projects" => [], "items" => [], "attention" => [], "gaps" => [],
      "source_frontiers" => {}
    }
  end

  def recovered_gap
    {
      "gap_id" => "gap:github", "source" => "github", "scope" => @project,
      "reason_code" => "unavailable", "reason" => "required evidence unavailable",
      "observed_at" => "2026-08-30T20:00:00Z", "freshness_at" => nil
    }
  end

  def recovery_amendment
    resolved = resolved_attention_record
    {
      "amendment_id" => "amendment:recovery", "kind" => "gap_resolution",
      "source" => "github", "event_at" => "2026-08-30T20:30:00Z",
      "observed_at" => "2026-08-31T08:00:00Z", "amended_at" => "2026-08-31T08:00:01Z",
      "items" => [ item("removed", "removed-project", "late-task", registration_id: "old") ],
      "attention" => [], "gaps" => [], "resolved_gap_ids" => [ recovered_gap.fetch("gap_id") ],
      "resolved_gaps" => [ recovered_gap ],
      "resolved_attention_ids" => [ resolved.fetch("attention_id") ],
      "resolved_attention" => [ resolved ], "source_frontiers" => {}
    }
  end

  def resolved_attention_record
    {
      "attention_id" => "attention:resolved", "kind" => "failed",
      "project_id" => "removed", "registration_id" => "old",
      "project" => "removed-project", "task_slug" => "resolved-task",
      "stage" => "4-execute", "state" => "failed"
    }
  end
end
