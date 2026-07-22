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
end
