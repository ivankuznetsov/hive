require "test_helper"
require "hive/refactor_patrol/github_gateway"

class RefactorPatrolGithubGatewayTest < Minitest::Test
  class FakeTransport
    attr_reader :commands

    def initialize(pr:, pages:)
      @pr = pr
      @pages = pages
      @commands = []
    end

    def repository_identity(*) = { "repository" => "acme/demo", "host" => "github.com" }
    def ensure_authenticated!(*) = true

    def capture3(*command, **options)
      commands << [ command, options ]
      body = command[1] == "pr" ? JSON.generate(@pr) : JSON.generate(@pages)
      [ body, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
  end

  def test_merged_pr_details_retains_classifier_metadata_and_path_inventory_without_patches
    transport = FakeTransport.new(
      pr: pr_document,
      pages: [ [
        { "filename" => "lib/new.rb", "status" => "modified", "patch" => "@@ -1 +1 @@\n-old\n+new" },
        { "filename" => "app/logo.png", "status" => "modified", "patch" => nil }
      ] ]
    )

    details = Hive::RefactorPatrol::GithubGateway.new(transport: transport)
      .merged_pr_details(17, worktree_path: "/repo")

    assert_equal "Add a feature", details.fetch("title")
    assert_equal "feature body", details.fetch("body")
    assert_equal %w[architecture feature], details.fetch("labels")
    assert_equal "dev", details.fetch("author")
    assert_equal(
      [
        { "path" => "lib/new.rb", "status" => "modified" },
        { "path" => "app/logo.png", "status" => "modified" }
      ],
      details.fetch("files")
    )
    fields = transport.commands.first.first.fetch(transport.commands.first.first.index("--json") + 1)
    %w[title body labels author].each { |field| assert_includes fields.split(","), field }
  end

  def test_merged_pr_details_fails_closed_when_metadata_bounds_are_exceeded
    oversized = pr_document.merge("body" => "x" * (32 * 1024 + 1))
    gateway = Hive::RefactorPatrol::GithubGateway.new(
      transport: FakeTransport.new(pr: oversized, pages: [ [] ])
    )
    assert_raises(Hive::GhError) { gateway.merged_pr_details(17, worktree_path: "/repo") }
  end

  def test_missing_classifier_metadata_reaches_the_durable_blocking_gate
    transport = FakeTransport.new(
      pr: pr_document.merge("title" => nil, "author" => nil),
      pages: [ [
        { "filename" => "lib/new.rb", "status" => "modified", "patch" => "@@" },
        { "filename" => "app/logo.png", "status" => "modified", "patch" => nil }
      ] ]
    )

    details = Hive::RefactorPatrol::GithubGateway.new(transport: transport)
      .merged_pr_details(17, worktree_path: "/repo")

    assert_equal "", details.fetch("title")
    assert_equal "", details.fetch("author")
  end

  def test_merged_pr_details_rejects_nested_inventory_gaps_and_detects_both_markers
    invalid = [
      [ pr_document.merge("labels" => nil), [ [] ] ],
      [ pr_document.merge("labels" => [ "feature" ]), [ [] ] ],
      [ pr_document.merge("changedFiles" => 0), [ [] ] ],
      [ pr_document, [ [ { "filename" => "lib/only.rb", "status" => "modified", "patch" => "" } ] ] ]
    ]
    invalid.each do |document, pages|
      gateway = Hive::RefactorPatrol::GithubGateway.new(
        transport: FakeTransport.new(pr: document, pages: pages)
      )
      assert_raises(Hive::GhError) { gateway.merged_pr_details(17, worktree_path: "/repo") }
    end

    files = 430.times.map do |index|
      patch = index < 21 ? "x" * 96_000 : "x" * 4_096
      { "filename" => "lib/#{index}.rb", "status" => "modified", "patch" => patch }
    end
    gateway = Hive::RefactorPatrol::GithubGateway.new(
      transport: FakeTransport.new(pr: pr_document.merge("changedFiles" => files.size), pages: [ files ])
    )
    large_details = gateway.merged_pr_details(17, worktree_path: "/repo")
    assert_equal 430, large_details.fetch("files").size
    assert large_details.fetch("files").none? { |file| file.key?("patch") }

    markers = {
      "patrol" => "<!-- hive-publication:v1 id=pub-#{'a' * 32} base=#{'b' * 40} -->",
      "patrol_successor" => "<!-- hive-patrol-fix-successor:v1 digest=#{'c' * 64} -->"
    }
    markers.each do |kind, marker|
      details = Hive::RefactorPatrol::GithubGateway.new(
        transport: FakeTransport.new(
          pr: pr_document.merge("body" => "body\n#{marker}"),
          pages: [ [
            { "filename" => "lib/a.rb", "status" => "modified", "patch" => "" },
            { "filename" => "lib/b.rb", "status" => "modified", "patch" => "" }
          ] ]
        )
      ).merged_pr_details(17, worktree_path: "/repo")
      assert_equal kind, details.dig("publication_provenance", "kind")
    end

    gateway = Hive::RefactorPatrol::GithubGateway.new
    assert_raises(Hive::GhError) do
      gateway.send(
        :validate_pr_repository_identity!, "https://%", "acme/demo", 17,
        host: "github.com"
      )
    end
  end

  private

  def pr_document
    {
      "number" => 17, "url" => "https://github.com/acme/demo/pull/17",
      "state" => "MERGED", "baseRefName" => "main", "baseRefOid" => "a" * 40,
      "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-08-20T12:00:00Z",
      "changedFiles" => 2, "title" => "Add a feature", "body" => "feature body",
      "labels" => [ { "name" => "feature" }, { "name" => "architecture" } ],
      "author" => { "login" => "dev" }
    }
  end
end
