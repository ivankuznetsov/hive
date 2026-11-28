require "test_helper"
require "hive/attempts/generation"

class AttemptsGenerationTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:id, :slug, :state_file, :stage_index, :stage_name, keyword_init: true)

  ProjectTask = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root,
    keyword_init: true
  )

  FolderTask = Struct.new(:folder, :state_file, keyword_init: true)
  WorkflowIdTask = Struct.new(:folder, :state_file, :workflow, keyword_init: true)

  def test_stable_task_id_stage_and_artifact_identity_form_generation
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "body\n<!-- WAITING -->\n")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 3, stage_name: "plan")

      first = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      second = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      next_stage = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "4-execute")

      assert_equal first.task_generation, second.task_generation
      assert_equal first.task_generation, first.ownership_generation
      assert_equal 0, first.task_input_epoch
      refute_equal first.task_generation, next_stage.task_generation
      assert_equal "id:42", first.task_locator
      assert_match(/\A[0-9a-f]{64}\z/, first.progress_token)
    end
  end


  def test_explicit_input_epoch_is_numeric_and_does_not_replace_ownership_generation
    task = FakeTask.new(id: 42, slug: "task-one", state_file: "/missing")
    generation = Hive::Attempts::Generation.resolve(
      task: task, project: "demo", intended_stage: "4-execute",
      ownership_generation: "opaque-owner", task_input_epoch: 9
    )

    assert_equal "opaque-owner", generation.task_generation
    assert_equal "opaque-owner", generation.ownership_generation
    assert_equal 9, generation.task_input_epoch
  end

  def test_current_input_epoch_accepts_a_workflow_id_without_a_descriptor
    with_tmp_dir do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "task\n<!-- WAITING -->\n")
      task = WorkflowIdTask.new(
        folder: folder, state_file: state_file, workflow: "routine"
      )

      assert_equal 0, Hive::Attempts::Generation.current_task_input_epoch(task)
    end
  end

  def test_legacy_locator_and_progress_change_are_deterministic
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "one")
      task = FakeTask.new(id: nil, slug: "legacy-task", state_file: state_file,
                          stage_index: 1, stage_name: "inbox")
      one = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")
      File.write(state_file, "two")
      two = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")

      assert_equal "project:demo/slug:legacy-task", one.task_locator
      refute_equal one.progress_token, two.progress_token
      refute_equal one.task_generation, two.task_generation
    end
  end

  def test_missing_and_unreadable_artifacts_have_stable_tokens
    with_tmp_dir do |dir|
      task = FakeTask.new(id: 1, slug: "missing", state_file: File.join(dir, "missing"))
      missing = Hive::Attempts::Generation.artifact_token(task)
      assert_match(/\A[0-9a-f]{64}\z/, missing)

      File.write(task.state_file, "body")
      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        unreadable = Hive::Attempts::Generation.artifact_token(task)
        assert_match(/\A[0-9a-f]{64}\z/, unreadable)
        refute_equal missing, unreadable
      end
    end
  end

  def test_dependency_admission_change_advances_generation
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "unchanged")
      task = ProjectTask.new(
        id: 42, slug: "dependent", state_file: state_file,
        stage_index: 4, stage_name: "execute", project_root: dir
      )
      fingerprint = "wait"
      resolver = ->(_task) { fingerprint }

      with_replaced_singleton_method(Hive::DependencySnapshot, :admission_fingerprint, resolver) do
        waiting = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )
        same_wait = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )
        fingerprint = "clear"
        clear = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )

        assert_equal waiting.task_generation, same_wait.task_generation
        refute_equal waiting.progress_token, clear.progress_token
        refute_equal waiting.task_generation, clear.task_generation
      end
    end
  end

  def test_downstream_attempt_uses_current_journal_task_generation
    with_tmp_dir do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "pr.md")
      File.write(state_file, "body")
      record = Hive::TaskJournal::Envelope.authoritative(
        {
          event_type: "generation_advanced",
          task: { "id" => "42", "slug" => "task-one" }, workflow: "coding",
          stage: "4-execute", attempt_id: "attempt-1", task_generation: 7,
          ownership_generation: "owner-7", commit_generation: 0,
          reason: "input_changed", evidence: [], provenance: {}, payload: {}
        }
      )
      File.write(
        File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME),
        "#{JSON.generate(record)}\n"
      )
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")

      generation = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "5-open-pr"
      )

      assert_equal 7, generation.task_input_epoch
    end
  end

  def test_downstream_generation_rejects_malformed_but_accepts_self_contained_history
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "body")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")
      journal = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      File.write(journal, "not-json\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::Attempts::Generation.current_task_input_epoch(task)
      end

      record = Hive::TaskJournal::Envelope.authoritative(
        {
          event_type: "generation_advanced",
          task: { "id" => "42", "slug" => "task-one" }, workflow: "coding",
          stage: "4-execute", attempt_id: "missing-attempt", task_generation: 7,
          ownership_generation: "owner-7", commit_generation: 0,
          reason: "input_changed", evidence: [], provenance: {}, payload: {}
        }
      )
      File.write(journal, "#{JSON.generate(record)}\n")
      assert_equal 7, Hive::Attempts::Generation.current_task_input_epoch(task)
    end
  end

  def test_downstream_generation_reads_the_authoritative_journal_directly
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "body")
      record = Hive::TaskJournal::Envelope.authoritative(
        {
        event_type: "generation_advanced", task: { "id" => "42", "slug" => "task-one" },
        workflow: "coding", stage: "4-execute", attempt_id: "gone", task_generation: 3,
        ownership_generation: "owner-3", commit_generation: 0, reason: "input_changed",
        evidence: [], provenance: { "source" => "test" }, payload: {}
        }
      )
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "#{JSON.generate(record)}\n")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 5, stage_name: "open-pr")

      assert_equal 3, Hive::Attempts::Generation.current_task_input_epoch(task)
    end
  end

  def test_current_input_epoch_uses_task_folder_and_accepts_empty_history
    with_tmp_dir do |dir|
      nested_state = File.join(dir, "elsewhere", "pr.md")
      task = FolderTask.new(folder: dir, state_file: nested_state)
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "")

      assert_equal 0, Hive::Attempts::Generation.current_task_input_epoch(task)
    end
  end

  def test_current_input_epoch_normalizes_a_non_integer_projection_generation
    projection = Object.new
    projection.define_singleton_method(:to_h) do
      { "identity" => { "task_generation" => "not-an-integer" } }
    end
    bounded = Hive::TaskProjection::Reader::BoundedRead.new(
      projection: projection, state: "current", diagnostics: [], truncated: false,
      journal_cursor: 0, journal_records: []
    )
    store = Object.new
    store.define_singleton_method(:read_routine) { |**| bounded }
    task = FolderTask.new(folder: "/tmp/task", state_file: "/tmp/task/pr.md")

    with_replaced_singleton_method(Hive::TaskProjection::Reader, :new, ->(**) { store }) do
      error = assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::Attempts::Generation.current_task_input_epoch(task)
      end
      assert_match(/invalid value for Integer/, error.message)
    end
  end

  def test_current_input_epoch_does_not_open_legacy_attempt_storage
    with_tmp_dir do |dir|
      task = FolderTask.new(folder: dir, state_file: File.join(dir, "pr.md"))
      with_env("HIVE_HOME" => dir, "HIVE_ATTEMPT_STORE_ROOT" => File.join(dir, "legacy-attempts")) do
        assert_equal 0, Hive::Attempts::Generation.current_task_input_epoch(task)
        refute File.exist?(File.join(dir, "legacy-attempts"))
      end
    end
  end

  def test_internal_pr_generation_preserves_legacy_identity_and_changes_across_all_producers
    require "hive/internal_pr_checkout"
    require "hive/daemon/recovery_coordinator"
    require "hive/daemon/dispatcher"
    require "hive/workflow_admission"

    with_tmp_dir do |dir|
      project_root = File.join(dir, "repo")
      folder = File.join(project_root, ".hive-state", "stages", "6-review", "adhoc-review-pr-42")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), {
        "id" => 42, "slug" => "adhoc-review-pr-42", "source" => "ad-hoc", "workflow" => "coding"
      }.to_yaml)
      oid_a = "a" * 40
      oid_b = "b" * 40
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 42
        pr_url: https://github.com/acme/repo/pull/42
        head_ref_oid: #{oid_a}
        ---
        PR body
      MD
      state_file = File.join(folder, "task.md")
      File.write(state_file, "Review task\n<!-- REVIEW_ERROR reason=agent_failed -->\n")

      task = Struct.new(
        :id, :slug, :state_file, :stage_index, :stage_name, :project_root, :folder, :workflow,
        keyword_init: true
      ).new(
        id: 42, slug: "adhoc-review-pr-42", state_file: state_file,
        stage_index: 6, stage_name: "review", project_root: project_root,
        folder: folder, workflow: "coding"
      )

      # Pre-deploy baseline (non-ad-hoc identical bytes) must equal legacy implicit gen 1.
      baseline_digest = Digest::SHA256.new
      baseline_digest << "hive-progress-v2\0"
      baseline_digest << state_file
      baseline_digest << File.binread(state_file)
      baseline_digest << "\0dependency-admission\0"
      baseline_digest << Hive::DependencySnapshot.admission_fingerprint(task)
      expected_legacy_token = baseline_digest.hexdigest

      legacy_gen = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "6-review"
      )
      assert_equal expected_legacy_token, legacy_gen.progress_token

      # Explicit gen 1 (head_transition_digest: nil) keeps the exact same legacy token.
      Hive::InternalPrCheckout.initialize_new_task!(
        task_folder: folder, task_id: "42", task_slug: "adhoc-review-pr-42", project: "demo",
        pr_host: "github.com", pr_repository: "acme/repo", pr_number: 42,
        pr_url: "https://github.com/acme/repo/pull/42", base_ref_name: "main",
        head_ref_name: "feat", head_repository: "acme/repo", is_cross_repository: false,
        pr_state: "OPEN", branch: "hive/review/pr-42", head_oid: oid_a
      )
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 42
        pr_url: https://github.com/acme/repo/pull/42
        head_oid: #{oid_a}
        ---
        PR body
      MD
      gen1 = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "6-review"
      )
      assert_equal legacy_gen.task_generation, gen1.task_generation

      # Committed head transition to B changes every eligible producer identically.
      store = Hive::InternalPrCheckout::Store.new(folder)
      current = store.read_current
      tx_b = "tx-transition-b"
      ret_label = Hive::InternalPrCheckout::Identity.retirement_label_for(
        transaction_id: tx_b, target_oid: oid_b
      )
      digest_b = Hive::InternalPrCheckout::Store.head_transition_digest(
        pr_url: current.fetch("pr_url"),
        pr_number: current.fetch("pr_number"),
        branch: current.fetch("branch"),
        reviewed_oid: oid_b,
        generation: 2,
        previous_generation: 1,
        retirement_label: ret_label,
        transaction_id: tx_b
      )
      store.write_current!(current.merge(
        "generation" => 2,
        "previous_generation" => 1,
        "retirement_label" => ret_label,
        "transaction_id" => tx_b,
        "reviewed_oid" => oid_b,
        "candidate_oid" => oid_b,
        "head_transition_digest" => digest_b
      ))
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 42
        pr_url: https://github.com/acme/repo/pull/42
        head_oid: #{oid_b}
        ---
        PR body
      MD

      gen2 = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "6-review"
      )
      refute_equal gen1.task_generation, gen2.task_generation
      refute_equal gen1.progress_token, gen2.progress_token

      # Table-test every eligible producer against the exact same generation binding.
      coordinator = Hive::Daemon::RecoveryCoordinator.new(state_home: File.join(dir, "state"))
      rec_pre = coordinator.send(
        :resolve_generation, task,
        project: "demo", intended_stage: "6-review",
        state_file_content: File.binread(state_file)
      )
      assert_equal gen2.task_generation, rec_pre.task_generation

      stripped_bytes = Hive::Markers.without_named_markers(
        File.binread(state_file), Hive::Markers::REVIEW_MARKER_NAMES
      )
      rec_post = coordinator.send(
        :resolve_generation, task,
        project: "demo", intended_stage: "6-review",
        state_file_content: stripped_bytes
      )
      direct_post_token = Hive::Attempts::Generation.artifact_token(
        task, state_file_content: stripped_bytes
      )
      assert_equal direct_post_token, rec_post.progress_token
      refute_equal gen2.task_generation, rec_post.task_generation

      wf_gen = Hive::WorkflowAdmission.generation_for(task, project: "demo")
      assert_equal gen2.ownership_generation, wf_gen

      # Stale supplied task_generation override fails closed with StaleTaskSource.
      assert_raises(Hive::Attempts::StaleTaskSource) do
        Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "6-review",
          task_generation: gen1.task_generation
        )
      end

      # Non-review stages (e.g., 2-brainstorm / Commands::Answer, 7-artifacts) are unaffected.
      brainstorm_task = Struct.new(
        :id, :slug, :state_file, :stage_index, :stage_name, :project_root, :folder, :workflow,
        keyword_init: true
      ).new(
        id: 42, slug: "adhoc-review-pr-42", state_file: state_file,
        stage_index: 2, stage_name: "brainstorm", project_root: project_root,
        folder: folder, workflow: "coding"
      )
      brainstorm_expected = Digest::SHA256.new
      brainstorm_expected << "hive-progress-v2\0"
      brainstorm_expected << state_file
      brainstorm_expected << File.binread(state_file)
      brainstorm_expected << "\0dependency-admission\0"
      brainstorm_expected << Hive::DependencySnapshot.admission_fingerprint(brainstorm_task)
      assert_equal brainstorm_expected.hexdigest, Hive::Attempts::Generation.artifact_token(brainstorm_task)

      # Pending transaction raises InternalPrCheckout::Error instead of hashing a fallback,
      # and Daemon::Dispatcher#bound_task_request_current? defers pending reads to the fence.
      store.write_pending!({
        "schema" => Hive::InternalPrCheckout::Store::PENDING_SCHEMA,
        "schema_version" => 1,
        "transaction_id" => "tx-pending-1",
        "phase" => "prepared",
        "task_id" => "42",
        "task_slug" => "adhoc-review-pr-42",
        "project" => "demo",
        "pr_host" => "github.com",
        "pr_repository" => "acme/repo",
        "pr_number" => 42,
        "pr_url" => "https://github.com/acme/repo/pull/42",
        "branch" => "hive/review/pr-42",
        "worktree_path" => File.join(dir, "wt"),
        "remote_fingerprint" => Digest::SHA256.hexdigest("github.com/acme/repo"),
        "old_generation" => 2,
        "after_generation" => 3,
        "old_reviewed_oid" => oid_b,
        "old_candidate_oid" => oid_b,
        "target_oid" => "c" * 40,
        "quarantine_ref" => Hive::InternalPrCheckout::Identity.quarantine_ref_for("tx-pending-1"),
        "candidate_archive_ref" => Hive::InternalPrCheckout::Identity.candidate_archive_ref_for(
          pr_number: 42, generation: 2, transaction_id: "tx-pending-1"
        ),
        "retirement_label" => Hive::InternalPrCheckout::Identity.retirement_label_for(
          transaction_id: "tx-pending-1", target_oid: "c" * 40
        ),
        "owned_temp_paths" => [],
        "created_at" => "2026-11-28T00:00:00.000000Z",
        "updated_at" => "2026-11-28T00:00:00.000000Z"
      })
      err = assert_raises(Hive::InternalPrCheckout::Error) do
        Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "6-review")
      end
      assert_equal "transition_interrupted", err.reason

      daemon_dispatcher = Hive::Daemon::Dispatcher.allocate
      req = Struct.new(
        :slug, :project, :task_id, :expected_stage, :argv, :task_generation,
        keyword_init: true
      ).new(
        slug: "adhoc-review-pr-42", project: "demo", task_id: "42",
        expected_stage: "6-review", argv: [ "hive", "review", "adhoc-review-pr-42" ],
        task_generation: gen2.task_generation
      )
      resolver_stub = Struct.new(:task) { def resolve = task }.new(task)
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_a, **_kw) { resolver_stub }) do
        assert daemon_dispatcher.send(:bound_task_request_current?, req),
               "daemon early request matching must defer pending internal PR reads to the admission fence"
      end
    end
  end
end
