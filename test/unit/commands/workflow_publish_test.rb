require "test_helper"
require "hive/commands/workflow/publish"
require "hive/workflow_package/publisher"

class WorkflowPublishCommandTest < Minitest::Test
  Package = Hive::WorkflowPackage::Publisher::Package

  def test_reports_submission_as_pending_review_and_never_as_listed
    published = nil
    publisher = Object.new
    publisher.define_singleton_method(:package) do |destination:|
      Package.new(name: "demo", version: "1.2.3", root: destination,
                  manifest_digest: "a" * 64, warnings: [])
    end
    publisher.define_singleton_method(:publish) do |package|
      published = package
      "https://github.com/ivankuznetsov/honeycomb/pull/42"
    end
    stdout = StringIO.new
    payload = Hive::Commands::Workflow::Publish.new(
      "demo", project_root: Dir.pwd, version: "1.2.3", json: true,
      stdout: stdout, publisher: publisher
    ).call!

    assert_equal "pending_review", payload.fetch("status")
    assert_equal false, payload.fetch("listed")
    assert_equal "a" * 64, payload.fetch("manifest_digest")
    assert_equal "demo", published.name
    assert_equal payload, JSON.parse(stdout.string)
  end
end
