require "test_helper"
require "hive/daily_digest/task_links"

class DailyDigestTaskLinksTest < Minitest::Test
  def test_replaced_project_identity_makes_persisted_task_link_historical
    current = {
      "project_id" => "new-project", "registration_id" => "new-registration",
      "name" => "demo"
    }
    record = {
      "projects" => [ {
        "project_id" => "old-project", "registration_id" => "old-registration",
        "name" => "demo"
      } ],
      "items" => [ {
        "fact_id" => "fact:one", "project_id" => "old-project", "project" => "demo",
        "task_slug" => "same-slug", "task_url" => "/tasks/demo/same-slug"
      } ],
      "attention" => [], "amendments" => []
    }
    links = Hive::DailyDigest::TaskLinks.new(
      current_projects: [ current ], resolver: ->(*) { flunk "replacement must not resolve" }
    )

    links.validate_rows!(record)

    assert_equal true, record.dig("items", 0, "historical")
    refute record.dig("items", 0).key?("task_url")
  end

  def test_exact_current_project_keeps_actionable_task_link
    current = {
      "project_id" => "project-1", "registration_id" => "registration-1", "name" => "demo"
    }
    row = {
      "fact_id" => "fact:one", "project_id" => "project-1", "project" => "demo",
      "task_slug" => "task", "task_url" => "/tasks/demo/task"
    }
    record = { "projects" => [ current ], "items" => [ row ], "attention" => [], "amendments" => [] }
    links = Hive::DailyDigest::TaskLinks.new(
      current_projects: [ current ], resolver: ->(_project, _row) { { slug: "task" } }
    )

    links.validate_rows!(record)

    assert_equal "/tasks/demo/task", row.fetch("task_url")
    refute row.key?("historical")
  end
end
