require "test_helper"

class StatusVisibilityTest < ActiveSupport::TestCase
  test "custom workflow terminals use the shared status retention identity" do
    old = 5.days.ago.utc.iso8601
    payload = {
      "projects" => [ {
        "name" => "custom",
        "workflows" => [ { "id" => "publishing", "stages" => [ { "dir" => "2-draft" }, { "dir" => "3-published" } ] } ],
        "tasks" => [
          { "slug" => "old-published", "workflow" => "publishing", "stage" => "3-published",
            "terminal" => true, "mtime" => old, "folder_mtime" => old },
          { "slug" => "old-draft", "workflow" => "publishing", "stage" => "2-draft",
            "terminal" => false, "mtime" => old, "folder_mtime" => old }
        ]
      } ]
    }

    visible = StatusVisibility.projects(payload).first.fetch("tasks").map { |task| task.fetch("slug") }

    assert_equal [ "old-draft" ], visible
  end
end
