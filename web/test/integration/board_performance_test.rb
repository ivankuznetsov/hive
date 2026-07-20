require "test_helper"

class BoardPerformanceTest < ActionDispatch::IntegrationTest
  PROJECTS = 20
  SCANNED_PER_PROJECT = 500
  VISIBLE_PER_PROJECT = 50
  MAX_RENDER_SECONDS = 1.5
  MAX_SNAPSHOT_MULTIPLIER = 2.0
  MAX_CARD_BYTES = 8 * 1024

  setup do
    sign_in!
  end

  test "production 20 by 500 scan renders retained cards and broadcasts within budget" do
    Dir.mktmpdir("hive-board-production-performance") do |root|
      projects = real_scan_fixture(root, projects: PROJECTS, tasks_per_project: SCANNED_PER_PROJECT)
      with_registered_projects(projects) do
        started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        get board_path
        elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started

        assert_response :success
        visible = PROJECTS * VISIBLE_PER_PROJECT
        assert_select ".board-card", visible

        old_payload = StatusBroadcaster.snapshot
        changed_file = Dir[File.join(root, "disk-00", ".hive-state", "stages", "1-inbox", "*", "idea.md")].first
        File.write(changed_file, "# changed\n\n<!-- WAITING -->\n")
        changed_payload = StatusBroadcaster.snapshot
        messages = capture_cable_payloads do
          StatusBroadcaster.instance_variable_set(:@last_payload, old_payload)
          StatusBroadcaster.send(:broadcast, changed_payload)
        end
        card_sizes = messages.grep(/target="card_/).map(&:bytesize).sort
        refute_empty card_sizes, "the performance gate must exercise the real targeted broadcaster"
        median = card_sizes.fetch(card_sizes.size / 2)
        assert_operator median, :<, MAX_CARD_BYTES,
                        "median rendered Turbo card payload was #{median} bytes (budget #{MAX_CARD_BYTES})"
        refute messages.any? { |message| message.include?('target="projects"') },
               "steady card updates must not broadcast the complete projects grid"
        assert_operator elapsed, :<, MAX_RENDER_SECONDS,
                        "production scan-to-render used #{elapsed.round(3)}s CPU (budget #{MAX_RENDER_SECONDS}s)"
      end
    end
  end

  test "filesystem scan and card assembly stay within twice the scan baseline" do
    Dir.mktmpdir("hive-board-performance") do |root|
      projects = real_scan_fixture(root, projects: 10, tasks_per_project: SCANNED_PER_PROJECT)
      baseline_status = Hive::Commands::Status.new
      baseline_status.define_singleton_method(:task_payload) do |row|
        { "slug" => row[:slug], "stage" => row[:stage], "workflow" => row[:workflow] }
      end

      baseline_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      baseline_status.json_payload(projects)
      baseline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - baseline_started

      snapshot_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      payload = Hive::Commands::Status.new.json_payload(projects)
      snapshot = Process.clock_gettime(Process::CLOCK_MONOTONIC) - snapshot_started

      assert_equal 10 * SCANNED_PER_PROJECT,
                   payload.fetch("projects").sum { |project| project.fetch("tasks").size }
      assert_operator snapshot, :<=, baseline * MAX_SNAPSHOT_MULTIPLIER,
                      "card snapshot #{snapshot.round(3)}s exceeded 2x filesystem baseline #{baseline.round(3)}s"
    end
  end

  private

  def with_registered_projects(projects)
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) { projects }
    StatusBroadcaster.stop!
    yield
  ensure
    StatusBroadcaster.stop!
    Hive::Config.define_singleton_method(:registered_projects, original) if original
  end

  def capture_cable_payloads
    server = ActionCable.server
    original = server.method(:broadcast)
    messages = []
    server.define_singleton_method(:broadcast) do |_stream, content|
      messages << content.to_s
    end
    yield
    messages
  ensure
    server.define_singleton_method(:broadcast, original) if original
  end

  def real_scan_fixture(root, projects:, tasks_per_project:)
    old = Time.now - 5.days
    projects.times.map do |project_index|
      name = format("disk-%02d", project_index)
      project_root = File.join(root, name)
      hive_state = File.join(project_root, ".hive-state")
      tasks_per_project.times do |task_index|
        terminal = task_index >= VISIBLE_PER_PROJECT
        stage = terminal ? "9-done" : "1-inbox"
        folder = File.join(hive_state, "stages", stage, format("disk-task-%02d-%03d", project_index, task_index))
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, terminal ? "task.md" : "idea.md")
        File.write(state_file, terminal ? "# done\n\n<!-- COMPLETE -->\n" : "# inbox\n")
        File.utime(old, old, state_file) if terminal
        File.utime(old, old, folder) if terminal
      end
      { "name" => name, "path" => project_root, "hive_state_path" => hive_state }
    end
  end
end
