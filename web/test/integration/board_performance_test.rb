require "test_helper"
require "digest"

class BoardPerformanceTest < ActionDispatch::IntegrationTest
  PROJECTS = 20
  SCANNED_PER_PROJECT = 500
  VISIBLE_PER_PROJECT = 50
  MAX_RENDER_SECONDS = 1.5
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
    cards = StatusVisibility.projects(@payload).flat_map { |project| project.fetch("tasks") }
    assert_equal visible, cards.size
    sizes = cards.map { |card| JSON.generate(card).bytesize }.sort
    median = sizes.fetch(sizes.size / 2)
    assert_operator median, :<, MAX_CARD_BYTES,
                    "median serialized card was #{median} bytes (budget #{MAX_CARD_BYTES})"
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
end
