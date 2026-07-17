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
end
