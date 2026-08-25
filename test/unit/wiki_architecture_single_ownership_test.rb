require "test_helper"

# Architecture patrol thesis: one documented decision has exactly one owner
# page. The overview (wiki/architecture.md) keeps only layer/boundary
# relationships plus cross-links and defers subsystem detail to the owning
# module pages.
class WikiArchitectureSingleOwnershipTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_workspace_boundary_guarantees_are_owned_by_the_module_page
    refute_match(/scan the attempt store or project fleet/, architecture,
      "architecture.md re-states the workspace projection's negative " \
      "guarantees instead of deferring to [[modules/task_workspace]]")
    refute_match(/does not enter `Commands::Status`/, architecture,
      "architecture.md duplicates the workspace guarantee list")

    owner = owner_page("task_workspace")
    assert_includes owner, "`Commands::Status`",
      "guarantee moved out of the overview must live on the owner page"
    assert_match(/owns no\n?mutation/, owner,
      "the no-mutation guarantee must live on the owner page")
    assert_includes owner, "global\nattempt store",
      "the attempt-store scan exclusion must live on the owner page"
  end

  def test_overview_still_carries_the_workspace_relationship_and_cross_link
    assert_includes architecture, "`Hive::TaskWorkspace::Builder`"
    assert_includes architecture, "[[modules/task_workspace]]"
  end

  def test_admission_narrative_appears_exactly_once_in_the_overview
    refute_includes architecture, "## Dispatch flow",
      "the duplicated admission narrative section must stay collapsed"
    assert_equal 1, architecture.scan("Attempts::Dispatcher").size
    assert_equal 1, architecture.scan("generation lock + lease").size
    assert_equal 1, architecture.scan("internal Hive worker").size
    assert_includes architecture, "[[modules/attempts]]"
    assert_includes architecture, "[[modules/daemon]]"
  end

  def test_admission_facts_relocated_from_the_overview_live_on_owner_pages
    attempts = owner_page("attempts")
    assert_match(/never\nprojects a recovery marker/, attempts)
    assert_match(/without adding an event bus/, attempts)
    assert_match(/does not own or reap/, attempts)

    daemon = owner_page("daemon")
    assert_match(/never adopted with `wait2`/, daemon)
  end

  def test_cross_references_point_at_the_collapsed_heading
    %w[daemon bot].each do |page|
      text = owner_page(page)
      assert_match(/\[\[architecture\]\]\s*§"Process model"/, text,
        "wiki/modules/#{page}.md must reference the collapsed heading")
      refute_match(/§"Dispatch flow"/, text)
    end
  end

  private

  def architecture
    @architecture ||= File.read(File.join(ROOT, "wiki/architecture.md"))
  end

  def owner_page(name)
    File.read(File.join(ROOT, "wiki/modules/#{name}.md"))
  end
end
