require "test_helper"
require "hive/bot/telegram"
require "hive/digest/changelog_generator"
require "hive/digest/renderer"
require "hive/digest/stats"

class HiveDigestRendererTest < Minitest::Test
  DATE = Date.new(2026, 6, 13)

  def test_renders_project_context_every_pr_bullet_link_counts_and_footer
    repos = [
      repository("a/repo", 1, bullets: [ "Adds implementation.", "Ships migration." ]),
      repository("b/repo", 2, bullets: [ "Fixes release behavior." ])
    ]
    changelog = changelog_for(repos)
    stats = Hive::Digest::Stats.new.for_repositories(repos)

    message = Hive::Digest::Renderer.render(changelog: changelog, date: DATE, stats: stats)

    assert_match(/\A\*Hive\* \\#Digest\nSat, 13 June 2026/, message)
    assert_includes message, "Projects 2 · PRs 2"
    assert_operator message.index("*a/repo*"), :<, message.index("*b/repo*")
    assert_includes message, "This makes a/repo useful\\."
    assert_includes message, "[PR \\#1](https://github.com/a/repo/pull/1)"
    assert_includes message, "[PR \\#2](https://github.com/b/repo/pull/2)"
    assert_includes message, "• Adds implementation\\."
    assert_includes message, "• Ships migration\\."
    assert_includes message, "• Fixes release behavior\\."
    assert_includes message, Hive::Digest::Renderer::FOOTER_DIVIDER
    assert_includes message, "Lines \\+3/\\-6 · PRs 2 · Commits 2"
  end

  def test_partial_and_wholly_unavailable_metrics_are_honest
    repo = repository(
      "a/repo", 1,
      metrics: { additions: 5, deletions: nil, commits: nil }
    )
    second = pull_request(
      repo.target, 2, metrics: { additions: nil, deletions: nil, commits: nil }
    )
    repo = Hive::Digest::RepositoryCollection.new(
      target: repo.target, metadata: repo.metadata, pull_requests: repo.pull_requests + [ second ]
    )
    stats = Hive::Digest::Stats.new.for_repositories([ repo ])

    message = Hive::Digest::Renderer.render(
      changelog: changelog_for([ repo ]), date: DATE, stats: stats, warnings: stats.warnings
    )

    assert_includes message, "Additions \\+5 \\(partial\\) · PRs 2"
    refute_includes message, "Deletions"
    refute_includes message, "Commits"
    assert_includes message, "*Warnings*"
    assert_includes message, "Statistics unavailable for a/repo\\#1"
    assert_includes message, "Statistics unavailable for a/repo\\#2"
  end

  def test_true_zero_metrics_remain_visible
    repo = repository("a/repo", 1, metrics: { additions: 0, deletions: 0, commits: 0 })
    stats = Hive::Digest::Stats.new.for_repositories([ repo ])

    message = Hive::Digest::Renderer.render(
      changelog: changelog_for([ repo ]), date: DATE, stats: stats
    )

    assert_includes message, "Lines \\+0/\\-0 · PRs 1 · Commits 0"
  end

  def test_empty_digest_uses_normal_counts_and_footer_without_invented_metrics
    stats = Hive::Digest::Stats.new.for_repositories([])
    changelog = Hive::Digest::Changelog.new(projects: [], facts: [], warnings: [])

    message = Hive::Digest::Renderer.render(changelog: changelog, date: DATE, stats: stats)

    assert_includes message, "Projects 0 · PRs 0"
    assert message.end_with?("#{Hive::Digest::Renderer::FOOTER_DIVIDER}\nPRs 0")
    refute_includes message, "Lines"
    refute_includes message, "Commits"
  end

  def test_markdown_metacharacters_and_link_targets_are_escaped
    repo = repository(
      "a/repo", 1,
      title: "Fix (docs) *now*",
      url: "https://github.com/a/repo/pull/1(foo)\\bar",
      bullets: [ "Escapes _all_ [text]!" ]
    )
    message = Hive::Digest::Renderer.render(
      changelog: changelog_for([ repo ]), date: DATE,
      stats: Hive::Digest::Stats.new.for_repositories([ repo ])
    )

    assert_includes message, "Fix \\(docs\\) \\*now\\*"
    assert_includes message, "1(foo\\)\\\\bar"
    assert_includes message, "Escapes \\_all\\_ \\[text\\]\\!"
  end

  def test_pathological_long_multibyte_bullet_splits_only_at_safe_escaped_lines
    bullet = ("é_*" * 3_000) + " END"
    repo = repository("a/repo", 1, bullets: [ bullet ])
    message = Hive::Digest::Renderer.render(
      changelog: changelog_for([ repo ]), date: DATE,
      stats: Hive::Digest::Stats.new.for_repositories([ repo ])
    )
    chunks = Hive::Bot::Telegram.allocate.send(:split_message, message)

    assert_operator chunks.size, :>, 1
    assert chunks.all? { |chunk| chunk.length <= Hive::Bot::Telegram::MAX_MESSAGE_CHARS }
    assert chunks.none? { |chunk| chunk.match?(/(?<!\\)(?:\\\\)*\\\z/) }, "no chunk may end on an escape prefix"
    assert_equal 1, chunks.join("\n").scan("https://github.com/a/repo/pull/1").size
    assert_equal 3_000, chunks.join.scan("é").size
    assert_equal 3_000, chunks.join.scan("\\_").size
    assert_equal 3_000, chunks.join.scan("\\*").size
    assert_includes chunks.join, "END"
  end

  def test_escape_helpers_match_telegram_markdown_v2_contract
    raw = "_*[]()~`>#+-=|{}.!"
    assert_equal "\\_\\*\\[\\]\\(\\)\\~\\`\\>\\#\\+\\-\\=\\|\\{\\}\\.\\!",
                 Hive::Digest::Renderer.escape_mdv2(raw)
    assert_equal "foo(bar\\)\\\\baz",
                 Hive::Digest::Renderer.escape_link_target("foo(bar)\\baz")
    assert_equal "code\\`\\\\tail",
                 Hive::Digest::Renderer.escape_code_span("code`\\tail")
  end

  private

  def repository(slug, number, title: "PR title", url: nil, bullets: [ "Concrete change." ], metrics: {})
    target = Hive::Digest::RepositoryTarget.new(
      project_name: slug.split("/").last,
      path: "/tmp/#{slug.tr('/', '-')}", repository: slug, host: "github.com"
    )
    pr = pull_request(target, number, title: title, url: url, metrics: metrics)
    repo = Hive::Digest::RepositoryCollection.new(
      target: target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: slug, description: "Description", url: "https://github.com/#{slug}"
      ),
      pull_requests: [ pr ]
    )
    @test_bullets ||= {}
    @test_bullets[[ slug, number ]] = bullets
    repo
  end

  def pull_request(target, number, title: "PR title", url: nil, metrics: {})
    Hive::Digest::PullRequest.new(
      target: target,
      number: number,
      title: title,
      url: url || "https://github.com/#{target.repository}/pull/#{number}",
      merged_at: Time.utc(2026, 6, 13, 12, number),
      body: "Body", diff: "diff --git a/a b/a", files: [ "a" ],
      additions: metrics.fetch(:additions, number),
      deletions: metrics.fetch(:deletions, number * 2),
      commits: metrics.fetch(:commits, 1)
    )
  end

  def changelog_for(repositories)
    projects = repositories.map do |repository|
      generated_prs = repository.pull_requests.map do |pr|
        bullets = @test_bullets&.fetch([ repository.target.repository, pr.number ], nil) ||
                  [ "Concrete change #{pr.number}." ]
        Hive::Digest::GeneratedPullRequest.new(
          pull_request: pr,
          bullets: bullets.map.with_index do |text, index|
            Hive::Digest::ChangeBullet.new(text: text, fact_ids: [ "fact-#{pr.number}-#{index}" ])
          end
        )
      end
      Hive::Digest::GeneratedProject.new(
        repository: repository,
        significance: "This makes #{repository.target.repository} useful.",
        pull_requests: generated_prs
      )
    end
    Hive::Digest::Changelog.new(projects: projects, facts: [], warnings: [])
  end
end
