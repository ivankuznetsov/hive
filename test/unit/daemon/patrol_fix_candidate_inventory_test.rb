require "test_helper"
require "fileutils"
require "json"
require "hive/daemon/patrol_fix_candidate_inventory"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/task_manifest"

class HiveDaemonPatrolFixCandidateInventoryTest < Minitest::Test
  include HiveTestHelper

  HEAD = "a" * 40

  def test_pages_more_than_sixty_four_owned_candidates_but_binds_the_complete_inventory
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      70.times do |index|
        write_manifest(hive_state, slug: format("repair-%03d", index),
                       path: "lib/other/#{index}.rb", evidence: "Unrelated root #{index}")
      end
      write_manifest(hive_state, slug: "repair-refresh-root",
                     path: "lib/session/refresh.rb", evidence: "Refresh token race")

      inventory = Hive::Daemon::PatrolFixCandidateInventory.new(hive_state_path: hive_state)
      first = inventory.call(source_snapshot)

      assert_equal 71, first.fetch("inventory_count")
      assert_operator first.fetch("candidates").length, :<=, 64
      assert_includes first.fetch("candidates").map { |item| item.fetch("identity") },
                      "repair-refresh-root"
      assert first.fetch("truncated")
      assert_match(/\A[0-9a-f]{64}\z/, first.fetch("inventory_digest"))

      store = Hive::PatrolFix::AdmissionStore.new(root: File.join(hive_state, "admissions"))
      store.reserve!(occurrence_id: "finding-new", snapshot: source_snapshot)
      prepared = store.prepare_decision!(
        "finding-new", candidates: first.fetch("candidates"), current_head: HEAD,
        inventory: {
          "count" => first.fetch("inventory_count"),
          "digest" => first.fetch("inventory_digest"),
          "context_digest" => first.fetch("context_digest"),
          "truncated" => first.fetch("truncated")
        }
      )
      assert_equal first.fetch("context_digest"),
                   prepared.dig("candidate_inventory", "context_digest")

      write_manifest(hive_state, slug: "repair-new-root",
                     path: "lib/new.rb", evidence: "A newly owned candidate")
      second = inventory.call(source_snapshot)

      assert_equal 72, second.fetch("inventory_count")
      refute_equal first.fetch("inventory_digest"), second.fetch("inventory_digest")
    end
  end

  def test_ignores_unrelated_task_metadata_but_fails_on_owned_manifest_corruption
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      unrelated = File.join(hive_state, "stages", "2-fix", "ordinary-task")
      FileUtils.mkdir_p(unrelated)
      File.binwrite(File.join(unrelated, "meta.yml"), "not: [valid")
      write_manifest(hive_state, slug: "repair-refresh-root",
                     path: "lib/session/refresh.rb", evidence: "Refresh token race")
      inventory = Hive::Daemon::PatrolFixCandidateInventory.new(hive_state_path: hive_state)

      assert_equal 1, inventory.call(source_snapshot).fetch("inventory_count")

      owned = File.join(hive_state, "stages", "2-fix", "repair-refresh-root",
                        Hive::PatrolFix::TaskManifest::FILENAME)
      File.binwrite(owned, "{broken")
      error = assert_raises(Hive::Daemon::PatrolFixCandidateInventory::InvalidInventory) do
        inventory.call(source_snapshot)
      end
      assert_match(/owned Patrol Fix manifest/i, error.message)
    end
  end

  def test_candidate_context_and_manifest_bytes_are_digest_bound_and_strictly_bounded
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      write_manifest(hive_state, slug: "repair-refresh-root",
                     path: "lib/session/refresh.rb", evidence: "Refresh token race",
                     remediation: "Consolidate refresh ownership")
      inventory = Hive::Daemon::PatrolFixCandidateInventory.new(hive_state_path: hive_state)

      result = inventory.call(source_snapshot)
      candidate = result.fetch("candidates").fetch(0)

      assert_equal %w[
        affected_code context_digest evidence evidence_digest identity kind
        manifest_digest remediation target_revision
      ], candidate.keys.sort
      assert_equal [ "lib/session/refresh.rb" ], candidate.fetch("affected_code")
      assert_equal [ "Refresh token race" ], candidate.fetch("evidence")
      assert_equal "Consolidate refresh ownership", candidate.fetch("remediation")
      assert_operator Hive::PatrolFix.canonical_json(candidate).bytesize, :<=,
                      Hive::Daemon::PatrolFixCandidateInventory::MAX_CANDIDATE_BYTES

      path = File.join(hive_state, "stages", "2-fix", "repair-refresh-root",
                       Hive::PatrolFix::TaskManifest::FILENAME)
      document = JSON.parse(File.binread(path))
      document.fetch("sources").fetch(0)["reproduction_guidance"] = "Use one refresh owner"
      File.binwrite(path, Hive::PatrolFix.canonical_json(document))
      changed = inventory.call(source_snapshot)

      refute_equal result.fetch("inventory_digest"), changed.fetch("inventory_digest")
      refute_equal candidate.fetch("manifest_digest"),
                   changed.fetch("candidates").fetch(0).fetch("manifest_digest")
      refute_equal candidate.fetch("context_digest"),
                   changed.fetch("candidates").fetch(0).fetch("context_digest")
    end
  end

  def test_multibyte_candidate_context_remains_valid_utf8_inside_exact_byte_bounds
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      write_manifest(
        hive_state, slug: "repair-unicode", path: "lib/unicode.rb",
        evidence: ("a" * 767) + "é", remediation: ("a" * 1_535) + "界"
      )

      candidate = Hive::Daemon::PatrolFixCandidateInventory.new(
        hive_state_path: hive_state
      ).call(source_snapshot).fetch("candidates").fetch(0)

      assert candidate.fetch("evidence").first.valid_encoding?
      assert_operator candidate.fetch("evidence").first.bytesize, :<=, 768
      assert candidate.fetch("remediation").valid_encoding?
      assert_operator candidate.fetch("remediation").bytesize, :<=, 1_536
    end
  end

  private

  def write_manifest(hive_state, slug:, path:, evidence:, remediation: "Apply a focused repair")
    folder = File.join(hive_state, "stages", "2-fix", slug)
    FileUtils.mkdir_p(folder)
    Hive::PatrolFix::TaskManifest.new(task_folder: folder).write!(
      "schema" => Hive::PatrolFix::TaskManifest::SCHEMA,
      "schema_version" => Hive::PatrolFix::TaskManifest::SCHEMA_VERSION,
      "task" => { "slug" => slug, "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => Digest::SHA256.hexdigest(slug) },
      "target_revision" => HEAD,
      "sources" => [ {
        "engine" => "ordinary_patrol", "identity" => "finding:#{slug}",
        "target_revision" => HEAD, "evidence" => [ evidence ],
        "affected_code" => [ path ], "reproduction_guidance" => remediation,
        "discovery_run" => "run:#{slug}", "semantic_lineage" => [ "lineage:#{slug}" ]
      } ],
      "aliases" => [], "relations" => { "successor" => nil, "issues" => [] }
    )
  end

  def source_snapshot
    Hive::PatrolFix::SourceSnapshot.build(
      engine: "ordinary_patrol", identity: "finding:new-refresh", title: "Refresh fails",
      summary: "Refresh tokens race during recovery", target_revision: HEAD,
      evidence: [ "Refresh token race is reachable" ],
      affected_code: [ "lib/session/refresh.rb" ],
      reproduction_guidance: "Run refresh recovery specs", discovery_run: "run:new",
      semantic_lineage: [ "lineage:new" ], aliases: [], external_issues: [],
      existing_pull_requests: [], accepted_at: Time.utc(2026, 8, 21, 12).iso8601
    )
  end
end
