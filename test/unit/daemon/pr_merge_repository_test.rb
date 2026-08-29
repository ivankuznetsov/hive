require "test_helper"
require "hive/daemon/pr_merge_repository"

class PrMergeRepositoryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)
  TASK_GENERATION = "c" * 64
  MARKER_GENERATION = "d" * 64

  def test_candidate_phases_round_trip_through_typed_rows
    with_repository do |repository, identity, database|
      key = repository.candidate_key(
        project: "hive", slug: "sqlite-cutover", task_generation: TASK_GENERATION,
        pull_request: pull_request
      )
      item = candidate(key)
      repository.upsert_candidate(identity, item, now: NOW)
      loaded = repository.candidates(identity).fetch(0)
      assert_equal "unknown", loaded.dig("remote", "state")
      row = database.read { |db| db[:pr_merge_reconciliations].first }
      assert_equal key, row.fetch(:reconciliation_id)
      assert_equal "task-1", row.fetch(:task_id)
      assert_equal TASK_GENERATION, row.fetch(:task_generation)
      assert_equal "pending", row.fetch(:archive_state)

      item = loaded
      item["remote"]["state"] = "merged"
      item["remote"]["merge_oid"] = "a" * 40
      item["architecture"]["status"] = "accepted"
      item = repository.checkpoint(
        identity, item, expected_task_generation: TASK_GENERATION, now: NOW + 1
      )
      row = database.read { |db| db[:pr_merge_reconciliations].first }
      assert_equal "merged", row.fetch(:state)
      assert_equal "accepted", row.fetch(:architecture_state)

      assert_raises(Hive::ConcurrentRunError) do
        repository.checkpoint(
          identity, item, expected_task_generation: "stale", now: NOW + 2
        )
      end

      stale_identity = Marshal.load(Marshal.dump(item))
      stale_identity["task"]["slug"] = "other-task"
      assert_raises(Hive::ConcurrentRunError) do
        repository.checkpoint(
          identity, stale_identity,
          expected_task_generation: TASK_GENERATION, now: NOW + 3
        )
      end
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      timestamp = NOW.iso8601(6)
      identity = {
        "registration" => "registration-1", "project_path" => root,
        "hive_state_path" => File.join(root, ".hive-state"), "host" => "github.com",
        "repository" => "hivecli/hive", "default_branch" => "main"
      }
      database.transaction do |db|
        installation = db[:installations].first.fetch(:installation_id)
        db[:projects].insert(
          project_id: "project-1", installation_id: installation,
          registration_id: identity.fetch("registration"), name: "hive",
          observed_path: root, state_root_path: identity.fetch("hive_state_path"),
          active: 1, registered_at: timestamp, last_observed_at: timestamp
        )
        db[:task_subjects].insert(
          task_id: "task-1", project_id: "project-1", workflow_id: "coding",
          task_slug: "sqlite-cutover", observed_path: File.join(root, "task"),
          source_fingerprint: "source-1", generation: 1,
          created_at: timestamp, last_observed_at: timestamp
        )
      end
      yield Hive::Daemon::PrMergeRepository.new(database: database), identity, database
    end
  end

  def pull_request
    {
      "url" => "https://github.com/hivecli/hive/pull/1", "host" => "github.com",
      "repository" => "hivecli/hive", "number" => 1, "observed_head" => "b" * 40
    }
  end

  def candidate(key)
    {
      "key" => key,
      "task" => { "project" => "hive", "slug" => "sqlite-cutover", "id" => 1, "workflow" => "coding", "folder" => "/tmp/task" },
      "observation" => { "stage" => "8-finalize", "marker" => "complete", "marker_generation" => MARKER_GENERATION, "task_generation" => TASK_GENERATION, "state_file_mtime" => NOW.iso8601(6), "held" => false, "hold_reason" => nil },
      "pull_request" => pull_request,
      "remote" => { "state" => "unknown", "merge_oid" => nil, "merged_at" => nil, "observed_at" => nil },
      "architecture" => { "status" => "pending", "request_id" => nil, "receipt" => nil, "last_error" => nil },
      "archive" => { "status" => "pending", "receipt_digest" => nil, "archived_at" => nil, "last_error" => nil },
      "retry" => { "failures" => 0, "not_before" => nil }, "updated_at" => NOW.iso8601(6)
    }
  end
end
