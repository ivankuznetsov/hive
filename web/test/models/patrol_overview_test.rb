require "test_helper"

class PatrolOverviewTest < ActiveSupport::TestCase
  FakeProject = Data.define(:name, :path, :hive_state_path, :config)

  test "ordinary and architecture sections read their bounded native queries" do
    ordinary = Object.new
    ordinary.define_singleton_method(:list_envelope) do |project:, project_root:|
      raise "wrong ordinary identity" unless [ project, project_root ] == [ "demo", "/repo" ]
      {
        "count" => 1, "counts" => { "active" => 1 },
        "findings" => [ { "id" => "finding-1" } ], "truncated" => false,
        "last_run_at" => "2026-08-21T12:00:00Z",
        "feature_review_active" => false
      }
    end
    architecture = Object.new
    job = architecture_job("complete")
    architecture.define_singleton_method(:recent_projection) do |project:, project_root:, limit:|
      raise "wrong architecture identity" unless
        [ project, project_root, limit ] == [ "demo", "/repo", PatrolOverview::ITEM_LIMIT ]
      {
        "count" => 1, "truncated" => false,
        "jobs" => [ job ]
      }
    end
    architecture.define_singleton_method(:show_envelope) do |job_id:, limit:, **|
      raise "wrong detail identity" unless [ job_id, limit ] == [ "job-complete", 1 ]
      {
        "job" => {
          "dispositions" => {
            "fix" => [ {
              "id" => "thesis-1",
              "thesis" => {
                "problem" => "Ownership is split",
                "proposed_refactor" => "Use one owner"
              }
            } ],
            "discuss" => []
          }
        }
      }
    end

    overview = PatrolOverview.new(
      project, ordinary_query: ordinary, architecture_query: architecture
    )

    assert_equal "attention", overview.ordinary.health
    assert_equal [ "finding-1" ], overview.ordinary.items.map { |item| item.fetch("id") }
    assert_equal "healthy", overview.architecture.health
    assert_equal "Ownership is split",
                 overview.architecture.items.first.fetch("findings").first.fetch("problem")
  end

  test "disabled lanes do not read stores" do
    unreadable = Object.new
    unreadable.define_singleton_method(:list_envelope) { |**| raise "must not read" }
    unreadable.define_singleton_method(:recent_projection) { |**| raise "must not read" }
    disabled = project(
      "patrol" => { "mode" => "off" },
      "refactor_patrol" => { "enabled" => false }
    )

    overview = PatrolOverview.new(
      disabled, ordinary_query: unreadable, architecture_query: unreadable
    )

    assert_equal "disabled", overview.ordinary.health
    assert_equal "disabled", overview.architecture.health
  end

  test "source failures are isolated and diagnostics do not disclose details" do
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
    ordinary = Object.new
    ordinary.define_singleton_method(:list_envelope) { |**| raise "#{secret} at /private/file" }
    architecture = Object.new
    architecture.define_singleton_method(:recent_projection) do |**|
      { "count" => 0, "truncated" => false, "jobs" => [] }
    end
    logged = nil
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| logged = message }

    overview = PatrolOverview.new(
      project, ordinary_query: ordinary,
      architecture_query: architecture, logger: logger
    )

    assert_equal "unavailable", overview.ordinary.health
    assert_equal "idle", overview.architecture.health
    refute_includes logged, secret
    refute_includes logged, "/private/file"
    assert_match(/RuntimeError diagnostic=[a-f0-9]{12}\z/, logged)
  end

  test "architecture preserves query order and bounds detail expansion" do
    jobs = 7.downto(1).map do |number|
      architecture_job("complete").merge("job_id" => "job-#{number}")
    end
    details = []
    architecture = Object.new
    architecture.define_singleton_method(:recent_projection) do |limit:, **|
      raise "unbounded query" unless limit == PatrolOverview::ITEM_LIMIT
      { "count" => jobs.length, "truncated" => true, "jobs" => jobs }
    end
    architecture.define_singleton_method(:show_envelope) do |job_id:, limit:, **|
      raise "unbounded detail" unless limit == 1
      details << job_id
      {
        "job" => {
          "dispositions" => {
            "fix" => 4.times.map do |index|
              {
                "id" => "#{job_id}-#{index}",
                "thesis" => { "problem" => "problem-#{index}" }
              }
            end,
            "discuss" => []
          }
        }
      }
    end

    section = PatrolOverview.new(project, architecture_query: architecture).architecture

    assert_equal jobs.map { |job| job.fetch("job_id") },
                 section.items.map { |job| job.fetch("job_id") }
    assert_equal %w[job-7 job-6 job-5 job-4 job-3], details
    assert_equal PatrolOverview::ARCHITECTURE_FINDINGS_PER_JOB,
                 section.items.fetch(0).fetch("findings").length
    refute section.items.fetch(5).key?("findings")
    assert section.truncated
  end

  private

  def project(config = nil)
    FakeProject.new(
      name: "demo", path: "/repo", hive_state_path: "/state",
      config: config || {
        "patrol" => { "mode" => "medium" },
        "refactor_patrol" => { "enabled" => true }
      }
    )
  end

  def architecture_job(state)
    {
      "job_id" => "job-#{state}", "state" => state, "complete" => true,
      "source" => { "number" => 7, "url" => "https://github.com/acme/demo/pull/7" },
      "counts" => { "fix" => 1, "discuss" => 0, "pending_actions" => 0 },
      "blockers" => [], "updated_at" => "2026-08-21T12:00:00Z"
    }
  end
end
