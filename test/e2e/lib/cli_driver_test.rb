require_relative "../../test_helper"
require_relative "cli_driver"

class E2ECliDriverTest < Minitest::Test
  def test_calls_real_bin_hive_and_captures_output
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        driver = Hive::E2E::CliDriver.new(sandbox, home)

        result = driver.call([ "version" ], cwd: sandbox)

        assert_equal 0, result.exit_code
        assert_equal "#{Hive::VERSION}\n", result.stdout
      end
    end
  end

  def test_exit_mismatch_carries_stdout_and_stderr
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        driver = Hive::E2E::CliDriver.new(sandbox, home)

        error = assert_raises(Hive::E2E::CliDriver::ExitMismatchError) do
          driver.call([ "help" ], expect_exit: 7, cwd: sandbox)
        end
        assert_equal 7, error.expected
        assert_equal 0, error.actual
        assert_includes error.stdout, "Commands:"
      end
    end
  end
end
