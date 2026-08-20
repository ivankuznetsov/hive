require "test_helper"
require "hive/refactor_patrol/migration_inventory"

class RefactorPatrolMigrationInventoryTest < Minitest::Test
  include HiveTestHelper

  class Store
    attr_reader :root

    def initialize(root, entries)
      @root = root
      @entries = entries
    end

    def patrol_fix_migration_page(limit:, cursor: nil)
      raise "unexpected cursor" if cursor
      raise "unexpected limit" unless limit == 10
      {
        "entries" => @entries, "next_cursor" => nil,
        "snapshot_token" => "f" * 64
      }
    end
  end

  def test_translates_job_actions_claims_patches_intents_prs_and_issues
    with_tmp_dir do |dir|
      root = File.join(dir, "refactor_patrol", "v4")
      entry = {
        "source_id" => "job-1", "source_schema" => "hive-refactor-patrol-job/v4",
        "canonical_digest" => "a" * 64, "record" => aggregate, "error" => nil
      }
      port = Hive::RefactorPatrol::MigrationInventory.new(Store.new(root, [ entry ]))

      candidate = port.migration_page(limit: 10).fetch("entries").fetch(0)

      assert_equal "architecture_finding", candidate.fetch("source_kind")
      assert_equal "job-1:thesis-1", candidate.fetch("source_id")
      assert_equal "claimed", candidate.fetch("authority_state")
      assert_equal "shared-root", candidate.fetch("semantic_root")
      kinds = candidate.fetch("observations").map { |item| item.fetch("kind") }
      %w[
        architecture_job branch canonical_action claim coding_task issue
        publication_intent pull_request validated_patch
      ].each { |kind| assert_includes kinds, kind }
    end
  end

  def test_opaque_v3_inventory_counts_raw_bytes_without_parsing_or_rewriting
    with_tmp_dir do |dir|
      root = File.join(dir, "refactor_patrol", "v4")
      v3 = File.join(dir, "refactor_patrol", "v3")
      FileUtils.mkdir_p(File.join(v3, "jobs"))
      path = File.join(v3, "jobs", "legacy.json")
      bytes = "{not-json\x00opaque".b
      File.binwrite(path, bytes)
      port = Hive::RefactorPatrol::MigrationInventory.new(Store.new(root, []))

      entries = port.opaque_v3_entries

      assert_equal 1, entries.length
      assert_equal "jobs/legacy.json", entries.first.fetch("source_id")
      assert_equal Digest::SHA256.hexdigest(bytes),
                   entries.first.fetch("canonical_digest")
      assert_equal bytes, File.binread(path)
    end
  end

  def test_each_finding_receives_only_its_own_action_artifacts
    with_tmp_dir do |dir|
      root = File.join(dir, "refactor_patrol", "v4")
      value = aggregate
      value.fetch("dispositions").fetch("fix") << {
        "id" => "thesis-2", "route" => "fix", "admissible" => true,
        "fingerprint" => "other-root"
      }
      value.fetch("actions") << value.fetch("actions").first.merge(
        "canonical_action_id" => "fix-2",
        "thesis_id" => "thesis-2",
        "thesis_fingerprint" => "other-root",
        "receipts" => { "pr_url" => "https://github.com/acme/demo/pull/43" }
      )
      entry = {
        "source_id" => "job-1", "source_schema" => "hive-refactor-patrol-job/v4",
        "canonical_digest" => "a" * 64, "record" => value, "error" => nil
      }
      port = Hive::RefactorPatrol::MigrationInventory.new(Store.new(root, [ entry ]))

      candidates = port.migration_page(limit: 10).fetch("entries")
      pr_by_source = candidates.to_h do |candidate|
        urls = candidate.fetch("observations").filter_map do |observation|
          observation.fetch("identity") if observation.fetch("kind") == "pull_request"
        end
        [ candidate.fetch("source_id"), urls ]
      end

      assert_equal [ "https://github.com/acme/demo/pull/42" ],
                   pr_by_source.fetch("job-1:thesis-1")
      assert_equal [ "https://github.com/acme/demo/pull/43" ],
                   pr_by_source.fetch("job-1:thesis-2")
    end
  end

  private

  def aggregate
    {
      "job_id" => "job-1", "state" => "acting", "complete" => false,
      "dispositions" => {
        "fix" => [
          {
            "id" => "thesis-1", "route" => "fix", "admissible" => true,
            "fingerprint" => "shared-root"
          }
        ],
        "discuss" => [], "dismiss" => []
      },
      "attempts" => [
        { "kind" => "discovery_claim", "generation" => 1, "state" => "running" }
      ],
      "actions" => [
        {
          "canonical_action_id" => "fix-1", "terminal" => true,
          "thesis_id" => "thesis-1", "thesis_fingerprint" => "shared-root",
          "outcome" => "pr_opened", "claims" => [],
          "receipts" => {
            "pr_url" => "https://github.com/acme/demo/pull/42",
            "issue_url" => "https://github.com/acme/demo/issues/41",
            "review_task_path" => "/tmp/review-task",
            "patch" => { "branch" => "hive/patrol-fix-1", "head" => "b" * 40 },
            "publication_attempts" => [ { "phase" => "pr_create_intent" } ]
          }
        }
      ]
    }
  end
end
