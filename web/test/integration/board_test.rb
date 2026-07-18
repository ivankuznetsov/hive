require "test_helper"

class BoardTest < ActionDispatch::IntegrationTest
  setup do
    sign_in!
    @original_snapshot = StatusBroadcaster.method(:snapshot)
    StatusBroadcaster.define_singleton_method(:snapshot) { BoardTest.payload }
  end

  teardown do
    StatusBroadcaster.define_singleton_method(:snapshot, @original_snapshot)
  end

  test "board and grid are stable first-class views" do
    get board_path
    assert_response :success
    assert_select "[data-board-band='alpha:coding']", 1
    assert_select "[data-stage='1-inbox']", 1
    assert_select "[data-stage='2-work']", 1
    assert_select "[data-card-slug='ship-board-260718-abcd']", 1
    assert_select "#board_sync[data-epoch][data-generation]", 1
    assert_select "[aria-live='polite']", 1
    assert_select ".stage-pager select[aria-label='Stage for alpha']", 1
    assert_select "[data-board-navigation-target='card'][tabindex='-1']", minimum: 1
    assert_select "a[href='#{grid_path}']", text: "Grid"

    get grid_path
    assert_response :success
    assert_select ".task-row", 2
    assert_select ".task-row", text: /old done/, count: 0
    assert_select "a[href='#{board_path}']", text: "Board"
  end

  test "workflow definitions remain project scoped" do
    get board_path

    assert_select "[data-board-band='alpha:coding'] [data-stage='2-work']", 1
    assert_select "[data-board-band='beta:coding'] [data-stage='2-draft']", 1
    assert_select "[data-board-band='alpha:coding'] [data-stage='2-draft']", 0
  end

  test "filters and grouping round trip through the query string" do
    get board_path, params: { project: "alpha", workflow: "coding", state: "ready", q: "ship", group: "agent" }

    assert_response :success
    assert_select "form[action='#{board_path}']"
    assert_select "select[name='project'] option[value='alpha'][selected]"
    assert_select "select[name='group'] option[value='agent'][selected]"
    assert_select "input[name='q'][value='ship']"
    assert_select "[data-board-band='alpha:coding']", 1
    assert_select "[data-board-band='beta:coding']", 0
    assert_select "[data-board-lane='codex']", 1
  end

  test "board uses shared archived-task retention" do
    get board_path

    assert_select "[data-card-slug='ship-board-260718-abcd']", 1
    assert_select "[data-card-slug='old-done-260701-dead']", 0
  end

  def self.payload
    now = Time.now.utc
    {
      "projects" => [
        project("alpha", "2-work", "ship-board-260718-abcd", now,
                stages: %w[1-inbox 2-work 3-done], agent: "codex"),
        project("beta", "2-draft", "write-board-260718-ef01", now,
                stages: %w[1-idea 2-draft 3-published], agent: "claude"),
        project("archive", "9-done", "old-done-260701-dead", now - 10.days,
                stages: %w[1-inbox 9-done], agent: "codex")
      ]
    }
  end

  def self.project(name, stage, slug, mtime, stages:, agent:)
    {
      "name" => name,
      "path" => "/tmp/#{name}",
      "hive_state_path" => "/tmp/#{name}/.hive-state",
      "workflows" => [
        {
          "id" => "coding",
          "dependency_gate_stage" => stages.last,
          "stages" => stages.each_with_index.map do |dir, index|
            { "name" => dir.split("-", 2).last, "dir" => dir, "index" => index + 1, "kind" => nil }
          end
        }
      ],
      "tasks" => [
        {
          "slug" => slug,
          "display_name" => slug.tr("-", " ").capitalize,
          "workflow" => "coding",
          "stage" => stage,
          "marker" => stage.end_with?("done") ? "complete" : "none",
          "action" => stage.end_with?("done") ? "archived" : "ready_to_run",
          "action_label" => stage.end_with?("done") ? "Archived" : "Ready to run",
          "dominant_state" => stage.end_with?("done") ? "idle" : "ready",
          "age_seconds" => (Time.now.utc - mtime).to_i,
          "mtime" => mtime.iso8601,
          "folder_mtime" => mtime.iso8601,
          "depends_on" => nil,
          "blocked_by" => nil,
          "implementation_identity" => {
            "stages" => { "execute" => { "provider" => agent, "model" => "test-model" } }
          },
          "operational_chips" => []
        }
      ]
    }
  end
end
