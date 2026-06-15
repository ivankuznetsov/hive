# frozen_string_literal: true

require "test_helper"
require "hive/stages/base"

# The hive runner detects tmux-stage completion ONLY from the terminal marker the
# agent writes into its state file (never from process exit). The agent-owned
# marker templates harden that contract by making the marker the unmissable final
# instruction. This pins that the marker is the literal last line of each of those
# templates, and that the runner-owned templates still forbid the agent from
# writing the marker (so the hardening did not bleed into them).
class TemplateMarkerLastLineTest < Minitest::Test
  include HiveTestHelper

  # Superset of every binding the four hardened templates reference; extra keys
  # are harmless, a missing one would raise NameError during render.
  BINDINGS = {
    project_name: "demo", worktree_path: "/wt", task_folder: "/tf",
    slug: "fix-thing-260601-aa11", branch: "fix-thing-260601-aa11",
    pr_url: "https://github.com/o/r/pull/7", user_supplied_tag: "user-data",
    plan_text: "PLAN", execute_output_text: "EXEC", reviews_summary: "REVIEWS",
    artifact_file: "artifact.md", brainstorm_text: "BRAINSTORM",
    skill_invocation: "/ce-plan", idea_text: "IDEA"
  }.freeze

  AGENT_OWNED_MARKER_TEMPLATES = {
    "open_pr_prompt.md.erb" => /\A<!-- COMPLETE pr_url=.* is_draft=true -->\z/,
    "artifacts_prompt.md.erb" => /\A<!-- COMPLETE -->\z/,
    "finalize_prompt.md.erb" => /\A<!-- COMPLETE pr_url=.* is_draft=false -->\z/,
    "plan_prompt.md.erb" => /\A<!-- COMPLETE -->\z/
  }.freeze

  def render_template(name)
    bindings = Hive::Stages::Base::TemplateBindings.new(BINDINGS)
    Hive::Stages::Base.render(name, bindings)
  end

  def last_nonblank_line(text)
    text.each_line.map(&:rstrip).reject(&:empty?).last.to_s.strip
  end

  def test_marker_is_the_last_line_of_every_agent_owned_template
    AGENT_OWNED_MARKER_TEMPLATES.each do |name, marker_re|
      last = last_nonblank_line(render_template(name))

      assert_match marker_re, last,
                   "#{name}: terminal marker must be the unmissable final line; got #{last.inspect}"
    end
  end

  def test_completion_section_is_explicitly_required_and_marker_driven
    AGENT_OWNED_MARKER_TEMPLATES.each_key do |name|
      rendered = render_template(name)

      assert_includes rendered, "Completion — REQUIRED",
                      "#{name}: must carry an explicit REQUIRED completion section"
      assert_match(/never from your process exiting/i, rendered,
                   "#{name}: must state completion is marker-driven, not exit-driven")
    end
  end

  # The hardening must NOT reach runner-owned stages, where the runner stamps the
  # marker and the agent is told not to.
  def test_runner_owned_templates_still_forbid_agent_marker_writes
    dir = File.expand_path("../../../templates", __dir__)
    review = File.read(File.join(dir, "review_prompt.md.erb"))
    execute = File.read(File.join(dir, "execute_prompt.md.erb"))

    assert_match(/must not write task\.md yourself/i, review)
    assert_match(/Do NOT update the task\.md marker yourself/i, execute)
    refute_match(/Completion — REQUIRED/, review,
                 "runner-owned review template must not get the agent-marker hardening")
    refute_match(/Completion — REQUIRED/, execute,
                 "runner-owned execute template must not get the agent-marker hardening")
  end
end
