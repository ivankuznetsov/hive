require "test_helper"

class PatrolOverviewTest < ActiveSupport::TestCase
  FakeProject = Data.define(:name, :path, :hive_state_path, :config)
  FakeFinding = Data.define(
    :id, :title, :category, :severity, :confidence, :description,
    :lifecycle_state, :lifecycle_updated_at
  )

  test "ordinary findings are active-first, newest-first, and bounded" do
    findings = 30.times.map do |index|
      FakeFinding.new(
        id: "finding-#{index}", title: "Finding #{index}", category: "bug",
        severity: "medium", confidence: "high", description: "Evidence #{index}",
        lifecycle_state: "active",
        lifecycle_updated_at: (Time.utc(2026, 8, 13) + index).iso8601
      )
    end
    findings << FakeFinding.new(
      id: "resolved", title: "Resolved", category: "bug", severity: "low",
      confidence: "high", description: "Done", lifecycle_state: "resolved",
      lifecycle_updated_at: Time.utc(2026, 8, 14).iso8601
    )
    query = Object.new
    query.define_singleton_method(:list_envelope) do |project:, project_root:|
      raise "wrong identity" unless project == "demo" && project_root == "/repo"

      {
        "count" => findings.size,
        "counts" => { "active" => 30, "resolved" => 1 },
        "findings" => findings.first(30).reverse.first(25).map do |finding|
          finding.to_h.transform_keys(&:to_s)
        end,
        "truncated" => true,
        "last_run_at" => "2026-08-13T12:00:00Z",
        "feature_review_active" => false
      }
    end

    section = overview(ordinary_query: query).ordinary

    assert_equal "attention", section.health
    assert_equal 31, section.total
    assert_equal({ "active" => 30, "resolved" => 1 }, section.counts)
    assert_equal 25, section.items.size
    assert_equal "finding-29", section.items.first.fetch("id")
    assert section.truncated
    assert_equal "2026-08-13T12:00:00Z", section.last_run_at
  end

  test "architecture jobs use the bounded native query projection" do
    jobs = [
      architecture_job("blocked", blocker: "partial_review"),
      architecture_job("complete")
    ]
    query = Object.new
    query.define_singleton_method(:recent_envelope) do |project:, project_root:, limit:|
      raise "wrong identity" unless project == "demo" && project_root == "/repo"
      raise "unbounded query" unless limit == PatrolOverview::ITEM_LIMIT

      {
        "count" => 120,
        "page" => { "has_more" => true },
        "jobs" => jobs
      }
    end
    query.define_singleton_method(:show_envelope) do |project:, project_root:, job_id:, limit:|
      raise "wrong detail identity" unless project == "demo" && project_root == "/repo"
      raise "unbounded history" unless limit == 1

      {
        "job" => {
          "dispositions" => {
            "fix" => [
              {
                "id" => "thesis-1",
                "thesis" => {
                  "problem" => "Architecture ownership is split",
                  "proposed_refactor" => "Move the policy behind one boundary"
                }
              }
            ],
            "discuss" => []
          }
        }
      }
    end

    section = overview(architecture_query: query).architecture

    assert_equal "attention", section.health
    assert_equal 120, section.total
    assert_equal({ "blocked" => 1, "complete" => 1 }, section.counts)
    assert_equal jobs.map { |job| job.fetch("job_id") },
                 section.items.map { |job| job.fetch("job_id") }
    assert_equal "Architecture ownership is split",
                 section.items.first.fetch("findings").first.fetch("problem")
    assert_equal "fix", section.items.first.fetch("findings").first.fetch("route")
    assert section.truncated
  end

  test "disabled patrols do not read their stores" do
    unreadable = Object.new
    unreadable.define_singleton_method(:list_envelope) { |**| raise "must not read" }
    unreadable.define_singleton_method(:recent_envelope) { |**| raise "must not read" }
    project = FakeProject.new(
      name: "demo", path: "/repo", hive_state_path: "/state",
      config: {
        "patrol" => { "mode" => "off" },
        "refactor_patrol" => { "enabled" => false }
      }
    )

    result = PatrolOverview.new(
      project, ordinary_query: unreadable, architecture_query: unreadable
    )

    assert_equal "disabled", result.ordinary.health
    assert_equal "disabled", result.architecture.health
    assert_empty result.ordinary.items
    assert_empty result.architecture.items
  end

  test "newest bounded architecture page drives health" do
    jobs = 24.times.map { architecture_job("complete") }
    jobs.unshift(architecture_job("blocked", blocker: "new_blocker").merge("job_id" => "newest"))
    query = Object.new
    query.define_singleton_method(:recent_envelope) do |limit:, **|
      raise "unbounded query" unless limit == PatrolOverview::ITEM_LIMIT

      { "count" => 40, "page" => { "has_more" => true }, "jobs" => jobs }
    end
    query.define_singleton_method(:show_envelope) do |**|
      { "job" => { "dispositions" => { "fix" => [], "discuss" => [] } } }
    end

    section = overview(architecture_query: query).architecture

    assert_equal "attention", section.health
    assert_equal "newest", section.items.first.fetch("job_id")
  end

  test "architecture detail reads stop at five jobs" do
    jobs = 6.times.map do |index|
      architecture_job("complete").merge("job_id" => "job-#{index}")
    end
    calls = []
    query = Object.new
    query.define_singleton_method(:recent_envelope) do |**|
      { "count" => 6, "page" => { "has_more" => false }, "jobs" => jobs }
    end
    query.define_singleton_method(:show_envelope) do |job_id:, **|
      calls << job_id
      { "job" => { "dispositions" => { "fix" => [], "discuss" => [] } } }
    end

    overview(architecture_query: query).architecture

    assert_equal 5, calls.size
  end

  test "section failures are isolated and client errors are stable" do
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
    ordinary = Object.new
    ordinary.define_singleton_method(:list_envelope) do |**|
      raise "#{secret} at /private/project/finding.json"
    end
    architecture = empty_architecture_query
    logged = nil

    logger = Object.new
    logger.define_singleton_method(:warn) { |message| logged = message }
    result = overview(
      ordinary_query: ordinary, architecture_query: architecture,
      logger: logger
    )
    assert_equal "unavailable", result.ordinary.health
    assert_equal "idle", result.architecture.health
    assert_equal "Patrol data is temporarily unavailable.", result.ordinary.error
    refute_includes logged, secret
    refute_includes logged, "/private/project/finding.json"
    assert_match(/RuntimeError diagnostic=[a-f0-9]{12}\z/, logged)
  end

  private

  def overview(ordinary_query: empty_ordinary_query,
               architecture_query: empty_architecture_query,
               logger: Rails.logger)
    project = FakeProject.new(
      name: "demo", path: "/repo", hive_state_path: "/state",
      config: {
        "patrol" => { "mode" => "medium" },
        "refactor_patrol" => { "enabled" => true }
      }
    )
    PatrolOverview.new(project, ordinary_query:, architecture_query:, logger:)
  end

  def empty_ordinary_query
    Object.new.tap do |query|
      query.define_singleton_method(:list_envelope) do |**|
        {
          "count" => 0, "counts" => {}, "findings" => [],
          "truncated" => false, "last_run_at" => nil,
          "feature_review_active" => false
        }
      end
    end
  end

  def empty_architecture_query
    Object.new.tap do |query|
      query.define_singleton_method(:recent_envelope) do |**|
        { "count" => 0, "page" => { "has_more" => false }, "jobs" => [] }
      end
      query.define_singleton_method(:show_envelope) do |**|
        raise "empty query must not request details"
      end
    end
  end

  def architecture_job(state, blocker: nil)
    {
      "job_id" => "job-#{state}", "state" => state,
      "complete" => state == "complete",
      "source" => { "number" => 7, "url" => "https://github.com/acme/demo/pull/7" },
      "counts" => {
        "fix" => 1, "discuss" => 0,
        "pending_actions" => state == "complete" ? 0 : 1
      },
      "blockers" => blocker ? [ { "scope" => "discovery", "reason" => blocker } ] : [],
      "updated_at" => "2026-08-13T12:00:00Z"
    }
  end
end
