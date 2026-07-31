require "test_helper"
require "hive/refactor_patrol/architecture_project_binding"

class RefactorPatrolArchitectureProjectBindingTest < Minitest::Test
  def test_source_identity_requires_an_exact_matching_pull_request_url
    assert_equal(
      {
        "host" => "github.example",
        "repository" => "Owner/Demo"
      },
      binding.source_identity!(source)
    )

    [
      source.merge(
        "url" => "ssh://github.example/Owner/Demo/pull/7"
      ),
      source.merge(
        "url" => "https://user@github.example/Owner/Demo/pull/7"
      ),
      source.merge(
        "url" => "https://github.example/Owner/Demo/pull/8"
      ),
      source.merge(
        "url" => "https://github.example/Other/Demo/pull/7"
      )
    ].each do |invalid|
      assert_raises(Hive::GhError) do
        binding.source_identity!(invalid)
      end
    end
  end

  def test_from_entry_returns_the_exact_registry_project_descriptor
    project = binding.from_entry!(entry: entry, source: source)

    assert_equal(
      {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "github.example/Owner/Demo"
      },
      project
    )

    case_variant = binding.from_entry!(
      entry: entry.merge(
        "repository_identity" => "GITHUB.EXAMPLE/owner/demo"
      ),
      source: source
    )
    assert_equal(
      "GITHUB.EXAMPLE/owner/demo",
      case_variant.fetch("repository")
    )
  end

  def test_from_entry_requires_strict_registry_fields_and_source_provenance
    {
      "project_id" => nil,
      "name" => "",
      "repository_identity" => 7
    }.each do |key, value|
      assert_raises(Hive::ConfigError) do
        binding.from_entry!(
          entry: entry.merge(key => value),
          source: source
        )
      end
    end

    assert_raises(Hive::ConfigError) do
      binding.from_entry!(
        entry: entry.merge("name" => "other"),
        source: source
      )
    end
    assert_raises(Hive::ConfigError) do
      binding.from_entry!(
        entry: entry.merge(
          "repository_identity" => "github.example/Other/Demo"
        ),
        source: source
      )
    end
  end

  def test_validate_accepts_only_a_full_project_descriptor
    project = {
      "project_id" => "project-1",
      "name" => "demo",
      "repository" => "github.example/Owner/Demo"
    }

    validated = binding.validate!(project: project, source: source)
    assert_equal project, validated
    assert_predicate validated, :frozen?
    assert validated.all? { |key, value| key.frozen? && value.frozen? }

    [
      project.reject { |key, _value| key == "project_id" },
      project.merge("extra" => "value"),
      project.merge("name" => "other"),
      project.merge("repository" => "github.example/Other/Demo")
    ].each do |invalid|
      assert_raises(Hive::ConfigError) do
        binding.validate!(project: invalid, source: source)
      end
    end
  end

  def test_assert_same_rejects_drift_in_every_canonical_project_field
    expected = binding.from_entry!(entry: entry, source: source)

    asserted = binding.assert_same!(
      expected: expected,
      observed: expected
    )
    assert_equal expected, asserted
    assert_predicate asserted, :frozen?

    {
      "project_id" => "project-2",
      "name" => "other",
      "repository" => "github.example/Owner/Other"
    }.each do |key, value|
      assert_raises(Hive::ConfigError) do
        binding.assert_same!(
          expected: expected,
          observed: expected.merge(key => value)
        )
      end
    end
  end

  private

  def binding
    Hive::RefactorPatrol::ArchitectureProjectBinding
  end

  def entry
    {
      "project_id" => "project-1",
      "name" => "demo",
      "repository_identity" => "github.example/Owner/Demo"
    }
  end

  def source
    {
      "url" => "https://github.example/Owner/Demo/pull/7",
      "number" => 7,
      "repository" => "Owner/Demo",
      "registration" => "demo"
    }
  end
end
