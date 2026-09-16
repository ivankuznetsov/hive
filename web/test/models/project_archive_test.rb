require "test_helper"

class ProjectArchiveTest < ActiveSupport::TestCase
  test "scopes reads and reuses history until a stage move or cache expiry" do
    name = create_hive_project!("project-archive-cache")
    project = Project.find!(name)
    calls = []
    command = Object.new
    command.define_singleton_method(:json_payload) do |projects|
      calls << projects.map { |entry| entry.fetch("name") }
      { "projects" => projects.map { |entry| entry.merge("tasks" => []) } }
    end
    original = Hive::Commands::Status.method(:new)
    Hive::Commands::Status.define_singleton_method(:new) { |**| command }
    ProjectArchive::CACHE.clear

    2.times { ProjectArchive.snapshot(project) }
    assert_equal [ [ name ] ], calls

    done = stage_dir(name, "9-done")
    FileUtils.mkdir_p(done.join("new-completion"))
    File.utime(Time.now + 1, Time.now + 1, done)
    ProjectArchive.snapshot(project)
    assert_equal [ [ name ], [ name ] ], calls

    travel 61.seconds do
      ProjectArchive.snapshot(project)
    end
    assert_equal [ [ name ], [ name ], [ name ] ], calls
  ensure
    Hive::Commands::Status.define_singleton_method(:new, original) if original
    ProjectArchive::CACHE.clear
  end
end
