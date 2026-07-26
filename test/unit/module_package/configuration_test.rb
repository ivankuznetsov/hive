require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/configuration"

class ModulePackageConfigurationTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  def test_requires_complete_setting_hook_and_grant_choices
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))

      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution, settings: {}, hooks: {}, grants: exact_grants(descriptor)
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution,
          settings: { "mode" => "safe", "api_token" => nil }, hooks: { "schedule" => false },
          grants: exact_grants(descriptor).merge("filesystem_read" => [])
        )
      end
    end
  end

  def test_builds_a_canonical_redacted_configuration
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution,
        settings: { "mode" => "fast", "api_token" => "DEMO_API_TOKEN" },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor)
      )

      assert_equal "DEMO_API_TOKEN", configuration.settings.fetch("api_token")
      refute_includes configuration.bytes, "super-secret-value"
      assert_match(/\A[0-9a-f]{64}\z/, configuration.digest)
      assert_equal configuration.digest, Hive::ModulePackage::Configuration.load(configuration.bytes).digest
    end
  end

  def test_each_expanded_high_risk_permission_requires_an_exact_grant
    with_tmp_dir do |root|
      permissions = {
        "repository_write" => true, "github_mutations" => [ "pull_requests" ],
        "external_commands" => [ "bin/test" ], "network_hosts" => [ "github.com" ],
        "filesystem_read" => [ "*" ], "filesystem_write" => [ "*" ], "secrets" => [ "GH_TOKEN" ]
      }
      resolution, descriptor = write_module_package(File.join(root, "package"), permissions: permissions)
      choices = { "mode" => "safe", "api_token" => nil }
      hooks = { "schedule" => false }

      Hive::ModulePackage::Manifest::PERMISSION_KEYS.each do |key|
        grants = exact_grants(descriptor)
        grants[key] = key == "repository_write" ? false : []
        assert_raises(Hive::ConfigError, key) do
          Hive::ModulePackage::Configuration.build(
            descriptor, generation: resolution, settings: choices, hooks: hooks, grants: grants
          )
        end
      end
    end
  end

  def test_load_and_generation_validation_reject_noncanonical_or_tampered_state
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      configuration = build_configuration(resolution, descriptor)

      noncanonical = JSON.generate(configuration.to_h)
      refute_equal configuration.bytes, noncanonical
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.load(noncanonical) }
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.load("{bad") }

      bad_generation = resolution.with(source_commit: "short")
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: bad_generation,
          settings: configuration.settings, hooks: configuration.hooks, grants: configuration.grants
        )
      end

      invalid_shape = configuration.to_h.merge("future" => true)
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.new(invalid_shape) }
      invalid_generation = deep_copy(configuration.to_h)
      invalid_generation["generation"]["version"] = "latest"
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.new(invalid_generation) }
      invalid_content = deep_copy(configuration.to_h)
      invalid_content["settings"] = []
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.new(invalid_content) }
      tampered = deep_copy(configuration.to_h)
      tampered["contract"]["hooks"] = []
      assert_raises(Hive::ConfigError) { Hive::ModulePackage::Configuration.new(tampered) }
    end
  end

  def test_setting_and_grant_normalization_rejects_unsupported_values
    normalize = ->(value, spec) do
      Hive::ModulePackage::Configuration.send(:normalize_setting, "choice", value, spec)
    end
    assert_equal 1.5, normalize.call(1.5, "type" => "number", "required" => true)
    assert_raises(Hive::ConfigError) do
      normalize.call(Float::INFINITY, "type" => "number", "required" => true)
    end
    assert_raises(Hive::ConfigError) do
      normalize.call("value", "type" => "future", "required" => true)
    end

    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      settings = { "mode" => "safe", "api_token" => nil }
      hooks = { "schedule" => false }
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution, settings: settings, hooks: hooks,
          grants: exact_grants(descriptor).merge("repository_write" => "yes")
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution, settings: settings, hooks: hooks,
          grants: exact_grants(descriptor).merge("network_hosts" => [ "one", "one" ])
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution, settings: settings, hooks: hooks,
          grants: exact_grants(descriptor).merge("repository_write" => true)
        )
      end
    end
  end

  private

  def build_configuration(resolution, descriptor)
    Hive::ModulePackage::Configuration.build(
      descriptor, generation: resolution,
      settings: { "mode" => "safe", "api_token" => nil },
      hooks: { "schedule" => false }, grants: exact_grants(descriptor)
    )
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
