require "test_helper"

class StatusPageFeedTest < ActiveSupport::TestCase
  setup do
    name = create_hive_project!("page-feed-project")
    @project = Project.find!(name).attributes.merge("tasks" => [])
    @history = @project.merge("tasks" => [ { "slug" => "finished", "stage" => "9-done",
      "workflow" => "coding", "action" => "archived" } ])
    @archive_calls = []
    @source = Object.new.extend(Hive::Web::StatusCommand)
    project = @project
    @source.define_singleton_method(:json_payload) { |_| { "projects" => [ project ] } }
    @running = { running: true, pid: 123 }
    @probes = 0
    @report = Object.new
    owner = self
    @report.define_singleton_method(:running_state) { owner.instance_variable_get(:@running) }
    @report.define_singleton_method(:safe_payload) do
      owner.instance_variable_set(:@probes, owner.instance_variable_get(:@probes) + 1)
      { "running" => owner.instance_variable_get(:@running)[:running], "binary_drift" => "none",
        "service_installed" => true, "uptime_sec" => 100 }
    end
    @old_registry = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) { [ project ] }
    @old_archive = ProjectArchive.method(:snapshot)
    ProjectArchive.define_singleton_method(:snapshot) do |selected|
      owner.instance_variable_get(:@archive_calls) << selected.name
      raise IOError, "history unavailable" if owner.instance_variable_get(:@fail_archive)

      { "projects" => [ owner.instance_variable_get(:@history) ] }
    end
    ProjectArchive::REQUESTS.clear
    @feed = StatusPageFeed.new(status_command: @source, daemon_report: @report)
  end

  teardown do
    @feed&.stop
    Hive::Config.define_singleton_method(:registered_projects, @old_registry) if @old_registry
    ProjectArchive.define_singleton_method(:snapshot, @old_archive) if @old_archive
  end

  test "history is requested on demand and its changes use the existing page version" do
    first = @feed.snapshot_state
    assert_empty @archive_calls
    assert_empty first.payload.fetch("project_archives")
    ProjectArchive.request(@project)
    assert_same first, @feed.current_state, "a project click only subscribes; it must not scan"
    assert_empty @archive_calls

    second = @feed.snapshot_state
    assert_equal [ @project["name"] ], @archive_calls
    assert_equal [ "finished" ], second.payload.dig("project_archives", @project["name"], "tasks").map { |task| task["slug"] }
    assert_empty second.payload.dig("projects", 0, "tasks"), "completed rows must stay outside the active task projection"
    refute_equal first.token, second.token
    assert_equal second.token, @feed.snapshot_state.token, "unchanged page data must not cause refresh loops"

    travel 121.seconds do
      count = @archive_calls.length
      third = @feed.snapshot_state
      assert_equal count, @archive_calls.length, "inactive projects must stop requesting history refreshes"
      assert_equal second.payload["project_archives"], third.payload["project_archives"], "history must remain visible after the subscription expires"
    end
  end

  test "a failed history refresh keeps completed tasks visible and recovers later" do
    ProjectArchive.request(@project)
    original = @feed.snapshot_state
    @fail_archive = true
    failed = @feed.snapshot_state
    assert_equal "fresh", failed.availability, "a history failure must not disable the active status feed"
    assert_equal original.payload.dig("project_archives", @project["name"], "tasks"),
      failed.payload.dig("project_archives", @project["name"], "tasks")
    assert_equal "completed_history_unavailable", failed.payload.dig("project_archives", @project["name"], "error")
    travel 130.seconds do
      @fail_archive = false
      recovered = @feed.snapshot_state
      assert_nil recovered.payload.dig("project_archives", @project["name"], "error")
      refute_equal failed.token, recovered.token, "recovery must reach a quiet open tab even after a long outage"
    end
  end

  test "a queued first history read does not expire behind a slow active scan" do
    ProjectArchive.request(@project)
    travel 130.seconds do
      state = @feed.snapshot_state
      assert_equal [ "finished" ], state.payload.dig("project_archives", @project["name"], "tasks").map { |task| task["slug"] }
    end
  end

  test "successful background reads do not extend an inactive project lease" do
    ProjectArchive.request(@project)
    @feed.snapshot_state
    travel(60.seconds) { @feed.snapshot_state }
    travel 121.seconds do
      count = @archive_calls.length
      @feed.snapshot_state
      assert_equal count, @archive_calls.length
    end
  end

  test "daemon version checks are reused until expiry or a liveness change" do
    2.times { @feed.snapshot_state }
    assert_equal 1, @probes
    refute @feed.current_state.payload.fetch("daemon_status").key?("uptime_sec")
    @running = { running: false, pid: nil }
    assert_equal false, @feed.snapshot_state.payload.dig("daemon_status", "running")
    assert_equal 2, @probes
    travel 61.seconds do
      @feed.snapshot_state
      assert_equal 3, @probes
    end
  end

  test "unreadable workflows retain saved Done grouping with a warning until recovery" do
    descriptor = File.join(@project.fetch("hive_state_path"), "workflows", "finished-writing.yml")
    FileUtils.mkdir_p(File.dirname(descriptor))
    workflow = { "id" => "finished-writing", "stages" => [ { "name" => "deliver", "kind" => "terminal", "state_file" => "article.md" } ] }.to_yaml
    File.write(descriptor, workflow)
    @history["tasks"].first.merge!("workflow" => "finished-writing", "stage" => "1-deliver")
    ProjectArchive.request(@project)
    first = @feed.snapshot_state
    File.write(descriptor, "id: [broken\n")
    Hive::Workflows::Project.reset!

    second = @feed.snapshot_state
    project = Project.new(@project).with_history(@history)
    band = Board.new([ project ], metadata: second.payload.fetch("board_metadata")).bands.sole

    assert_equal "fresh", second.availability
    assert_equal "workflow_unavailable", band.error
    assert_equal [ "Done" ], band.columns.select { |column| column.tasks.any? }.map(&:label)
    assert_equal first.payload.dig("board_metadata", @project["name"], "workflows", "finished-writing"),
      second.payload.dig("board_metadata", @project["name"], "workflows", "finished-writing")

    File.write(descriptor, workflow)
    Hive::Workflows::Project.reset!
    recovered = @feed.snapshot_state
    assert_nil Board.new([ project ], metadata: recovered.payload.fetch("board_metadata")).bands.sole.error
  ensure
    Hive::Workflows::Project.reset!
  end

  test "reopened tasks use the fresh active row instead of stale completed history" do
    active = @project.merge("tasks" => [ @history["tasks"].first.merge("stage" => "4-execute", "action" => "agent_running") ])
    merged = Project.new(active).with_history(@history)
    assert_equal 1, merged.tasks.length
    assert_equal "agent_running", merged.tasks.first["action"]
    assert_nil merged.tasks.first["archive_source"]
  end

  test "history from a relocated project is not reused" do
    wrong = @history.merge("hive_state_path" => "/old/project-state")
    assert_empty Project.new(@project).with_history(wrong).tasks
    @feed.send(:publish, { "projects" => [ @project ], "project_archives" => { @project["name"] => wrong } })
    assert_empty @feed.snapshot_state.payload.fetch("project_archives")
  end
end
