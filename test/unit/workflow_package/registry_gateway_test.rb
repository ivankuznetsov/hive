require "test_helper"
require "hive/workflow_package/registry_gateway"

class WorkflowPackageRegistryGatewayTest < Minitest::Test
  Status = Data.define(:success?)

  def test_verifies_fork_parent_and_owner_from_current_github_evidence
    calls = []
    runner = lambda do |args, chdir:|
      calls << [ args, chdir ]
      body = JSON.generate(
        "nameWithOwner" => "alice/honeycomb",
        "parent" => { "nameWithOwner" => "ivankuznetsov/honeycomb" }
      )
      [ body, "", Status.new(success?: true) ]
    end
    gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)

    assert gateway.verify_fork!(
      "alice/honeycomb", parent: "ivankuznetsov/honeycomb", owner: "alice"
    )
    assert_equal(
      [ "gh", "repo", "view", "alice/honeycomb", "--json", "nameWithOwner,parent" ],
      calls.first.first
    )
    assert_raises(Hive::WorkflowPackage::PublishConflict) do
      gateway.verify_fork!(
        "alice/honeycomb", parent: "other/registry", owner: "alice"
      )
    end
  end

  def test_pull_request_and_commit_parent_are_observed_separately
    runner = lambda do |args, chdir:|
      raise "unexpected chdir" unless chdir.nil?
      body =
        if args.include?("repos/alice/honeycomb/git/commits/#{'a' * 40}")
          JSON.generate("parents" => [ { "sha" => "b" * 40 } ])
        else
          JSON.generate([ {
            "number" => 7,
            "url" => "https://github.com/ivankuznetsov/honeycomb/pull/7",
            "state" => "OPEN", "isDraft" => false, "mergedAt" => nil,
            "headRepository" => { "nameWithOwner" => "alice/honeycomb" },
            "headRefName" => "contribution/demo", "headRefOid" => "a" * 40,
            "baseRefName" => "main", "body" => "metadata"
          } ])
        end
      [ body, "", Status.new(success?: true) ]
    end

    gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)
    pr = gateway.pull_requests("ivankuznetsov/honeycomb").fetch(0)

    assert_equal "contribution/demo", pr.head_branch
    refute pr.draft
    assert_equal "b" * 40, gateway.commit_parent_oid(pr.head_repository, pr.head_oid)
  end
end
