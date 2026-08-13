require "test_helper"
require "hive/cli_argv_policy"

class HiveCliArgvPolicyTest < Minitest::Test
  VALUE_OPTIONS = %w[--base --depends-on --workflow --idempotency-key].freeze

  def test_json_and_encoding_policy
    assert Hive::CliArgvPolicy.json_requested?(%w[status --json])
    refute Hive::CliArgvPolicy.json_requested?(%w[status --json --no-json])
    assert_equal %w[status --json=maybe],
                 Hive::CliArgvPolicy.reject_unsupported_json_assignments(
                   %w[status --json=maybe], before_index: 1
                 )

    error = assert_raises(Thor::MalformattedArgumentError) do
      Hive::CliArgvPolicy.reject_unsupported_json_assignments(%w[status --json=maybe])
    end
    assert_match(/invalid boolean value/, error.message)

    error = assert_raises(Thor::MalformattedArgumentError) do
      Hive::CliArgvPolicy.validate_encoding([ "status", "bad\xFF".b ])
    end
    assert_match(/argument 2/, error.message)
  end

  def test_normalizes_leading_json_for_general_and_e2e_routes
    assert_equal %w[status --json],
                 Hive::CliArgvPolicy.normalize_leading_json_options(%w[--json status])

    commands = %w[list run]
    options = { commands: commands, top_level_flags: %w[--help -h --version -v], help_flags: %w[--help -h] }
    assert_equal %w[--version],
                 Hive::CliArgvPolicy.normalize_leading_json_options(%w[--json --version], **options)
    assert_equal %w[--help run],
                 Hive::CliArgvPolicy.normalize_leading_json_options(%w[--json --help run], **options)
    assert_equal %w[--json --help missing],
                 Hive::CliArgvPolicy.normalize_leading_json_options(%w[--json --help missing], **options)
    assert_equal %w[run --json pattern],
                 Hive::CliArgvPolicy.normalize_leading_json_options(%w[--json run pattern], **options)
  end

  def test_help_rewrite_respects_new_text_boundary_and_e2e_fallback
    argv = %w[new demo explain --help literally]
    text_start = Hive::CliArgvPolicy.new_text_start_index(argv, value_options: VALUE_OPTIONS)
    assert_equal argv, Hive::CliArgvPolicy.rewrite_help(argv, text_start_index: text_start)

    assert_equal %w[help approve], Hive::CliArgvPolicy.rewrite_help(%w[approve task --help])
    assert_equal %w[help run], Hive::CliArgvPolicy.rewrite_help(
      %w[missing --help], known_commands: %w[list run], fallback_command: "run"
    )
  end

  def test_lifts_new_options_and_preserves_literal_tail
    argv = %w[new demo write it --workflow content --json]
    assert_equal %w[new --workflow content --json demo -- write it],
                 Hive::CliArgvPolicy.lift_new_options(argv, value_options: VALUE_OPTIONS)

    argv = %w[new demo write --workflow]
    assert_equal %w[new demo -- write --workflow],
                 Hive::CliArgvPolicy.lift_new_options(argv, value_options: VALUE_OPTIONS)
  end
end
