require "test_helper"
require "hive/attempts/context"

class AttemptsContextTest < Minitest::Test
  include HiveTestHelper

  def test_explicit_context_projects_attempt_identity
    Hive::Attempts::Context.with(
      attempt_id: "attempt-1", task_generation: 7, ownership_generation: "generation-1"
    ) do
      assert Hive::Attempts::Context.active?
      assert_equal(
        {
          "attempt_id" => "attempt-1", "task_generation" => 7,
          "ownership_generation" => "generation-1"
        },
        Hive::Attempts::Context.projection
      )
    end

    refute Hive::Attempts::Context.active?
  end

  def test_environment_context_is_validated_against_store
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      store.create_launching(
        attempt_id: "attempt-env", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-env", task_input_epoch: 5,
        progress_token: "progress", provider: "codex",
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
        launch_timeout_sec: 30, now: Time.now.utc
      )

      with_env(
        "HIVE_ATTEMPT_INTERNAL" => "1",
        "HIVE_ATTEMPT_ID" => "attempt-env",
        "HIVE_ATTEMPT_STORE_ROOT" => root
      ) do
        assert_equal 5, Hive::Attempts::Context.current.task_generation
        assert_equal "generation-env", Hive::Attempts::Context.current.ownership_generation
      end
    end
  end

  def test_unverified_environment_does_not_enable_internal_mode
    with_env(
      "HIVE_ATTEMPT_INTERNAL" => "1",
      "HIVE_ATTEMPT_ID" => "missing",
      "HIVE_ATTEMPT_STORE_ROOT" => File.join(Dir.tmpdir, "missing-attempt-store")
    ) do
      refute Hive::Attempts::Context.active?
      assert_empty Hive::Attempts::Context.projection
    end
  end

  def test_store_errors_fail_closed
    broken_store = Object.new
    broken_store.define_singleton_method(:fetch) { |_id| raise Hive::Error, "broken" }
    with_replaced_singleton_method(Hive::Attempts::Store, :new, ->(**_kwargs) { broken_store }) do
      with_env(
        "HIVE_ATTEMPT_INTERNAL" => "1",
        "HIVE_ATTEMPT_ID" => "attempt",
        "HIVE_ATTEMPT_STORE_ROOT" => "/tmp/attempts"
      ) do
        assert_nil Hive::Attempts::Context.current
      end
    end
  end

  def test_context_rejects_non_numeric_or_negative_epochs
    assert_raises(ArgumentError) do
      Hive::Attempts::Context.new(attempt_id: "attempt", task_generation: "opaque")
    end
    assert_raises(ArgumentError) do
      Hive::Attempts::Context.new(attempt_id: "attempt", task_generation: -1)
    end
  end
end
