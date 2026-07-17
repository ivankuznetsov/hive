require "test_helper"
require "hive/babysitter/job"

class BabysitterJobTest < Minitest::Test
  def test_identity_is_stable_across_repository_and_url_spellings
    first = Hive::Babysitter::Job.identity(
      project: "Demo", task_id: 42, task_slug: "durable-task", task_generation: 3,
      repository: "git@github.com:Acme/Demo.git", pr_number: 12
    )
    second = Hive::Babysitter::Job.identity(
      project: "demo", task_id: "42", task_slug: "durable-task", task_generation: 3,
      repository: "https://github.com/acme/demo", pr_number: 12
    )

    assert_equal first, second
    assert_equal "github.com/acme/demo", first.fetch("repository")
    assert_equal Hive::Babysitter::Job.job_id(first), Hive::Babysitter::Job.job_id(second)
    assert_match(/\Absj-v1-[0-9a-f]{32}\z/, Hive::Babysitter::Job.job_id(first))
  end

  def test_identity_rejects_ambiguous_fields
    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.identity(
        project: "demo", task_id: nil, task_slug: "task", task_generation: -1,
        repository: "not a repository", pr_number: 0
      )
    end
  end

  def test_identity_rejects_invalid_generations_and_pr_numbers
    base = {
      project: "demo", task_id: 42, task_slug: "task", task_generation: 1,
      repository: "github.com/acme/demo", pr_number: 12
    }

    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.identity(**base.merge(task_generation: "1"))
    end
    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.identity(**base.merge(pr_number: 0))
    end
  end

  def test_job_id_requires_every_identity_coordinate
    error = assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.job_id(valid_identity.reject { |key, _value| key == "project" })
    end

    assert_includes error.message, "project"
  end

  def test_record_validation_rejects_structural_and_scalar_corruption
    record = valid_record

    assert_invalid(record.merge("surprise" => true), "top-level")
    assert_invalid(record.merge("schema_version" => 99), "schema")
    assert_invalid(record.merge("identity" => record.fetch("identity").merge("extra" => true)), "identity")
    assert_invalid(record.merge("head_generation" => 0), "head_generation")
    assert_invalid(record.merge("updated_at" => "not-time"), "invalid babysitter job")
  end

  def test_claim_validation_rejects_bad_shape_and_fence
    assert_invalid(valid_record.merge("claims" => [ { "owner" => "daemon" } ]), "claim")

    claim = {
      "owner" => "daemon", "owner_pid" => nil, "owner_process_start_time" => nil,
      "claim_fence" => 0, "state" => "active",
      "claimed_at" => "2026-07-17T00:00:00Z", "heartbeat_at" => "2026-07-17T00:00:00Z",
      "expires_at" => "2026-07-17T00:05:00Z", "finished_at" => nil, "outcome" => nil
    }
    assert_invalid(valid_record.merge("claims" => [ claim ]), "fence")
  end

  def test_pr_url_and_sha_must_match_the_canonical_identity
    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.normalize_pr_url("https://github.com/acme/other/pull/12", valid_identity)
    end
    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.normalize_pr_url("https://[invalid", valid_identity)
    end
    assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.validate_sha!("not-a-sha")
    end
  end

  private

  def valid_identity
    Hive::Babysitter::Job.identity(
      project: "demo", task_id: 42, task_slug: "task", task_generation: 1,
      repository: "github.com/acme/demo", pr_number: 12
    )
  end

  def valid_record
    Hive::Babysitter::Job.build(
      identity: valid_identity, pr_url: "https://github.com/acme/demo/pull/12",
      branch: "feature/task", task_folder: "/tmp/task", head_sha: "a" * 40,
      head_generation: 1, finalize_attempt_id: "attempt-1", now: Time.utc(2026, 7, 17)
    )
  end

  def assert_invalid(record, message)
    error = assert_raises(Hive::Babysitter::Job::Invalid) do
      Hive::Babysitter::Job.validate!(record)
    end
    assert_includes error.message, message
  end
end
