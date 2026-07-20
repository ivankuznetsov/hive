require "test_helper"
require "hive/digest/repository"

class HiveDigestRepositoryTest < Minitest::Test
  def test_collection_rejects_pull_requests_from_another_target
    target = repository_target("owner/repo")
    other = repository_target("owner/other")
    pull_request = Hive::Digest::PullRequest.new(
      target: other,
      number: 7,
      title: "Change",
      url: "https://github.com/owner/other/pull/7",
      merged_at: Time.utc(2026, 6, 13, 12),
      body: "Body",
      diff: "Diff",
      files: [ "lib/change.rb" ]
    )
    metadata = Hive::Digest::RepositoryMetadata.new(
      name: "owner/repo", description: "Description", url: "https://github.com/owner/repo"
    )

    error = assert_raises(ArgumentError) do
      Hive::Digest::RepositoryCollection.new(
        target: target, metadata: metadata, pull_requests: [ pull_request ]
      )
    end
    assert_match(/another target/, error.message)
  end

  private

  def repository_target(repository)
    Hive::Digest::RepositoryTarget.new(
      project_name: repository, path: "/tmp/#{repository.tr('/', '-')}",
      repository: repository, host: "github.com"
    )
  end
end
