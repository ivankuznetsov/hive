require "test_helper"
require "rbconfig"
require "hive/setup/qmd_probe"

class SetupQmdProbeTest < Minitest::Test
  def test_call_forwards_the_exact_version_probe
    argv = nil
    status = Object.new
    status.define_singleton_method(:success?) { true }

    result = Hive::Setup::QmdProbe.call("/managed/qmd", runner: lambda { |value|
      argv = value
      [ "qmd 2.0.0", "", status ]
    })

    assert_equal [ "/managed/qmd", "--version" ], argv
    assert_equal "qmd 2.0.0", result.fetch(0)
    assert result.fetch(2).success?
  end

  def test_diagnostic_redacts_controls_and_bounds_characters
    secret = [ "sk", "Q" * 24 ].join("-")
    detail = Hive::Setup::QmdProbe.diagnostic(
      "",
      "NODE_MODULE_VERSION mismatch #{secret}\u0000#{'x' * 1_500}"
    )

    assert_includes detail, "NODE_MODULE_VERSION mismatch"
    assert_includes detail, "[REDACTED:openai_api_key]"
    refute_includes detail, secret
    refute_includes detail, "\u0000"
    assert_operator detail.length, :<=, 1_000
  end

  def test_bounded_runner_terminates_a_hung_probe
    error = assert_raises(Hive::Error) do
      Hive::Setup::QmdProbe.capture3_bounded(
        [ RbConfig.ruby, "-e", "sleep 30" ],
        timeout_sec: 0.05
      )
    end

    assert_equal "hive setup: qmd startup probe timed out after 0.05s", error.message
  end
end
