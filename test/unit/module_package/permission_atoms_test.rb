require "test_helper"
require "hive/module_package/permission_atoms"

class ModulePackagePermissionAtomsTest < Minitest::Test
  def test_expands_each_permission_value_into_one_canonical_atom
    permissions = {
      "repository_write" => true,
      "github_mutations" => %w[pull_requests issues],
      "external_commands" => [],
      "network_hosts" => [ "api.example.test" ],
      "filesystem_read" => [ "repository" ],
      "filesystem_write" => [],
      "secrets" => [ "MODULE_TOKEN" ]
    }

    atoms = Hive::ModulePackage::PermissionAtoms.expand(permissions)

    assert_equal(
      [
        { "category" => "repository_write", "value" => true },
        { "category" => "github_mutations", "value" => "issues" },
        { "category" => "github_mutations", "value" => "pull_requests" },
        { "category" => "network_hosts", "value" => "api.example.test" },
        { "category" => "filesystem_read", "value" => "repository" },
        { "category" => "secrets", "value" => "MODULE_TOKEN" }
      ],
      atoms
    )
    assert_predicate atoms, :frozen?
    assert atoms.all?(&:frozen?)
  end

  def test_omits_false_and_empty_permissions_and_rejects_noncanonical_input
    empty = Hive::ModulePackage::Manifest::PERMISSION_KEYS.to_h do |category|
      [ category, category == "repository_write" ? false : [] ]
    end
    assert_empty Hive::ModulePackage::PermissionAtoms.expand(empty)

    assert_raises(Hive::ConfigError) do
      Hive::ModulePackage::PermissionAtoms.expand(empty.except("secrets"))
    end
    assert_raises(Hive::ConfigError) do
      Hive::ModulePackage::PermissionAtoms.expand(
        empty.merge("github_mutations" => [ "issues", "issues" ])
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::ModulePackage::PermissionAtoms.expand(
        empty.merge("repository_write" => "yes")
      )
    end
  end
end
