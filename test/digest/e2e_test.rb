require "test_helper"
require "hive/digest"

class HiveDigestE2ETest < Minitest::Test
  include HiveTestHelper

  FakeResolver = Struct.new(:resolution) do
    def resolve(repos:)
      raise "unexpected repository filter: #{repos.inspect}" unless repos.empty?

      resolution
    end
  end

  FakeCollector = Struct.new(:report) do
    def for_date(_date, targets:)
      raise "unexpected digest targets" unless targets == report.repositories.map(&:target)

      report
    end
  end

  def setup
    missing = %w[HOME HIVE_TELEGRAM_BOT_TOKEN HIVE_DIGEST_TEST_CHAT_ID].select do |key|
      ENV[key].to_s.strip.empty?
    end
    flunk "missing required live digest env vars: #{missing.join(', ')}" unless missing.empty?
    preflight_live_agent! if name == "test_live_agent_and_telegram_digest_over_fixture_prs"
  end

  def test_live_agent_and_telegram_digest_over_fixture_prs
    with_tmp_global_config(home: ENV.fetch("HOME")) do |home|
      target = target_for(home)
      repository = repository_collection(target)
      write_global_config(home, target)

      result = Hive::Digest.run(
        date: Date.new(2026, 7, 19),
        resolver: FakeResolver.new(resolution_for(target)),
        collector: FakeCollector.new(report_for(repository)),
        cfg: Hive::Config.load_global_digest_config
      )

      assert_equal :sent, result.status
      assert_equal 2, result.pr_count
      result.delivery.responses.each { |response| assert_message_id(response) }

      generated = result.projects.fetch(0)
      assert_equal [ 10, 11 ], generated.pull_requests.map { |row| row.pull_request.number }
      generated.pull_requests.each do |row|
        refute_empty row.bullets
        row.bullets.each { |bullet| refute_empty bullet.fact_ids }
        assert_includes result.message, row.pull_request.url
      end
      ledger_files = Dir[File.join(Hive::Paths.state_home, "digest", "runs", "*", "ledger.json")]
      assert_equal 1, ledger_files.size, "the generator must retain exactly one safe ledger"
      ledger = JSON.parse(File.read(ledger_files.first))
      assert_operator ledger.fetch("evidence_checksums").size, :>=, 4
      semantic_evidence = {
        "-pr10-body-001" => /DigestEvidenceCollector|implementation/i,
        "-pr10-body-002" => /verify_digest_release|release/i,
        "-pr10-body-003" => /hive-digest v2|migration/i,
        "-pr11-body-001" => /nil metrics remain unknown|incomplete statistics|fix/i
      }
      semantic_evidence.each do |suffix, semantic_pattern|
        fact = ledger.dig("output", "facts").find do |row|
          row.fetch("evidence_ids").any? { |evidence_id| evidence_id.end_with?(suffix) }
        end
        refute_nil fact, "live generation must account for #{suffix}"
        assert_equal "material", fact.fetch("kind")
        generated_pr = generated.pull_requests.find { |row| row.pull_request.number == fact.fetch("number") }
        citing_bullets = generated_pr.bullets.select { |bullet| bullet.fact_ids.include?(fact.fetch("id")) }
        refute_empty citing_bullets, "#{suffix} must reach a bullet for its PR"
        assert_match semantic_pattern, ([ fact.fetch("text") ] + citing_bullets.map(&:text)).join(" ")
      end
      assert_equal [ 10, 11 ],
                   ledger.dig("output", "projects", 0, "pull_requests").map { |row| row.fetch("number") }
    end
  end

  def test_live_telegram_empty_digest
    with_tmp_global_config(home: ENV.fetch("HOME")) do |home|
      target = target_for(home)
      repository = Hive::Digest::RepositoryCollection.new(
        target: target,
        metadata: Hive::Digest::RepositoryMetadata.new(
          name: target.repository,
          description: "Digest fixture repository",
          url: "https://github.com/#{target.repository}"
        ),
        pull_requests: []
      )
      write_global_config(home, target)

      result = Hive::Digest.run(
        date: Date.new(2026, 7, 19),
        resolver: FakeResolver.new(resolution_for(target)),
        collector: FakeCollector.new(report_for(repository)),
        cfg: Hive::Config.load_global_digest_config
      )

      assert_equal :empty, result.status
      assert_includes result.message, "PRs 0"
      refute_includes result.message, "Lines"
      refute_includes result.message, "Commits"
      result.delivery.responses.each { |response| assert_message_id(response) }
    end
  end

  private

  def preflight_live_agent!
    profile = Hive::AgentProfiles.lookup(live_agent_name)
    profile.check_version!
    profile.preflight!
  rescue Hive::Error => e
    flunk "live digest agent #{live_agent_name.inspect} preflight failed: #{e.message}"
  end

  def live_agent_name
    agent = ENV["HIVE_DIGEST_TEST_AGENT"].to_s.strip
    agent.empty? ? "claude" : agent
  end

  def target_for(home)
    path = File.join(home, "digest-e2e-project")
    FileUtils.mkdir_p(path)
    Hive::Digest::RepositoryTarget.new(
      project_name: "Digest E2E",
      path: path,
      repository: "ivankuznetsov/hive",
      host: "github.com"
    )
  end

  def repository_collection(target)
    prs = [
      pull_request(
        target, number: 10, title: "Implement complete evidence",
        body: "## Implementation\nAdd DigestEvidenceCollector for complete repository and PR evidence.\n\n" \
              "## Release\nAdd verify_digest_release to the release gate.\n\n" \
              "## Migration\nMove JSON consumers to hive-digest v2.",
        diff: "diff --git a/lib/evidence.rb b/lib/evidence.rb\n@@ -0,0 +1 @@\n+collect_complete_evidence\n",
        additions: 42, deletions: 0, commits: 2
      ),
      pull_request(
        target, number: 11, title: "Fix warning semantics",
        body: "## Fix\nEnsure nil metrics remain unknown so incomplete statistics stay visible.",
        diff: "diff --git a/lib/stats.rb b/lib/stats.rb\n@@ -1 +1 @@\n-zero\n+unknown\n",
        additions: 1, deletions: nil, commits: 1
      )
    ]
    Hive::Digest::RepositoryCollection.new(
      target: target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: target.repository,
        description: "Hive coordinates durable engineering workflows.",
        url: "https://github.com/#{target.repository}"
      ),
      pull_requests: prs
    )
  end

  def pull_request(target, number:, title:, body:, diff:, additions:, deletions:, commits:)
    Hive::Digest::PullRequest.new(
      target: target,
      number: number,
      title: title,
      url: "https://github.com/#{target.repository}/pull/#{number}",
      merged_at: Time.utc(2026, 7, 19, 12, number),
      body: body,
      diff: diff,
      files: [ number == 10 ? "lib/evidence.rb" : "lib/stats.rb" ],
      additions: additions,
      deletions: deletions,
      commits: commits
    )
  end

  def resolution_for(target)
    Hive::Digest::Resolution.new(targets: [ target ], warnings: [])
  end

  def report_for(repository)
    Hive::Digest::CollectionReport.new(
      resolved_count: 1,
      repositories: [ repository ],
      failures: [],
      warnings: []
    )
  end

  def write_global_config(home, target)
    File.write(File.join(home, "config.yml"), {
      "registered_projects" => [ { "name" => target.project_name, "path" => target.path } ],
      "digest" => {
        "enabled" => true,
        "agent" => live_agent_name,
        "max_catchup_days" => 7
      },
      "bot" => {
        "chat_id_allowlist" => [ Integer(ENV.fetch("HIVE_DIGEST_TEST_CHAT_ID")) ]
      }
    }.to_yaml)
  end

  def assert_message_id(response)
    message_id =
      if response.respond_to?(:message_id)
        response.message_id
      elsif response.is_a?(Hash)
        response["message_id"] || response[:message_id]
      end

    assert message_id.to_i.positive?, "Telegram response must include a positive message_id"
  end
end
