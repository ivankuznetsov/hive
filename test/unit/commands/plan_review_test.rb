require "test_helper"
require "hive/commands/plan_review"

class PlanReviewCommandTest < Minitest::Test
  include HiveTestHelper

  def command
    Hive::Commands::PlanReview.new(
      "slug-260812-abcd", "approve",
      review_id: "pr-1", task_generation: 1, policy_fingerprint: "f" * 64,
      expected_artifact_digest: "a" * 64
    )
  end

  def test_envelope_error_kind_maps_every_typed_plan_review_failure
    cmd = command
    {
      Hive::PlanReview::StaleDecision.new("stale") => "stale_decision",
      Hive::PlanReview::ConflictingDecision.new("conflict") => "conflicting_decision",
      Hive::PlanReview::UnauthorizedAction.new("nope") => "unauthorized",
      Hive::PlanReview::InvalidAction.new("bad action") => "invalid_action",
      # AmbiguousSlug subclasses InvalidTaskPath, so it must be matched first.
      Hive::AmbiguousSlug.new("ambiguous", slug: "slug", candidates: []) => "ambiguous_slug",
      Hive::InvalidTaskPath.new("bad path") => "invalid_task_path",
      Hive::ConcurrentRunError.new("locked") => "concurrent_run",
      Hive::ConfigError.new("config") => "config",
      Hive::GitError.new("git") => "git",
      Hive::InternalError.new("internal") => "internal",
      StandardError.new("unclassified") => "error"
    }.each do |error, expected|
      assert_equal expected, cmd.envelope_error_kind(error), error.class.name
    end
  end

  def test_normalized_operator_prefers_the_caller_then_the_environment
    assert_equal "alice", Hive::Commands::PlanReview.normalized_operator("  alice  ")

    with_env("USER" => "bob") do
      assert_equal "bob", Hive::Commands::PlanReview.normalized_operator(nil)
      assert_equal "bob", Hive::Commands::PlanReview.normalized_operator("   ")
    end
    with_env("USER" => "") do
      assert_equal "local-operator", Hive::Commands::PlanReview.normalized_operator(nil)
    end
  end

  def test_persist_raise_resolves_locks_persists_and_commits_the_exact_task
    task = Struct.new(
      :hive_state_path, :project_root, :stage_index, :stage_name, :slug,
      keyword_init: true
    ).new(
      hive_state_path: "/tmp/state", project_root: "/tmp/project",
      stage_index: 3, stage_name: "plan", slug: "demo-task"
    )
    resolver = Struct.new(:task) { def resolve = task }.new(task)
    commits = []
    git_ops = Object.new
    git_ops.define_singleton_method(:hive_commit) { |**kwargs| commits << kwargs }
    persisted = nil

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*) { resolver }) do
      commit_lock = ->(*, &block) { block.call }
      with_replaced_singleton_method(Hive::Lock, :with_commit_lock, commit_lock) do
        replacement = lambda do |**kwargs|
          persisted = kwargs
          { "applied" => true, "level" => "mandatory" }
        end
        with_replaced_singleton_method(
          Hive::PlanReview::DecisionService, :persist_raise!, replacement
        ) do
          with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { git_ops }) do
            result = Hive::Commands::PlanReview.persist_raise_for_target!(
              "demo-task", level: "mandatory", operator: "alice", reason: "sensitive"
            )
            assert_equal "mandatory", result.fetch("level")
          end
        end
      end
    end

    assert_equal task, persisted.fetch(:task)
    assert_equal "alice", persisted.fetch(:operator)
    assert_equal "3-plan", commits.first.fetch(:stage_name)
    assert_equal "raise plan review level to mandatory", commits.first.fetch(:action)
  end

  def test_human_success_output_reports_applied_review_and_required_action
    task = Struct.new(:slug, :folder).new("demo-task", "/tmp/demo-task")
    decision = Object.new
    {
      action: "approve_finding", decision_id: "prd-#{'d' * 64}",
      target_fingerprint: "prf-#{'f' * 64}"
    }.each { |name, value| decision.define_singleton_method(name) { value } }
    decision.define_singleton_method(:[]) do |key|
      { "review_id" => "pr-#{'a' * 64}" }.fetch(key)
    end
    record = Object.new
    {
      review_id: "pr-#{'a' * 64}", task_generation: "generation-1",
      policy_fingerprint: "b" * 64, state: "awaiting_decision", outcome: nil,
      required_action: "answer remaining finding"
    }.each { |name, value| record.define_singleton_method(name) { value } }
    record.define_singleton_method(:execution_allowed?) { false }
    projection = Struct.new(:record, :observation_digest).new(record, "c" * 64)
    result = Object.new
    result.define_singleton_method(:applied) { true }
    result.define_singleton_method(:noop?) { false }
    result.define_singleton_method(:decision) { decision }
    service = Object.new
    service.define_singleton_method(:apply) { |**| result }

    command = Hive::Commands::PlanReview.new(
      "demo-task", "approve-finding",
      review_id: "pr-#{'a' * 64}", task_generation: "generation-1",
      policy_fingerprint: "b" * 64, expected_artifact_digest: "e" * 64,
      resolver: -> { task }, service_factory: ->(_task) { service },
      resumer: ->(_task) { projection }
    )
    out, = capture_io { command.call }

    assert_includes out, "applied plan review approve_finding for demo-task"
    assert_includes out, "awaiting_decision"
    assert_includes out, "answer remaining finding"
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
