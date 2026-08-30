require "test_helper"
require "hive/daily_digest/store"

class DigestsTest < ActionDispatch::IntegrationTest
  setup do
    FileUtils.rm_rf(Hive::Paths.daily_digest_root)
  end

  teardown do
    FileUtils.rm_rf(Hive::Paths.daily_digest_root)
  end

  test "selected day is authenticated attention first filterable and read only" do
    get "/digests/2026-08-30"
    assert_redirected_to login_path

    sign_in!
    project_name = create_hive_project!("digest-live")
    slug = create_task!(project_name, "Waiting for digest answer")
    current = Hive::Config.find_project(project_name)
    store = Hive::DailyDigest::Store.new
    stored = store.write_base(record(current:, slug:))
    store.append_amendment("2026-08-30", amendment)
    before = File.binread(store.base_path("2026-08-30"))

    get digest_path("2026-08-30")

    assert_response :success
    assert_select "article.digest-page[aria-labelledby='digest-heading']"
    assert_select "nav[aria-label='Digest date']"
    assert_select ".digest-badge", text: "Closed"
    assert_select ".digest-badge", text: "Partial"
    assert_select ".digest-attention", text: /Needs attention/
    assert_select ".digest-activity", text: /Project activity/
    assert_operator response.body.index("Needs attention"), :<, response.body.index("Project activity")
    assert_select "a[href='#{task_path(project_name, slug, anchor: "task-questions")}']",
                  text: /Open answer flow/
    assert_select "a[href='https://github.com/acme/repo/pull/42']", text: /PR #42/
    assert_select ".digest-amendments", text: /Late amendments/
    assert_select ".digest-amendment-details", text: /Late: Task stage changed/
    assert_select ".digest-amendment-details", text: /Recovered: Github · recovered-source/
    assert_select ".digest-project-option[value='removed-project']", text: /removed-project/
    assert_select ".digest-historical", text: /Historical project/
    refute_includes response.body, "PRIVATE QUESTION TEXT"
    refute_includes response.body, "SECRET-BINDING"
    assert_equal before, File.binread(store.base_path("2026-08-30"))

    get digest_path("2026-08-30"), params: { project: project_name }

    assert_response :success
    assert_select ".digest-project-group[data-project='#{project_name}']", 1
    assert_select ".digest-project-group[data-project='removed-project']", 0
    assert_select ".digest-gap[data-scope='global']", 1
    assert_select ".digest-gap[data-scope='removed-project']", 0
    assert_select "select[name='project'] option[value='#{project_name}'][selected]", 1
    assert_equal before, File.binread(store.base_path("2026-08-30"))
    assert_equal stored.fetch("record_id"), store.read("2026-08-30").fetch("record_id")
  end

  test "missing empty partial stale and pruned days remain distinct" do
    sign_in!
    store = Hive::DailyDigest::Store.new
    store.write_base(simple_record("2026-08-28", content: "empty", completeness: "complete"))
    store.write_base(simple_record("2026-08-29", content: "unknown", completeness: "partial",
                                   gaps: [ gap("global") ]))
    store.write_base(simple_record("2026-08-30", lifecycle: "open", content: "empty",
                                   completeness: "complete",
                                   last_materialized_at: "2026-08-30T00:00:00Z"))
    store.write_base(simple_record("2026-08-27"))
    store.prune("2026-08-27", pruned_at: "2026-09-01T00:00:00Z", reason: "test")

    get digest_path("2026-08-26")
    assert_response :success
    assert_select ".digest-state-missing", text: /not persisted/
    assert_select "code", text: "hive digest refresh --date 2026-08-26"

    get digest_path("2026-08-27")
    assert_select ".digest-state-pruned", text: /pruned/

    get digest_path("2026-08-28")
    assert_select ".digest-empty", text: /No material activity/

    get digest_path("2026-08-29")
    assert_select ".digest-state-partial", text: /incomplete/i
    assert_select ".digest-empty", 0

    get digest_path("2026-08-30")
    assert_select ".digest-state-stale", text: /stale/i
  end

  private

  def record(current:, slug:)
    simple_record("2026-08-30").merge(
      "projects" => [
        current.slice("project_id", "registration_id", "name"),
        {
          "project_id" => "removed-id", "registration_id" => "removed-registration",
          "name" => "removed-project"
        }
      ],
      "items" => [
        item(current.fetch("project_id"), current.fetch("name"), slug,
             pr: { "number" => 42, "url" => "https://github.com/acme/repo/pull/42" }),
        item("removed-id", "removed-project", "historical-task")
      ],
      "attention" => [
        {
          "attention_id" => "attention-live", "kind" => "unanswered",
          "project_id" => current.fetch("project_id"), "project" => current.fetch("name"),
          "task_id" => 1, "task_slug" => slug, "stage" => "1-inbox", "state" => "waiting",
          "waiting_since" => "2026-08-30T10:00:00Z", "waiting_age_seconds" => 3_600,
          "question" => "PRIVATE QUESTION TEXT", "binding" => "SECRET-BINDING"
        }
      ],
      "gaps" => [ gap("global"), gap("removed-project", project_id: "removed-id") ],
      "completeness" => "partial", "content" => "non_empty"
    )
  end

  def simple_record(date, lifecycle: "closed", completeness: "complete", content: "non_empty",
                    gaps: [], last_materialized_at: nil)
    day = Date.iso8601(date)
    start = Time.utc(day.year, day.month, day.day)
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => "a" * 64,
      "local_date" => date, "sequence" => day.day,
      "time_zone" => "UTC", "starts_at" => start.iso8601,
      "ends_at" => (start + 86_400).iso8601, "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => lifecycle,
      "closed_at" => lifecycle == "closed" ? (start + 86_401).iso8601 : nil,
      "completeness" => completeness, "content" => content,
      "last_materialized_at" => last_materialized_at || (start + 86_401).iso8601,
      "projects" => [], "items" => content == "non_empty" ? [ item("demo", "demo", "task") ] : [],
      "attention" => [], "gaps" => gaps, "source_frontiers" => {}
    }
  end

  def item(project_id, project, slug, pr: nil)
    {
      "fact_id" => "fact:#{project_id}:#{slug}", "kind" => "stage_transition",
      "category" => "progress", "summary" => "Task stage changed",
      "project_id" => project_id, "project" => project, "task_id" => 1,
      "task_slug" => slug, "stage" => "4-execute", "occurred_at" => "2026-08-30T09:00:00Z",
      "observed_at" => "2026-08-30T09:00:01Z", "source" => "task_journal",
      "details" => {}, "pr" => pr
    }.compact
  end

  def gap(scope, project_id: nil)
    {
      "gap_id" => "gap:#{scope}", "source" => "github", "scope" => scope,
      "reason" => "required evidence unavailable", "reason_code" => "unavailable",
      "observed_at" => "2026-08-30T09:00:00Z", "freshness_at" => nil,
      "project_id" => project_id, "task_slug" => nil
    }
  end

  def amendment
    {
      "amendment_id" => "late:one", "kind" => "late_observation", "source" => "task_journal",
      "event_at" => "2026-08-30T20:00:00Z", "observed_at" => "2026-08-31T08:00:00Z",
      "amended_at" => "2026-08-31T08:00:01Z",
      "items" => [ item("removed-id", "removed-project", "late-task") ],
      "attention" => [], "gaps" => [], "resolved_gap_ids" => [ "gap:recovered" ],
      "resolved_gaps" => [
        gap("recovered-source").merge("gap_id" => "gap:recovered")
      ],
      "source_frontiers" => {}, "private_payload" => "MUST NOT RENDER"
    }
  end
end
