require "test_helper"
require "json_schemer"
require "hive/commands/digest"

class HiveCommandsDigestTest < Minitest::Test
  Runner = Struct.new(:calls, :result, :error) do
    def run(date:, dry_run:, repos:)
      calls << { date: date, dry_run: dry_run, repos: repos }
      raise error if error

      result
    end
  end

  def test_bare_and_filtered_invocations_use_one_runner
    output = StringIO.new
    runner = Runner.new([], result, nil)

    Hive::Commands::Digest.new(
      date: "2026-06-13", dry_run: true, repos: [ "owner/repo", "other/repo" ],
      runner: runner, output: output
    ).call

    assert_equal [
      { date: Date.new(2026, 6, 13), dry_run: true, repos: [ "owner/repo", "other/repo" ] }
    ], runner.calls
    assert_equal "digest body\n", output.string
  end

  def test_blank_date_defers_london_default_to_runner
    runner = Runner.new([], result, nil)

    Hive::Commands::Digest.new(date: nil, dry_run: true, runner: runner, output: StringIO.new).call

    assert_nil runner.calls.first.fetch(:date)
  end

  def test_invalid_and_impossible_dates_raise_config_error
    [ "13-06-2026", "2026-13-45" ].each do |date|
      error = assert_raises(Hive::ConfigError) do
        Hive::Commands::Digest.new(date: date, runner: Runner.new([], nil, nil)).call
      end
      assert_match(/YYYY-MM-DD/, error.message)
    end
  end

  def test_json_error_envelope_uses_v2_for_config_and_generation_failures
    cases = [
      [ "bad-date", nil, "config", Hive::ExitCodes::CONFIG ],
      [ "2026-06-13", Hive::Digest::GenerationError.new("coverage missing"), "internal", Hive::ExitCodes::SOFTWARE ]
    ]
    cases.each do |date, error, kind, exit_code|
      output = StringIO.new
      command = Hive::Commands::Digest.new(
        date: date, json: true, runner: Runner.new([], nil, error), output: output
      )

      assert_raises(Hive::Error) { command.call }
      payload = JSON.parse(output.string)
      assert_equal "hive-digest", payload.fetch("schema")
      assert_equal 2, payload.fetch("schema_version")
      assert_equal false, payload.fetch("ok")
      assert_equal kind, payload.fetch("error_kind")
      assert_equal exit_code, payload.fetch("exit_code")
      assert_schema_valid(payload)
    end
  end

  def test_non_json_error_prints_no_envelope
    output = StringIO.new
    command = Hive::Commands::Digest.new(
      date: "bad", runner: Runner.new([], nil, nil), output: output
    )

    assert_raises(Hive::ConfigError) { command.call }
    assert_empty output.string
  end

  def test_dry_run_json_emits_complete_v2_changelist
    output = StringIO.new
    Hive::Commands::Digest.new(
      date: "2026-06-13", dry_run: true, json: true,
      runner: Runner.new([], result, nil), output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal true, payload.fetch("ok")
    assert_equal "hive-digest", payload.fetch("schema")
    assert_equal 2, payload.fetch("schema_version")
    assert_equal "2026-06-13", payload.fetch("date")
    assert_equal "sent", payload.fetch("status")
    assert_equal 2, payload.fetch("resolved_repository_count")
    assert_equal 1, payload.fetch("collected_repository_count")
    assert_equal 1, payload.fetch("project_count")
    assert_equal 1, payload.fetch("pr_count")
    assert_equal 5, payload.fetch("additions")
    assert_nil payload.fetch("deletions", nil), "wholly unknown totals must be omitted"
    assert_equal 1, payload.fetch("commits")
    assert_equal "digest body", payload.fetch("message")
    assert_nil payload.fetch("chat_id")
    project = payload.fetch("projects").first
    assert_equal "owner/repo", project.fetch("repository")
    assert_equal "Why it matters.", project.fetch("description")
    refute project.key?("deletions")
    pr = project.fetch("prs").first
    assert_equal [ "Adds the complete change." ], pr.fetch("bullets")
    refute pr.key?("deletions")
    warning = payload.fetch("warnings").first
    assert_equal "statistics_incomplete", warning.fetch("kind")
    assert_equal [ "deletions" ], warning.fetch("metrics")
    assert_schema_valid(payload)
  end

  def test_real_send_json_has_chat_and_null_message
    output = StringIO.new
    delivery = Hive::Digest::Sender::SendResult.new(
      chat_id: 4242, responses: [], dry_run: false, text: "digest body"
    )
    result = self.result(dry_run: false, delivery: delivery)

    Hive::Commands::Digest.new(
      date: "2026-06-13", json: true,
      runner: Runner.new([], result, nil), output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal 4242, payload.fetch("chat_id")
    assert_nil payload.fetch("message")
    assert_schema_valid(payload)
  end

  def test_honest_empty_payload_has_pr_zero_and_no_metrics
    output = StringIO.new
    empty = empty_result
    Hive::Commands::Digest.new(
      date: "2026-06-13", dry_run: true, json: true,
      runner: Runner.new([], empty, nil), output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal "empty", payload.fetch("status")
    assert_equal 0, payload.fetch("project_count")
    assert_equal 0, payload.fetch("pr_count")
    assert_empty payload.fetch("projects")
    Hive::Digest::PR_METRICS.each { |metric| refute payload.key?(metric.to_s) }
    assert_schema_valid(payload)
  end

  def test_plain_real_output_reports_counts
    output = StringIO.new
    Hive::Commands::Digest.new(
      date: "2026-06-13", runner: Runner.new([], result(dry_run: false), nil), output: output
    ).call

    assert_equal "hive digest: sent for 2026-06-13 (1 projects, 1 PRs)\n", output.string
  end

  private

  def result(dry_run: true, delivery: nil)
    warning = Hive::Digest::Warning.new(
      kind: "statistics_incomplete", repository: "owner/repo", pr_number: 7,
      metrics: [ "deletions" ], message: "Statistics unavailable for owner/repo#7: deletions"
    )
    repository = repository_collection
    stats = Hive::Digest::Stats.new.for_repositories([ repository ])
    project = Hive::Digest::GeneratedProject.new(
      repository: repository,
      significance: "Why it matters.",
      pull_requests: [
        Hive::Digest::GeneratedPullRequest.new(
          pull_request: repository.pull_requests.first,
          bullets: [
            Hive::Digest::ChangeBullet.new(text: "Adds the complete change.", fact_ids: [ "fact-1" ])
          ]
        )
      ]
    )
    Hive::Digest::Result.new(
      status: :sent, date: Date.new(2026, 6, 13), dry_run: dry_run,
      resolved_repository_count: 2, collected_repository_count: 1,
      projects: [ project ], pr_count: 1, stats: stats, warnings: [ warning ],
      message: "digest body", delivery: delivery
    )
  end

  def empty_result
    stats = Hive::Digest::Stats.new.for_repositories([])
    Hive::Digest::Result.new(
      status: :empty, date: Date.new(2026, 6, 13), dry_run: true,
      resolved_repository_count: 1, collected_repository_count: 1,
      projects: [], pr_count: 0, stats: stats, warnings: [],
      message: "empty body", delivery: nil
    )
  end

  def repository_collection
    target = Hive::Digest::RepositoryTarget.new(
      project_name: "Project", path: "/tmp/project", repository: "owner/repo", host: "github.com"
    )
    pr = Hive::Digest::PullRequest.new(
      target: target, number: 7, title: "Ship change",
      url: "https://github.com/owner/repo/pull/7", merged_at: Time.utc(2026, 6, 13, 12),
      body: "Body", diff: "diff --git a/a b/a", files: [ "a" ],
      additions: 5, deletions: nil, commits: 1
    )
    Hive::Digest::RepositoryCollection.new(
      target: target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: "owner/repo", description: "Description", url: "https://github.com/owner/repo"
      ),
      pull_requests: [ pr ]
    )
  end

  def assert_schema_valid(payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest"))))
    assert_empty schema.validate(payload).map { |error| error.fetch("error") }
  end
end
