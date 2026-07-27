require "test_helper"
require_relative "../../../packaging/release_candidate/remote_workflow"

class ReleaseCandidateRemoteWorkflowTest < Minitest::Test
  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ACTION_LOCK = "c" * 64

  FakeClient = Struct.new(:runs, :dispatches, keyword_init: true) do
    def repository
      { "full_name" => "ivankuznetsov/hive", "default_branch" => "main" }
    end

    def branch(_name)
      { "name" => "main", "protected" => true }
    end

    def comparison(base:, head:)
      { "status" => "behind", "base_sha" => base, "head_sha" => head }
    end

    def workflow(_path)
      {
        "path" => ".github/workflows/release-candidate.yml",
        "state" => "active", "revision" => WORKFLOW_SHA
      }
    end

    def dispatch_workflow(path:, ref:, inputs:)
      dispatches << { path: path, ref: ref, inputs: inputs }
      true
    end

    def workflow_runs(_path)
      runs
    end

    def run(run_id)
      runs.find { |row| row["id"] == run_id }
    end

    def artifacts(run_id)
      {
        "artifacts" => [ {
          "id" => 77, "name" => "hive-release-candidate-#{run_id}-2",
          "expired" => false, "digest" => "sha256:#{'d' * 64}",
          "workflow_run" => { "id" => run_id, "head_sha" => WORKFLOW_SHA }
        } ]
      }
    end
  end

  def test_dispatch_resolves_exact_request_run
    client = FakeClient.new(runs: [ workflow_run("req-abc123", status: "queued") ], dispatches: [])
    result = workflow(client).dispatch(request_id: "req-abc123")

    assert_equal "queued", result.fetch("status")
    assert_equal 42, result.fetch("run_id")
    assert_equal "req-abc123", client.dispatches.one?.then { client.dispatches.first[:inputs]["request_id"] }
    assert_equal false, result.fetch("release_action_performed")
  end

  def test_dispatch_returns_dispatched_unresolved_after_bounded_resolution
    client = FakeClient.new(runs: [], dispatches: [])
    sleeps = 0
    result = workflow(client, sleeper: ->(_seconds) { sleeps += 1 }).dispatch(
      request_id: "req-abc123", resolution_attempts: 3
    )

    assert_equal "dispatched_unresolved", result.fetch("status")
    assert_equal 2, sleeps
    assert_equal [
      "bin/hive-release-candidate", "collect", "--request", "req-abc123"
    ], result.fetch("collect_argv")
  end

  def test_retry_dispatch_preserves_exact_candidate_artifact_producer
    client = FakeClient.new(
      runs: [ workflow_run("req-next12", status: "queued") ], dispatches: []
    )
    source = {
      "candidate_sha" => SHA,
      "workflow_sha" => WORKFLOW_SHA,
      "action_lock_sha256" => ACTION_LOCK,
      "run_id" => 41,
      "run_attempt" => 1,
      "artifact_id" => 77,
      "artifact_digest" => "sha256:#{'d' * 64}",
      "artifact_name" => "hive-release-candidate-31-1",
      "artifact_producer_run_id" => 31,
      "artifact_producer_run_attempt" => 1
    }

    workflow(client).dispatch(
      request_id: "req-next12", source: source,
      selector: { "mode" => "named", "gates" => [ "Catalog integrity" ] }
    )
    inputs = client.dispatches.fetch(0).fetch(:inputs)
    assert_equal "41", inputs.fetch("source_run_id")
    assert_equal "1", inputs.fetch("source_run_attempt")
    assert_equal "31", inputs.fetch("source_artifact_run_id")
    assert_equal "1", inputs.fetch("source_artifact_run_attempt")
    assert_equal "hive-release-candidate-31-1", inputs.fetch("source_artifact_name")
  end

  def test_collect_chained_retry_resolves_original_artifact_from_terminal_evidence
    client = FakeClient.new(
      runs: [ workflow_run("req-chain1", status: "completed", conclusion: "failure") ],
      dispatches: []
    )
    client.define_singleton_method(:artifacts) do |run_id|
      {
        "artifacts" => [ {
          "id" => 88,
          "name" => "hive-release-candidate-evidence-#{run_id}-2",
          "expired" => false
        } ]
      }
    end
    client.define_singleton_method(:evidence) do |run_id, run_attempt|
      {
        "trust_scope" => "trusted_remote",
        "request_id" => "req-chain1",
        "candidate_sha" => SHA,
        "workflow_sha" => WORKFLOW_SHA,
        "run_id" => run_id,
        "run_attempt" => run_attempt,
        "action_lock_sha256" => ACTION_LOCK,
        "artifact" => {
          "id" => 77,
          "digest" => "sha256:#{'d' * 64}",
          "name" => "hive-release-candidate-31-1",
          "producer_run_id" => 31,
          "producer_run_attempt" => 1
        }
      }
    end
    client.define_singleton_method(:artifact) do |_artifact_id|
      {
        "id" => 77,
        "name" => "hive-release-candidate-31-1",
        "expired" => false,
        "digest" => "sha256:#{'d' * 64}",
        "workflow_run" => { "id" => 31, "head_sha" => WORKFLOW_SHA }
      }
    end

    result = workflow(client).collect(request_id: "req-chain1")
    assert_equal "terminal", result.fetch("status")
    assert_equal 31, result.dig("artifact", "artifact_producer_run_id")
    assert_equal "hive-release-candidate-31-1", result.dig("artifact", "artifact_name")
  end

  def test_collect_reports_queued_running_terminal_not_found_ambiguous_and_timeout
    client = FakeClient.new(runs: [], dispatches: [])
    assert_equal "not_found", workflow(client).collect(request_id: "req-abc123").fetch("status")

    client.runs = [ workflow_run("req-abc123", status: "queued") ]
    assert_equal "queued", workflow(client).collect(request_id: "req-abc123").fetch("status")

    client.runs = [ workflow_run("req-abc123", status: "in_progress") ]
    assert_equal "running", workflow(client).collect(request_id: "req-abc123").fetch("status")

    client.runs = [ workflow_run("req-abc123", status: "completed", conclusion: "success") ]
    terminal = workflow(client).collect(request_id: "req-abc123")
    assert_equal "terminal", terminal.fetch("status")
    assert_equal 77, terminal.dig("artifact", "artifact_id")

    client.runs = [
      workflow_run("req-abc123"),
      workflow_run("req-abc123").merge("id" => 43)
    ]
    assert_equal "ambiguous", workflow(client).collect(request_id: "req-abc123").fetch("status")

    client.runs = [ workflow_run("req-abc123", status: "queued") ]
    ticks = [ 0, 2 ]
    result = workflow(
      client, sleeper: ->(_seconds) { },
      monotonic_clock: -> { ticks.shift || 2 }
    ).collect(
      request_id: "req-abc123", wait: true, timeout: 1
    )
    assert_equal "timeout", result.fetch("status")
  end

  private

  def workflow(client, sleeper: ->(_seconds) { }, monotonic_clock: -> { 0 })
    identity = HiveReleaseCandidate::RemoteIdentity.new(
      repository: "ivankuznetsov/hive", candidate_sha: SHA,
      workflow_sha: WORKFLOW_SHA, action_lock_sha256: ACTION_LOCK
    )
    HiveReleaseCandidate::RemoteWorkflow.new(
      identity: identity, client: client, sleeper: sleeper,
      monotonic_clock: monotonic_clock
    )
  end

  def workflow_run(request_id, status: "queued", conclusion: nil)
    {
      "id" => 42, "run_attempt" => 2,
      "name" => "hive-release-candidate:#{request_id}:#{SHA}",
      "event" => "workflow_dispatch", "status" => status, "conclusion" => conclusion,
      "head_sha" => WORKFLOW_SHA, "head_branch" => "main",
      "path" => ".github/workflows/release-candidate.yml",
      "head_repository" => { "full_name" => "ivankuznetsov/hive" }
    }
  end
end
