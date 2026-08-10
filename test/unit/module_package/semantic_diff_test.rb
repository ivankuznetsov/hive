require "test_helper"
require "hive/module_package/semantic_diff"

class ModulePackageSemanticDiffTest < Minitest::Test
  def test_reports_permission_expansion_and_hook_changes
    old_data = {
      "hooks" => [ { "id" => "schedule", "events" => [], "schedules" => [ "0 * * * *" ] } ],
      "settings" => [],
      "permissions" => { "repository_write" => false, "github_mutations" => [], "network_hosts" => [] }
    }
    new_data = {
      "hooks" => [
        { "id" => "schedule", "events" => [], "schedules" => [ "0 */2 * * *" ] },
        { "id" => "merged", "events" => [ "pull_request.merged" ], "schedules" => [] }
      ],
      "settings" => [],
      "permissions" => { "repository_write" => true, "github_mutations" => [ "pull_requests" ], "network_hosts" => [ "github.com" ] }
    }

    diff = Hive::ModulePackage::SemanticDiff.compare(old_data, new_data)

    assert_equal [ "merged" ], diff.hooks.fetch("added")
    assert_equal [ "schedule" ], diff.hooks.fetch("changed")
    assert_includes diff.permission_expansions, "repository_write"
    assert_includes diff.permission_expansions, "github_mutations:pull_requests"
    assert diff.consent_required?
  end
end
