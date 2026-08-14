require "test_helper"
require "hive/commands/plan_review"

class PlanReviewCommandTest < Minitest::Test
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

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
