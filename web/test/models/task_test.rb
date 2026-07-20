require "test_helper"

class TaskTest < ActiveSupport::TestCase
  test "finds the task in its project snapshot" do
    project = { "name" => "alpha" }
    attributes = { "slug" => "ship-it-260720-abcd", "stage" => "3-plan" }
    snapshot = {
      "projects" => [
        { "name" => "other", "tasks" => [ attributes ] },
        { "name" => "alpha", "tasks" => [ attributes ] }
      ]
    }

    task = Task.find!(project:, slug: attributes["slug"], snapshot:)

    assert_equal "3-plan", task["stage"]
    assert_equal attributes["slug"], task.slug
  end

  test "raises the typed not-found error for an unknown task" do
    error = assert_raises(Hive::InvalidTaskPath) do
      Task.find!(project: { "name" => "alpha" }, slug: "missing", snapshot: { "projects" => [] })
    end

    assert_equal "unknown task missing", error.message
  end

  test "resolves only plain media filenames inside the real task folder" do
    root = Pathname(Dir.mktmpdir("hive-web-task-model"))
    folder = root.join("task")
    media = folder.join("media")
    media.mkpath
    media.join("still.png").binwrite("png")
    root.join("outside.png").binwrite("outside")
    task = Task.new(
      project: { "name" => "alpha" },
      attributes: { "slug" => "ship-it-260720-abcd", "folder" => folder.to_s }
    )

    assert_equal media.join("still.png").realpath.to_s, task.media_path("still.png")
    assert_nil task.media_path("../outside.png")
    assert_nil task.media_path("still.rb")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end
end
