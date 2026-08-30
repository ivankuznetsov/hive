require "test_helper"
require "hive/proposals/context_selector"
require "hive/context_provenance"
require_relative "../../support/proposal_query_fixture"

class ProposalContextSelectorTest < Minitest::Test
  include HiveTestHelper
  include ProposalQueryFixture

  Context = Struct.new(:proposal_binding, keyword_init: true)
  PromptContext = Struct.new(
    :proposal_binding, :project, :task_slug, :attempt_id, :intended_stage,
    :task_generation, :ownership_generation, keyword_init: true
  )
  PromptTask = Struct.new(:project_root, :folder, :slug, :id, keyword_init: true)

  def setup
    setup_proposal_query_fixture
  end

  def test_selects_closed_typed_terminal_facts_without_free_form_or_restricted_content
    selection = selector.select(
      context: context(@rejected), max_items: 20, max_bytes: 2_048,
      remaining_bytes: 2_048
    )

    refute selection.empty?
    assert_equal [ @rejected, @draft ].intersection(selection.selected_ids), selection.selected_ids
    assert_includes selection.text, '"status":"rejected"'
    assert_includes selection.text, '"recall":0.91'
    refute_includes selection.text, "Untrusted change"
    refute_includes selection.text, "Never include this instruction"
    refute_includes selection.text, "secret"
    refute_includes selection.text, "Threshold exceeded"
    assert_equal "none", selection.items.first.fetch("retention_enforcement")
  end

  def test_shared_budget_truncates_whole_items_and_records_provenance
    selection = selector.select(
      context: context(@rejected), max_items: 20, max_bytes: 2_048,
      remaining_bytes: Hive::Proposals::ContextSelector::HEADER.bytesize + 10
    )

    assert selection.empty?
    assert selection.truncated
    assert_equal "budget_exhausted", selection.reason
    assert_equal Hive::Proposals::ContextSelector::HEADER.bytesize + 10,
                 selection.provenance.fetch("effective_budget")
    assert_empty selection.selected_ids
    assert_equal "", selection.text
  end

  def test_absent_malformed_and_stale_durable_bindings_fail_closed
    unbound = selector.select(context: Context.new, max_items: 2, max_bytes: 100, remaining_bytes: 100)
    assert unbound.empty?
    assert_equal "unbound", unbound.reason

    malformed = Context.new(proposal_binding: { "subject" => { "kind" => "workflow" } })
    assert_equal "unbound", selector.select(
      context: malformed, max_items: 2, max_bytes: 100, remaining_bytes: 100
    ).reason

    stale = context(proposal_id(99))
    result = selector.select(context: stale, max_items: 2, max_bytes: 100, remaining_bytes: 100)
    assert result.empty?
    assert_equal "stale_binding", result.reason
  end

  def test_prompt_composition_preserves_receipt_appendix_and_shared_byte_cap
    with_tmp_dir do |project|
      state_root = File.join(project, ".hive-state", "proposals", "v1")
      FileUtils.mkdir_p(File.join(project, ".hive-state", "stages", "4-execute", "task"))
      @root = state_root
      @store = Hive::Proposals::Store.new(root: state_root)
      @draft = proposal_id(1)
      @rejected = proposal_id(2)
      create_record(@draft, revision: "v1")
      create_record(@rejected, revision: "v2", retries: @draft)
      append_evaluation(@rejected, 1, "fail", "cost", 1.4)
      append_rejection(@rejected, 2)
      task = PromptTask.new(
        project_root: project,
        folder: File.join(project, ".hive-state", "stages", "4-execute", "task"),
        slug: "task", id: 1
      )
      prompt_context = PromptContext.new(
        proposal_binding: context(@rejected).proposal_binding,
        project: "", task_slug: "task", attempt_id: "attempt-1",
        intended_stage: "4-execute", task_generation: 1, ownership_generation: "owner"
      )
      decorated = Hive::ContextProvenance.decorate_prompt(
        task:, prompt: "contract", context: prompt_context
      )
      appendix = decorated.delete_prefix("contract\n\n")

      assert_operator appendix.bytesize, :<=, Hive::ContextProvenance::MAX_PROMPT_APPENDIX_BYTES
      assert_includes appendix, "Optional context provenance receipt"
      assert_includes appendix, "Retained proposal facts"
      refute_includes appendix, "Threshold exceeded"

      oversized_receipt = "r" * (Hive::ContextProvenance::MAX_PROMPT_APPENDIX_BYTES - 8)
      with_replaced_singleton_method(
        Hive::ContextProvenance, :prompt_appendix, ->(_task, _context) { oversized_receipt }
      ) do
        capped = Hive::ContextProvenance.decorate_prompt(
          task:, prompt: "contract", context: prompt_context
        )
        assert_equal "contract\n\n#{oversized_receipt}", capped
      end
    end
  end

  private

  def selector
    Hive::Proposals::ContextSelector.new(query: @query)
  end

  def context(id)
    Context.new(
      proposal_binding: {
        "schema_version" => 1,
        "subject" => {
          "kind" => "workflow", "reference" => "coding", "revision" => "v2",
          "proposal_id" => id
        }
      }
    )
  end
end
