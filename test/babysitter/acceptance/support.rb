require "test_helper"
require "json"
require "set"
require "hive/babysitter/project_tick"
require "hive/babysitter/pr_fixer"

module BabysitterAcceptanceSupport
  WorktreeResult = Struct.new(:path, :branch, keyword_init: true)

  def babysitter_project(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def babysitter_pr(attrs = {})
    {
      "number" => 42,
      "url" => "https://example.test/demo/pull/42",
      "headRefName" => "feature",
      "baseRefName" => "main",
      "labels" => [],
      "updatedAt" => "2026-05-26T10:00:00Z"
    }.merge(attrs)
  end

  def babysitter_cfg(overrides = {})
    babysitter = {
      "enabled" => true,
      "labels_ignore" => %w[wip do-not-merge draft],
      "max_concurrent_prs" => 2,
      "budget_minutes" => 30,
      "budget_usd" => 50
    }.merge(overrides.fetch("babysitter", {}))

    {
      "execute" => { "agent" => "claude" },
      "agents" => {},
      "babysitter" => babysitter
    }.merge(overrides.reject { |key, _value| key == "babysitter" })
  end

  def write_babysitter_config(dir, overrides = {})
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    File.write(File.join(dir, ".hive-state", "config.yml"), babysitter_cfg(overrides).to_yaml)
  end

  def babysitter_events(project)
    path = File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def with_non_green_babysitter_context(project, worktree_path, pr = babysitter_pr)
    status = { "mergeable" => "CONFLICTING", "statusCheckRollup" => [ { "conclusion" => "FAILURE" } ] }
    context = Hive::Babysitter::ContextBuilder::Context.new(
      status_rollup: status,
      failing_jobs: [ { "name" => "ci", "log" => "failure" } ],
      diff_stat: "README.md | 1 +",
      mergeable_state: "CONFLICTING",
      base_ref: pr.fetch("baseRefName"),
      head_ref: pr.fetch("headRefName")
    )

    with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_path, _number, **_kwargs) { status }) do
      with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, lambda { |_project, _pr|
        WorktreeResult.new(path: worktree_path, branch: pr.fetch("headRefName"))
      }) do
        with_replaced_singleton_method(Hive::Babysitter::ContextBuilder, :build, ->(**_kwargs) { context }) do
          yield
        end
      end
    end
  end

  def acceptance_logger
    Object.new.tap do |logger|
      def logger.event(*) = nil
    end
  end
end
