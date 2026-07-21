require "test_helper"
require "hive/workflow_package/permission_projection"

class WorkflowPackagePermissionProjectionTest < Minitest::Test
  Projection = Hive::WorkflowPackage::PermissionProjection

  def test_projects_every_actor_into_one_exact_conservative_union
    descriptor = {
      "stages" => [
        { "kind" => "agent", "permissions" => "read-only" },
        {
          "kind" => "council",
          "permissions" => { "preset" => "scoped", "tools" => [ "Edit(../../../../docs)" ] },
          "reviewers" => [
            { "permissions" => { "preset" => "scoped", "tools" => [ "WebFetch" ] } }
          ]
        }
      ]
    }

    assert_equal({
      "risk" => "high",
      "capabilities" => %w[filesystem-read filesystem-write network],
      "network_hosts" => [ "*" ],
      "filesystem_read" => %w[repository task],
      "filesystem_write" => [ "repository/docs" ],
      "secrets" => []
    }, Projection.derive!(descriptor))
  end

  def test_yolo_dominates_all_bounded_sets
    permissions = Projection.derive!({
      "stages" => [ { "kind" => "agent", "permissions" => "yolo" } ]
    })

    assert_equal "high", permissions.fetch("risk")
    assert_equal Hive::WorkflowPackage::RegistryManifest::CAPABILITIES.sort,
                 permissions.fetch("capabilities")
    %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
      assert_equal [ "*" ], permissions.fetch(key)
    end
  end

  def test_missing_or_unenforced_permission_constructs_fail_closed
    [
      { "kind" => "agent" },
      { "kind" => "agent", "permissions" => { "preset" => "scoped", "tools" => [ "Write(path)" ] } },
      { "kind" => "agent", "permissions" => { "preset" => "future" } }
    ].each do |stage|
      assert_raises(Hive::ConfigError) do
        Projection.derive!({ "stages" => [ stage ] })
      end
    end
  end
end
