require_relative "../../test_helper"
require_relative "diff_walker"

class E2EDiffWalkerTest < Minitest::Test
  def test_renders_basic_errors
    text = Hive::E2E::DiffWalker.new.render([
      {
        "keywordLocation" => "/required",
        "instanceLocation" => "/projects/0",
        "error" => "missing key"
      }
    ])

    assert_includes text, "/projects/0"
    assert_includes text, "/required"
    assert_includes text, "missing key"
  end

  def test_renders_parse_error
    assert_equal "parse_error: bad json\n", Hive::E2E::DiffWalker.new.render([], parse_error: "bad json")
  end
end
