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

      assert_includes prompt, "Capture requirement: not_applicable"
      assert_includes prompt, "media/capture-manifest.json"
      assert_includes prompt, "hive-artifact-capture"
      assert_match(/Do not call Screenote or any external upload tool/, prompt)
      refute_includes prompt, "create_screenshot_upload"
      assert_includes prompt, "Completion — REQUIRED",
                      "the visual contract must not weaken the marker-driven completion guard"
    end
  end

  def test_render_prompt_cannot_turn_connected_screenote_into_ambient_upload_authority
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = task_for(dir)

      prompt = Hive::Stages::Artifacts.render_prompt(
        task,
        screenote: {
          connected: true,
          project_id: "proj_123",
          base_url: "https://screenote.test",
          reason: nil
        }
      )

      assert_includes prompt, "Required media remains local"
      assert_match(/External publication\s+is a separate operator-confirmed action/, prompt)
      refute_includes prompt, "proj_123"
      refute_includes prompt, "https://screenote.test"
      refute_includes prompt, "signed upload URL"
    end
  end

  def test_render_prompt_does_not_leak_disconnected_screenote_configuration
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = task_for(dir)
      reason = "Screenote OAuth token expired; run `hive connect screenote`."

      prompt = Hive::Stages::Artifacts.render_prompt(
        task,
        screenote: {
          connected: false,
          project_id: nil,
          base_url: "https://screenote.test",
          reason: reason
        }
      )

      assert_includes prompt, "Required media remains local"
      refute_includes prompt, reason
      refute_includes prompt, "https://screenote.test"
    end
  end

  private

  def task_for(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end
end
