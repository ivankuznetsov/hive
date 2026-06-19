require "test_helper"
require "hive/stages/artifacts"
require "hive/task"

class StagesArtifactsPromptTest < Minitest::Test
  def test_render_prompt_includes_visual_capture_contract
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      prompt = Hive::Stages::Artifacts.render_prompt(task)

      assert_includes prompt, "Visual demo capture"
      assert_includes prompt, "media/manifest.json"
      assert_includes prompt, 'status: "skipped"'
      assert_includes prompt, 'status: "failed"'
      assert_includes prompt, "push_to_screenote"
      assert_includes prompt, "screenote_url"
      assert_includes prompt, "Completion — REQUIRED",
                      "the visual contract must not weaken the marker-driven completion guard"
    end
  end
end
