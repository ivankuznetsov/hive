require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "hive/internal_pr_checkout"
require "hive/review_budget"
require "hive/runtime_control_plane"
require "hive/stages/review"
require "hive/task"

class InternalPrCheckoutReconcilerTest < Minitest::Test
  class InjectedCrash < StandardError; end

  def setup
    @tmp = Dir.mktmpdir("ipc-reconciler-test-")
    @hive_home = File.join(@tmp, "hive-home")
    FileUtils.mkdir_p(@hive_home)
    @prev_hive_home = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = @hive_home
    Hive::RuntimeControlPlane.disconnect
    Hive::Lock.task_lease_repository = nil

    @remote = File.join(@tmp, "remote.git")
    @project = File.join(@tmp, "project")
    @worktree_root = File.join(@tmp, "worktrees")
    FileUtils.mkdir_p(@worktree_root)

    git(@tmp, "init", "--bare", @remote)
    git(@tmp, "clone", @remote, @project)
    git(@project, "config", "user.name", "Test")
    git(@project, "config", "user.email", "test@example.com")

    File.write(File.join(@project, ".gitignore"), "build/\nobstructed.txt\n")
    File.write(File.join(@project, "app.rb"), "puts 'base'\n")
    git(@project, "add", ".")
    git(@project, "commit", "-m", "initial main")
    git(@project, "branch", "-M", "main")
    git(@project, "push", "-u", "origin", "main")
    @base_oid = git(@project, "rev-parse", "HEAD").strip

    # Commit A (PR head v1)
    git(@project, "checkout", "-b", "pr-head")
    File.write(File.join(@project, "app.rb"), "puts 'head-A'\n")
    File.write(File.join(@project, "only_a.txt"), "a-file\n")
    git(@project, "add", ".")
    git(@project, "commit", "-m", "PR commit A")
    @oid_a = git(@project, "rev-parse", "HEAD").strip
    git(@project, "push", "origin", "#{@oid_a}:refs/pull/42/head")

    # Commit B (force-pushed unrelated PR head v2)
    git(@project, "checkout", "--orphan", "pr-head-b")
    git(@project, "rm", "-rf", ".")
    File.write(File.join(@project, ".gitignore"), "build/\nobstructed.txt\n")
    File.write(File.join(@project, "app.rb"), "puts 'head-B'\n")
    File.write(File.join(@project, "only_b.txt"), "b-file\n")
    File.write(File.join(@project, "obstructed.txt"), "tracked-in-b\n")
    git(@project, "add", "-f", ".gitignore", "app.rb", "only_b.txt", "obstructed.txt")
    git(@project, "commit", "-m", "PR commit B (force-pushed)")
    @oid_b = git(@project, "rev-parse", "HEAD").strip

    # Commit C (another force-pushed PR head v3)
    git(@project, "checkout", "--orphan", "pr-head-c")
    git(@project, "rm", "-rf", ".")
    File.write(File.join(@project, ".gitignore"), "build/\nobstructed.txt\n")
    File.write(File.join(@project, "app.rb"), "puts 'head-C'\n")
    File.write(File.join(@project, "only_c.txt"), "c-file\n")
    git(@project, "add", "-f", ".gitignore", "app.rb", "only_c.txt")
    git(@project, "commit", "-m", "PR commit C")
    @oid_c = git(@project, "rev-parse", "HEAD").strip

    git(@project, "checkout", "main")
    git(@project, "branch", "-D", "pr-head", "pr-head-b", "pr-head-c")

    # Configure Hive state root & register project in SQLite runtime control plane
    @state_root = File.join(@project, ".hive-state")
    FileUtils.mkdir_p(File.join(@state_root, "stages", "6-review"))
    File.write(File.join(@state_root, "config.yml"), YAML.dump(
      "worktree_root" => @worktree_root
    ))
    @database = Hive::RuntimeControlPlane.database.migrate!
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    @database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert(
        project_id: "widget-proj",
        installation_id: installation,
        registration_id: "widget-proj",
        name: "widget",
        observed_path: @project,
        state_root_path: @state_root,
        active: 1,
        registered_at: timestamp,
        last_observed_at: timestamp
      )
    end

    @pr_url = "https://github.com/acme/widget/pull/42"
    @slug = "adhoc-review-pr-42"
    @branch = "hive/review/pr-42"
    @wt = File.join(@worktree_root, @slug)
    @task_folder = File.join(@state_root, "stages", "6-review", @slug)

    setup_internal_pr_task!(head_oid: @oid_a, legacy: false)
  end

  def teardown
    Hive::Lock.task_lease_repository = nil
    Hive::RuntimeControlPlane.disconnect
    ENV["HIVE_HOME"] = @prev_hive_home
    FileUtils.rm_rf(@tmp)
  end

  def test_ae1_unchanged_rerun_is_byte_for_byte_noop_and_sqlite_lease_contention_returns_busy
    before_fs = snapshot_tree(@task_folder)
    before_git = snapshot_git(@wt, @branch)

    gh = stub_gh([ meta_for(@oid_a) ])
    reconciler = build_reconciler(gh: gh)

    result = reconciler.reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "current", result.status
    assert_equal "head_unchanged", result.reason
    refute result.retryable
    assert_equal 1, result.generation
    assert_equal @oid_a, result.head_oid
    assert_equal @oid_a, result.candidate_oid
    assert_nil result.checkout_digest
    assert_equal "OPEN", result.pr_observation["state"]

    # AE1: Entire task folder byte-for-byte identical (zero filename exclusions) + Git state identical.
    assert_equal before_fs, snapshot_tree(@task_folder)
    assert_equal before_git, snapshot_git(@wt, @branch)
    # SQLite task lease was released cleanly.
    assert_nil Hive::Lock.read_task_lock(@task_folder)

    # Repeat once more to verify repeated idempotency.
    result2 = build_reconciler(gh: stub_gh([ meta_for(@oid_a) ])).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "current", result2.status
    assert_equal before_fs, snapshot_tree(@task_folder)

    # Separately test SQLite lease contention via a live child holder process.
    Hive::RuntimeControlPlane.disconnect
    Hive::Lock.task_lease_repository = nil
    child_rd, child_wr = IO.pipe
    ready_rd, ready_wr = IO.pipe
    pid = fork do
      child_wr.close
      ready_rd.close
      Hive::RuntimeControlPlane.disconnect
      Hive::Lock.task_lease_repository = nil
      Hive::Lock.with_task_lock(@task_folder, op: "external_holder", create: false) do
        ready_wr.write("locked\n")
        ready_wr.flush
        child_rd.read(1)
      end
      exit!(0)
    end
    child_rd.close
    ready_wr.close
    assert_equal "locked\n", ready_rd.gets

    gh_calls = 0
    counting_gh = Object.new
    counting_gh.define_singleton_method(:validated_pr_metadata) { |*| gh_calls += 1; raise "must not call gh" }

    busy = build_reconciler(gh: counting_gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "busy", busy.status
    assert_equal "task_locked", busy.reason
    assert busy.retryable
    assert_equal 0, gh_calls
    assert_equal before_fs, snapshot_tree(@task_folder)

    child_wr.write("x")
    child_wr.close
    ready_rd.close
    Process.waitpid(pid)
    assert_nil Hive::Lock.read_task_lock(@task_folder)
  end

  def test_ae2_ae6_ae7_repush_checks_out_exact_oid_retires_active_state_and_strips_review_markers_preserving_prose
    # Seed rich active review state (AE6 + AE7): embedded REVIEW_COMPLETE + REVIEW_WAITING,
    # operator prose, unrelated marker, findings, suppressions, ci-blocked, deferred, escalations,
    # browser receipt, fix-success, fix-guardrail, github-publication.json, nested subdir, and unrelated notes.md.
    File.write(File.join(@task_folder, "task.md"), <<~MD)
      ---
      id: "0042"
      source: ad-hoc
      ---
      # Operator review notes
      Keep this exact prose line untouched.
      <!-- REVIEW_COMPLETE pass=1 browser=passed -->
      <!-- CUSTOM_OPERATOR_NOTE owner=human -->
      More prose here.
      <!-- REVIEW_WAITING reason=escalations pass=1 -->
    MD
    File.write(File.join(@task_folder, "notes.md"), "unrelated operator notes\n")
    File.write(File.join(@task_folder, "github-publication.json"), "{\"head\":\"#{@oid_a}\"}\n")
    reviews = File.join(@task_folder, "reviews")
    FileUtils.mkdir_p(File.join(reviews, "nested-validation"))
    File.write(File.join(reviews, "claude-01.md"), "finding 1\n")
    File.write(File.join(reviews, "suppressed.md"), "suppressed item\n")
    File.write(File.join(reviews, "ci-blocked.md"), "old ci error\n")
    File.write(File.join(reviews, "deferred-findings.md"), "deferred item\n")
    File.write(File.join(reviews, "escalations-01.md"), "escalation 1\n")
    File.write(File.join(reviews, "browser-result-01-01.json"), "{\"status\":\"failed\"}\n")
    File.write(File.join(reviews, "fix-success-01.md"), "old sentinel\n")
    File.write(File.join(reviews, "fix-guardrail-01.md"), "old guardrail\n")
    File.write(File.join(reviews, "nested-validation", "output.log"), "old nested output\n")
    FileUtils.mkdir_p(File.join(@wt, "build"))
    File.write(File.join(@wt, "build", "cache.o"), "ignored-build-output")

    # Push force-pushed commit B to remote PR ref.
    push_pr_head!(@oid_b)

    gh = stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ])
    result = build_reconciler(gh: gh, tx_ids: [ "tx0002" ]).reconcile(task: @task, mode: :explicit_reopen)

    assert_equal "reopened", result.status
    assert_equal "head_changed", result.reason
    refute result.retryable
    assert_equal 2, result.generation
    assert_equal @oid_b, result.head_oid
    assert_equal @oid_a, result.previous_head_oid
    assert_equal @oid_b, result.candidate_oid
    assert_match(/\A[0-9a-f]{64}\z/, result.checkout_digest)
    assert_equal "tx0002", result.transaction_id

    # Git checkout moved to exact force-pushed OID B; ignored build cache survived.
    assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip
    assert_equal @branch, git(@wt, "symbolic-ref", "--short", "HEAD").strip
    assert_equal "puts 'head-B'\n", File.read(File.join(@wt, "app.rb"))
    assert_equal "ignored-build-output", File.read(File.join(@wt, "build", "cache.o"))

    # Old candidate A preserved via immutable archive ref; quarantine ref cleaned up.
    archive_ref = Hive::InternalPrCheckout::Identity.candidate_archive_ref_for(
      pr_number: 42, generation: 1, transaction_id: "tx0002"
    )
    assert_equal @oid_a, git(@wt, "rev-parse", "--verify", archive_ref).strip
    q_ref = Hive::InternalPrCheckout::Identity.quarantine_ref_for("tx0002")
    refute system("git", "-C", @wt, "show-ref", "--verify", "--quiet", q_ref)

    # Canonical pr.md & worktree.yml projections updated; pr_url retained.
    pr_fm = Hive::Gh.pr_frontmatter(File.join(@task_folder, "pr.md"))
    assert_equal @oid_b, pr_fm["head_oid"]
    refute pr_fm.key?("head_ref_oid")
    assert_equal @pr_url, pr_fm["pr_url"]
    pointer = YAML.safe_load_file(File.join(@task_folder, "worktree.yml"))
    assert_equal @oid_b, pointer["execute_base_head"]

    # AE6: Both REVIEW_COMPLETE and REVIEW_WAITING stripped; prose & unrelated marker intact!
    task_body = File.read(File.join(@task_folder, "task.md"))
    refute_includes task_body, "REVIEW_COMPLETE"
    refute_includes task_body, "REVIEW_WAITING"
    assert_includes task_body, "Keep this exact prose line untouched."
    assert_includes task_body, "<!-- CUSTOM_OPERATOR_NOTE owner=human -->"
    assert_equal "unrelated operator notes\n", File.read(File.join(@task_folder, "notes.md"))

    # AE7: Flat active reviews/ has ONLY archive/; github-publication.json moved to archive.
    assert_equal [ "archive" ], Dir.children(reviews)
    refute File.exist?(File.join(@task_folder, "github-publication.json"))
    assert_equal 2, Hive::Stages::Review::PassArchive.generation(@task_folder)

    label = Hive::InternalPrCheckout::Identity.retirement_label_for(transaction_id: "tx0002", target_oid: @oid_b)
    archived = File.join(reviews, "archive", label)
    assert File.file?(File.join(archived, "retirement.json"))
    assert File.file?(File.join(archived, "claude-01.md"))
    assert File.file?(File.join(archived, "suppressed.md"))
    assert File.file?(File.join(archived, "ci-blocked.md"))
    assert File.file?(File.join(archived, "deferred-findings.md"))
    assert File.file?(File.join(archived, "escalations-01.md"))
    assert File.file?(File.join(archived, "browser-result-01-01.json"))
    assert File.file?(File.join(archived, "fix-success-01.md"))
    assert File.file?(File.join(archived, "fix-guardrail-01.md"))
    assert File.file?(File.join(archived, "nested-validation", "output.log"))
    assert File.file?(File.join(archived, "head-state", "github-publication.json"))
    assert_includes File.read(File.join(archived, "head-state", "state-file-before.md")), "REVIEW_COMPLETE"

    # Pending cleared and history integrity verified.
    store = Hive::InternalPrCheckout::Store.new(@task_folder)
    refute store.pending_present?
    assert store.verify_history_integrity!
  end

  def test_ae6_manual_steering_hold_prevents_mutation_and_network_calls
    File.write(File.join(@task_folder, "task.md"), <<~MD)
      ---
      id: "0042"
      source: ad-hoc
      ---
      <!-- MANUAL_STEERING agent=claude started_at=2026-08-29T12:00:00Z -->
    MD
    push_pr_head!(@oid_b)
    before_fs = snapshot_tree(@task_folder)
    before_git = snapshot_git(@wt, @branch)

    gh_calls = 0
    gh = Object.new
    gh.define_singleton_method(:validated_pr_metadata) { |*| gh_calls += 1; raise "must not call gh" }

    result = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "busy", result.status
    assert_equal "manual_steering", result.reason
    refute result.retryable
    assert_equal 0, gh_calls
    assert_equal before_fs, snapshot_tree(@task_folder)
    assert_equal before_git, snapshot_git(@wt, @branch)
  end

  def test_ae4_preflight_refusals_make_zero_remote_or_write_calls_and_target_obstruction_cleans_fetch
    gh_calls = 0
    gh = Object.new
    gh.define_singleton_method(:validated_pr_metadata) { |*| gh_calls += 1; raise "must not call gh" }

    # 1. Missing worktree.yml
    orig_pointer = File.read(File.join(@task_folder, "worktree.yml"))
    File.unlink(File.join(@task_folder, "worktree.yml"))
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "pointer_missing", res.reason
    assert_equal 0, gh_calls

    # 2. Duplicate YAML key in worktree.yml
    File.write(File.join(@task_folder, "worktree.yml"), "path: #{@wt}\nbranch: #{@branch}\nbranch: #{@branch}\n")
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "pointer_malformed", res.reason
    assert_equal 0, gh_calls

    # 3. Wrong branch in worktree.yml
    File.write(File.join(@task_folder, "worktree.yml"), YAML.dump("path" => @wt, "branch" => "other/branch", "execute_base_head" => @oid_a))
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "pointer_unowned", res.reason
    assert_equal 0, gh_calls
    File.write(File.join(@task_folder, "worktree.yml"), orig_pointer)

    # 4. Detached HEAD
    git(@wt, "checkout", "--detach", @oid_a)
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "checkout_detached", res.reason
    assert_equal 0, gh_calls
    git(@wt, "checkout", @branch)

    # 5. Dirty working tree
    File.write(File.join(@wt, "dirty.txt"), "untracked")
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "checkout_dirty", res.reason
    assert_equal 0, gh_calls
    File.unlink(File.join(@wt, "dirty.txt"))

    # 6. Unsafe git config
    git(@project, "config", "remote.origin.uploadpack", "/bin/true")
    res = build_reconciler(gh: gh).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "git_config_unsafe", res.reason
    assert_equal 0, gh_calls
    git(@project, "config", "--unset", "remote.origin.uploadpack")

    # 7. Target-tree ignored obstruction (detectable only after fetch):
    #    must safely clean up quarantine ref & pending.json and preserve ignored bytes!
    File.write(File.join(@wt, "obstructed.txt"), "operator-secret-ignored\n")
    push_pr_head!(@oid_b)
    res = build_reconciler(gh: stub_gh([ meta_for(@oid_b) ]), tx_ids: [ "txobs1" ]).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res.status
    assert_equal "checkout_dirty", res.reason
    assert_equal "operator-secret-ignored\n", File.read(File.join(@wt, "obstructed.txt"))
    assert_equal @oid_a, git(@wt, "rev-parse", "HEAD").strip
    refute Hive::InternalPrCheckout::Store.new(@task_folder).pending_present?
    refute system("git", "-C", @wt, "show-ref", "--verify", "--quiet",
                  Hive::InternalPrCheckout::Identity.quarantine_ref_for("txobs1"))
  end

  def test_ae5_crash_after_fetch_before_journal_then_repush_cleans_quarantine_and_recovers
    push_pr_head!(@oid_b)
    failpoint = lambda do |phase, _payload|
      raise InjectedCrash, "boom at #{phase}" if phase == :after_fetch_before_fetched_journal
    end

    assert_raises(InjectedCrash) do
      build_reconciler(gh: stub_gh([ meta_for(@oid_b) ]), tx_ids: [ "txfetch1" ], failpoint: failpoint)
        .reconcile(task: @task, mode: :explicit_reopen)
    end

    # Quarantine ref was installed at B, pending.json is still at `prepared`.
    q_ref = Hive::InternalPrCheckout::Identity.quarantine_ref_for("txfetch1")
    assert_equal @oid_b, git(@wt, "rev-parse", "--verify", q_ref).strip
    store = Hive::InternalPrCheckout::Store.new(@task_folder)
    assert_equal "prepared", store.read_pending["phase"]

    # Local continuation on unconfirmed pending defers with remote_observation_required (zero gh calls).
    local_res = build_reconciler(gh: Object.new).reconcile(task: @task, mode: :local_verify)
    assert_equal "blocked", local_res.status
    assert_equal "remote_observation_required", local_res.reason
    assert local_res.retryable
    assert store.pending_present?

    # Now repush remote PR to C! Explicit reopen must clean old quarantine ref by expected OID B
    # and cleanly commit C from last committed state A.
    push_pr_head!(@oid_c)
    res = build_reconciler(gh: stub_gh([ meta_for(@oid_c), meta_for(@oid_c) ]), tx_ids: [ "txrec2" ])
          .reconcile(task: @task, mode: :explicit_reopen)

    assert_equal "reopened", res.status
    assert_equal "pending_recovered_reopened", res.reason
    assert_equal @oid_c, res.head_oid
    assert_equal 2, res.generation
    assert_equal @oid_c, git(@wt, "rev-parse", "HEAD").strip
    refute system("git", "-C", @wt, "show-ref", "--verify", "--quiet", q_ref)
    refute store.pending_present?
    assert_equal 2, Hive::Stages::Review::PassArchive.generation(@task_folder)
  end

  def test_ae5_failpoints_across_every_phase_converge_with_single_retirement_and_single_grant_expiry
    phases = %i[
      after_prepared
      after_fetch_before_fetched_journal
      after_candidate_archive_ref
      after_fetched
      after_checked_out
      after_confirmed
      after_budget_expiry
      after_archive_dir_created
      after_retirement_receipt
      after_first_archive_move
      after_pass_archive_retire
      after_partial_head_moves
      after_archived
      after_projected
      after_current_published
      after_quarantine_cleanup
    ]

    phases.each_with_index do |target_phase, idx|
      # Reset clean task state for each phase test
      teardown
      setup
      grant_token = seed_active_review_grant_and_files!
      push_pr_head!(@oid_b)

      tx_id = format("txp%02d", idx)
      fp = ->(phase, _payload) { raise InjectedCrash, "crash at #{phase}" if phase == target_phase }
      assert_raises(InjectedCrash, "expected crash at #{target_phase}") do
        build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ]), tx_ids: [ tx_id ], failpoint: fp)
          .reconcile(task: @task, mode: :explicit_reopen)
      end

      # Post-confirmation crashes must also roll forward via `:local_verify` with ZERO provider I/O!
      confirmed_phase = %i[
        after_confirmed after_budget_expiry after_archive_dir_created after_retirement_receipt
        after_first_archive_move after_pass_archive_retire after_partial_head_moves
        after_archived after_projected after_current_published after_quarantine_cleanup
      ].include?(target_phase)

      if confirmed_phase
        no_gh = Object.new
        no_gh.define_singleton_method(:validated_pr_metadata) { |*| raise "must not call gh during confirmed recovery" }
        rec = build_reconciler(gh: no_gh).reconcile(task: @task, mode: :local_verify)
      else
        rec = build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ])).reconcile(task: @task, mode: :explicit_reopen)
      end

      assert_equal "reopened", rec.status, "failed recovery for phase #{target_phase}: #{rec.inspect}"
      assert_equal "pending_recovered_reopened", rec.reason
      assert_equal tx_id, rec.transaction_id, "must reuse transaction_id at phase #{target_phase}"
      assert_equal 2, rec.generation
      assert_equal @oid_b, rec.head_oid
      assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip

      # Exactly ONE retirement directory and ONE expiry entry per grant!
      assert_equal 2, Hive::Stages::Review::PassArchive.generation(@task_folder), "duplicate archive at #{target_phase}"
      audit_lines = File.readlines(File.join(@task_folder, "review-budget", "audit.jsonl")).map { |l| JSON.parse(l) }
      expiries = audit_lines.select { |e| e["event"] == "expiry" && e["expiry_reason"] == "internal_pr_head_changed" }
      assert_equal 1, expiries.length, "expected exactly 1 expiry at #{target_phase}, got #{expiries.length}"

      # Archived grant resolves cleanly via O(1) indexed store.
      budget = Hive::ReviewBudget.new(task: @task, project: @task.project_name)
      found = budget.store.archived_grant(grant_token)
      assert found, "archived_grant missing after recovery from #{target_phase}"
      assert_equal grant_token, found.fetch("observation_digest")
    end
  end

  def test_ae8_late_remote_race_restores_prior_state_and_fences_obstructed_rollback
    grant_token = seed_active_review_grant_and_files!
    before_fs = snapshot_tree(@task_folder)
    before_git = snapshot_git(@wt, @branch)

    # Initial observation returns B, checkout moves to B, final observation sees C!
    push_pr_head!(@oid_b)
    gh = stub_gh([ meta_for(@oid_b), meta_for(@oid_c) ])
    res = build_reconciler(gh: gh, tx_ids: [ "txrace1" ]).reconcile(task: @task, mode: :explicit_reopen)

    assert_equal "blocked", res.status
    assert_equal "remote_changed_before_linearization", res.reason
    assert res.retryable

    # Restored task bytes, branch, HEAD, refs, and zero expiries!
    assert_equal before_fs, snapshot_tree(@task_folder)
    assert_equal before_git, snapshot_git(@wt, @branch)
    audit_lines = File.readlines(File.join(@task_folder, "review-budget", "audit.jsonl")).map { |l| JSON.parse(l) }
    assert_empty audit_lines.select { |e| e["event"] == "expiry" }
    assert Hive::ReviewBudget.new(task: @task, project: @task.project_name).store.grants.any? { |g| g["observation_digest"] == grant_token }

    # Operator obstruction during rollback: inject ignored file blocking restore to A
    # right before rollback runs -> must preserve bytes and keep pending.json fenced!
    common_dir = git(@wt, "rev-parse", "--git-common-dir").strip
    FileUtils.mkdir_p(File.join(common_dir, "info"))
    fp = lambda do |phase, _payload|
      if phase == :before_rollback_checkout
        File.write(File.join(common_dir, "info", "exclude"), "only_a.txt\n")
        File.write(File.join(@wt, "only_a.txt"), "precious-operator-file")
      end
    end
    res2 = build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_c) ]), tx_ids: [ "txrace2" ], failpoint: fp)
           .reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res2.status
    assert_equal "checkout_dirty", res2.reason
    refute res2.retryable
    assert_equal "precious-operator-file", File.read(File.join(@wt, "only_a.txt"))
    assert Hive::InternalPrCheckout::Store.new(@task_folder).pending_present?
  end

  def test_ae9_head_returns_to_earlier_oid_a_to_b_to_a_gets_ordinals_1_2_3_and_distinct_digests
    # Gen 1 (OID A) -> Gen 2 (OID B)
    push_pr_head!(@oid_b)
    r1 = build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ]), tx_ids: [ "txaba1" ])
         .reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "reopened", r1.status
    assert_equal 2, r1.generation
    assert_equal @oid_b, r1.head_oid

    # Gen 2 (OID B) -> Gen 3 (back to OID A!)
    push_pr_head!(@oid_a)
    r2 = build_reconciler(gh: stub_gh([ meta_for(@oid_a), meta_for(@oid_a) ]), tx_ids: [ "txaba2" ])
         .reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "reopened", r2.status
    assert_equal 3, r2.generation
    assert_equal @oid_a, r2.head_oid
    assert_equal @oid_b, r2.previous_head_oid
    assert_equal 3, Hive::Stages::Review::PassArchive.generation(@task_folder)
    refute_equal r1.checkout_digest, r2.checkout_digest
    refute_nil r2.checkout_digest
  end

  def test_legacy_task_adoption_with_head_ref_oid_and_preexisting_archive
    teardown
    setup
    setup_internal_pr_task!(head_oid: @oid_a, legacy: true)

    # Preexisting validated archive makes implicit ordinal = 2.
    pre_dir = File.join(@task_folder, "reviews", "archive", "20260801T000000Z-7-artifacts-to-6-review")
    FileUtils.mkdir_p(pre_dir)
    File.write(File.join(pre_dir, "claude-01.md"), "old archived pass\n")

    before_fs = snapshot_tree(@task_folder)

    # Unchanged head stays zero-write with nil head_transition_digest.
    res = build_reconciler(gh: stub_gh([ meta_for(@oid_a) ])).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "current", res.status
    assert_equal 2, res.generation
    assert_nil res.checkout_digest
    assert_equal before_fs, snapshot_tree(@task_folder)

    # First changed head retires ordinal 2 -> publishes ordinal 3, canonical head_oid, preserves old archive!
    push_pr_head!(@oid_b)
    res2 = build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ]), tx_ids: [ "txleg1" ])
           .reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "reopened", res2.status
    assert_equal 3, res2.generation
    assert_equal @oid_b, res2.head_oid
    assert_equal 3, Hive::Stages::Review::PassArchive.generation(@task_folder)
    assert File.file?(File.join(pre_dir, "claude-01.md"))

    pr_fm = Hive::Gh.pr_frontmatter(File.join(@task_folder, "pr.md"))
    assert_equal @oid_b, pr_fm["head_oid"]
    refute pr_fm.key?("head_ref_oid")
  end

  def test_candidate_provenance_from_real_write_fix_success_vs_forged_stale_and_diverged
    # Make a clean descendant commit in the owned worktree.
    File.write(File.join(@wt, "fix.rb"), "puts 'fixed'\n")
    git(@wt, "add", "fix.rb")
    git(@wt, "commit", "-m", "Hive review fix")
    cand_oid = git(@wt, "rev-parse", "HEAD").strip

    # 1. Without candidate.json (even with legacy fix-success sentinel on disk!), blocks with candidate_unproven!
    File.write(File.join(@task_folder, "reviews", "fix-success-01.md"), "<!-- HIVE: fix-success sentinel for pass 01; head=#{cand_oid} kind=fixed -->\n")
    push_pr_head!(@oid_b)
    gh_calls = 0
    gh_fail = Object.new
    gh_fail.define_singleton_method(:validated_pr_metadata) { |*| gh_calls += 1; raise "must not call gh" }

    blocked = build_reconciler(gh: gh_fail).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", blocked.status
    assert_equal "candidate_unproven", blocked.reason
    assert_equal 0, gh_calls

    # 2. Run the REAL Review.write_fix_success controller path!
    ctx = Hive::Stages::Review::Context.new(
      worktree_path: @wt, task_folder: @task_folder, default_branch: "main", pass: 1
    )
    Hive::Stages::Review.write_fix_success(ctx, kind: "fixed")
    store = Hive::InternalPrCheckout::Store.new(@task_folder)
    assert store.candidate_present?
    assert_equal cand_oid, store.read_candidate["candidate_oid"]

    # 3. Stray extra candidate file blocks as multiply-matching candidate_unproven!
    stray = File.join(store.store_dir, "candidate-copy.json")
    File.write(stray, "{}\n")
    res_stray = build_reconciler(gh: gh_fail).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res_stray.status
    assert_equal "candidate_unproven", res_stray.reason
    File.unlink(stray)

    # 4. Wrong PR / wrong generation in candidate.json blocks!
    orig_cand = store.read_candidate
    store.write_candidate!(orig_cand.merge("generation" => 99))
    res_wrong_gen = build_reconciler(gh: gh_fail).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res_wrong_gen.status
    assert_equal "candidate_unproven", res_wrong_gen.reason
    store.write_candidate!(orig_cand)

    # 5. Valid sealed candidate succeeds on repush and preserves `cand_oid` at candidate_archive_ref!
    res_ok = build_reconciler(gh: stub_gh([ meta_for(@oid_b), meta_for(@oid_b) ]), tx_ids: [ "txcand1" ])
             .reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "reopened", res_ok.status
    assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip
    cand_ref = Hive::InternalPrCheckout::Identity.candidate_archive_ref_for(
      pr_number: 42, generation: 1, transaction_id: "txcand1"
    )
    assert_equal cand_oid, git(@wt, "rev-parse", "--verify", cand_ref).strip
    refute store.candidate_present?

    # 6. Diverged non-descendant checkout (reset to unrelated commit C without candidate) blocks as checkout_diverged!
    git(@wt, "reset", "--hard", @oid_c)
    res_div = build_reconciler(gh: gh_fail).reconcile(task: @task, mode: :explicit_reopen)
    assert_equal "blocked", res_div.status
    assert_equal "checkout_diverged", res_div.reason
    assert_equal 0, gh_calls
  end

  private

  def setup_internal_pr_task!(head_oid:, legacy:)
    FileUtils.rm_rf(@task_folder)
    FileUtils.rm_rf(@wt)
    git(@project, "worktree", "prune")
    system("git", "-C", @project, "branch", "-D", @branch, out: File::NULL, err: File::NULL)
    git(@project, "worktree", "add", "-b", @branch, @wt, head_oid)

    FileUtils.mkdir_p(File.join(@task_folder, "reviews"))
    File.write(File.join(@task_folder, "meta.yml"), YAML.dump("id" => "0042", "slug" => @slug, "workflow" => "coding"))
    File.write(File.join(@task_folder, "task.md"), "---\nid: \"0042\"\nsource: ad-hoc\n---\n# Review PR 42\n")
    pr_key = legacy ? "head_ref_oid" : "head_oid"
    File.write(File.join(@task_folder, "pr.md"), <<~MD)
      ---
      source: ad-hoc
      pr_number: 42
      pr_url: #{@pr_url}
      base_ref_name: main
      head_ref_name: contributor-branch
      head_repository: fork-user/widget
      is_cross_repository: true
      state: OPEN
      #{pr_key}: #{head_oid}
      ---
      # PR 42
    MD
    pointer = { "path" => @wt, "branch" => @branch, "slug" => @slug, "base_branch" => "main" }
    pointer["execute_base_head"] = head_oid unless legacy
    File.write(File.join(@task_folder, "worktree.yml"), YAML.dump(pointer))

    @task = Hive::Task.new(@task_folder)

    unless legacy
      Hive::InternalPrCheckout.initialize_new_task!(
        task_folder: @task_folder,
        task_id: @task.id.to_s,
        task_slug: @slug,
        project: @task.project_name.to_s,
        pr_host: "github.com",
        pr_repository: "acme/widget",
        pr_number: 42,
        pr_url: @pr_url,
        base_ref_name: "main",
        head_ref_name: "contributor-branch",
        head_repository: "fork-user/widget",
        is_cross_repository: true,
        pr_state: "OPEN",
        branch: @branch,
        head_oid: head_oid,
        clock: -> { Time.utc(2026, 8, 29, 12, 0, 0) }
      )
    end
  end

  def seed_active_review_grant_and_files!
    reviews = File.join(@task_folder, "reviews")
    FileUtils.mkdir_p(reviews)
    File.chmod(0o700, reviews)
    File.write(File.join(reviews, "claude-01.md"), "finding 1\n")
    File.write(File.join(reviews, "claude-02.md"), "finding 2\n")
    File.write(File.join(reviews, "suppressed.md"), "suppressed\n")
    File.write(File.join(@task_folder, "github-publication.json"), "{\"head\":\"#{@oid_a}\"}\n")

    proj = @task.project_name.to_s
    tid = @task.id.to_s
    scope = { "anchor_artifacts" => {}, "first_pass" => 1, "history_digest" => "0" * 64 }
    marker_raw = Hive::Markers.build_marker("REVIEW_STALE", "reason" => "final_fix_unverified", "pass" => "2")
    marker = { "attrs" => { "pass" => "2", "reason" => "final_fix_unverified" }, "name" => "review_stale", "raw" => marker_raw }
    esc_proof = Hive::ReviewBudget::EscalationProof.capture("escalations-02.md", "### Q1. Confirm?\n### A1. Yes\n")
    evidence = {
      "artifacts" => { "claude-01.md" => Digest::SHA256.hexdigest("finding 1\n") },
      "escalation_proof" => esc_proof,
      "head" => @oid_a,
      "marker" => marker,
      "ownership" => { "task_generation" => 0 },
      "pass" => 2,
      "project" => proj,
      "receipt_chain_digest" => Hive::ReviewBudget::EMPTY_CHAIN,
      "resume_evidence" => nil,
      "scope" => scope,
      "task" => @slug,
      "task_generation" => 0,
      "task_id" => tid,
      "worktree" => nil
    }
    token = Hive::ReviewBudget.digest(evidence)
    decision = { passes: 1, reason: "test grant" }
    grant = {
      "schema" => Hive::ReviewBudget::Store::GRANT_SCHEMA,
      "schema_version" => 1,
      "project" => proj,
      "task" => @slug,
      "task_id" => tid,
      "task_generation" => 0,
      "scope" => scope,
      "sequence" => 1,
      "observation_digest" => token,
      "evidence" => evidence,
      "previous_receipt_digest" => Hive::ReviewBudget::EMPTY_CHAIN,
      "amount" => 1,
      "reason" => "test grant",
      "caller" => "test",
      "source" => "cli",
      "decision_id" => Hive::ReviewBudget.digest([ proj, tid, @slug, token, decision ]),
      "recorded_at" => Time.utc(2026, 8, 29, 12, 0, 0).iso8601(6)
    }
    budget = Hive::ReviewBudget.new(task: @task, project: proj)
    receipt = budget.store.write_grant!(grant)
    budget.reconcile_audit!(receipt)
    token
  end

  def push_pr_head!(oid)
    git(@project, "push", "-f", "origin", "#{oid}:refs/pull/42/head")
  end

  def meta_for(oid, state: "OPEN")
    Hive::Gh::PrMetadata.new(
      number: 42,
      url: @pr_url,
      base_ref_name: "main",
      head_ref_oid: oid,
      is_cross_repository: true,
      state: state,
      is_draft: false,
      head_ref_name: "contributor-branch",
      head_repository: "fork-user/widget",
      host: "github.com",
      repository: "acme/widget"
    )
  end

  def stub_gh(responses)
    queue = responses.dup
    gh = Object.new
    gh.define_singleton_method(:validated_pr_metadata) do |*_args, **_kwargs|
      raise Hive::GhError, "unexpected extra validated_pr_metadata call" if queue.empty?

      val = queue.shift
      raise val if val.is_a?(Exception)

      val
    end
    gh
  end

  def build_reconciler(gh:, tx_ids: [ "tx0001" ], failpoint: nil)
    ids = tx_ids.dup
    Hive::InternalPrCheckout::Reconciler.new(
      gh: gh,
      clock: -> { Time.utc(2026, 8, 29, 12, 30, 0) },
      id_generator: -> { ids.shift || SecureRandom.hex(8) },
      allow_local_transport: true,
      failpoint: failpoint
    )
  end

  def snapshot_tree(root)
    entries = {}
    walk = lambda do |dir, prefix|
      Dir.children(dir).sort.each do |name|
        rel = prefix.empty? ? name : "#{prefix}/#{name}"
        full = File.join(dir, name)
        stat = File.lstat(full)
        if stat.symlink?
          entries[rel] = [ :symlink, File.readlink(full) ]
        elsif stat.directory?
          entries[rel] = [ :dir, stat.mode & 0o7777 ]
          walk.call(full, rel)
        elsif stat.file?
          entries[rel] = [ :file, stat.mode & 0o7777, File.binread(full) ]
        end
      end
    end
    walk.call(root, "")
    entries
  end

  def snapshot_git(wt, branch)
    {
      head: git(wt, "rev-parse", "HEAD").strip,
      symref: git(wt, "symbolic-ref", "HEAD").strip,
      branch_oid: git(wt, "rev-parse", "refs/heads/#{branch}").strip,
      status: git(wt, "status", "--porcelain=v1", "-z"),
      index: git(wt, "ls-files", "--stage", "-z"),
      refs: git(wt, "for-each-ref", "--format=%(refname) %(objectname)")
    }
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
