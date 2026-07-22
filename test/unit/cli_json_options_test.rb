require "test_helper"
require "hive/cli_json_options"

class CliJsonOptionsTest < Minitest::Test
  def test_requested_uses_last_boolean_before_delimiter
    assert Hive::CliJsonOptions.requested?(%w[run --no-json --json])
    refute Hive::CliJsonOptions.requested?(%w[run --json --no-json])
    refute Hive::CliJsonOptions.requested?(%w[run -- --json])
  end

  def test_unsupported_assignment_respects_command_text_boundary
    argv = %w[new demo --json=maybe]

    assert_equal "--json=maybe", Hive::CliJsonOptions.unsupported_assignment(argv)
    assert_nil Hive::CliJsonOptions.unsupported_assignment(argv, before_index: 2)
  end
end
