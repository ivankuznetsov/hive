require "test_helper"
require "hive/module_package/command_target"

class ModulePackageCommandTargetTest < Minitest::Test
  def test_parses_argv_without_a_shell_and_rejects_malformed_bounds
    assert_equal(
      [ "git", "commit", "-m", "safe message" ],
      Hive::ModulePackage::CommandTarget.argv("git commit -m 'safe message'")
    )

    malformed = [
      nil,
      "",
      "git\nstatus",
      "x" * (Hive::ModulePackage::CommandTarget::MAX_BYTES + 1),
      "git " + Array.new(
        Hive::ModulePackage::CommandTarget::MAX_ARGUMENTS, "x"
      ).join(" "),
      "git " + ("x" * (Hive::ModulePackage::CommandTarget::MAX_ARGUMENT_BYTES + 1)),
      "'unterminated"
    ]
    malformed.each do |value|
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::CommandTarget.argv(value)
      end
    end
  end
end
