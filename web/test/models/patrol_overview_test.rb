require "test_helper"

class PatrolOverviewTest < ActiveSupport::TestCase
  FakeProject = Struct.new(:name, :attributes) do
    def [](key) = attributes[key]
  end

  test "both sections pass through the common bounded projection" do
    projection = operational_projection
    overview = PatrolOverview.new(
      FakeProject.new("demo", { "patrol_fix" => projection })
    )

    assert_equal projection.dig("discovery", "ordinary", "items"), overview.ordinary.items
    assert_equal projection.dig("discovery", "architecture", "items"), overview.architecture.items
    assert_equal "attention", overview.ordinary.health
    assert_equal "running", overview.architecture.health
  end

  test "missing or cross-project projection fails closed" do
    projection = operational_projection.merge("project" => "other")
    overview = PatrolOverview.new(
      FakeProject.new("demo", { "patrol_fix" => projection })
    )

    assert_equal "unavailable", overview.ordinary.health
    assert_equal "unavailable", overview.architecture.health
    assert_equal "Patrol data is temporarily unavailable.", overview.ordinary.error
  end

  test "web adapter never opens discovery stores" do
    source = File.read(Rails.root.join("app/models/patrol_overview.rb"))

    refute_includes source, "StateStore"
    refute_includes source, "JobStore"
    refute_includes source, "FindingQuery"
    refute_includes source, "JobQuery"
  end

  private

  def operational_projection
    Hive::PatrolFix::OperationalProjection.new(
      project: "demo", tasks: [], admissions: [],
      discovery: {
        "ordinary" => lane("ordinary", "attention", ordinary_item),
        "architecture" => lane("architecture", "running", architecture_item),
        "post_merge" => { "queued" => 1 }, "coverage" => {}
      },
      migration: {
        "status" => "committed", "candidate_count" => 0, "group_count" => 0,
        "disposition_count" => 0, "acknowledgement_count" => 0,
        "manifest_digest" => "a" * 64
      }, now: Time.utc(2026, 8, 21, 12)
    ).to_h
  end

  def lane(engine, health, item)
    {
      "enabled" => true, "health" => health, "total" => 1,
      "counts" => { item.fetch("state") => 1 }, "last_run_at" => nil,
      "truncated" => false,
      "allowance" => {
        "engine" => engine, "utc_date" => "2026-08-21", "limit" => 4,
        "used" => 1, "remaining" => 3, "status" => "available", "retry_at" => nil
      }, "items" => [ item ]
    }
  end

  def ordinary_item
    item("ordinary_patrol", "finding-1", "active").merge(
      "title" => "Repair login", "summary" => "Login can crash"
    )
  end

  def architecture_item
    item("architecture_patrol", "job-1", "analyzing").merge(
      "title" => "Consolidate ownership", "route" => "fix",
      "source" => {
        "kind" => "pull_request", "id" => "42",
        "url" => "https://github.com/acme/demo/pull/42", "number" => 42
      }, "evidence" => [ "Duplicate owner" ]
    )
  end

  def item(engine, identity, state)
    {
      "engine" => engine, "identity" => identity, "state" => state,
      "title" => nil, "summary" => nil, "route" => nil, "severity" => nil,
      "confidence" => nil, "feature_id" => nil, "target_revision" => nil,
      "source" => nil, "updated_at" => nil, "evidence" => [], "blocker" => nil
    }
  end
end
