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
      assert_includes prompt, "screenote_url"
      assert_includes prompt, "screenote_skipped_reason"
      refute_includes prompt, "push_to_" + "screenote"
      assert_includes prompt, "Completion — REQUIRED",
                      "the visual contract must not weaken the marker-driven completion guard"
    end
  end

  def test_render_prompt_includes_connected_screenote_mcp_upload_contract
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

      assert_includes prompt, "- connected via MCP"
      assert_includes prompt, "default project_id: proj_123"
      assert_includes prompt, "`create_screenshot_upload`"
      assert_includes prompt, 'project_id: "proj_123"'
      assert_includes prompt, "signed upload URL"
      assert_includes prompt, "`screenote_url`"
      assert_includes prompt, "`screenote_skipped_reason`"
    end
  end

  def test_render_prompt_includes_disconnected_screenote_skip_contract
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

      assert_includes prompt, "- not connected: #{reason}"
      assert_includes prompt, "Screenote upload is unavailable: #{reason}"
      assert_includes prompt, "Still capture and commit local media."
      assert_includes prompt, "Leave every `screenote_url` as `null`"
      assert_includes prompt, "`screenote_skipped_reason`"
    end
  end

  private

  def task_for(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end
end
