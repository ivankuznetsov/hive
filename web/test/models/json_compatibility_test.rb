require "test_helper"

class JsonCompatibilityTest < ActiveSupport::TestCase
  test "Active Support decodes JSON with json 3 keyword options" do
    assert_equal({ "provider" => "codex" }, ActiveSupport::JSON.decode('{"provider":"codex"}'))
  end
end
