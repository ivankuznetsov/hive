require "test_helper"
require "json"
require "stringio"
require "hive/commands/doctor"

class HiveCommandsDoctorWebAliasTest < Minitest::Test
  def test_native_web_aliases_are_non_failing_warning_rows_in_human_and_json_output
    inspector = Object.new
    inspector.define_singleton_method(:inspect) { [] }
    environment = { "HIVEBOX_DIFF_TIMEOUT_SEC" => "20" }

    human = StringIO.new
    human_exit = Hive::Commands::Doctor.new(
      config: base_config,
      project_root: nil,
      output: human,
      inspector: inspector,
      environment: environment
    ).call
    assert_equal Hive::Commands::Doctor::EXIT_SUCCESS, human_exit
    assert_includes human.string, "HIVEBOX_DIFF_TIMEOUT_SEC"
    assert_includes human.string, "HIVE_WEB_DIFF_TIMEOUT_SEC"
    assert_includes human.string, "next major release"

    json = StringIO.new
    json_exit = Hive::Commands::Doctor.new(
      config: base_config,
      project_root: nil,
      json: true,
      output: json,
      inspector: inspector,
      environment: environment
    ).call
    payload = JSON.parse(json.string)
    warning = payload.fetch("checks").fetch(0)
    assert_equal Hive::Commands::Doctor::EXIT_SUCCESS, json_exit
    assert_equal "warning", warning.fetch("kind")
    assert_equal "HIVEBOX_DIFF_TIMEOUT_SEC", warning.fetch("alias")
    assert_equal "HIVE_WEB_DIFF_TIMEOUT_SEC", warning.fetch("replacement")
    assert_equal 1, payload.dig("summary", "warnings")
  end

  private

  def base_config
    {
      "claude" => { "mode" => "headless" },
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" }
    }
  end
end
