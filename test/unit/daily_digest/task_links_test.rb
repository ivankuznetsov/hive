require "test_helper"
require "hive/daily_digest/task_links"

class DailyDigestTaskLinksTest < Minitest::Test
  def test_replaced_project_identity_makes_persisted_task_link_historical
    current = {
      "project_id" => "stable-project", "registration_id" => "new-registration",
      "name" => "demo"
    }
    record = {
      "projects" => [ {
        "project_id" => "stable-project", "registration_id" => "old-registration",
        "name" => "demo"
      } ],
      "items" => [ {
        "fact_id" => "fact:one", "project_id" => "stable-project",
        "registration_id" => "old-registration", "project" => "demo",
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

  def test_two_registrations_with_one_project_id_are_resolved_by_row_registration
    old = {
      "project_id" => "stable-project", "registration_id" => "old-registration", "name" => "demo"
    }
    current = old.merge("registration_id" => "new-registration")
    old_row = {
      "fact_id" => "fact:old", "project_id" => "stable-project",
      "registration_id" => "old-registration", "project" => "demo",
      "task_slug" => "same-slug", "task_url" => "/tasks/demo/same-slug"
    }
    current_row = old_row.merge(
      "fact_id" => "fact:new", "registration_id" => "new-registration"
    )
    record = {
      "projects" => [ old, current ], "items" => [ old_row, current_row ],
      "attention" => [], "amendments" => []
    }
    links = Hive::DailyDigest::TaskLinks.new(
      current_projects: [ current ],
      resolver: ->(_project, _row) { { project: "demo", slug: "same-slug", source: nil } }
    )

    links.validate_rows!(record)

    assert_equal true, old_row.fetch("historical")
    refute old_row.key?("task_url")
    assert_equal "/tasks/demo/same-slug", current_row.fetch("task_url")
    refute current_row.key?("historical")
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
      current_projects: [ current ],
      resolver: ->(_project, _row) { { project: "demo", slug: "task", source: nil } }
    )

    links.validate_rows!(record)

    assert_equal "/tasks/demo/task", row.fetch("task_url")
    refute row.key?("historical")
  end

  def test_archived_task_rebuilds_actionable_url_and_preserves_answer_anchor
    current = {
      "project_id" => "project-1", "registration_id" => "registration-1", "name" => "demo"
    }
    row = {
      "fact_id" => "fact:one", "project_id" => "project-1", "project" => "demo",
      "task_slug" => "task", "task_url" => "/tasks/demo/task#task-questions"
    }
    record = { "projects" => [ current ], "items" => [], "attention" => [ row ], "amendments" => [] }
    links = Hive::DailyDigest::TaskLinks.new(
      current_projects: [ current ],
      resolver: ->(*) { { project: "demo", slug: "task", source: "archive" } }
    )

    links.validate_rows!(record)

    assert_equal "/tasks/demo/task?source=archive#task-questions", row.fetch("task_url")
    refute row.key?("historical")
  end

  def test_terminal_destination_uses_the_resolved_workflow_not_coding_stage_number
    stage = Struct.new(:name)
    workflow = Struct.new(:stages).new([ stage.new("inbox"), stage.new("done") ])
    task = Struct.new(:slug, :stage_name, :workflow).new("article", "done", workflow)

    destination = Hive::DailyDigest::TaskLinks.destination_for({ "name" => "content" }, task)

    assert_equal({ project: "content", slug: "article", source: "archive" }, destination)
  end

  def test_resolution_failures_make_the_task_historical
    current = { "project_id" => "project-1", "name" => "demo" }
    row = {
      "fact_id" => "fact:one", "project_id" => "project-1", "project" => "demo",
      "task_slug" => "task", "task_url" => "/tasks/demo/task"
    }
    record = { "projects" => [ current ], "items" => [ row ], "attention" => [], "amendments" => [] }
    links = Hive::DailyDigest::TaskLinks.new(
      current_projects: [ current ], resolver: ->(*) { raise IOError, "unreadable task" }
    )

    links.validate_rows!(record)

    assert_equal true, row.fetch("historical")
    refute row.key?("task_url")
  end
end
