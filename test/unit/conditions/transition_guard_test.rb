require "test_helper"
require "hive/conditions/transition_guard"

class ConditionsTransitionGuardTest < Minitest::Test
  include HiveTestHelper

  def test_closure_guard_accepts_only_the_exact_valid_receipt_digest
    task = Object.new
    calls = []
    validator = lambda do |observed, receipt_digest:, project:|
      calls << [ observed, receipt_digest, project ]
      {
        "type" => "task_closure",
        "receipt_digest" => receipt_digest,
        "evidence_digest" => "b" * 64,
        "reason" => "already_delivered",
        "authority" => "remote_merge"
      }
    end

    with_replaced_singleton_method(Hive::TaskClosure, :transition_evidence, validator) do
      assert Hive::Conditions::TransitionGuard.validate_closure!(
        task, receipt_digest: "a" * 64, project: "app"
      )
    end

    assert_equal [ [ task, "a" * 64, "app" ] ], calls
  end

  def test_closure_guard_fails_closed_for_an_absent_invalid_or_stale_receipt
    validator = ->(*) { nil }

    with_replaced_singleton_method(Hive::TaskClosure, :transition_evidence, validator) do
      error = assert_raises(Hive::TaskClosure::InvalidReceipt) do
        Hive::Conditions::TransitionGuard.validate_closure!(
          Object.new, receipt_digest: "b" * 64, project: "app"
        )
      end
      assert_match(/absent, invalid, or stale/, error.message)
    end
  end

  def test_legacy_task_matches_only_an_attempt_from_its_registered_project
    with_tmp_dir do |root|
      first_root = File.join(root, "first")
      second_root = File.join(root, "second")
      projects = [
        { "name" => "first", "path" => first_root },
        { "name" => "second", "path" => second_root }
      ]
      repository = Object.new
      repository.define_singleton_method(:active_attempts) do
        [ { "project" => "first", "task_slug" => "same-slug", "task_id" => "task-1" } ]
      end
      task_type = Struct.new(:project_root, :slug, :id, keyword_init: true)
      first = task_type.new(project_root: first_root, slug: "same-slug", id: nil)
      second = task_type.new(project_root: second_root, slug: "same-slug", id: nil)

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
        assert Hive::Conditions::TransitionGuard.send(
          :admitted_attempt?, first, repository: repository
        )
        refute Hive::Conditions::TransitionGuard.send(
          :admitted_attempt?, second, repository: repository
        )
      end
    end
  end

  def test_identified_task_requires_the_same_attempt_task_id
    project_root = "/tmp/hive-transition-project"
    projects = [ { "name" => "demo", "path" => project_root } ]
    repository = Object.new
    repository.define_singleton_method(:active_attempts) do
      [ { "project" => "demo", "task_slug" => "task", "task_id" => "other" } ]
    end
    task = Struct.new(:project_root, :slug, :id, keyword_init: true).new(
      project_root: project_root, slug: "task", id: "expected"
    )

    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
      refute Hive::Conditions::TransitionGuard.send(
        :admitted_attempt?, task, repository: repository
      )
    end
  end

  def test_terminal_attempt_waits_for_task_journal_publication
    projection = { "identity" => { "attempt_id" => "attempt-1" } }
    repository = Object.new
    journal_acknowledged = false
    repository.define_singleton_method(:publication) do |_attempt_id|
      { "consumers" => { "journal" => journal_acknowledged } }
    end

    assert Hive::Conditions::TransitionGuard.send(
      :journal_publication_pending?, projection, repository: repository
    )
    journal_acknowledged = true
    refute Hive::Conditions::TransitionGuard.send(
      :journal_publication_pending?, projection, repository: repository
    )
  end
end
