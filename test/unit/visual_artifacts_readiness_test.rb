require "test_helper"
require "hive/visual_artifacts_readiness"

class VisualArtifactsReadinessTest < Minitest::Test
  include HiveTestHelper

  def with_fake_path(*names)
    with_tmp_dir do |dir|
      names.each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      yield dir
    end
  end

  def test_capture_tooling_status_reports_both_tools_present
    with_fake_path("ffmpeg", "asciinema") do |dir|
      status = Hive::VisualArtifactsReadiness.capture_tooling_status(path_env: dir)

      assert_equal true, status[:satisfied]
      assert_empty status[:missing]
      assert_equal File.join(dir, "ffmpeg"), status[:ffmpeg][:path]
      assert_equal true, status[:ffmpeg][:present]
      assert_equal File.join(dir, "asciinema"), status[:asciinema][:path]
      assert_equal true, status[:asciinema][:present]
    end
  end

  def test_capture_tooling_status_reports_only_missing_asciinema
    with_fake_path("ffmpeg") do |dir|
      status = Hive::VisualArtifactsReadiness.capture_tooling_status(path_env: dir)

      assert_equal false, status[:satisfied]
      assert_equal [ "asciinema" ], status[:missing]
      assert_equal File.join(dir, "ffmpeg"), status[:ffmpeg][:path]
      assert_equal true, status[:ffmpeg][:present]
      assert_nil status[:asciinema][:path]
      assert_equal false, status[:asciinema][:present]
    end
  end

  def test_capture_tooling_status_reports_neither_tool_present
    status = Hive::VisualArtifactsReadiness.capture_tooling_status(path_env: "")

    assert_equal false, status[:satisfied]
    assert_equal %w[ffmpeg asciinema], status[:missing]
    assert_equal false, status[:ffmpeg][:present]
    assert_nil status[:ffmpeg][:path]
    assert_equal false, status[:asciinema][:present]
    assert_nil status[:asciinema][:path]
  end

  def test_screenote_status_reports_connected_from_global_config
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          base_url: https://screenote.example
          api_token: secret
      YAML

      status = Hive::VisualArtifactsReadiness.screenote_status

      assert_equal true, status[:connected]
      assert_equal "https://screenote.example", status[:base_url]
      assert_nil status[:reason]
      assert_equal true, Hive::VisualArtifactsReadiness.screenote_connected?
    end
  end

  def test_screenote_status_reports_connected_from_env_overrides
    with_tmp_global_config do
      with_env("HIVE_SCREENOTE_BASE_URL" => "https://screenote.env",
               "HIVE_SCREENOTE_API_TOKEN" => "env-secret") do
        status = Hive::VisualArtifactsReadiness.screenote_status

        assert_equal true, status[:connected]
        assert_equal "https://screenote.env", status[:base_url]
      end
    end
  end

  def test_screenote_status_reports_not_connected_when_either_value_is_blank
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          base_url: https://screenote.example
          api_token: ""
      YAML

      status = Hive::VisualArtifactsReadiness.screenote_status

      assert_equal false, status[:connected]
      assert_match(/not both configured/, status[:reason])
      assert_equal false, Hive::VisualArtifactsReadiness.screenote_connected?
    end
  end

  def test_screenote_status_degrades_malformed_global_config_to_not_connected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote: enabled
      YAML

      status = Hive::VisualArtifactsReadiness.screenote_status

      assert_equal false, status[:connected]
      assert_match(/screenote.*must be a Hash/, status[:reason])
      assert_equal false, Hive::VisualArtifactsReadiness.screenote_connected?
    end
  end
end
