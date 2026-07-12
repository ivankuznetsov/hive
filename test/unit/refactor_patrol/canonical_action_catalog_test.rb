require "test_helper"
require "hive/refactor_patrol/canonical_action_catalog"

class RefactorPatrolCanonicalActionCatalogTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 11, 10, 0, 0)

  def test_rebuilds_terminal_proof_and_recovers_from_deleted_or_corrupt_projection
    with_tmp_dir do |root|
      project = File.join(root, "old")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      catalog = catalog_for(state_home, [ entry("old", project) ])
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")

      first = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      ).fetch(action_id)
      assert_equal "pr_opened", first.fetch("outcome")
      assert_equal "https://github.com/acme/demo/pull/41", first.dig("proof", "pr_url")
      assert File.file?(catalog.path)

      File.delete(catalog.path)
      rebuilt = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
      assert_equal first, rebuilt.fetch(action_id)

      File.write(catalog.path, "{")
      repaired = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
      assert_equal first, repaired.fetch(action_id)
      assert_equal Hive::RefactorPatrol::CanonicalActionCatalog::SCHEMA,
                   JSON.parse(File.read(catalog.path)).fetch("schema")
    end
  end

  def test_nonterminal_actions_are_not_catalogued
    with_tmp_dir do |root|
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      store = terminal_store(project, terminal: false, outcome: "queued")
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      catalog = catalog_for(File.join(root, "state"), [ entry("project", project) ])

      assert_empty catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
    end
  end

  def test_conflicting_terminal_proofs_fail_closed
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      [ one, two ].each { |path| FileUtils.mkdir_p(path) }
      terminal_store(one, registration: "one", pr_url: "https://github.com/acme/demo/pull/41")
      terminal_store(two, registration: "two", pr_url: "https://github.com/acme/demo/pull/42")
      catalog = catalog_for(
        File.join(root, "state"), [ entry("one", one), entry("two", two) ]
      )

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.rebuild!
      end
      refute File.exist?(catalog.path)
    end
  end

  def test_wrong_repository_remote_proof_fails_closed
    with_tmp_dir do |root|
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      terminal_store(project, pr_url: "https://github.com/other/demo/pull/41")
      catalog = catalog_for(File.join(root, "state"), [ entry("project", project) ])

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.rebuild!
      end
    end
  end

  def test_resolves_exact_pr_and_issue_proofs_across_registrations
    with_tmp_dir do |root|
      pr_root = File.join(root, "pr-owner")
      issue_root = File.join(root, "issue-owner")
      [ pr_root, issue_root ].each { |path| FileUtils.mkdir_p(path) }
      pr_store = terminal_store(pr_root, registration: "pr-owner")
      issue_store = terminal_issue_store(issue_root, registration: "issue-owner")
      pr_action_id = pr_store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      issue_action_id = issue_store.read_job("job-issue").dig(
        "actions", 0, "canonical_action_id"
      )
      catalog = catalog_for(
        File.join(root, "state"),
        [ entry("pr-owner", pr_root), entry("issue-owner", issue_root) ]
      )

      proofs = catalog.resolve(
        action_ids: [ issue_action_id, pr_action_id ],
        expected_identity: identity,
        dry_run: false
      )

      assert_equal "https://github.com/acme/demo/pull/41",
                   proofs.dig(pr_action_id, "proof", "pr_url")
      assert_equal "pr-owner", proofs.dig(pr_action_id, "owner", "registration")
      assert_equal "https://github.com/acme/demo/issues/52",
                   proofs.dig(issue_action_id, "proof", "issue_url")
      assert_equal "issue-owner", proofs.dig(issue_action_id, "owner", "registration")
    end
  end

  def test_rejects_a_proof_requested_for_another_repository
    with_tmp_dir do |root|
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      catalog = catalog_for(File.join(root, "state"), [ entry("project", project) ])

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.resolve(
          action_ids: [ action_id ],
          expected_identity: { "host" => "github.com", "repository" => "other/demo" },
          dry_run: false
        )
      end
    end
  end

  def test_foreign_terminal_proof_materializes_locally_and_survives_owner_removal
    with_tmp_dir do |root|
      old_root = File.join(root, "old")
      new_root = File.join(root, "new")
      state_home = File.join(root, "state")
      [ old_root, new_root ].each { |path| FileUtils.mkdir_p(path) }
      old_store = terminal_store(old_root, registration: "old")
      new_store = classified_store(new_root, registration: "new")
      entries = [ entry("old", old_root), entry("new", new_root) ]
      catalog = catalog_for(state_home, entries)
      plan = new_store.plan_actions(
        "job-new", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ]
      )
      action_id = plan.first.fetch("canonical_action_id")
      assert_equal old_store.read_job("job-old").dig("actions", 0, "canonical_action_id"), action_id
      proof = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )

      linked = new_store.initialize_actions!(
        "job-new",
        specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ],
        terminal_proofs: proof,
        now: T0 + 60
      )
      action = linked.fetch("actions").first
      assert linked.fetch("complete")
      assert_equal "pr_opened", action.fetch("outcome")
      assert_equal "old", action.dig("receipts", "canonical_action_link", "owner", "registration")
      assert_equal "https://github.com/acme/demo/pull/41", action.dig("receipts", "pr_url")
      assert_empty action.fetch("claims")

      catalog.rebuild!
      entries.shift
      FileUtils.rm_rf(old_root)
      File.delete(catalog.path)
      rebuilt = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
      assert_equal "old", rebuilt.dig(action_id, "owner", "registration")
    end
  end

  def test_dry_run_reads_proof_without_creating_catalog_files
    with_tmp_dir do |root|
      project = File.join(root, "project")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      catalog = catalog_for(state_home, [ entry("project", project) ])

      result = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: true
      )

      assert_equal "pr_opened", result.fetch(action_id).fetch("outcome")
      refute File.exist?(catalog.path)
      refute Dir.exist?(catalog.root)
      refute Dir.exist?(catalog.archive_root)
    end
  end

  def test_dry_run_does_not_rewrite_an_existing_projection
    with_tmp_dir do |root|
      project = File.join(root, "project")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      entries = [ entry("project", project) ]
      initial_catalog = catalog_for(state_home, entries)
      initial_catalog.rebuild!
      before = File.binread(File.join(state_home, "refactor_patrol", "v2", "indexes",
                                      "canonical-actions.json"))
      archive_path = Dir.glob(File.join(initial_catalog.archive_root, "*.json")).fetch(0)
      archive_before = File.binread(archive_path)

      result = catalog_for(state_home, entries, clock: -> { T0 + 86_400 }).resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: true
      )

      assert_equal "pr_opened", result.fetch(action_id).fetch("outcome")
      assert_equal before, File.binread(File.join(state_home, "refactor_patrol", "v2", "indexes",
                                                "canonical-actions.json"))
      assert_equal archive_before, File.binread(archive_path)
    end
  end

  def test_default_dependencies_rebuild_from_registered_projects
    with_tmp_global_config do |home|
      project = File.join(home, "project")
      FileUtils.mkdir_p(project)
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ { "name" => "project", "path" => project } ] }.to_yaml
      )
      catalog = Hive::RefactorPatrol::CanonicalActionCatalog.new

      catalog.rebuild!

      assert_match(%r{/refactor_patrol/v2/indexes\z}, catalog.root)
    end
  end

  def test_registry_and_store_enumeration_fail_closed
    with_tmp_dir do |root|
      invalid_registry = catalog_for(File.join(root, "state-a"), [ { "name" => "missing" } ])
      raised_registry = catalog_for(
        File.join(root, "state-b"), [], registry: -> { raise "registry unavailable" }
      )
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      unreadable_store = catalog_for(
        File.join(root, "state-c"), [ entry("project", project) ],
        job_store_factory: ->(_path) {
          raise Hive::RefactorPatrol::JobStore::CorruptRecord, "broken aggregate"
        }
      )

      [ invalid_registry, raised_registry, unreadable_store ].each do |catalog|
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofUnresolved) do
          catalog.rebuild!
        end
      end
    end
  end

  def test_existing_projection_requires_a_readable_authoritative_witness
    with_tmp_dir do |root|
      project = File.join(root, "project")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      terminal_store(project)
      entries = [ entry("project", project) ]
      catalog = catalog_for(state_home, entries)
      catalog.rebuild!
      FileUtils.rm_rf(catalog.archive_root)
      entries.clear
      FileUtils.rm_rf(project)

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofUnresolved) do
        catalog.rebuild!
      end
    end
  end

  def test_durable_archive_survives_owner_deregistration_and_projection_loss
    with_tmp_dir do |root|
      project = File.join(root, "owner")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      entries = [ entry("owner", project) ]
      catalog = catalog_for(state_home, entries)
      expected = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      ).fetch(action_id)
      archive_path = File.join(catalog.archive_root, "#{action_id}.json")
      assert File.file?(archive_path)

      entries.clear
      FileUtils.rm_rf(project)
      File.delete(catalog.path)
      after_deletion = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
      assert_equal expected, after_deletion.fetch(action_id)

      File.write(catalog.path, "{")
      after_corruption = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )
      assert_equal expected, after_corruption.fetch(action_id)
    end
  end

  def test_corrupt_archive_fails_closed_when_the_owner_is_gone
    with_tmp_dir do |root|
      project = File.join(root, "owner")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      entries = [ entry("owner", project) ]
      catalog = catalog_for(File.join(root, "state"), entries)
      catalog.rebuild!
      archive_path = File.join(catalog.archive_root, "#{action_id}.json")
      archived = JSON.parse(File.binread(archive_path))
      archived["proof_digest"] = "0" * 64
      File.write(archive_path, "#{JSON.pretty_generate(archived)}\n")
      entries.clear
      FileUtils.rm_rf(project)
      File.delete(catalog.path)

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::CorruptArchive) do
        catalog.resolve(action_ids: [ action_id ], expected_identity: identity, dry_run: false)
      end
      refute File.exist?(catalog.path)
    end
  end

  def test_archive_rejects_nonfiles_unreadable_json_and_invalid_identity_shapes
    with_tmp_dir do |root|
      project = File.join(root, "owner")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      catalog = catalog_for(
        File.join(root, "state"), [ entry("owner", project) ]
      )
      catalog.rebuild!
      archive_path = File.join(catalog.archive_root, "#{action_id}.json")
      original = JSON.parse(File.binread(archive_path))
      variants = [
        "{",
        JSON.generate(original.except("kind")),
        JSON.generate(original.merge("host" => "GITHUB.COM")),
        JSON.generate(original.merge("identity" => "changed-identity"))
      ]
      variants.each do |content|
        File.write(archive_path, content)
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::CorruptArchive) do
          catalog.rebuild!
        end
      end

      FileUtils.rm_f(archive_path)
      FileUtils.mkdir_p(archive_path)
      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::CorruptArchive) do
        catalog.rebuild!
      end
    end
  end

  def test_archive_persistence_refuses_replacement_and_unreadable_existing_entry
    with_tmp_dir do |root|
      project = File.join(root, "owner")
      FileUtils.mkdir_p(project)
      terminal_store(project)
      catalog = catalog_for(
        File.join(root, "state"), [ entry("owner", project) ]
      )
      snapshot = catalog.rebuild!
      action_id, entry = snapshot.fetch("actions").first
      replacement = json_copy(entry)
      replacement["outcome"] = "no_diff"

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.send(:persist_archive_entries!, action_id => replacement)
      end

      File.write(File.join(catalog.archive_root, "#{action_id}.json"), "{")
      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::CorruptArchive) do
        catalog.send(:persist_archive_entries!, action_id => entry)
      end
    end
  end

  def test_bad_digest_in_disposable_projection_is_rebuilt_from_archive
    with_tmp_dir do |root|
      project = File.join(root, "owner")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
      catalog = catalog_for(
        File.join(root, "state"), [ entry("owner", project) ]
      )
      expected = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      ).fetch(action_id)
      projection = JSON.parse(File.binread(catalog.path))
      projection.dig("actions", action_id)["proof_digest"] = "0" * 64
      File.write(catalog.path, "#{JSON.pretty_generate(projection)}\n")

      repaired = catalog.resolve(
        action_ids: [ action_id ], expected_identity: identity, dry_run: false
      )

      assert_equal expected, repaired.fetch(action_id)
      refute_equal "0" * 64,
                   JSON.parse(File.binread(catalog.path)).dig(
                     "actions", action_id, "proof_digest"
                   )
    end
  end

  def test_authoritative_aggregate_rebuilds_a_stale_disposable_projection
    with_tmp_dir do |root|
      project = File.join(root, "project")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      catalog = catalog_for(state_home, [ entry("project", project) ])
      catalog.rebuild!
      FileUtils.rm_rf(catalog.archive_root)
      path = File.join(store.root, "jobs", "job-old.json")
      aggregate = JSON.parse(File.binread(path))
      aggregate.dig("actions", 0, "receipts")["pr_url"] =
        "https://github.com/acme/demo/pull/42"
      File.write(path, "#{JSON.pretty_generate(aggregate)}\n")

      rebuilt = catalog.rebuild!

      assert_equal "https://github.com/acme/demo/pull/42",
                   rebuilt.fetch("actions").values.first.dig("proof", "pr_url")
    end
  end

  def test_terminal_action_identity_and_required_fields_are_recomputed
    with_tmp_dir do |root|
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      aggregate = store.read_job("job-old")
      action = aggregate.fetch("actions").first
      catalog = catalog_for(File.join(root, "state"), [ entry("project", project) ])

      wrong_id = json_copy(action).merge("canonical_action_id" => "fix-#{'0' * 64}")
      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.send(:entry_for_action, store, project, aggregate, wrong_id)
      end

      missing_kind = json_copy(action)
      missing_kind.delete("kind")
      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.send(:entry_for_action, store, project, aggregate, missing_kind)
      end
    end
  end

  def test_materialized_link_outcome_must_match_the_local_terminal_action
    with_tmp_dir do |root|
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      store = terminal_store(project)
      aggregate = store.read_job("job-old")
      action = aggregate.fetch("actions").first
      action_id = action.fetch("canonical_action_id")
      link = terminal_proof(action_id, project_root: project)
      linked_action = json_copy(action).merge(
        "outcome" => "merged",
        "receipts" => link.fetch("proof").merge("canonical_action_link" => link)
      )
      catalog = catalog_for(File.join(root, "state"), [ entry("project", project) ])

      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.send(:entry_for_action, store, project, aggregate, linked_action)
      end
    end
  end

  def test_canonical_action_links_require_exact_identity_shape_and_digest
    with_tmp_dir do |root|
      catalog = catalog_for(File.join(root, "state"), [])
      action_id = "fix-#{'1' * 64}"
      valid = terminal_proof(action_id, project_root: "/owner")
      invalid = []
      invalid << {}
      invalid << redigest_terminal_proof(
        valid.merge("canonical_action_id" => "fix-#{'2' * 64}")
      )
      invalid_owner = json_copy(valid)
      invalid_owner["owner"].delete("registration")
      invalid << redigest_terminal_proof(invalid_owner)
      null_owner = json_copy(valid)
      null_owner["owner"]["project_root"] = "\0"
      invalid << redigest_terminal_proof(null_owner)
      invalid_proof = json_copy(valid)
      invalid_proof["proof"]["unknown"] = true
      invalid << redigest_terminal_proof(invalid_proof)
      invalid << valid.merge("proof_digest" => "0" * 64)

      invalid.each do |proof|
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
          catalog.send(:validate_terminal_proof!, proof, expected_action_id: action_id)
        end
      end
    end
  end

  def test_remote_terminal_outcomes_require_exact_urls_and_pr_handoff
    with_tmp_dir do |root|
      closed_root = File.join(root, "closed")
      no_handoff_root = File.join(root, "no-handoff")
      missing_url_root = File.join(root, "missing-url")
      invalid_url_root = File.join(root, "invalid-url")
      outside_handoff_root = File.join(root, "outside-handoff")
      null_handoff_root = File.join(root, "null-handoff")
      wrong_stage_root = File.join(root, "wrong-stage")
      nested_task_root = File.join(root, "nested-task")
      [ closed_root, no_handoff_root, missing_url_root, invalid_url_root,
        outside_handoff_root, null_handoff_root, wrong_stage_root,
        nested_task_root ].each do |path|
        FileUtils.mkdir_p(path)
      end
      closed = terminal_store(closed_root, outcome: "closed_without_merge")
      closed_id = closed.read_job("job-old").dig("actions", 0, "canonical_action_id")
      closed_catalog = catalog_for(
        File.join(root, "closed-state"), [ entry("closed", closed_root) ]
      )
      assert_equal "closed_without_merge", closed_catalog.resolve(
        action_ids: [ closed_id ], expected_identity: identity, dry_run: false
      ).fetch(closed_id).fetch("outcome")

      terminal_store(no_handoff_root, review_task_path: nil)
      terminal_store(missing_url_root, pr_url: nil)
      terminal_store(invalid_url_root, pr_url: "%")
      terminal_store(outside_handoff_root, review_task_path: "/tmp/review/task")
      terminal_store(null_handoff_root, review_task_path: "\0")
      terminal_store(
        wrong_stage_root,
        review_task_path: File.join(
          wrong_stage_root, ".hive-state", "stages", "5-open-pr", "review-task"
        )
      )
      terminal_store(
        nested_task_root,
        review_task_path: File.join(
          nested_task_root, ".hive-state", "stages", "6-review", "review-task", "nested"
        )
      )
      [ no_handoff_root, missing_url_root, invalid_url_root,
        outside_handoff_root, null_handoff_root, wrong_stage_root,
        nested_task_root ].each do |project|
        catalog = catalog_for(
          File.join(root, "#{File.basename(project)}-state"),
          [ entry(File.basename(project), project) ]
        )
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
          catalog.rebuild!
        end
      end
    end
  end

  def test_catalog_rebuild_recovers_review_handoff_after_task_stage_advancement
    with_tmp_dir do |root|
      %w[6-review 7-artifacts 8-finalize 9-done].each do |stage|
        project = File.join(root, "project-#{stage}")
        state_home = File.join(root, "state-#{stage}")
        task_path = File.join(
          project, ".hive-state", "stages", stage, "patrol-refactor-fingerprint"
        )
        FileUtils.mkdir_p(task_path)
        store = terminal_store(project, review_task_path: task_path)
        action_id = store.read_job("job-old").dig("actions", 0, "canonical_action_id")
        catalog = catalog_for(state_home, [ entry(stage, project) ])

        first = catalog.rebuild!
        FileUtils.rm_f(catalog.path)
        rebuilt = catalog.rebuild!

        assert_equal task_path,
                     first.dig("actions", action_id, "proof", "review_task_path"), stage
        assert_equal task_path,
                     rebuilt.dig("actions", action_id, "proof", "review_task_path"), stage
      end
    end
  end

  def test_issue_number_and_duplicate_urls_must_match_the_exact_repository
    with_tmp_dir do |root|
      mismatch_root = File.join(root, "number-mismatch")
      wrong_host_root = File.join(root, "wrong-host")
      [ mismatch_root, wrong_host_root ].each { |path| FileUtils.mkdir_p(path) }
      terminal_issue_store(
        mismatch_root, registration: "mismatch", issue_number: 99
      )
      terminal_issue_store(
        wrong_host_root,
        registration: "wrong-host",
        duplicate_issue_urls: [ "https://example.com/acme/demo/issues/53" ]
      )

      [ mismatch_root, wrong_host_root ].each do |project|
        catalog = catalog_for(
          File.join(root, "#{File.basename(project)}-state"),
          [ entry(File.basename(project), project) ]
        )
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
          catalog.rebuild!
        end
      end
    end
  end

  def test_source_and_requested_repository_identities_are_strict
    with_tmp_dir do |root|
      catalog = catalog_for(File.join(root, "state"), [])
      assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
        catalog.send(:source_identity, { "url" => "%", "repository" => "acme/demo" })
      end
      [ nil,
        { "host" => "github.com", "repository" => "invalid" },
        { "host" => "%", "repository" => "acme/demo" } ].each do |requested|
        assert_raises(Hive::RefactorPatrol::CanonicalActionCatalog::ProofConflict) do
          catalog.resolve(action_ids: [ "fix-x" ], expected_identity: requested, dry_run: true)
        end
      end
    end
  end

  def test_invalid_catalog_shapes_are_discarded_and_rebuilt
    with_tmp_dir do |root|
      project = File.join(root, "project")
      state_home = File.join(root, "state")
      FileUtils.mkdir_p(project)
      terminal_store(project)
      catalog = catalog_for(state_home, [ entry("project", project) ])
      valid = catalog.rebuild!
      variants = []
      variants << valid.merge("schema" => "wrong")
      invalid_entry = json_copy(valid)
      invalid_entry.fetch("actions").values.first["witnesses"] = [ {} ]
      variants << invalid_entry
      variants << valid.merge("updated_at" => "not-a-time")

      variants.each do |data|
        File.write(catalog.path, "#{JSON.pretty_generate(data)}\n")
        repaired = catalog.rebuild!
        assert_equal Hive::RefactorPatrol::CanonicalActionCatalog::SCHEMA,
                     repaired.fetch("schema")
      end
    end
  end

  private

  def catalog_for(state_home, entries, clock: -> { T0 }, registry: -> { entries },
                  job_store_factory: ->(project_root) {
                    Hive::RefactorPatrol::JobStore.new(project_root)
                  })
    Hive::RefactorPatrol::CanonicalActionCatalog.new(
      state_home: state_home,
      registry: registry,
      job_store_factory: job_store_factory,
      clock: clock
    )
  end

  def terminal_store(root, registration: "old", pr_url: "https://github.com/acme/demo/pull/41",
                     review_task_path: File.join(root, ".hive-state", "stages", "6-review", "task"),
                     terminal: true, outcome: "pr_opened")
    store = Hive::RefactorPatrol::JobStore.new(root)
    action_id = store.canonical_action_id(
      repository: "acme/demo", host: "github.com", kind: "fix", identity: "fp-accepted"
    )
    receipts = if terminal && outcome == "pr_opened"
      { "pr_url" => pr_url, "review_task_path" => review_task_path }.compact
    elsif terminal && outcome == "closed_without_merge"
      { "pr_url" => pr_url }.compact
    else
      {}
    end
    aggregate = job(
      registration: registration,
      state: terminal ? "complete" : "acting",
      complete: terminal,
      actions: [ action(action_id, terminal: terminal, outcome: outcome, receipts: receipts) ],
      job_id: "job-old"
    )
    store.write_job!(aggregate)
    store
  end

  def terminal_issue_store(root, registration:,
                           issue_url: "https://github.com/acme/demo/issues/52",
                           issue_number: 52,
                           duplicate_issue_urls: [ "https://github.com/acme/demo/issues/53" ])
    store = Hive::RefactorPatrol::JobStore.new(root)
    family_id = "af1-#{'f' * 64}"
    action_id = store.canonical_action_id(
      repository: "acme/demo", host: "github.com", kind: "issue", identity: family_id
    )
    aggregate = job(
      registration: registration,
      state: "complete",
      complete: true,
      actions: [
        action(
          action_id,
          terminal: true,
          outcome: "issue_created",
          receipts: {
            "issue_url" => issue_url,
            "issue_number" => issue_number,
            "duplicate_issue_urls" => duplicate_issue_urls
          }
        ).merge("kind" => "issue", "family_id" => family_id, "owner_job_id" => "job-issue")
      ],
      job_id: "job-issue"
    )
    aggregate["policy"]["issue_filing"] = true
    store.write_job!(aggregate)
    store
  end

  def classified_store(root, registration:)
    store = Hive::RefactorPatrol::JobStore.new(root)
    store.write_job!(
      job(
        registration: registration, state: "classified", complete: false,
        actions: [], job_id: "job-new"
      )
    )
    store
  end

  def job(registration:, state:, complete:, actions:, job_id:)
    {
      "schema" => Hive::RefactorPatrol::JobStore::SCHEMA,
      "schema_version" => Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => registration,
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40
      },
      "analysis_sha" => "c" * 40,
      "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => false },
      "state" => state,
      "complete" => complete,
      "dispositions" => {
        "accepted" => [
          {
            "id" => "accepted", "feature_id" => "checkout",
            "fingerprint" => "fp-accepted", "score" => 0.8,
            "admissible" => true, "reasons" => []
          }
        ],
        "flagged" => [], "suppressed" => []
      },
      "feature_results" => [
        {
          "feature_id" => "checkout", "complete" => true,
          "thesis_ids" => [ "accepted" ], "errors" => []
        }
      ],
      "review_errors" => [], "zero_reason" => nil,
      "attempts" => [ { "number" => 1, "outcome" => state } ],
      "actions" => actions,
      "created_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }
  end

  def action(action_id, terminal:, outcome:, receipts:)
    {
      "canonical_action_id" => action_id,
      "thesis_id" => "accepted",
      "thesis_fingerprint" => "fp-accepted",
      "kind" => "fix",
      "owner_job_id" => "job-old",
      "outcome" => outcome,
      "terminal" => terminal,
      "receipts" => receipts,
      "claims" => [],
      "created_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }
  end

  def entry(name, path)
    { "name" => name, "path" => path }
  end

  def identity
    { "host" => "github.com", "repository" => "acme/demo" }
  end

  def terminal_proof(action_id, project_root:)
    review_task_path = File.join(
      project_root, ".hive-state", "stages", "6-review", "review-task"
    )
    redigest_terminal_proof(
      "canonical_action_id" => action_id,
      "owner" => {
        "registration" => "owner",
        "project_root" => project_root,
        "job_id" => "job-owner",
        "pr_number" => 7,
        "merge_sha" => "b" * 40
      },
      "outcome" => "pr_opened",
      "proof" => {
        "pr_url" => "https://github.com/acme/demo/pull/41",
        "review_task_path" => review_task_path
      }
    )
  end

  def redigest_terminal_proof(proof)
    payload = proof.reject { |key, _| key == "proof_digest" }
    proof.merge(
      "proof_digest" => ::Digest::SHA256.hexdigest(JSON.generate(deep_sort_json(payload)))
    )
  end

  def deep_sort_json(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [ key, deep_sort_json(value.fetch(key)) ] }
    when Array
      value.map { |item| deep_sort_json(item) }
    else value
    end
  end

  def json_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
