require "test_helper"
require "support/task_projection_replay"
require "hive/gh"
require "hive/git_ops"
require "open3"

class TaskProjectionReplayTest < Minitest::Test
  include HiveTestHelper

  FIXTURES = File.expand_path("../fixtures/incidents", __dir__)
  TASK_1849 = File.join(FIXTURES, "task-1849")

  def test_1849_new_attempt_and_head_own_current_gate_while_old_wait_is_historical
    result = replay(TASK_1849).replay

    assert_equal "attempt-b", result.canonical.dig("identity", "attempt_id")
    assert_equal "b" * 40, result.canonical.dig("identity", "head_sha")
    assert_equal "satisfied",
                 result.canonical.dig("current_conditions", "ChangesPresent", "state")
    assert_equal "attempt-b",
                 result.canonical.dig("current_conditions", "ChangesPresent", "attempt_id")
    wait = result.canonical.fetch("history").find { |fact| fact["event_id"] == "1849-a-wait" }
    assert_equal "superseded", wait.fetch("state")
    assert_equal "satisfied", wait.fetch("original_state")
    assert_equal "newer_incompatible_attempt", wait.fetch("superseded_reason")
    assert_equal "eligible", result.canonical.dig("gate", "status")
  end

  def test_missing_corrupt_and_stale_snapshots_replay_identically_without_live_observation
    sentinels = [
      [ Hive::GitOps, :new ],
      [ Hive::Gh, :pr_frontmatter ],
      [ Open3, :capture3 ]
    ]
    run = lambda do
      expected = replay(TASK_1849).replay(snapshot: :missing).canonical
      assert_equal expected, replay(TASK_1849).replay(snapshot: :corrupt).canonical
      assert_equal expected, replay(TASK_1849).replay(snapshot: :stale).canonical
    end

    with_sentinels(sentinels, 0, run)
  end

  def test_journal_reordering_is_rejected_by_fixture_digest_contract
    error = assert_raises(HiveTestSupport::TaskProjectionReplay::InvalidFixture) do
      replay(TASK_1849).replay(shuffle: true)
    end
    assert_match(/digest mismatch for task-journal\.jsonl/, error.message)
  end

  def test_synthetic_events_require_declared_source_provenance
    with_tmp_dir do |dir|
      bundle = File.join(dir, "task-1849")
      FileUtils.cp_r(TASK_1849, bundle)
      journal = File.join(bundle, "task-journal.jsonl")
      content = File.read(journal).sub(
        '"source":"incident_reconstruction","synthetic":true',
        '"source":"","synthetic":true'
      )
      File.write(journal, content)
      manifest_path = File.join(bundle, "manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest.fetch("files")["task-journal.jsonl"] = ::Digest::SHA256.file(journal).hexdigest
      File.write(manifest_path, JSON.pretty_generate(manifest))

      error = assert_raises(HiveTestSupport::TaskProjectionReplay::InvalidFixture) do
        replay(bundle)
      end
      assert_match(/lacks provenance source/, error.message)
    end
  end

  def test_minimal_second_fixture_uses_the_same_incident_agnostic_contract
    result = replay(File.join(FIXTURES, "sample-current")).replay

    assert_equal "sample-current", result.manifest.fetch("incident")
    assert_equal "sample-attempt", result.canonical.dig("identity", "attempt_id")
    assert_equal "eligible", result.canonical.dig("gate", "status")
  end

  def test_attempt_metadata_independently_rejects_forged_journal_task_identity
    with_tmp_dir do |dir|
      bundle = File.join(dir, "sample-current")
      FileUtils.cp_r(File.join(FIXTURES, "sample-current"), bundle)
      attempts_path = File.join(bundle, "attempts.json")
      attempts = JSON.parse(File.read(attempts_path))
      attempts.fetch("attempts").first["task_slug"] = "different-task"
      File.write(attempts_path, JSON.pretty_generate(attempts))
      manifest_path = File.join(bundle, "manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest.fetch("files")["attempts.json"] = ::Digest::SHA256.file(attempts_path).hexdigest
      File.write(manifest_path, JSON.pretty_generate(manifest))

      assert_raises(Hive::TaskProjection::InvalidJournal) { replay(bundle).replay }
    end
  end

  private

  def replay(path)
    HiveTestSupport::TaskProjectionReplay.new(path)
  end

  def with_sentinels(entries, index, run)
    return run.call if index == entries.length

    owner, method = entries.fetch(index)
    replacement = lambda do |*|
      raise "live observation sentinel invoked: #{owner}.#{method}"
    end
    with_replaced_singleton_method(owner, method, replacement) do
      with_sentinels(entries, index + 1, run)
    end
  end
end
