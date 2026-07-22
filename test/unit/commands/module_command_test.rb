require "test_helper"
require "hive/commands/module"

class ModuleCommandTest < Minitest::Test
  def test_rejects_missing_unknown_and_extra_arguments
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new(nil, nil, project_root: Dir.pwd).call!
    end
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("unknown", nil, project_root: Dir.pwd).call!
    end
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("list", "extra", project_root: Dir.pwd).call!
    end
  end
end
