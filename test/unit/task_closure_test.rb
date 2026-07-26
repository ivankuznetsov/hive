require "test_helper"
require "hive/task_closure"
require "hive/task_meta"
require "json_schemer"

class TaskClosureTest < Minitest::Test
  include HiveTestHelper

  FakeGh = Struct.new(
    :repository, :state, :reachable, :merge_oid, :remote_default_branch,
    :head_oid,
    keyword_init: true
  ) do
    def ensure_authenticated!(*)
      true
    end

    def repository_identity(*, **)
      { "host" => "github.com", "repository" => repository || "acme/app" }
    end

    def closure_pr_facts(host:, repository:, number:, **)
      raise Hive::GhError, "pull request not found" if state == "MISSING"

      {
        "repository" => repository,
        "number" => number,
        "url" => "https://#{host}/#{repository}/pull/#{number}",
        "state" => state || "MERGED",
        "merged_at" => "2026-07-25T10:00:00Z",
        "merge_oid" => merge_oid || ("a" * 40),
        "head_oid" => head_oid || ("b" * 40),
        "base_ref_name" => "main",
        "reachable_from_default" => reachable != false
      }
    end

    def closure_default_branch(**)
      remote_default_branch || "main"
    end

    def closure_commit_facts(oid:, default_branch:, **)
      {
        "oid" => oid,
        "default_branch" => default_branch,
        "comparison" => reachable == false ? "diverged" : "ahead",
        "reachable_from_default" => reachable != false
      }
    end
  end

  EmptyAttempts = Struct.new(:unused) do
    def scan
      Hive::Attempts::Scan.new(records: [], invalid_records: [])
    end
  end

  Attempt = Struct.new(:attempt_id, :state, :payload, keyword_init: true) do
    def [](key) = payload[key]
    def live? = %w[launching running].include?(state)
  end

  AttemptStore = Struct.new(:records, keyword_init: true) do
    def scan
      Hive::Attempts::Scan.new(records: records, invalid_records: [])
    end
  end

  def test_verified_same_repository_merge_closes_and_replays_idempotently
    with_closure_project do |task, project|
      service = service_for
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)

      assert preview.valid?, preview.to_h.inspect
      assert_equal "remote_merge", preview.authority

      receipt = service.confirm!(
        task: task, project: project, input: input,
        preview_digest: preview.preview_digest,
        operator: "tester", channel: "cli", authorized: true
      )
      archived = Hive::TaskResolver.new(task.slug, project_filter: project).resolve
      assert_equal "9-done", "#{archived.stage_index}-#{archived.stage_name}"
      assert_equal :complete, Hive::Markers.current(archived.state_file).name
      assert_equal "already_delivered", receipt.fetch("reason")
      assert File.file?(File.join(archived.folder, "closure.json"))
      assert_equal 0o600, File.stat(File.join(archived.folder, "closure.json")).mode & 0o777

      replay = service.confirm!(
        task: archived, project: project, input: input,
        preview_digest: preview.preview_digest,
        operator: "tester", channel: "cli", authorized: true
      )
      assert_equal receipt.fetch("receipt_digest"), replay.fetch("receipt_digest")
    end
  end

  def test_daemon_reconciles_same_repository_merge_and_replays_idempotently
    with_closure_project do |task, project|
      File.write(
        File.join(task.folder, "pr.md"),
        <<~MD
          ---
          pr_url: https://github.com/acme/app/pull/42
          pr_number: 42
          head_oid: #{"b" * 40}
          ---
        MD
      )
      service = service_for
      receipt = service.reconcile_remote_merge!(
        task: task,
        project: project,
        pr_url: "https://github.com/acme/app/pull/42",
        expected_head: "b" * 40,
        expected_merge_oid: "a" * 40
      )

      archived = Hive::TaskResolver.new(task.slug, project_filter: project).resolve
      assert_equal "9-done", "#{archived.stage_index}-#{archived.stage_name}"
      assert_equal :complete, Hive::Markers.current(archived.state_file).name
      assert_equal "remote_merge", receipt.fetch("authority")
      assert_equal "hive-daemon", receipt.dig("confirmed_by", "operator")
      assert_equal "daemon", receipt.dig("confirmed_by", "channel")

      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path(Hive::TaskClosure::SCHEMA)))
      )
      assert schema.valid?(receipt), schema.validate(receipt).to_a.inspect

      replay = service.reconcile_remote_merge!(
        task: archived,
        project: project,
        pr_url: "https://github.com/acme/app/pull/42",
        expected_head: "b" * 40,
        expected_merge_oid: "a" * 40
      )
      assert_equal receipt.fetch("receipt_digest"), replay.fetch("receipt_digest")
    end
  end

  def test_daemon_cannot_take_over_an_operator_owned_closure
    with_closure_project do |task, project|
      service = service_for
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)
      service.confirm!(
        task: task,
        project: project,
        input: input,
        preview_digest: preview.preview_digest,
        operator: "tester",
        channel: "cli",
        authorized: true
      )
      archived = Hive::TaskResolver.new(task.slug, project_filter: project).resolve

      error = assert_raises(Hive::TaskClosure::InvalidReceipt) do
        service.reconcile_remote_merge!(
          task: archived,
          project: project,
          pr_url: "https://github.com/acme/app/pull/42",
          expected_head: "b" * 40,
          expected_merge_oid: "a" * 40
        )
      end
      assert_match(/operator closure receipt already owns/, error.message)
    end
  end

  def test_daemon_reconciliation_rejects_head_or_merge_drift_at_final_verification
    [
      [ FakeGh.new(head_oid: "c" * 40), "b" * 40, "a" * 40 ],
      [ FakeGh.new(merge_oid: "d" * 40), "b" * 40, "a" * 40 ]
    ].each do |gh, expected_head, expected_merge_oid|
      with_closure_project do |task, project|
        service = service_for(gh: gh)

        error = assert_raises(Hive::TaskClosure::StalePreview) do
          service.reconcile_remote_merge!(
            task: task,
            project: project,
            pr_url: "https://github.com/acme/app/pull/42",
            expected_head: expected_head,
            expected_merge_oid: expected_merge_oid
          )
        end

        assert_match(/head or merge OID changed/, error.message)
        assert File.directory?(task.folder)
        refute File.exist?(File.join(task.folder, "closure.json"))
      end
    end
  end

  def test_daemon_channel_is_not_public_confirmation_authority
    with_closure_project do |task, project|
      service = service_for
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)

      assert_raises(Hive::TaskClosure::Unauthorized) do
        service.confirm!(
          task: task,
          project: project,
          input: input,
          preview_digest: preview.preview_digest,
          operator: "hive-daemon",
          channel: "daemon",
          authorized: true
        )
      end
      assert File.directory?(task.folder)
    end
  end

  def test_open_closed_missing_and_unreachable_evidence_fail_closed
    {
      "OPEN" => /not MERGED/,
      "CLOSED" => /not MERGED/,
      "MISSING" => /not found/
    }.each do |state, message|
      with_closure_project do |task, project|
        preview = service_for(gh: FakeGh.new(state: state)).preview(
          task: task, project: project, input: input_for("acme/app#42")
        )
        refute preview.valid?
        assert_match message, preview.errors.map { |entry| entry["message"] }.join(" ")
      end
    end

    with_closure_project do |task, project|
      preview = service_for(gh: FakeGh.new(reachable: false)).preview(
        task: task, project: project, input: input_for("b" * 40)
      )
      refute preview.valid?
      assert_match(/not reachable/, preview.errors.map { |entry| entry["message"] }.join(" "))
    end
  end

  def test_commit_reachability_uses_the_live_remote_default_branch
    with_closure_project do |task, project|
      preview = service_for(
        gh: FakeGh.new(remote_default_branch: "trunk")
      ).preview(
        task: task, project: project, input: input_for("b" * 40)
      )

      assert preview.valid?, preview.to_h.inspect
      assert_equal "trunk", preview.task_repository.fetch("default_branch")
    end
  end

  def test_reference_grammar_rejects_credentials_query_arbitrary_hosts_and_short_sha
    references = [
      "https://token@github.com/acme/app/pull/42",
      "https://github.com/acme/app/pull/42?state=merged",
      "https://evil.example/acme/app/pull/42",
      "https://github.com/acme//app/pull/42",
      "https://github.com/acme/app/pull/42/",
      "abcdef1"
    ]
    references.each do |reference|
      with_closure_project do |task, project|
        preview = service_for.preview(
          task: task, project: project, input: input_for(reference)
        )
        refute preview.valid?, reference
        assert preview.errors.any? { |entry| entry["field"].start_with?("evidence") }
      end
    end
  end

  def test_evidence_count_attestation_size_and_invalid_utf8_are_bounded
    with_closure_project do |task, project|
      preview = service_for.preview(
        task: task,
        project: project,
        input: input_for(*Array.new(17) { |index| "acme/app##{index + 1}" })
      )
      refute preview.valid?
      assert preview.errors.any? { |entry| entry["code"] == "too_many" }

      invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
      preview = service_for.preview(
        task: task,
        project: project,
        input: {
          "reason" => "superseded",
          "evidence" => [ "acme/app#42" ],
          "successor" => invalid,
          "attestation" => "x" * 2049
        }
      )
      refute preview.valid?
      assert preview.errors.any? { |entry| entry["code"] == "invalid_utf8" }
      assert preview.errors.any? { |entry| entry["code"] == "too_large" }
    end
  end

  def test_cross_repository_requires_superseded_successor_and_attestation
    with_closure_project(successor: true) do |task, project|
      same_reason = service_for.preview(
        task: task,
        project: project,
        input: input_for("other/tool#7")
      )
      refute same_reason.valid?
      assert same_reason.errors.any? { |entry| entry["code"] == "cross_repository" }

      input = {
        "reason" => "superseded",
        "evidence" => [ "other/tool#7" ],
        "successor" => "#{project}:successor-task",
        "attestation" => "The successor incorporates this work."
      }
      preview = service_for.preview(task: task, project: project, input: input)
      assert preview.valid?, preview.to_h.inspect
      assert_equal "operator_attestation", preview.authority
      assert_equal "successor-task", preview.successor.fetch("slug")
      assert_equal false, preview.evidence.first.fetch("same_repository")
    end
  end

  def test_stale_preview_marker_race_and_live_owner_block_confirmation
    with_closure_project do |task, project|
      service = service_for
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)
      Hive::Markers.set(task.state_file, :error, "reason" => "changed")

      assert_raises(Hive::TaskClosure::StalePreview) do
        service.confirm!(
          task: task, project: project, input: input,
          preview_digest: preview.preview_digest,
          operator: "tester", channel: "cli", authorized: true
        )
      end
      assert File.directory?(task.folder)
    end

    with_closure_project do |task, project|
      lock = Hive::Lock.acquire_task_lock(task.folder, "operation" => "test")
      preview = service_for.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )
      refute preview.valid?
      assert preview.blockers.any? { |entry| entry["code"] == "live_attempt" }
    ensure
      Hive::Lock.release_task_lock(task.folder, lock_id: lock["lock_id"]) if lock
    end
  end

  def test_confirmation_requires_authorized_operator_channel
    with_closure_project do |task, project|
      service = service_for
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)

      assert_raises(Hive::TaskClosure::Unauthorized) do
        service.confirm!(
          task: task, project: project, input: input,
          preview_digest: preview.preview_digest,
          operator: "", channel: "action", authorized: false
        )
      end
      assert File.directory?(task.folder)
    end
  end

  def test_corrupt_and_identity_mismatched_receipts_are_quarantined
    with_closure_project do |task, project|
      path = File.join(task.folder, "closure.json")
      File.binwrite(path, "{")
      result = service_for.read(task, project: project)
      assert_equal "invalid", result.status
      assert_equal "{", File.binread(result.quarantine_path)
      refute File.exist?(path)
      assert File.file?("#{result.quarantine_path}.reason.json")
      projected = Hive::TaskClosure.projection(task, project: project)
      assert_equal "invalid", projected.fetch("status")
      assert_equal result.quarantine_path, projected.fetch("quarantine_path")

      restarted = service_for.read(task, project: project)
      assert_equal "invalid", restarted.status
      assert_equal result.quarantine_path, restarted.quarantine_path
      assert_raises(Hive::TaskClosure::InvalidReceipt) do
        service_for.confirm!(
          task: task,
          project: project,
          input: input_for("acme/app#42"),
          preview_digest: "a" * 64,
          operator: "tester",
          channel: "cli",
          authorized: true
        )
      end
      assert File.directory?(task.folder)
    end

    with_closure_project do |task, project|
      service = service_for
      preview = service.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )
      receipt = service.send(:build_receipt, preview, operator: "tester", channel: "cli")
      receipt["task"]["slug"] = "different-task"
      unsigned = receipt.reject { |key, _| key == "receipt_digest" }
      receipt["receipt_digest"] = Hive::TaskClosure.digest(unsigned)
      File.binwrite(File.join(task.folder, "closure.json"), JSON.generate(receipt))

      result = service.read(task, project: project)
      assert_equal "invalid", result.status
      assert_match(/identity/, result.error)
    end
  end

  def test_re_digested_receipt_with_noncanonical_evidence_url_is_quarantined
    with_closure_project do |task, project|
      service = service_for
      preview = service.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )
      receipt = service.send(:build_receipt, preview, operator: "tester", channel: "cli")
      receipt["evidence"].first["url"] = "javascript:alert(1)"
      receipt["evidence_digest"] = Hive::TaskClosure.digest(receipt.fetch("evidence"))
      unsigned = receipt.reject { |key, _| key == "receipt_digest" }
      receipt["receipt_digest"] = Hive::TaskClosure.digest(unsigned)
      File.binwrite(File.join(task.folder, "closure.json"), JSON.generate(receipt))

      result = service.read(task, project: project)

      assert_equal "invalid", result.status
      assert_match(/canonical/, result.error)
      assert File.file?(result.quarantine_path)
      refute File.exist?(File.join(task.folder, "closure.json"))
    end
  end

  def test_different_evidence_cannot_reuse_an_existing_receipt
    with_closure_project do |task, project|
      service = service_for
      original = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: original)
      service.confirm!(
        task: task, project: project, input: original,
        preview_digest: preview.preview_digest,
        operator: "tester", channel: "cli", authorized: true
      )
      archived = Hive::TaskResolver.new(task.slug, project_filter: project).resolve

      assert_raises(Hive::TaskClosure::StalePreview) do
        service.confirm!(
          task: archived, project: project, input: input_for("acme/app#43"),
          preview_digest: preview.preview_digest,
          operator: "tester", channel: "cli", authorized: true
        )
      end
    end
  end

  def test_preview_and_receipt_match_their_published_schemas
    with_closure_project do |task, project|
      service = service_for
      preview = service.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )
      receipt = service.send(
        :build_receipt, preview, operator: "tester", channel: "cli"
      )

      preview_schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path(Hive::TaskClosure::INPUT_SCHEMA)))
      )
      receipt_schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path(Hive::TaskClosure::SCHEMA)))
      )
      assert preview_schema.valid?(preview.to_h), preview_schema.validate(preview.to_h).to_a.inspect
      assert receipt_schema.valid?(receipt), receipt_schema.validate(receipt).to_a.inspect
    end
  end

  def test_receipt_written_before_transition_failure_resumes_to_archive
    with_closure_project do |task, project|
      input = input_for("acme/app#42")
      interrupted = service_for
      preview = interrupted.preview(task: task, project: project, input: input)
      interrupted.define_singleton_method(:transition!) do |_task, _project, _receipt|
        raise Hive::TaskClosure::Error, "simulated crash before move"
      end

      assert_raises(Hive::TaskClosure::Error) do
        interrupted.confirm!(
          task: task, project: project, input: input,
          preview_digest: preview.preview_digest,
          operator: "tester", channel: "cli", authorized: true
        )
      end
      assert File.file?(File.join(task.folder, "closure.json"))

      receipt = service_for.confirm!(
        task: task, project: project, input: input,
        preview_digest: preview.preview_digest,
        operator: "tester", channel: "cli", authorized: true
      )
      archived = Hive::TaskResolver.new(task.slug, project_filter: project).resolve
      assert_equal "9-done", "#{archived.stage_index}-#{archived.stage_name}"
      assert_equal receipt.fetch("receipt_digest"),
                   JSON.parse(File.read(File.join(archived.folder, "closure.json")))
                       .fetch("receipt_digest")
    end
  end

  def test_final_locked_guard_rejects_worktree_mutation_after_receipt_persist
    with_closure_project do |task, project|
      worktree = Hive::Worktree.new(
        task.project_root, task.slug,
        worktree_root: Hive::Worktree.canonical_root(task.project_root)
      )
      worktree.create!(task.slug, default_branch: "main")
      worktree.write_pointer!(task.folder, task.slug)
      File.write(File.join(worktree.path, "delivered.txt"), "merged through PR\n")
      run!("git", "-C", worktree.path, "add", "delivered.txt")
      run!("git", "-C", worktree.path, "commit", "-m", "delivered", "--quiet")
      head = Hive::GitOps.new(worktree.path).head_sha
      service = service_for(gh: FakeGh.new(head_oid: head))
      input = input_for("acme/app#42")
      preview = service.preview(task: task, project: project, input: input)
      assert preview.valid?, preview.to_h.inspect

      original_transition = service.method(:transition!)
      service.define_singleton_method(:transition!) do |locked_task, name, receipt|
        File.write(File.join(worktree.path, "late-change.txt"), "unsafe\n")
        original_transition.call(locked_task, name, receipt)
      end

      error = assert_raises(Hive::TaskClosure::VerificationFailed) do
        service.confirm!(
          task: task, project: project, input: input,
          preview_digest: preview.preview_digest,
          operator: "tester", channel: "cli", authorized: true
        )
      end
      assert_match(/uncommitted changes/, error.message)
      assert File.directory?(task.folder)
      assert File.file?(File.join(task.folder, "closure.json"))
    end
  end

  def test_daemon_final_guard_rejects_pr_binding_mutation_after_observation
    with_closure_project do |task, project|
      pr_path = File.join(task.folder, "pr.md")
      File.write(
        pr_path,
        "---\npr_url: https://github.com/acme/app/pull/42\n" \
        "pr_number: 42\nhead_oid: #{'b' * 40}\n---\n"
      )
      service = service_for
      original_transition = service.method(:transition!)
      service.define_singleton_method(:transition!) do |locked_task, name, receipt|
        File.write(
          pr_path,
          "---\npr_url: https://github.com/acme/app/pull/43\n" \
          "pr_number: 43\nhead_oid: #{'c' * 40}\n---\n"
        )
        original_transition.call(locked_task, name, receipt)
      end

      assert_raises(Hive::TaskClosure::InvalidReceipt) do
        service.reconcile_remote_merge!(
          task: task,
          project: project,
          pr_url: "https://github.com/acme/app/pull/42",
          expected_head: "b" * 40,
          expected_merge_oid: "a" * 40
        )
      end
      assert File.directory?(task.folder)
      refute File.file?(File.join(task.folder, "closure.json"))
      assert_equal "invalid",
                   Hive::TaskClosure.read(task, project: project).status
    end
  end

  def test_live_durable_attempt_blocks_closure
    with_closure_project do |task, project|
      attempt = Attempt.new(
        attempt_id: "attempt-live",
        state: "running",
        payload: { "project" => project, "task_slug" => task.slug }
      )
      service = service_for(
        attempt_store: AttemptStore.new(records: [ attempt ])
      )

      preview = service.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )

      refute preview.valid?
      assert preview.blockers.any? { |entry| entry["message"].include?("attempt-live") }
    end
  end

  def test_owned_worktree_with_uncommitted_changes_blocks_closure
    with_closure_project do |task, project|
      root = Hive::Worktree.canonical_root(task.project_root)
      worktree = Hive::Worktree.new(task.project_root, task.slug, worktree_root: root)
      worktree.create!(task.slug, default_branch: "main")
      worktree.write_pointer!(task.folder, task.slug)
      File.write(File.join(worktree.path, "unmerged.txt"), "local only\n")

      preview = service_for.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )

      refute preview.valid?
      assert preview.blockers.any? { |entry| entry["code"] == "unique_worktree_changes" }

      FileUtils.rm_f(File.join(worktree.path, "unmerged.txt"))
      File.write(File.join(worktree.path, "committed-only.txt"), "not merged\n")
      run!("git", "-C", worktree.path, "add", "committed-only.txt")
      run!("git", "-C", worktree.path, "commit", "-m", "task-only", "--quiet")
      committed_preview = service_for.preview(
        task: task, project: project, input: input_for("acme/app#42")
      )
      refute committed_preview.valid?
      assert committed_preview.blockers.any? do |entry|
        entry["code"] == "unique_worktree_changes"
      end
    end
  end

  private

  def input_for(*evidence)
    {
      "reason" => "already_delivered",
      "evidence" => evidence,
      "successor" => nil,
      "attestation" => nil
    }
  end

  def service_for(gh: FakeGh.new, attempt_store: EmptyAttempts.new)
    Hive::TaskClosure.new(gh: gh, attempt_store: attempt_store)
  end

  def with_closure_project(successor: false)
    with_tmp_global_config do |home|
      project = File.join(home, "app")
      FileUtils.mkdir_p(project)
      run!("git", "-C", project, "init", "-b", "main", "--quiet")
      run!("git", "-C", project, "config", "user.email", "test@example.com")
      run!("git", "-C", project, "config", "user.name", "Test")
      run!("git", "-C", project, "config", "commit.gpgsign", "false")
      File.write(File.join(project, "README.md"), "app\n")
      run!("git", "-C", project, "add", "README.md")
      run!("git", "-C", project, "commit", "-m", "initial", "--quiet")
      Hive::GitOps.new(project).hive_state_init
      hive_state = File.join(project, ".hive-state")
      File.write(
        File.join(hive_state, "config.yml"),
        {
          "default_branch" => "main",
          "default_workflow" => "coding",
          "worktree_root" => File.join(home, "worktrees")
        }.to_yaml
      )
      folder = File.join(hive_state, "stages", "4-execute", "closure-task")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(folder, id: 1, slug: "closure-task", display_name: "Closure Task")
      File.write(File.join(folder, "task.md"), "# Closure task\n")
      if successor
        successor_folder = File.join(hive_state, "stages", "1-inbox", "successor-task")
        FileUtils.mkdir_p(successor_folder)
        Hive::TaskMeta.write(
          successor_folder, id: 2, slug: "successor-task", display_name: "Successor"
        )
        File.write(File.join(successor_folder, "idea.md"), "# Successor\n")
      end
      run!("git", "-C", hive_state, "add", ".")
      run!("git", "-C", hive_state, "commit", "-m", "seed tasks", "--quiet")
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            {
              "name" => "app",
              "path" => project,
              "hive_state_path" => hive_state,
              "repository_identity" => "github.com/acme/app"
            }
          ]
        }.to_yaml
      )
      attempts = File.join(home, "attempts")
      with_env("HIVE_ATTEMPT_STORE_ROOT" => attempts) do
        yield Hive::Task.new(folder), "app"
      end
    end
  end
end
