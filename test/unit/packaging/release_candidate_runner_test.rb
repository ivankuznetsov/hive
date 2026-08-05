require "test_helper"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateRunnerTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__).freeze

  def test_runner_keeps_the_exact_public_facade
    assert_equal(
      [
        [ :keyreq, :repo_root ],
        [ :key, :runs_root ],
        [ :key, :gate_executor ],
        [ :key, :upgrade_executor ],
        [ :key, :sandbox ],
        [ :key, :remote_client ]
      ],
      HiveReleaseCandidate::Runner.instance_method(:initialize).parameters
    )
    assert_equal(
      %i[collect dispatch inspect list plan registry repo_root repository rerun resume run runs_root],
      HiveReleaseCandidate::Runner.public_instance_methods(false).sort
    )
  end

  def test_runner_composes_the_release_candidate_collaborators
    runner = HiveReleaseCandidate::Runner.new(repo_root: ROOT)

    assert_instance_of HiveReleaseCandidate::Repository, runner.repository
    assert_instance_of HiveReleaseCandidate::GateRegistry, runner.registry
    assert_instance_of HiveReleaseCandidate::BaselineCache,
                       runner.instance_variable_get(:@baseline_cache)
    assert_instance_of HiveReleaseCandidate::GateExecution,
                       runner.instance_variable_get(:@gate_execution)
    assert_instance_of HiveReleaseCandidate::LocalAttempt,
                       runner.instance_variable_get(:@local_attempt)
    assert_instance_of HiveReleaseCandidate::RemoteRun,
                       runner.instance_variable_get(:@remote_run)
  end

  def test_repository_appends_extracted_collaborators_to_tool_inputs
    repository = HiveReleaseCandidate::Repository.new(ROOT)
    sha = repository.resolve_sha

    assert_equal(
      %w[
        packaging/release_candidate/repository.rb
        packaging/release_candidate/local_attempt.rb
        packaging/release_candidate/remote_run.rb
        packaging/release_candidate/gate_execution.rb
        packaging/release_candidate/baseline_cache.rb
      ],
      repository.inputs(sha).dig("tool", "paths").last(5)
    )
  end
end
