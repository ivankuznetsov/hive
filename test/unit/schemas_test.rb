require "test_helper"

# Pin the closed-enum behaviour of Hive::Schemas::*Kind modules. The tests
# guard against drift in two ways:
#   1. The expected value count is locked — adding a new kind must update
#      this count deliberately, which surfaces in code review.
#   2. ALL is self-derived from the module's constants, so renaming a
#      constant without updating ALL is impossible.
#
# Producers (Hive::Commands::Run / Hive::Commands::Status) and their current
# schema files both
# reference these constants — a drift between any of those three surfaces
# fails this test or the schema-drift test in schema_files_test.rb.
class SchemasTest < Minitest::Test
  # The Schemas namespace must be owned by its dedicated file, not by the
  # root entrypoint. lib/hive.rb keeps only the require_relative so the
  # public constant path (Hive::Schemas) stays unchanged for every
  # `require "hive"` consumer.
  def test_schemas_namespace_is_owned_by_dedicated_file_not_root_entrypoint
    schemas_source = File.read(File.expand_path("../../lib/hive/schemas.rb", __dir__))
    root_source = File.read(File.expand_path("../../lib/hive.rb", __dir__))

    assert_includes schemas_source, "module Schemas",
                    "Hive::Schemas must be defined in lib/hive/schemas.rb"
    refute_includes root_source, "module Schemas",
                    "the lib/hive.rb root entrypoint must not own the schema namespace"
  end

  def test_requiring_hive_loads_the_schemas_namespace_from_its_own_file
    # test_helper already performed `require "hive"` for this process.
    assert defined?(Hive::Schemas::SCHEMA_VERSIONS),
           "require 'hive' must load Hive::Schemas"

    # The namespace must be served by its dedicated file, not re-opened
    # inside lib/hive.rb.
    loaded_schemas = $LOADED_FEATURES.grep(%r{/lib/hive/schemas\.rb$})
    assert_equal 1, loaded_schemas.length,
                 "lib/hive/schemas.rb must be loaded exactly once when hive is required"

    root_source = File.read(File.expand_path("../../lib/hive.rb", __dir__))
    assert_match(%r{require_relative "hive/schemas"}, root_source,
                 "lib/hive.rb must wire in the dedicated schemas file")
  end

  def test_schema_dir_resolves_to_the_published_schemas_directory
    # The move of the namespace out of lib/hive.rb must not shift the
    # published-schema root: schema_path feeds every producer and the
    # schema_files drift tests.
    expected = File.expand_path("schemas", File.expand_path("../..", __dir__))
    assert_equal expected, Hive::Schemas.schema_dir
    assert File.file?(Hive::Schemas.schema_path("hive-status")),
           "schema_path must resolve to a real published schema file"
  end

  def test_run_error_kind_all_contains_fifteen_values
    assert_equal 15, Hive::Schemas::RunErrorKind::ALL.length,
                 "RunErrorKind::ALL count is locked; adding a kind requires bumping this assertion deliberately"
  end

  def test_run_error_kind_all_values_match_known_kinds
    expected = %w[
      concurrent_run task_in_error plan_review_blocked wrong_stage stage config agent git
      worktree ambiguous_slug invalid_task_path internal error dependency_wait
      admission_error
    ].sort
    assert_equal expected, Hive::Schemas::RunErrorKind::ALL.sort
  end

  def test_run_error_kind_values_are_frozen_strings
    Hive::Schemas::RunErrorKind::ALL.each do |value|
      assert_kind_of String, value
      assert_predicate value, :frozen?, "RunErrorKind value #{value.inspect} must be frozen"
    end
  end

  def test_run_error_kind_all_is_self_derived_from_constants
    # Every constant in the module other than ALL itself must appear in ALL.
    declared = Hive::Schemas::RunErrorKind.constants.reject { |c| c == :ALL }
    declared_values = declared.map { |c| Hive::Schemas::RunErrorKind.const_get(c) }
    assert_equal declared_values.sort, Hive::Schemas::RunErrorKind::ALL.sort,
                 "RunErrorKind::ALL must be self-derived from the module's constants"
  end

  def test_status_error_kind_all_contains_three_values
    assert_equal 3, Hive::Schemas::StatusErrorKind::ALL.length,
                 "StatusErrorKind::ALL count is locked; adding a kind requires bumping this assertion deliberately"
  end

  def test_status_error_kind_all_values_match_known_kinds
    expected = %w[config internal error].sort
    assert_equal expected, Hive::Schemas::StatusErrorKind::ALL.sort
  end

  def test_status_error_kind_values_are_frozen_strings
    Hive::Schemas::StatusErrorKind::ALL.each do |value|
      assert_kind_of String, value
      assert_predicate value, :frozen?, "StatusErrorKind value #{value.inspect} must be frozen"
    end
  end

  def test_status_error_kind_all_is_self_derived_from_constants
    declared = Hive::Schemas::StatusErrorKind.constants.reject { |c| c == :ALL }
    declared_values = declared.map { |c| Hive::Schemas::StatusErrorKind.const_get(c) }
    assert_equal declared_values.sort, Hive::Schemas::StatusErrorKind::ALL.sort,
                 "StatusErrorKind::ALL must be self-derived from the module's constants"
  end
end
