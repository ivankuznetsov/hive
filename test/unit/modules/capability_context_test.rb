require "test_helper"
require "hive/modules/capability_context"

class ModulesCapabilityContextTest < Minitest::Test
  def test_enforces_each_grant_category_without_first_party_exemptions
    context = Hive::Modules::CapabilityContext.new(
      "repository_write" => true,
      "github_mutations" => [ "pull_requests" ], "external_commands" => [ "git" ],
      "network_hosts" => [ "api.github.com" ], "filesystem_read" => [ "repository" ],
      "filesystem_write" => [ ".hive-state/patrol/**" ], "secrets" => [ "PATROL_TOKEN" ]
    )

    assert context.require_repository_write!
    assert context.require_github_mutation!("pull_requests")
    assert context.require_external_command!([ "/usr/bin/git", "status" ])
    assert context.require_network_host!("https://api.github.com/repos")
    assert context.require_filesystem_read!("lib/hive.rb")
    assert context.require_filesystem_write!(".hive-state/patrol/**")
    assert context.require_secret!("PATROL_TOKEN")
    assert_raises(Hive::Modules::CapabilityDenied) { context.require_github_mutation!("issues") }
    assert_raises(Hive::Modules::CapabilityDenied) { context.require_external_command!("bash") }
    assert_raises(Hive::Modules::CapabilityDenied) { context.require_network_host!("example.com") }
    assert_raises(Hive::Modules::CapabilityDenied) { context.require_secret!("OTHER_TOKEN") }
    assert_raises(Hive::Modules::CapabilityDenied) do
      context.require_filesystem_read!("/etc/passwd")
    end
    assert_raises(Hive::Modules::CapabilityDenied) do
      context.require_filesystem_read!("../another-project/secret")
    end
  end

  def test_wildcards_are_explicit_and_malformed_snapshots_fail_closed
    grants = {
      "repository_write" => false, "github_mutations" => [ "*" ], "external_commands" => [ "*" ],
      "network_hosts" => [ "*" ], "filesystem_read" => [ "*" ], "filesystem_write" => [ "*" ],
      "secrets" => [ "*" ]
    }
    context = Hive::Modules::CapabilityContext.new(grants)
    assert context.require_external_command!("anything")
    assert context.require_filesystem_write!("any/path")
    assert_raises(Hive::Modules::CapabilityDenied) { context.require_repository_write! }
    assert_raises(Hive::Modules::CapabilityDenied) do
      Hive::Modules::CapabilityContext.new(grants.reject { |key, _value| key == "network_hosts" })
    end
    assert_raises(Hive::Modules::CapabilityDenied) do
      Hive::Modules::CapabilityContext.new(grants.merge("network_hosts" => [ "*", "api.github.com" ]))
    end
    assert_raises(Hive::Modules::CapabilityDenied) do
      Hive::Modules::CapabilityContext.new(grants.merge("network_hosts" => [ "api.github.com", "api.github.com" ]))
    end
    assert_equal "http://[", context.send(:normalized_host, "http://[")
  end
end
