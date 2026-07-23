require "test_helper"
require "hive/digest"

class HiveDigestRunTest < Minitest::Test
  include HiveTestHelper

  FakeResolver = Struct.new(:resolution, :calls, :error) do
    def resolve(repos:)
      calls << repos
      raise error if error

      resolution
    end
  end

  FakeCollector = Struct.new(:report, :calls) do
    def for_date(date, targets:)
      calls << { date: date, targets: targets }
      report
    end
  end

  FakeGenerator = Struct.new(:changelog, :calls, :error) do
    def generate(repositories, date:)
      calls << { repositories: repositories, date: date }
      raise error if error

      changelog
    end
  end

  FakeSender = Struct.new(:calls, :chat_id) do
    def preflight! = calls << :preflight

    def deliver(text, dry_run:)
      calls << { text: text, dry_run: dry_run }
      Hive::Digest::Sender::SendResult.new(
        chat_id: dry_run ? nil : chat_id, responses: [], dry_run: dry_run, text: text
      )
    end
  end

  FakeRenderer = Struct.new(:calls) do
    def render(**kwargs)
      calls << kwargs
      "rendered"
    end
  end

  def test_partial_collection_generates_complete_successes_and_delivers_warnings
    warning = Hive::Digest::Warning.new(
      kind: "repository_collection_failed", repository: "owner/bad",
      message: "Could not collect owner/bad"
    )
    collected = repository_collection
    bad_target = Hive::Digest::RepositoryTarget.new(
      project_name: "Bad", path: "/tmp/bad", repository: "owner/bad", host: "github.com"
    )
    report = Hive::Digest::CollectionReport.new(
      resolved_count: 2, repositories: [ collected ], failures: [ warning ], warnings: [ warning ]
    )
    generator = FakeGenerator.new(changelog_for(collected), [], nil)
    sender = FakeSender.new([], nil)
    renderer = FakeRenderer.new([])

    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13), dry_run: true, cfg: {}, repos: [ "owner/repo" ],
      resolver: resolver_for(target, bad_target, warnings: []),
      collector: FakeCollector.new(report, []),
      generator: generator,
      stats: Hive::Digest::Stats.new,
      renderer: renderer,
      sender: sender
    )

    assert_equal :sent, result.status
    assert_equal 1, result.pr_count
    assert_equal 2, result.resolved_repository_count
    assert_equal 1, result.collected_repository_count
    assert_equal [ warning ], result.warnings
    assert_equal [ collected ], generator.calls.first.fetch(:repositories)
    assert_equal true, sender.calls.last.fetch(:dry_run)
    assert_equal [ warning ], renderer.calls.first.fetch(:warnings)
  end

  def test_honest_empty_skips_agent_and_sends_normal_zero_pr_digest
    empty_repository = repository_collection(pull_requests: [])
    report = Hive::Digest::CollectionReport.new(
      resolved_count: 1, repositories: [ empty_repository ], failures: [], warnings: []
    )
    generator = FakeGenerator.new(nil, [], RuntimeError.new("must not run"))
    sender = FakeSender.new([], 123)

    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13), dry_run: false, cfg: {},
      resolver: resolver_for(target), collector: FakeCollector.new(report, []),
      generator: generator, stats: Hive::Digest::Stats.new, sender: sender
    )

    assert_equal :empty, result.status
    assert_equal 0, result.pr_count
    assert_empty result.projects
    assert_empty generator.calls
    assert_equal :preflight, sender.calls.first
    assert_includes result.message, "Projects 0 · PRs 0"
    assert_includes result.message, "PRs 0"
    refute_includes result.message, "Lines"
    refute_includes result.message, "Commits"
  end

  def test_all_collection_failed_calls_neither_generator_renderer_nor_sender
    failure = Hive::Digest::Warning.new(
      kind: "repository_collection_failed", repository: "owner/repo", message: "outage"
    )
    report = Hive::Digest::CollectionReport.new(
      resolved_count: 1, repositories: [], failures: [ failure ], warnings: [ failure ]
    )
    generator = FakeGenerator.new(nil, [], nil)
    renderer = FakeRenderer.new([])
    sender = FakeSender.new([], nil)

    assert_raises(Hive::Digest::CollectionError) do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13), dry_run: true, cfg: {},
        resolver: resolver_for(target), collector: FakeCollector.new(report, []),
        generator: generator, renderer: renderer, sender: sender
      )
    end

    assert_empty generator.calls
    assert_empty renderer.calls
    assert_empty sender.calls
  end

  def test_empty_scope_fails_before_collection_render_or_send
    error = Hive::ConfigError.new("no registered GitHub repositories")
    resolver = FakeResolver.new(nil, [], error)
    collector = FakeCollector.new(nil, [])
    renderer = FakeRenderer.new([])
    sender = FakeSender.new([], nil)

    assert_raises(Hive::ConfigError) do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13), dry_run: true, cfg: {}, resolver: resolver,
        collector: collector, renderer: renderer, sender: sender
      )
    end

    assert_empty collector.calls
    assert_empty renderer.calls
    assert_empty sender.calls
  end

  def test_real_send_preflights_before_paid_generation
    order = []
    sender = Object.new
    sender.define_singleton_method(:preflight!) { order << :preflight }
    sender.define_singleton_method(:deliver) do |text, dry_run:|
      order << :deliver
      Hive::Digest::Sender::SendResult.new(
        chat_id: 123, responses: [], dry_run: dry_run, text: text
      )
    end
    generated = changelog_for(repository_collection)
    generator = Object.new
    generator.define_singleton_method(:generate) do |_repositories, date:|
      order << :generate
      generated
    end

    Hive::Digest.run(
      date: Date.new(2026, 6, 13), dry_run: false, cfg: {},
      resolver: resolver_for(target), collector: collector_for(repository_collection),
      generator: generator, stats: Hive::Digest::Stats.new,
      renderer: FakeRenderer.new([]), sender: sender
    )

    assert_equal %i[preflight generate deliver], order
  end

  def test_generation_failure_is_nonzero_and_sends_nothing
    generator = FakeGenerator.new(
      nil, [], Hive::Digest::GenerationError.new("coverage missing")
    )
    sender = FakeSender.new([], nil)

    assert_raises(Hive::Digest::GenerationError) do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13), dry_run: true, cfg: {},
        resolver: resolver_for(target), collector: collector_for(repository_collection),
        generator: generator, stats: Hive::Digest::Stats.new,
        renderer: FakeRenderer.new([]), sender: sender
      )
    end

    assert_empty sender.calls
  end

  def test_default_date_uses_london_calendar_when_host_differs
    empty_repository = repository_collection(pull_requests: [])
    collector = collector_for(empty_repository)

    with_env("TZ" => "America/Los_Angeles") do
      result = Hive::Digest.run(
        dry_run: true, cfg: {}, clock: -> { Time.utc(2026, 6, 14, 0, 30) },
        resolver: resolver_for(target), collector: collector,
        stats: Hive::Digest::Stats.new, sender: FakeSender.new([], nil)
      )

      assert_equal Date.new(2026, 6, 13), result.date
      assert_equal Date.new(2026, 6, 13), collector.calls.first.fetch(:date)
    end
  end

  def test_real_run_loads_env_file_before_preflight
    calls = []
    empty_repository = repository_collection(pull_requests: [])
    sender = Object.new
    sender.define_singleton_method(:preflight!) { calls << :preflight }
    sender.define_singleton_method(:deliver) do |text, dry_run:|
      Hive::Digest::Sender::SendResult.new(chat_id: 1, responses: [], dry_run: dry_run, text: text)
    end

    with_replaced_singleton_method(Hive::EnvFile, :load!, -> { calls << :env }) do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13), dry_run: false, cfg: {},
        resolver: resolver_for(target), collector: collector_for(empty_repository),
        stats: Hive::Digest::Stats.new, sender: sender
      )
    end

    assert_equal %i[env preflight], calls
  end

  def test_result_rejects_unknown_status_and_inconsistent_count
    base = {
      date: Date.new(2026, 6, 13), dry_run: true,
      resolved_repository_count: 1, collected_repository_count: 1,
      projects: [], pr_count: 0, stats: nil, warnings: [], message: "x", delivery: nil
    }
    assert_raises(ArgumentError) { Hive::Digest::Result.new(status: :bogus, **base) }
    assert_raises(ArgumentError) { Hive::Digest::Result.new(status: :sent, **base) }
  end

  private

  def target
    @target ||= Hive::Digest::RepositoryTarget.new(
      project_name: "Project", path: "/tmp/project", repository: "owner/repo", host: "github.com"
    )
  end

  def pull_request
    @pull_request ||= Hive::Digest::PullRequest.new(
      target: target, number: 7, title: "Ship change",
      url: "https://github.com/owner/repo/pull/7",
      merged_at: Time.utc(2026, 6, 13, 12), body: "Body",
      diff: "diff --git a/a b/a", files: [ "a" ],
      additions: 5, deletions: 2, commits: 1
    )
  end

  def repository_collection(pull_requests: [ pull_request ])
    Hive::Digest::RepositoryCollection.new(
      target: target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: "owner/repo", description: "Description", url: "https://github.com/owner/repo"
      ),
      pull_requests: pull_requests
    )
  end

  def changelog_for(repository)
    generated_prs = repository.pull_requests.map do |pr|
      Hive::Digest::GeneratedPullRequest.new(
        pull_request: pr,
        bullets: [ Hive::Digest::ChangeBullet.new(text: "Adds the complete change.", fact_ids: [ "fact-1" ]) ]
      )
    end
    Hive::Digest::Changelog.new(
      projects: [
        Hive::Digest::GeneratedProject.new(
          repository: repository,
          significance: "This makes the project more useful.",
          pull_requests: generated_prs
        )
      ],
      facts: [], warnings: []
    )
  end

  def resolver_for(*targets, warnings: [])
    FakeResolver.new(Hive::Digest::Resolution.new(targets: targets, warnings: warnings), [], nil)
  end

  def collector_for(*repositories)
    FakeCollector.new(
      Hive::Digest::CollectionReport.new(
        resolved_count: repositories.size, repositories: repositories, failures: [], warnings: []
      ),
      []
    )
  end
end
