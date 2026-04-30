require_relative "../../test_helper"
require_relative "scenario_parser"

class E2EScenarioParserTest < Minitest::Test
  def test_template_parses
    scenario = Hive::E2E::ScenarioParser.parse(File.expand_path("../scenarios/_template.yml", __dir__))

    assert_equal "template", scenario.name
    assert scenario.steps.any? { |step| step.kind == "ruby_block" }
  end

  def test_unknown_step_kind_reports_line
    Dir.mktmpdir("scenario") do |dir|
      path = File.join(dir, "bad.yml")
      File.write(path, <<~YAML)
        name: bad
        steps:
          - kind: nope
      YAML

      error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
        Hive::E2E::ScenarioParser.parse(path)
      end
      assert_includes error.message, "unknown step kind"
      assert_operator error.line, :>, 0
    end
  end
end
