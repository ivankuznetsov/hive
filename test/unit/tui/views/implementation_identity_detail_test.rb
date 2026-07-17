require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/implementation_identity_detail"

class ImplementationIdentityDetailViewTest < Minitest::Test
  def test_renders_four_stage_provenance_and_unsupported_effort_honestly
    identity = {
      "generation" => 3,
      "pending" => false,
      "stages" => {
        "execute" => stage("pi", "anthropic/claude-sonnet", nil, true, "persisted_execute", "resolved"),
        "open_pr" => stage("pi", "anthropic/claude-sonnet", "medium", false,
                           "persisted_execute", "preview"),
        "review.fix" => stage("pi", "anthropic/claude-sonnet", "high", false,
                              "persisted_execute", "preview"),
        "review.ci" => stage("pi", "anthropic/claude-sonnet", "high", false,
                             "explicit_override", "resolved")
      }
    }
    row = Hive::Tui::Snapshot.from_payload(payload(identity)).rows.first
    state = Hive::Tui::Model::ImplementationIdentityDetailState.new(row: row)
    model = Hive::Tui::Model.initial(cols: 120, rows: 30).with(
      mode: :implementation_identity_detail,
      implementation_identity_detail_state: state
    )

    output = Hive::Tui::Views::ImplementationIdentityDetail.render(model)

    assert_includes output, "Generation: 3"
    %w[execute open_pr review.fix review.ci].each { |stage_name| assert_includes output, stage_name }
    assert_includes output, "medium (requested, not applied)"
    assert_includes output, "explicit_override"
  end

  def test_renders_pending_execute_without_inventing_owner
    row = Hive::Tui::Snapshot.from_payload(
      payload("generation" => 0, "pending" => true, "stages" => {})
    ).rows.first
    model = Hive::Tui::Model.initial.with(
      mode: :implementation_identity_detail,
      implementation_identity_detail_state:
        Hive::Tui::Model::ImplementationIdentityDetailState.new(row: row)
    )

    output = Hive::Tui::Views::ImplementationIdentityDetail.render(model)

    assert_includes output, "Execute ownership is pending"
    refute_includes output, "claude/"
  end

  private

  def stage(provider, model, effort, supported, source, status)
    {
      "provider" => provider, "model" => model,
      "requested_effort" => effort,
      "effective_effort" => supported ? effort : nil,
      "effort_supported" => supported, "source" => source,
      "originating_attempt" => "attempt", "resolved_attempt" => nil,
      "status" => status
    }
  end

  def payload(identity)
    {
      "projects" => [
        {
          "name" => "demo",
          "tasks" => [
            {
              "stage" => "6-review", "slug" => "owned-task",
              "folder" => "/tmp/owned-task", "state_file" => "/tmp/owned-task/task.md",
              "marker" => "review_working", "attrs" => {}, "mtime" => Time.now.iso8601,
              "age_seconds" => 0, "action" => "agent_running", "action_label" => "Agent running",
              "implementation_identity" => identity
            }
          ]
        }
      ]
    }
  end
end
