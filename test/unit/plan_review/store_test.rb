require "test_helper"
require "hive/plan_review/store"

class PlanReviewStoreTest < Minitest::Test
  def test_read_only_construction_does_not_create_review_state
    Dir.mktmpdir("hive-plan-review-store") do |task_folder|
      store = Hive::PlanReview::Store.new(task_folder:)

      refute File.exist?(store.root)
      assert_nil store.current(optional: true)
      refute File.exist?(store.root)
    end
  end

  def test_attempt_history_is_immutable_and_projection_has_one_current_winner
    with_store do |store|
      manifest = manifest_record
      store.create_review!(manifest)
      attempt_id = Hive::PlanReview::Identity.attempt(manifest.review_id)
      refs = store.write_attempt!(
        review_id: manifest.review_id,
        attempt_id:,
        plan_bytes: "# Plan\n",
        result: { "outcome" => "success" },
        coverage: { "completed" => [ "whole_document", "adversarial" ] },
        route_receipt: { "provider" => "grok", "model" => "grok-4.6" }
      )
      current = projection_record(manifest, attempt_id:, artifacts: refs)

      published = store.publish_current!(current, expected_version: nil)
      assert_equal 1, published.version
      assert_equal published.to_h, store.current.to_h

      assert_raises(Hive::PlanReview::StaleObservation) do
        store.publish_current!(current, expected_version: nil)
      end
      assert_raises(Hive::PlanReview::InvalidRecord) do
        store.write_attempt!(
          review_id: manifest.review_id,
          attempt_id:,
          plan_bytes: "changed",
          result: {}, coverage: {}, route_receipt: {}
        )
      end
      assert_equal "# Plan\n", store.read_reference(refs.fetch("input_plan"))
    end
  end

  def test_late_old_review_cannot_replace_current_and_secret_values_are_redacted
    with_store do |store|
      first = manifest_record
      store.create_review!(first)
      current = projection_record(first, required_action: "use sk-#{'x' * 30}")
      store.publish_current!(current, expected_version: nil)

      stale = projection_record(first, version: 2, plan_digest: "d" * 64)
      assert_raises(Hive::PlanReview::StaleObservation) do
        store.publish_current!(stale, expected_version: 1)
      end
      assert_includes store.current.required_action, "[REDACTED:openai_api_key]"
      refute_includes File.read(store.current_path), "sk-#{'x' * 30}"
    end
  end

  def test_concurrent_current_pointer_promotions_have_one_winner
    with_store do |store|
      first = manifest_record
      store.create_review!(first)
      candidates = %w[first second].map do |action|
        projection_record(first, required_action: action)
      end
      gate = Queue.new
      results = Queue.new
      threads = candidates.map do |candidate|
        Thread.new do
          gate.pop
          results << store.publish_current!(candidate, expected_version: nil)
        rescue Hive::PlanReview::StaleObservation => e
          results << e
        end
      end
      candidates.length.times { gate << true }
      threads.each(&:join)
      observed = candidates.length.times.map { results.pop }

      assert_equal 1, observed.count { |value| value.is_a?(Hive::PlanReview::Record) }
      assert_equal 1, observed.count { |value| value.is_a?(Hive::PlanReview::StaleObservation) }
      assert_includes %w[first second], store.current.required_action
    end
  end

  def test_symlinked_or_hash_mismatched_artifacts_fail_closed
    with_store do |store, task_folder|
      first = manifest_record
      store.create_review!(first)
      outside = File.join(task_folder, "outside.json")
      File.write(outside, "{}")
      link = File.join(store.root, "linked.json")
      File.symlink(outside, link)
      bad_ref = { "path" => "linked.json", "sha256" => Digest::SHA256.hexdigest("{}"), "bytes" => 2 }

      assert_raises(Hive::PlanReview::InvalidRecord) do
        store.publish_current!(
          projection_record(first, artifacts: { "critique" => bad_ref }),
          expected_version: nil
        )
      end
    end
  end

  private

  def with_store
    Dir.mktmpdir("hive-plan-review-store") do |task_folder|
      yield Hive::PlanReview::Store.new(task_folder:), task_folder
    end
  end

  def manifest_record
    Hive::PlanReview::Record.new(
      "schema" => "hive-plan-review", "schema_version" => 1, "kind" => "manifest",
      "review_id" => "pr-#{'a' * 64}", "prior_review_id" => nil,
      "task_id" => "task-1", "task_generation" => "generation-1",
      "plan_digest" => "b" * 64, "policy_fingerprint" => "c" * 64,
      "computed_level" => "standard", "effective_level" => "standard",
      "created_at" => "2026-08-12T12:00:00.000000Z"
    )
  end

  def projection_record(manifest, version: 1, attempt_id: nil, artifacts: {},
                        required_action: nil, plan_digest: manifest.plan_digest)
    Hive::PlanReview::Record.new(
      manifest.to_h.merge(
        "kind" => "projection", "version" => version, "plan_digest" => plan_digest,
        "candidate_plan_digest" => nil, "state" => "reviewing", "outcome" => nil,
        "attempt_ids" => Array(attempt_id), "current_attempt_id" => attempt_id,
        "coverage" => [], "findings" => [], "decisions" => [], "routes" => [],
        "artifacts" => artifacts, "blockers" => [], "required_action" => required_action,
        "degradation_reason" => nil, "execution_allowed" => false,
        "updated_at" => "2026-08-12T12:01:00.000000Z"
      )
    )
  end
end
