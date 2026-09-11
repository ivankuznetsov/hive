require "test_helper"
require "hive/stages/brainstorm"

class HiveBrainstormSuggestionsPromptContractTest < Minitest::Test
  Task = Data.define(:folder, :project_root) do
    def state_file = File.join(folder, "brainstorm.md")
  end
  Profile = Data.define(:name) do
    def format_skill_invocation(skill) = skill
  end

  def test_first_pass_prompt_declares_suggestion_envelopes_inert
    prompt = File.read(File.expand_path("../../../templates/brainstorm_prompt.md.erb", __dir__))

    assert_includes prompt, "hive-suggestion:v1"
    assert_includes prompt, "never a filled answer"
    assert_includes prompt, "must not cause `## Requirements`"
    assert_includes prompt, "must not cause `<!-- COMPLETE -->`"
    assert_includes prompt, "do not discover or invoke a skill"
    assert_includes prompt, "must write that terminal marker"
  end

  def test_unanswered_round_renders_a_skill_free_preservation_only_prompt
    Dir.mktmpdir do |root|
      task = Task.new(folder: root, project_root: root)
      File.write(File.join(root, "idea.md"), "Choose an adapter.\n")
      File.write(
        File.join(root, "brainstorm.md"),
        "## Round 1\n### Q1. Which adapter?\n### A1.\n" \
        "<!-- hive-suggestion:v1 binding=#{"d" * 64} -->\nCandidate\n" \
        "<!-- /hive-suggestion:v1 -->\n<!-- WAITING -->\n"
      )

      prompt = Hive::Stages::Brainstorm.render_prompt(
        task,
        { "brainstorm" => { "skill" => "/ce-brainstorm" } },
        profile: Profile.new(name: :fixture)
      )

      assert_includes prompt, "PRESERVATION MODE"
      refute_includes prompt, "/ce-brainstorm"
      assert_includes prompt, "inspect `brainstorm.md` first"
    end
  end

  def test_codex_preservation_prompt_requires_complete_shell_commands
    Dir.mktmpdir do |root|
      task = Task.new(folder: root, project_root: root)
      File.write(File.join(root, "idea.md"), "Choose an adapter.\n")
      File.write(
        File.join(root, "brainstorm.md"),
        "## Round 1\n### Q1. Which adapter?\n### A1.\n" \
        "<!-- hive-suggestion:v1 binding=#{"d" * 64} -->\nCandidate\n" \
        "<!-- /hive-suggestion:v1 -->\n<!-- WAITING -->\n"
      )

      prompt = Hive::Stages::Brainstorm.render_prompt(
        task,
        { "brainstorm" => { "skill" => "/ce-brainstorm" } },
        profile: Profile.new(name: :codex)
      )

      assert_includes prompt, "complete shell command"
      assert_includes prompt, "sed -n '1,240p' brainstorm.md"
      assert_includes prompt, "Do not submit bare Ruby or Python"
      assert_includes prompt, "source as a command"
    end
  end

  def test_answered_round_keeps_the_interview_skill_instruction
    Dir.mktmpdir do |root|
      task = Task.new(folder: root, project_root: root)
      File.write(File.join(root, "idea.md"), "Choose an adapter.\n")
      File.write(
        File.join(root, "brainstorm.md"),
        "## Round 1\n### Q1. Which adapter?\n### A1.\nOperator answer\n<!-- WAITING -->\n"
      )

      prompt = Hive::Stages::Brainstorm.render_prompt(
        task,
        { "brainstorm" => { "skill" => "/ce-brainstorm" } },
        profile: Profile.new(name: :fixture)
      )

      refute_includes prompt, "PRESERVATION MODE"
      assert_includes prompt, "/ce-brainstorm"
    end
  end
end
