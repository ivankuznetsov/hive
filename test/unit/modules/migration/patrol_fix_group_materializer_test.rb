require "test_helper"
require "hive/commands/init"
require "hive/modules/migration/patrol_fix_group_materializer"
require "hive/patrol_fix/migration/disposition_manifest"
require "hive/patrol_fix/source_snapshot"

class PatrolFixGroupMaterializerTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 8, 21, 12)

  class SourceAuthority
    def initialize(snapshots) = @snapshots = snapshots
    def snapshot_for(member, group:) = @snapshots.fetch(member)
  end

  def test_materializes_all_group_aliases_before_source_acknowledgement
    with_project do |project|
      snapshots = {
        "ordinary_finding:finding-1" => snapshot("ordinary_patrol", "finding-1"),
        "architecture_finding:job-1:thesis-1" =>
          snapshot("architecture_patrol", "job-1:thesis-1")
      }
      manifest = manifest_for(snapshots.keys, route: "create_or_attach_inbox")
      materializer = build_materializer(project, manifest, snapshots)

      binding = materializer.call(manifest.to_h.fetch("semantic_groups").first)
      task = task_folder(project, binding.fetch("slug"))
      document = Hive::PatrolFix::TaskManifest.new(task_folder: task).read

      assert_equal %w[architecture_patrol ordinary_patrol],
                   document.fetch("sources").map { |source| source.fetch("engine") }.sort
      snapshots.each_key do |member|
        record = admission_record(project, manifest, member)
        assert_equal "bound", record.fetch("status")
        materializer.record_source_acknowledgement!(
          member, task: binding, receipt_id: "source:#{Digest::SHA256.hexdigest(member)}",
          now: NOW
        )
        assert_equal "acknowledged", admission_record(project, manifest, member).fetch("status")
      end
    end
  end

  def test_exact_existing_pr_imports_done_and_replay_commits_same_task
    with_project do |project|
      member = "ordinary_finding:finding-1"
      publication = exact_publication
      snapshots = { member => snapshot(
        "ordinary_patrol", "finding-1", existing_pull_requests: [ publication ]
      ) }
      manifest = manifest_for(
        [ member ], route: "done_existing_pr",
        canonical_identity: publication.fetch("id"), publication: publication
      )
      materializer = build_materializer(project, manifest, snapshots)
      group = manifest.to_h.fetch("semantic_groups").first

      first = materializer.call(group)
      second = materializer.call(group)

      assert_equal first, second
      done = File.join(project, ".hive-state", "stages", "6-done", first.fetch("slug"))
      assert File.directory?(done)
      assert Hive::PatrolFix::ReceiptStore.new(task_folder: done).read_all.any? do |receipt|
        receipt.fetch("kind") == "publication"
      end
      assert_equal 1, Dir.glob(File.join(project, ".hive-state", "stages", "*", first.fetch("slug"))).length
    end
  end

  private

  def with_project
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        yield project
      end
    end
  end

  def build_materializer(project, manifest, snapshots)
    Hive::Modules::Migration::PatrolFixGroupMaterializer.new(
      project_root: project, hive_state_path: File.join(project, ".hive-state"),
      manifest: manifest, source_authority: SourceAuthority.new(snapshots),
      clock: -> { NOW }
    )
  end

  def snapshot(engine, identity, existing_pull_requests: [])
    Hive::PatrolFix::SourceSnapshot.build(
      engine: engine, identity: identity, title: "Repair refresh handling",
      summary: "Refresh can leave state inconsistent.", target_revision: "a" * 40,
      evidence: [ "The refresh path can fail after mutation." ],
      affected_code: [ "lib/refresh.rb" ],
      reproduction_guidance: "Exercise the failing refresh path.",
      discovery_run: "migration-run", semantic_lineage: [ "shared-root" ],
      aliases: [], external_issues: [], existing_pull_requests: existing_pull_requests,
      accepted_at: NOW.iso8601
    )
  end

  def manifest_for(members, route:, canonical_identity: nil, publication: nil)
    candidates = members.map.with_index do |member, index|
      kind, id = member.split(":", 2)
      observations = if publication
        [ {
          "kind" => "pull_request", "identity" => publication.fetch("id"),
          "state" => publication.fetch("state"), "match" => "exact",
          "canonical_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(publication)),
          "details" => { "publication" => publication }
        } ]
      else
        []
      end
      {
        "source_kind" => kind, "source_id" => id,
        "source_schema" => "example/v1", "canonical_digest" => (index + 1).to_s * 64,
        "authority_state" => "accepted", "semantic_root" => "shared-root",
        "observations" => observations, "blocking_reason" => nil
      }
    end
    digest = Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
      members.sort.map do |member|
        candidate = candidates.find do |entry|
          "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}" == member
        end
        [ member, candidate.fetch("canonical_digest") ]
      end
    ))
    group = {
      "group_id" => "group-#{'a' * 32}", "candidate_set_digest" => digest,
      "members" => members.sort, "canonical_source" => members.sort.first,
      "semantic_decision" => {},
      "canonical_decision" => {
        "route" => route, "canonical_identity" => canonical_identity,
        "planned_mutations" => [],
        "observation_ids" => publication ? [ publication.fetch("id") ] : []
      }
    }
    dispositions = candidates.map do |candidate|
      candidate.slice("source_kind", "source_id", "source_schema", "canonical_digest").merge(
        "group_id" => group.fetch("group_id"), "route" => route,
        "canonical_identity" => canonical_identity, "blocking_reason" => nil
      )
    end
    observations = publication ? [ {
      "group_id" => group.fetch("group_id"), "kind" => "pull_request",
      "identity" => publication.fetch("id"),
      "canonical_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(publication)),
      "route" => "adopt_read_only"
    } ] : []
    Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: {
        "candidates" => candidates, "count" => candidates.length,
        "root_digest" => Hive::PatrolFix::Migration::DispositionManifest.inventory_root(candidates),
        "opaque_v3" => {
          "count" => 0,
          "root_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json([])),
          "entries" => []
        }
      },
      reconciliation: {
        "groups" => [ group ], "dispositions" => dispositions,
        "observation_dispositions" => observations
      }
    )
  end

  def admission_record(project, manifest, member)
    group = manifest.to_h.fetch("semantic_groups").first
    id = "migration-#{Digest::SHA256.hexdigest([ group.fetch('group_id'), member ].join("\0"))}"
    Hive::PatrolFix::AdmissionStore.new(
      root: File.join(project, ".hive-state", "patrol-fix", "admissions")
    ).fetch(id)
  end

  def task_folder(project, slug)
    Dir.glob(File.join(project, ".hive-state", "stages", "*", slug)).fetch(0)
  end

  def exact_publication
    {
      "id" => "github:acme/demo#42", "publication_id" => "pub-#{'7' * 32}",
      "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
      "host" => "github.com", "repository" => "acme/demo", "base_branch" => "main",
      "creation_base_revision" => "a" * 40, "branch" => "hive/patrol-fix",
      "head_revision" => "b" * 40, "diff_digest" => "c" * 64,
      "title_digest" => "d" * 64, "body_digest" => "e" * 64,
      "marker_digest" => "f" * 64, "state" => "closed",
      "observed_at" => NOW.iso8601
    }
  end
end
