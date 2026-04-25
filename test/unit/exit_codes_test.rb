require "test_helper"

# Pin the exit-code contract. Each Hive::Error subclass owns a stable code
# that automated callers depend on. Changing one of these values is a
# breaking change for the CLI contract.
class ExitCodesTest < Minitest::Test
  def test_exit_code_constants_are_stable
    assert_equal 0,  Hive::ExitCodes::SUCCESS
    assert_equal 1,  Hive::ExitCodes::GENERIC
    assert_equal 2,  Hive::ExitCodes::ALREADY_INITIALIZED
    assert_equal 3,  Hive::ExitCodes::TASK_IN_ERROR
    assert_equal 4,  Hive::ExitCodes::WRONG_STAGE
    assert_equal 64, Hive::ExitCodes::USAGE
    assert_equal 70, Hive::ExitCodes::SOFTWARE
    assert_equal 75, Hive::ExitCodes::TEMPFAIL
    assert_equal 78, Hive::ExitCodes::CONFIG
  end

  def test_error_subclasses_map_to_their_contract_code
    assert_equal Hive::ExitCodes::GENERIC,             Hive::Error.new("x").exit_code
    assert_equal Hive::ExitCodes::USAGE,               Hive::InvalidTaskPath.new("x").exit_code
    assert_equal Hive::ExitCodes::TEMPFAIL,            Hive::ConcurrentRunError.new("x").exit_code
    assert_equal Hive::ExitCodes::SOFTWARE,            Hive::GitError.new("x").exit_code
    assert_equal Hive::ExitCodes::SOFTWARE,            Hive::WorktreeError.new("x").exit_code
    assert_equal Hive::ExitCodes::SOFTWARE,            Hive::AgentError.new("x").exit_code
    assert_equal Hive::ExitCodes::CONFIG,              Hive::ConfigError.new("x").exit_code
    assert_equal Hive::ExitCodes::SOFTWARE,            Hive::StageError.new("x").exit_code
    assert_equal Hive::ExitCodes::TASK_IN_ERROR,       Hive::TaskInErrorState.new("x").exit_code
    assert_equal Hive::ExitCodes::WRONG_STAGE,         Hive::WrongStage.new("x").exit_code
    assert_equal Hive::ExitCodes::ALREADY_INITIALIZED, Hive::AlreadyInitialized.new("x").exit_code
  end

  # The `schema_version` emit sites in run.rb / status.rb call
  # SCHEMA_VERSIONS.fetch("hive-run") / .fetch("hive-status") with literal
  # strings. Pin both keys so a rename of either constant key without
  # updating the call sites fails at test time, not at runtime as a
  # cryptic KeyError out of a real `hive run`.
  def test_schema_versions_keys_match_emit_sites
    assert Hive::Schemas::SCHEMA_VERSIONS.key?("hive-status"),
           "Hive::Commands::Status emits payload['schema'] = 'hive-status' and fetches the version by that key"
    assert Hive::Schemas::SCHEMA_VERSIONS.key?("hive-run"),
           "Hive::Commands::Run emits payload['schema'] = 'hive-run' and fetches the version by that key"
  end
end
