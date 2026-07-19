require "test_helper"
require "digest"

class BoardPerformanceTest < ActionDispatch::IntegrationTest
  PROJECTS = 20
  SCANNED_PER_PROJECT = 500
  VISIBLE_PER_PROJECT = 50
  MAX_RENDER_SECONDS = 1.5
  MAX_SNAPSHOT_MULTIPLIER = 2.0
  MAX_CARD_BYTES = 8 * 1024

  setup do
    sign_in!
    @original_snapshot = StatusBroadcaster.method(:snapshot)
    @payload = synthetic_payload
    payload = @payload
    StatusBroadcaster.define_singleton_method(:snapshot) { payload }
  end

  teardown do
    StatusBroadcaster.define_singleton_method(:snapshot, @original_snapshot)
  end

  test "retained 20 by 500 snapshot renders at most one thousand cards within budget" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get board_path
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :success
    visible = PROJECTS * VISIBLE_PER_PROJECT
    assert_select ".board-card", visible
    assert_operator elapsed, :<, MAX_RENDER_SECONDS,
                    "initial board render took #{elapsed.round(3)}s (budget #{MAX_RENDER_SECONDS}s)"
    projects = StatusVisibility.projects(@payload)
    cards = projects.flat_map { |project| project.fetch("tasks") }
    assert_equal visible, cards.size
    samples = projects.flat_map do |project|
      project.fetch("tasks").map { |card| [ project, card ] }
    end.first(101)
    sizes = samples.map do |project, card|
      html = ApplicationController.render(
        partial: "board/card", locals: { task: card, project: project }
      )
      %(<turbo-stream action="replace"><template>#{html}</template></turbo-stream>).bytesize
    end.sort
    median = sizes.fetch(sizes.size / 2)
    assert_operator median, :<, MAX_CARD_BYTES,
                    "median rendered Turbo card payload was #{median} bytes (budget #{MAX_CARD_BYTES})"
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

  def synthetic_payload
    now = Time.now.utc
    old = (now - 5.days).iso8601
    recent = now.iso8601
    {
      "projects" => PROJECTS.times.map do |project_index|
        project = format("scale-%02d", project_index)
        {
          "name" => project,
          "path" => "/tmp/#{project}",
          "hive_state_path" => "/tmp/#{project}/.hive-state",
          "workflows" => [ workflow ],
          "tasks" => SCANNED_PER_PROJECT.times.map do |task_index|
            terminal = task_index >= VISIBLE_PER_PROJECT
            card(project, task_index, terminal: terminal, observed_at: terminal ? old : recent)
          end
        }
      end
    }
  end

  def workflow
    {
      "id" => "coding",
      "dependency_gate_stage" => "9-done",
      "stages" => [
        { "name" => "inbox", "dir" => "1-inbox", "index" => 1, "kind" => nil },
        { "name" => "done", "dir" => "9-done", "index" => 2, "kind" => nil }
      ]
    }
  end

  def card(project, index, terminal:, observed_at:)
    slug = format("scale-task-%02d-%03d", project.delete_prefix("scale-").to_i, index)
    {
      "slug" => slug,
      "display_name" => "Scale task #{index}",
      "workflow" => "coding",
      "stage" => terminal ? "9-done" : "1-inbox",
      "terminal" => terminal,
      "marker" => terminal ? "complete" : "waiting",
      "action" => terminal ? "archived" : "ready_to_brainstorm",
      "action_label" => terminal ? "Archived" : "Ready to brainstorm",
      "dominant_state" => terminal ? "idle" : "ready",
      "state_rank" => terminal ? 6 : 5,
      "fingerprint" => "tfp1:#{Digest::SHA256.hexdigest(slug)}",
      "card_digest" => "card1:#{Digest::SHA256.hexdigest("card:#{slug}")}",
      "allowed_transitions" => terminal ? [] : [ {
        "destination" => "9-done", "verb" => "approve", "direction" => "forward",
        "confirmation" => "none", "label" => "Move to Done"
      } ],
      "depends_on" => nil,
      "blocked_by" => nil,
      "operational_chips" => [],
      "age_seconds" => terminal ? 5.days.to_i : index,
      "mtime" => observed_at,
      "folder_mtime" => observed_at
    }
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
