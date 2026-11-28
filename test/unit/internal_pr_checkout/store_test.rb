require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hive/internal_pr_checkout"
require "hive/review_budget"
require "hive/stages/review/pass_archive"

class InternalPrCheckoutStoreTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("ipc-store-test-")
    @project = File.join(@tmp, "project")
    @task_folder = File.join(@project, ".hive-state", "stages", "6-review", "adhoc-review-pr-42")
    FileUtils.mkdir_p(File.join(@task_folder, "reviews"))
    File.write(File.join(@task_folder, "pr.md"), <<~MD)
      ---
      source: ad-hoc
      pr_number: 42
      pr_url: https://github.com/acme/widget/pull/42
      head_oid: #{"a" * 40}
      ---
      # PR 42
    MD
    @store = Hive::InternalPrCheckout::Store.new(@task_folder)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_fixed_anchor_count_is_constant_and_generation_one_has_nil_transition_digest
    assert_equal 6, @store.fixed_anchor_paths.size

    current, root = @store.initialize_generation_one!(
      task_id: "0001",
      task_slug: "adhoc-review-pr-42",
      project: "widget",
      pr_host: "github.com",
      pr_repository: "acme/widget",
      pr_number: 42,
      pr_url: "https://github.com/acme/widget/pull/42",
      base_ref_name: "main",
      head_ref_name: "feat/x",
      head_repository: "acme/widget",
      is_cross_repository: false,
      pr_state: "OPEN",
      branch: "hive/review/pr-42",
      head_oid: "a" * 40,
      committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
    )

    assert_equal 1, current["generation"]
    assert_nil current["head_transition_digest"]
    assert_equal 0, root["generation_count"]
    assert_equal 1, root["next_ordinal"]
    assert_equal 6, @store.fixed_anchor_paths.size
    assert @store.verify_history_integrity!
  end

  def test_bootstrap_legacy_history_incorporates_preexisting_archives_in_order
    # Preexisting legacy archive from before history indexing existed
    legacy_dir = File.join(@task_folder, "reviews", "archive", "20260801T000000Z-7-artifacts-to-6-review")
    FileUtils.mkdir_p(legacy_dir)
    File.write(File.join(legacy_dir, "claude-01.md"), "# legacy pass\n")

    # New retirement directory
    new_dir = File.join(@task_folder, "reviews", "archive", "internal-pr-reopen-bbbbbbbbbbbb-tx1")
    FileUtils.mkdir_p(new_dir)
    File.write(File.join(new_dir, "claude-01.md"), "# gen 2 pass\n")

    root, digest = @store.seal_retirement!(label: "internal-pr-reopen-bbbbbbbbbbbb-tx1")

    assert_equal 2, root["generation_count"]
    assert_equal 3, root["next_ordinal"]
    assert_equal [ "20260801T000000Z-7-artifacts-to-6-review", "internal-pr-reopen-bbbbbbbbbbbb-tx1" ],
                 @store.sealed_labels
    assert_match(/\A[0-9a-f]{64}\z/, digest)
    assert @store.verify_history_integrity!

    # Replay idempotency on same latest label
    root2, digest2 = @store.seal_retirement!(label: "internal-pr-reopen-bbbbbbbbbbbb-tx1")
    assert_equal root, root2
    assert_equal digest, digest2
  end

  def test_custody_detects_anchor_edits_absent_anchor_creation_and_deep_archive_tamper
    @store.initialize_generation_one!(
      task_id: "0001",
      task_slug: "adhoc-review-pr-42",
      project: "widget",
      pr_host: "github.com",
      pr_repository: "acme/widget",
      pr_number: 42,
      pr_url: "https://github.com/acme/widget/pull/42",
      base_ref_name: "main",
      head_ref_name: "feat/x",
      head_repository: "acme/widget",
      is_cross_repository: false,
      pr_state: "OPEN",
      branch: "hive/review/pr-42",
      head_oid: "a" * 40,
      committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
    )
    arch = File.join(@task_folder, "reviews", "archive", "gen-0001", "nested")
    FileUtils.mkdir_p(arch)
    File.write(File.join(arch, "report.md"), "original\n")
    @store.seal_retirement!(label: "gen-0001")
    @store.sync_current_history_root_digest!

    # 1. Clean spawn passes custody.
    capture = @store.capture_custody
    assert @store.verify_custody!(capture)

    # 2. Tampering with a fixed anchor (`pr.md`) restores original bytes and raises CustodyError.
    orig_pr = File.read(File.join(@task_folder, "pr.md"))
    capture = @store.capture_custody
    File.write(File.join(@task_folder, "pr.md"), "tampered\n")
    err = assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_custody!(capture) }
    assert_includes err.message, "original bytes were restored"
    assert_equal orig_pr, File.read(File.join(@task_folder, "pr.md"))

    # 3. Creating a previously absent fixed anchor (`candidate.json`) deletes it and raises CustodyError.
    capture = @store.capture_custody
    File.write(@store.candidate_path, "{}\n")
    err = assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_custody!(capture) }
    assert_includes err.message, "original bytes were restored"
    refute File.exist?(@store.candidate_path)

    # 4. Adding an unseen file deep inside a sealed archive fails custody AND
    #    leaves subsequent verify_history_integrity! blocked until repaired.
    capture = @store.capture_custody
    rogue = File.join(arch, "sneaky.md")
    File.write(rogue, "injected\n")
    err = assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_custody!(capture) }
    assert_equal "custody_mismatch", err.reason
    assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_history_integrity! }
    File.unlink(rogue)
    assert @store.verify_history_integrity!

    # 5. Replacing an archived file with a symlink fails custody & integrity.
    capture = @store.capture_custody
    File.unlink(File.join(arch, "report.md"))
    File.symlink("/etc/hosts", File.join(arch, "report.md"))
    assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_custody!(capture) }
    assert_raises(Hive::InternalPrCheckout::CustodyError) { @store.verify_history_integrity! }
  end

  def test_rebuild_history_after_restore_preserves_head_transition_digest_and_shared_ordinals
    @store.initialize_generation_one!(
      task_id: "0001",
      task_slug: "adhoc-review-pr-42",
      project: "widget",
      pr_host: "github.com",
      pr_repository: "acme/widget",
      pr_number: 42,
      pr_url: "https://github.com/acme/widget/pull/42",
      base_ref_name: "main",
      head_ref_name: "feat/x",
      head_repository: "acme/widget",
      is_cross_repository: false,
      pr_state: "OPEN",
      branch: "hive/review/pr-42",
      head_oid: "a" * 40,
      committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
    )

    # Preexisting rewind -> ordinal 2
    d1 = File.join(@task_folder, "reviews", "archive", "20260829T120000Z-7-artifacts-to-6-review")
    FileUtils.mkdir_p(d1)
    File.write(File.join(d1, "claude-01.md"), "pass 1\n")
    @store.seal_retirement!(label: File.basename(d1))
    @store.sync_current_history_root_digest!
    assert_equal 2, Hive::Stages::Review::PassArchive.generation(@task_folder)

    # Simulate head change retiring ordinal 2 -> commits generation 3 with non-nil head_transition_digest
    d2 = File.join(@task_folder, "reviews", "archive", "internal-pr-reopen-bbbbbbbbbbbb-tx2")
    FileUtils.mkdir_p(d2)
    File.write(File.join(d2, "claude-01.md"), "pass 2\n")
    _r, h_digest = @store.seal_retirement!(label: File.basename(d2))
    tx_digest = Hive::InternalPrCheckout::Store.head_transition_digest(
      pr_url: "https://github.com/acme/widget/pull/42",
      pr_number: 42,
      branch: "hive/review/pr-42",
      reviewed_oid: "b" * 40,
      generation: 3,
      previous_generation: 2,
      retirement_label: File.basename(d2),
      transaction_id: "tx2"
    )
    current = @store.read_current.merge(
      "reviewed_oid" => "b" * 40,
      "candidate_oid" => "b" * 40,
      "generation" => 3,
      "previous_generation" => 2,
      "previous_reviewed_oid" => "a" * 40,
      "retirement_label" => File.basename(d2),
      "transaction_id" => "tx2",
      "head_transition_digest" => tx_digest,
      "history_root_digest" => h_digest
    )
    @store.write_current!(current)

    # Later rewind -> ordinal 4, head_transition_digest stays identical!
    d3 = File.join(@task_folder, "reviews", "archive", "20260829T130000Z-7-artifacts-to-6-review")
    FileUtils.mkdir_p(d3)
    File.write(File.join(d3, "claude-01.md"), "pass 3\n")
    @store.seal_retirement!(label: File.basename(d3))
    @store.sync_current_history_root_digest!
    assert_equal 4, Hive::Stages::Review::PassArchive.generation(@task_folder)
    assert_equal tx_digest, @store.read_current["head_transition_digest"]
    assert @store.verify_history_integrity!

    # Failed rewind restore removes d3 -> rebuild brings ordinal cleanly back to 3
    FileUtils.rm_rf(d3)
    @store.rebuild_history_after_restore!
    assert_equal 3, Hive::Stages::Review::PassArchive.generation(@task_folder)
    assert_equal tx_digest, @store.read_current["head_transition_digest"]
    assert @store.verify_history_integrity!
  end

  def test_scale_beyond_firewall_and_budget_limits_with_constant_anchors_and_o1_grant_replay
    # Grow history to 4,150 generations (exceeds ArtifactFirewall::MAX_ENTRIES=128,
    # HARD_MAX_ENTRIES=4096, and ReviewBudget::MAX_FILES=4096).
    total_archives = 4_150
    @store.initialize_generation_one!(
      task_id: "0042",
      task_slug: "adhoc-review-pr-42",
      project: "widget",
      pr_host: "github.com",
      pr_repository: "acme/widget",
      pr_number: 42,
      pr_url: "https://github.com/acme/widget/pull/42",
      base_ref_name: "main",
      head_ref_name: "feat/scale",
      head_repository: "acme/widget",
      is_cross_repository: false,
      pr_state: "OPEN",
      branch: "hive/review/pr-42",
      head_oid: "a" * 40,
      committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
    )

    archive_root = File.join(@task_folder, "reviews", "archive")
    FileUtils.mkdir_p(archive_root)

    # Create 4,150 archive directories and seal a valid indexed history root
    # with real review-grant receipts placed in early (0001), middle (2048),
    # and late (4150) generations to prove O(1) lookup past 4,096 archives.
    grant_positions = { 1 => 1, 2048 => 2, total_archives => 3 }
    grants_by_token = {}
    first_grant_token = nil

    archive_state = { "present" => true, "count" => 0, "sum" => "0", "xor" => "0" }
    manifests_state = { "present" => true, "count" => 0, "sum" => "0", "xor" => "0" }
    grant_index = { "schema" => Hive::InternalPrCheckout::Store::GRANT_INDEX_SCHEMA, "schema_version" => 1, "buckets" => {} }
    buckets = {}

    label_pages = []
    current_page_entries = []

    (1..total_archives).each do |idx|
      label = format("gen-%05d", idx)
      dir = File.join(archive_root, label)
      Dir.mkdir(dir)
      @store.send(:add_membership_entry!, archive_state, label, "directory")

      if (seq = grant_positions[idx])
        grant_doc = sample_grant_document(variant: idx, sequence: seq)
        token = grant_doc.fetch("observation_digest")
        first_grant_token ||= token
        grant_name = "review-grant-#{token}.json"
        grant_path = File.join(dir, grant_name)
        grant_bytes = "#{JSON.generate(Hive::ReviewBudget.canonical(grant_doc))}\n"
        File.write(grant_path, grant_bytes)
        File.chmod(0o600, grant_path)
        sha = Digest::SHA256.hexdigest(grant_bytes)
        grants_by_token[token] = grant_doc
        @store.send(:add_membership_entry!, archive_state, "#{label}/#{grant_name}", "file")

        m_file = "archive-#{label}-p0000.json"
        m_doc = {
          "schema" => Hive::InternalPrCheckout::Store::ARCHIVE_MANIFEST_SCHEMA,
          "schema_version" => 1,
          "label" => label,
          "page" => 0,
          "previous_page" => nil,
          "entries" => [ { "path" => grant_name, "kind" => "file", "mode" => 0o600, "size" => grant_bytes.bytesize, "sha256" => sha } ]
        }
        m_path = File.join(@store.manifests_dir, m_file)
        @store.send(:write_private_json!, m_path, m_doc)
        @store.send(:add_membership_entry!, manifests_state, m_file, "file")
        m_digest = @store.send(:file_sha256, m_path)

        prefix = token[0, 2]
        buckets[prefix] ||= { "schema" => Hive::InternalPrCheckout::Store::GRANT_BUCKET_SCHEMA, "schema_version" => 1, "prefix" => prefix, "entries" => {} }
        buckets[prefix]["entries"][token] = [ {
          "label" => label,
          "file" => grant_name,
          "sha256" => sha,
          "manifest_file" => m_file,
          "manifest_digest" => m_digest
        } ]

        current_page_entries << {
          "ordinal" => idx, "label" => label, "manifest_head_file" => m_file,
          "manifest_head_digest" => m_digest, "retirement_receipt_digest" => nil, "entry_count" => 1
        }
      else
        current_page_entries << {
          "ordinal" => idx, "label" => label, "manifest_head_file" => nil,
          "manifest_head_digest" => nil, "retirement_receipt_digest" => nil, "entry_count" => 0
        }
      end

      if current_page_entries.length == 200 || idx == total_archives
        page_idx = label_pages.length
        page_file = format("label-page-%04d.json", page_idx)
        prev = label_pages.last
        page_doc = {
          "schema" => Hive::InternalPrCheckout::Store::LABEL_PAGE_SCHEMA,
          "schema_version" => 1,
          "page" => page_idx,
          "previous_page" => prev ? { "file" => prev[:file], "digest" => prev[:digest] } : nil,
          "entries" => current_page_entries
        }
        page_path = File.join(@store.manifests_dir, page_file)
        @store.send(:write_private_json!, page_path, page_doc)
        @store.send(:add_membership_entry!, manifests_state, page_file, "file")
        label_pages << { file: page_file, digest: @store.send(:file_sha256, page_path), count: current_page_entries.length }
        current_page_entries = []
      end
    end

    buckets.each do |prefix, bdoc|
      bfile = "grant-bucket-#{prefix}.json"
      bpath = File.join(@store.manifests_dir, bfile)
      @store.send(:write_private_json!, bpath, bdoc)
      @store.send(:add_membership_entry!, manifests_state, bfile, "file")
      grant_index["buckets"][prefix] = @store.send(:file_sha256, bpath)
    end
    @store.send(:write_private_json!, @store.grant_index_path, grant_index)
    grant_index_digest = @store.send(:file_sha256, @store.grant_index_path)

    root = {
      "schema" => Hive::InternalPrCheckout::Store::HISTORY_ROOT_SCHEMA,
      "schema_version" => 1,
      "generation_count" => total_archives,
      "next_ordinal" => total_archives + 1,
      "latest_label" => format("gen-%05d", total_archives),
      "label_chain_head" => { "file" => label_pages.last[:file], "digest" => label_pages.last[:digest], "count" => label_pages.last[:count] },
      "grant_index_digest" => grant_index_digest,
      "archive_membership_state" => archive_state,
      "archive_membership_digest" => @store.send(:finalize_membership_state, archive_state),
      "manifests_membership_state" => manifests_state,
      "manifests_membership_digest" => @store.send(:finalize_membership_state, manifests_state)
    }
    @store.send(:write_private_json!, @store.history_root_path, root)
    @store.sync_current_history_root_digest!

    # 1. Firewall anchors stay fixed at 6 (well below 128 default / 4096 hard limit).
    assert_equal 6, @store.fixed_anchor_paths.size
    assert_equal total_archives + 1, Hive::Stages::Review::PassArchive.generation(@task_folder)

    # 2. Custody capture & verify succeed across 4,150 archives (no HARD_MAX_ENTRIES failure).
    capture = @store.capture_custody
    assert @store.verify_custody!(capture)

    # 3. ReviewBudget::Store#archived_grant resolves early, middle, and late grants cleanly!
    fake_task = Struct.new(:folder, :slug, :id, :project_root, :stage_name).new(
      @task_folder, "adhoc-review-pr-42", "0042", @project, "review"
    )
    budget = Hive::ReviewBudget.new(task: fake_task, project: "widget")
    grants_by_token.each do |token, expected_doc|
      found = budget.store.archived_grant(token)
      assert_equal expected_doc.fetch("decision_id"), found.fetch("decision_id")
      replayed = budget.replay(evidence_token: token, passes: 1, reason: "scale test grant")
      assert_equal expected_doc.fetch("decision_id"), replayed.fetch("decision_id")
    end
    assert_nil budget.store.archived_grant("9" * 64)

    # 4. Over-limit individual manifest (> 256 KB) is rejected with custody_limit_exceeded -> evidence_limit.
    oversized_manifest = File.join(@store.manifests_dir, "archive-gen-00001-p0000.json")
    File.write(oversized_manifest, "x" * (Hive::InternalPrCheckout::Store::MAX_RECORD_BYTES + 10))
    err = assert_raises(Hive::ReviewBudget::Refused) { budget.store.archived_grant(first_grant_token) }
    assert_equal "evidence_limit", err.reason
  end

  private

  def sample_grant_document(variant:, sequence:)
    scope = { "anchor_artifacts" => {}, "first_pass" => 1, "history_digest" => Digest::SHA256.hexdigest("hist-#{variant}") }
    marker_raw = Hive::Markers.build_marker("REVIEW_STALE", "reason" => "final_fix_unverified", "pass" => "2")
    marker = { "attrs" => { "pass" => "2", "reason" => "final_fix_unverified" }, "name" => "review_stale", "raw" => marker_raw }
    esc_proof = Hive::ReviewBudget::EscalationProof.capture("escalations-02.md", "### Q1. Confirm?\n### A1. Yes\n")
    evidence = {
      "artifacts" => { "claude-01.md" => Digest::SHA256.hexdigest("art-#{variant}") },
      "escalation_proof" => esc_proof,
      "head" => "a" * 40,
      "marker" => marker,
      "ownership" => { "task_generation" => 0 },
      "pass" => 2,
      "project" => "widget",
      "receipt_chain_digest" => Hive::ReviewBudget::EMPTY_CHAIN,
      "resume_evidence" => nil,
      "scope" => scope,
      "task" => "adhoc-review-pr-42",
      "task_generation" => 0,
      "task_id" => "0042",
      "worktree" => nil
    }
    real_token = Hive::ReviewBudget.digest(evidence)
    decision = { passes: 1, reason: "scale test grant" }
    {
      "schema" => Hive::ReviewBudget::Store::GRANT_SCHEMA,
      "schema_version" => 1,
      "project" => "widget",
      "task" => "adhoc-review-pr-42",
      "task_id" => "0042",
      "task_generation" => 0,
      "scope" => scope,
      "sequence" => sequence,
      "observation_digest" => real_token,
      "evidence" => evidence,
      "previous_receipt_digest" => Hive::ReviewBudget::EMPTY_CHAIN,
      "amount" => 1,
      "reason" => "scale test grant",
      "caller" => "test",
      "source" => "cli",
      "decision_id" => Hive::ReviewBudget.digest([ "widget", "0042", "adhoc-review-pr-42", real_token, decision ]),
      "recorded_at" => Time.utc(2026, 8, 29, 12, 0, 0).iso8601(6)
    }
  end
end
