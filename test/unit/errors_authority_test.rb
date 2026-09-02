require "test_helper"

# Pin the ownership of the Hive error taxonomy. The concrete error classes
# (InvalidTaskPath, ConcurrentRunError, ProviderRouteFailed, …) must be owned
# by the dedicated clean-loadable errors boundary (lib/hive/errors.rb), not
# re-opened inside the lib/hive.rb root entrypoint. lib/hive.rb keeps only
# the require_relative so the public constant paths stay unchanged for every
# `require "hive"` consumer.
#
# This mirrors the Schemas ownership contract in schemas_test.rb: a dedicated
# file owns the namespace and the root entrypoint only wires it in.
class ErrorsAuthorityTest < Minitest::Test
  def test_error_taxonomy_is_owned_by_dedicated_file_not_root_entrypoint
    errors_source = File.read(File.expand_path("../../lib/hive/errors.rb", __dir__))
    root_source = File.read(File.expand_path("../../lib/hive.rb", __dir__))

    assert_includes errors_source, "class InvalidTaskPath < Error",
                    "the error taxonomy must be defined in lib/hive/errors.rb"
    refute_match(/class \w+\s*<\s*(Error|ConfigError|AgentError|GitError|WrongStage|InvalidTaskPath)/,
                 root_source,
                 "the lib/hive.rb root entrypoint must not own the error taxonomy")
  end

  def test_requiring_hive_loads_the_error_taxonomy_from_the_errors_file
    # test_helper already performed `require "hive"` for this process.
    assert defined?(Hive::InvalidTaskPath),
           "require 'hive' must load the concrete error taxonomy"
    assert defined?(Hive::ProviderRouteFailed),
           "require 'hive' must load the provider-routing error boundary"

    # The taxonomy must be served by its dedicated file, not re-opened
    # inside lib/hive.rb.
    loaded_errors = $LOADED_FEATURES.grep(%r{/lib/hive/errors\.rb$})
    assert_equal 1, loaded_errors.length,
                 "lib/hive/errors.rb must be loaded exactly once when hive is required"

    root_source = File.read(File.expand_path("../../lib/hive.rb", __dir__))
    assert_match(%r{require_relative "hive/errors"}, root_source,
                 "lib/hive.rb must wire in the dedicated errors file")
  end

  def test_moved_taxonomy_preserves_exit_code_contract_and_ancestry
    # The move must not shift behavior: exit-code overrides and inheritance
    # (IS-A for exit-code convenience) survive the relocation verbatim.
    assert_equal Hive::ExitCodes::USAGE, Hive::InvalidTaskPath.new("x").exit_code
    assert_equal Hive::ExitCodes::TEMPFAIL, Hive::ConcurrentRunError.new("x").exit_code
    assert_equal Hive::ExitCodes::TASK_IN_ERROR, Hive::TaskInErrorState.new("x").exit_code
    assert_operator Hive::ProviderRouteFailed.ancestors, :include?, Hive::AgentError
    assert_operator Hive::ConditionGateBlocked.ancestors, :include?, Hive::WrongStage
  end
end