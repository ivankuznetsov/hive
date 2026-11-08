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

  def test_requested_honors_separate_boolean_values_and_last_option
    %w[--json --no-json --skip-json].each do |option|
      %w[true TRUE t T].each do |value|
        assert Hive::CliJsonOptions.requested?([ "status", option, value ])
      end
      %w[false FALSE f F].each do |value|
        refute Hive::CliJsonOptions.requested?([ "status", option, value ])
      end
    end
    assert Hive::CliJsonOptions.requested?(%w[status --json false --json])
    refute Hive::CliJsonOptions.requested?(%w[status --json --json false])
    refute Hive::CliJsonOptions.requested?(%w[status --no-json -- --json true])
    assert Hive::CliJsonOptions.requested?(%w[status --json=true false])
  end
end
