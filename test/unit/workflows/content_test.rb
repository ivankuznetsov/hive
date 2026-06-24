require "test_helper"
require "hive/workflow_selection"
require "hive/workflows/registry"

class WorkflowsContentTest < Minitest::Test
  def descriptor
    Hive::Workflows::Registry.fetch(:content)
  end

  def stages_by_name
    descriptor.stages.to_h { |stage| [ stage.name, stage ] }
  end

  def test_registry_exposes_content_workflow
    assert_same descriptor, Hive::Workflows::Registry.fetch(:content)
    assert_includes Hive::Workflows::Registry.ids, :content
    assert_includes Hive::WorkflowSelection.valid_names, "content"
  end

  def test_descriptor_has_content_id_and_ordered_stages
    assert_equal :content, descriptor.id
    assert_equal %w[inbox research outline draft critique done], descriptor.stage_names
    assert_equal %w[1-inbox 2-research 3-outline 4-draft 5-critique 6-done], descriptor.stage_dirs
    assert_equal (1..6).to_a, descriptor.stages.map(&:index)
    assert descriptor.stages.frozen?
  end

  def test_descriptor_uses_expected_state_files_and_stage_kinds
    expected = {
      "inbox" => [ "idea.md", :inert ],
      "research" => [ "research.md", :agent ],
      "outline" => [ "outline.md", :agent ],
      "draft" => [ "draft.md", :agent ],
      "critique" => [ "critique.md", :agent ],
      "done" => [ "article.md", :agent ]
    }

    expected.each do |name, (state_file, kind)|
      stage = stages_by_name.fetch(name)
      assert_equal state_file, stage.state_file
      assert_equal kind, stage.kind
    end
  end

  def test_descriptor_pins_agent_skills_budgets_timeouts_and_status_modes
    expected = {
      "research" => [ "/deep-research", 3.0, 1800 ],
      "outline" => [ "/seo:research", 0.75, 600 ],
      "draft" => [ "/write:writer", 1.5, 1200 ],
      "critique" => [ "/write:editor", 1.0, 900 ],
      "done" => [ "/write:writer", 1.0, 900 ]
    }

    expected.each do |name, (skill, budget_usd, timeout_sec)|
      stage = stages_by_name.fetch(name)
      assert_equal skill, stage.skill
      assert_equal budget_usd, stage.budget_usd
      assert_equal timeout_sec, stage.timeout_sec
      assert_equal :state_file_marker, stage.status_mode
    end

    inbox = stages_by_name.fetch("inbox")
    assert_nil inbox.skill
    assert_nil inbox.budget_usd
    assert_nil inbox.timeout_sec
    assert_nil inbox.status_mode
  end

  def test_descriptor_carries_transition_verbs_after_inbox
    assert_nil descriptor.stages.first.advance_verb
    assert_equal [ nil, "research", "outline", "draft", "critique", "done" ],
                 descriptor.stages.map { |stage| stage.advance_verb&.name }
  end

  def test_done_is_terminal_stage
    assert_equal "done", descriptor.stages.last.name
    assert_nil descriptor.next_stage_after("done")
  end
end
