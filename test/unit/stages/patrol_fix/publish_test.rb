require_relative "fix_test"
require "digest"
require "hive/commands/approve"
require "hive/stages/patrol_fix/publish"

class PatrolFixPublishStageTest < Minitest::Test
  include HiveTestHelper

  class LocalGit
    attr_reader :pushes

    def initialize
      @delegate = Hive::GithubPublication::GitGateway.new(
        remote: "origin", allow_local_transport: true
      )
      @pushes = 0
    end

    def repository_identity(worktree_path:)
      { "host" => "github.com", "repository" => "acme/demo" }
    end

    def observe(**values) = @delegate.observe(**values)

    def push_exact(**values)
      @pushes += 1
      @delegate.push_exact(**values)
    end
  end

  class FakeGithub
    attr_reader :creates, :records
    attr_accessor :after_create

    def initialize
      @creates = 0
      @records = []
      @after_create = nil
    end

    def authenticate!(**)
      true
    end

    def list_pull_requests(**) = records

    def create_pull_request(request:, **)
      @creates += 1
      records << owned_record(request)
      after_create&.call(request)
      true
    end

    def owned_record(request, state: "OPEN", draft: true, number: 42)
      {
        "number" => number, "url" => "https://github.com/acme/demo/pull/#{number}",
        "state" => state, "draft" => draft,
        "head_branch" => request.branch, "head_oid" => request.head_oid,
        "head_repository" => request.repository,
        "base_branch" => request.base_branch,
        "base_repository" => request.repository,
        "title" => request.title, "body" => request.published_body
      }
    end
  end

  def test_publishes_exact_approved_generation_and_writes_receipt_before_cleanup
    with_publish_task do |task, worktree_root, _manifest, _review, remote|
      git = LocalGit.new
      github = FakeGithub.new
      cleanup_observation = nil
      cleanup = lambda do |_task, _owner|
        cleanup_observation = [
          File.file?(File.join(task.folder, "pr.md")),
          Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.any? do |row|
            row["kind"] == "publication"
          end
        ]
      end

      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: git, github_gateway: github,
        worktree_root: worktree_root, cleanup: cleanup
      )

      assert_equal :complete, result.fetch(:status)
      assert_equal [ true, true ], cleanup_observation
      assert_equal 1, git.pushes
      assert_equal 1, github.creates
      assert_equal remote_head(remote, "hive/patrol-fix/repair-one/g1"),
                   result.dig(:receipt, "payload", "head_revision")
      assert_equal "draft", result.dig(:receipt, "payload", "state")
      assert_includes File.read(File.join(task.folder, "pr.md")),
                      "https://github.com/acme/demo/pull/42"

      state = File.read(publication_state_path(task))
      refute_includes state, "## Patrol Fix"
      refute_includes state, "diff --git"
      refute_includes state, "Fix Patrol finding: repair-one"
      refute_includes state, "Independent review approved the exact patch."
      assert_includes state, result.dig(:receipt, "payload", "body_digest")
      assert_equal "advance", Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "5-publish"
      ).to_h.dig("action", "kind")
    end
  end

  def test_publication_rework_defaults_to_review_when_no_specific_source_is_secret
    snapshot = {
      "manifest" => { "sources" => [ { "engine" => "git", "identity" => "commit", "evidence" => [ "clean" ] } ] },
      "validation" => { "payload" => { "commands" => [ { "identity" => "bundle exec rake test" } ] } },
      "review" => { "payload" => { "rationale" => "Reviewed cleanly.", "evidence" => [ "focused tests pass" ] } }
    }

    assert_equal "review", Hive::Stages::PatrolFix::Publish.send(
      :publication_rework_stage, snapshot, []
    )
  end

  def test_existing_exact_owned_pr_is_imported_without_push_or_create
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      git = LocalGit.new
      github = FakeGithub.new
      request = Hive::Stages::PatrolFix::Publish.publication_request(
        task, config, git_gateway: git, worktree_root: worktree_root
      )
      github.records << github.owned_record(
        request, state: "MERGED", draft: false, number: 77
      )

      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: git, github_gateway: github,
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )

      assert_equal 0, git.pushes
      assert_equal 0, github.creates
      assert_equal 77, result.dig(:receipt, "payload", "number")
      assert_equal "merged", result.dig(:receipt, "payload", "state")
    end
  end

  def test_changed_head_immediately_before_push_blocks_without_remote_effect
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      delegate = LocalGit.new
      calls = 0
      mutating_git = Object.new
      mutating_git.define_singleton_method(:repository_identity) do |**values|
        delegate.repository_identity(**values)
      end
      mutating_git.define_singleton_method(:observe) do |**values|
        calls += 1
        if calls == 2
          worktree = values.fetch(:worktree_path)
          File.write(File.join(worktree, "late.rb"), "puts :late\n")
          PatrolFixStageFixture.git(worktree, "add", "late.rb")
          PatrolFixStageFixture.git(worktree, "commit", "-m", "late change")
        end
        delegate.observe(**values)
      end
      mutating_git.define_singleton_method(:push_exact) { |**values| delegate.push_exact(**values) }

      error = assert_raises(Hive::GithubPublication::Blocked) do
        Hive::Stages::PatrolFix::Publish.run!(
          task, config, git_gateway: mutating_git, github_gateway: FakeGithub.new,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )
      end

      assert_equal "stale_authority", error.code
      assert_equal 0, delegate.pushes
      refute publication_receipt(task)
    end
  end

  def test_changed_head_after_create_blocks_before_canonical_receipt
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      git = LocalGit.new
      github = FakeGithub.new
      github.after_create = lambda do |request|
        File.write(File.join(request.worktree_path, "late.rb"), "puts :late\n")
        PatrolFixStageFixture.git(request.worktree_path, "add", "late.rb")
        PatrolFixStageFixture.git(request.worktree_path, "commit", "-m", "late change")
      end

      error = assert_raises(Hive::GithubPublication::Blocked) do
        Hive::Stages::PatrolFix::Publish.run!(
          task, config, git_gateway: git, github_gateway: github,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )
      end

      assert_equal "stale_authority", error.code
      assert_equal 1, git.pushes
      assert_equal 1, github.creates
      refute publication_receipt(task)
      refute File.exist?(File.join(task.folder, "pr.md"))
    end
  end

  def test_repository_identity_is_revalidated_immediately_before_create
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      delegate = LocalGit.new
      identity_calls = 0
      drifting_git = Object.new
      drifting_git.define_singleton_method(:repository_identity) do |**values|
        identity_calls += 1
        identity = delegate.repository_identity(**values)
        identity_calls >= 4 ? identity.merge("repository" => "acme/other") : identity
      end
      drifting_git.define_singleton_method(:observe) { |**values| delegate.observe(**values) }
      drifting_git.define_singleton_method(:push_exact) { |**values| delegate.push_exact(**values) }
      github = FakeGithub.new

      error = assert_raises(Hive::GithubPublication::Blocked) do
        Hive::Stages::PatrolFix::Publish.run!(
          task, config, git_gateway: drifting_git, github_gateway: github,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )
      end

      assert_equal "stale_authority", error.code
      assert_equal 1, delegate.pushes
      assert_equal 0, github.creates
      refute publication_receipt(task)
    end
  end

  def test_secret_in_review_body_blocks_before_push_without_leaking_diagnostic
    with_publish_task(review_rationale: "token ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}") do |task, worktree_root, _manifest, _review, _remote|
      git = LocalGit.new
      github = FakeGithub.new
      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: git, github_gateway: github,
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )

      assert_equal :parked, result.fetch(:status)
      block = result.fetch(:receipt)
      assert_equal "publication_block", block.fetch("kind")
      assert_equal "secret_detected", block.dig("payload", "code")
      assert_equal "operator", block.dig("payload", "owner")
      assert_equal [ "body" ], block.dig("payload", "blocked_fields")
      assert_equal "review", block.dig("payload", "rework_stage")
      refute_includes JSON.generate(block), "ghp_"
      assert_equal 0, git.pushes
      assert_equal 0, github.creates
      refute publication_receipt(task)
      projection = Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "5-publish"
      ).to_h
      assert_equal "publication_blocked", projection.dig("outcome", "kind")
      assert_equal "operator", projection.fetch("blocker_owner")
      assert_equal "parked", projection.dig("action", "kind")

      replay = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: Object.new, github_gateway: Object.new,
        worktree_root: worktree_root, cleanup: ->(*) { flunk "park replay must not clean up" }
      )
      assert_equal block, replay.fetch(:receipt)
    end
  end

  def test_secret_rework_stage_uses_the_earliest_authority_that_can_change_the_bytes
    token = "ghp_aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
    [
      [ { source_evidence: "evidence #{token}" }, "inbox", [ "body" ] ],
      [ { fixed_contents: "puts '#{token}'\n" }, "fix", [ "diff" ] ]
    ].each do |options, expected_stage, expected_fields|
      with_publish_task(**options) do |task, worktree_root, _manifest, _review, _remote|
        result = Hive::Stages::PatrolFix::Publish.run!(
          task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )

        assert_equal expected_stage, result.dig(:receipt, "payload", "rework_stage")
        assert_equal expected_fields, result.dig(:receipt, "payload", "blocked_fields")
        refute_includes JSON.generate(result.fetch(:receipt)), token
      end
    end
  end

  def test_cleanup_failure_is_diagnostic_and_cannot_revoke_completion
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
        worktree_root: worktree_root,
        cleanup: ->(*) { raise Hive::WorktreeError, "private cleanup detail" }
      )

      assert_equal :complete, result.fetch(:status)
      assert publication_receipt(task)
      projection = Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "5-publish"
      ).to_h
      assert_equal "cleanup_failed", projection.dig("diagnostic", "code")
      refute_includes projection.dig("diagnostic", "summary"), "private cleanup detail"
      assert_equal "advance", projection.dig("action", "kind")
    end
  end

  def test_publication_receipt_must_be_current_before_cleanup
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      cleanup_calls = 0
      with_replaced_singleton_method(
        Hive::Stages::PatrolFix::Publish, :current_publication, ->(*) { nil }
      ) do
        error = assert_raises(Hive::GithubPublication::Blocked) do
          Hive::Stages::PatrolFix::Publish.run!(
            task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
            worktree_root: worktree_root, cleanup: ->(*) { cleanup_calls += 1 }
          )
        end
        assert_equal "stale_authority", error.code
      end
      assert_equal 0, cleanup_calls
      assert publication_receipt(task)
    end
  end

  def test_default_cleanup_removes_the_controller_owned_worktree
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root,
        slug: task.slug, worktree_root: worktree_root
      ).read
      destination = owner.fetch("worktree")

      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
        worktree_root: worktree_root
      )

      assert_equal :complete, result.fetch(:status)
      refute File.exist?(destination)
    end
  end

  def test_receipt_replay_never_cleans_tampered_worktree_custody
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )
      foreign = File.join(File.dirname(task.project_root), "foreign-worktree")
      FileUtils.mkdir_p(foreign)
      sentinel = File.join(foreign, "keep.txt")
      File.write(sentinel, "keep\n")
      owner_path = File.join(
        task.folder, Hive::PatrolFix::WorktreeReceipt::FILENAME
      )
      owner = JSON.parse(File.binread(owner_path))
      owner["worktree"] = foreign
      File.write(owner_path, Hive::PatrolFix.canonical_json(owner))
      cleanup_calls = 0

      result = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: ->(*) { flunk "receipt replay must not call Git" },
        github_gateway: ->(*) { flunk "receipt replay must not call GitHub" },
        worktree_root: worktree_root,
        cleanup: ->(*) { cleanup_calls += 1 }
      )

      assert_equal :complete, result.fetch(:status)
      assert_equal 0, cleanup_calls
      assert File.file?(sentinel)
      assert_equal "cleanup_failed", Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "5-publish"
      ).to_h.dig("diagnostic", "code")
    end
  end

  def test_durable_receipt_replay_repairs_pr_metadata_without_remote_or_worktree
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      git = LocalGit.new
      github = FakeGithub.new
      first = Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: git, github_gateway: github,
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )
      File.unlink(File.join(task.folder, "pr.md"))

      replay = Hive::Stages::PatrolFix::Publish.run!(
        task, config,
        git_gateway: ->(*) { flunk "durable publication must not re-open Git custody" },
        github_gateway: ->(*) { flunk "durable publication must not repeat GitHub" },
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )

      assert_equal first.fetch(:receipt), replay.fetch(:receipt)
      assert File.file?(File.join(task.folder, "pr.md"))
      assert_equal 1, git.pushes
      assert_equal 1, github.creates
    end
  end

  def test_receipt_gates_done_move_and_replay_between_publish_and_move_is_remote_free
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        Hive::PatrolFix::StageTransition.with_lock(task) do |transition|
          transition.begin!("6-done")
        end
      end

      git = LocalGit.new
      github = FakeGithub.new
      Hive::Stages::PatrolFix::Publish.run!(
        task, config, git_gateway: git, github_gateway: github,
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )
      receipt_name = Hive::PatrolFix::ReceiptStore::FILENAME
      receipt_bytes = File.binread(File.join(task.folder, receipt_name))
      pr_bytes = File.binread(File.join(task.folder, "pr.md"))

      Hive::Stages::PatrolFix::Publish.run!(
        task, config,
        git_gateway: ->(*) { flunk "receipt replay must not reopen Git" },
        github_gateway: ->(*) { flunk "receipt replay must not call GitHub" },
        worktree_root: worktree_root, cleanup: ->(*) { true }
      )
      assert_equal receipt_bytes, File.binread(File.join(task.folder, receipt_name))
      assert_equal pr_bytes, File.binread(File.join(task.folder, "pr.md"))

      original = Hive::DependencySnapshot.method(:enforce_admission!)
      Hive::DependencySnapshot.define_singleton_method(:enforce_admission!) { |*| true }
      begin
        Hive::Commands::Approve.new(task.folder, quiet: true).call
      ensure
        Hive::DependencySnapshot.define_singleton_method(:enforce_admission!, original)
      end

      destination = File.join(task.hive_state_path, "stages", "6-done", task.slug)
      assert File.directory?(destination)
      assert_equal receipt_bytes, File.binread(File.join(destination, receipt_name))
      assert_equal pr_bytes, File.binread(File.join(destination, "pr.md"))
      projection = Hive::PatrolFix::Projection.new(
        task_folder: destination, stage: "6-done"
      ).to_h
      assert_equal "current", projection.fetch("state")
      assert_equal true, projection.fetch("archived")
      assert_equal "done", projection.dig("action", "kind")
      assert_equal 1, git.pushes
      assert_equal 1, github.creates
    end
  end

  def test_stage_final_authority_check_rejects_a_controller_that_skips_revalidation
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      replace_review = lambda do
        rewrite_receipts(task) do |rows|
          rows.map do |row|
            row["receipt_id"] == "review-one" ? row.merge("receipt_id" => "review-two") : row
          end
        end
      end
      controller = Object.new
      controller.define_singleton_method(:publish!) do |request, **|
        replace_review.call
        {
          "publication_id" => request.publication_id,
          "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
          "state" => "draft", "head_oid" => request.head_oid,
          "branch" => request.branch, "repository" => request.repository,
          "host" => request.host, "base_branch" => request.base_branch,
          "body_digest" => request.body_digest
        }
      end

      error = assert_raises(Hive::GithubPublication::Blocked) do
        Hive::Stages::PatrolFix::Publish.run!(
          task, config, git_gateway: LocalGit.new, github_gateway: FakeGithub.new,
          controller: controller, worktree_root: worktree_root, cleanup: ->(*) { true }
        )
      end

      assert_equal "stale_authority", error.code
    end
  end

  def test_publish_approval_requires_referenced_fix_and_validation
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      rewrite_receipts(task) { |rows| rows.reject { |row| row["kind"] == "fix" } }

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Publish.publication_request(
          task, config, git_gateway: LocalGit.new, worktree_root: worktree_root
        )
      end

      assert_match(/references unavailable fix/, error.message)
    end
  end

  def test_publish_approval_must_bind_the_exact_validated_patch
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      rewrite_receipts(task) do |rows|
        rows.map do |row|
          next row unless row["kind"] == "fix"

          row.merge("payload" => row.fetch("payload").merge("diff_digest" => "f" * 64))
        end
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Publish.publication_request(
          task, config, git_gateway: LocalGit.new, worktree_root: worktree_root
        )
      end

      assert_match(/does not bind one exact validated patch/, error.message)
    end
  end

  def test_repository_identity_and_request_identity_are_strict
    with_publish_task do |task, worktree_root, _manifest, _review, _remote|
      bad_git = LocalGit.new
      bad_git.define_singleton_method(:repository_identity) { |**| { "repository" => "acme/demo" } }

      assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Publish.publication_request(
          task, config, git_gateway: bad_git, worktree_root: worktree_root
        )
      end

      snapshot = Hive::Stages::PatrolFix::Publish.send(
        :exact_snapshot!, task, config, git_gateway: LocalGit.new,
        worktree_root: worktree_root
      )
      snapshot["repository_identity"] = {
        "host" => "github.com", "repository" => "invalid"
      }
      assert_raises(Hive::GithubPublication::Blocked) do
        Hive::Stages::PatrolFix::Publish.send(
          :request_from_snapshot, task, config, snapshot
        )
      end
    end
  end

  def test_body_bounding_and_default_git_gateway
    bounded = Hive::Stages::PatrolFix::Publish.send(:bounded_utf8, "é" * 20, 9)

    assert bounded.valid_encoding?
    assert_operator bounded.bytesize, :<=, 9
    assert_instance_of Hive::GithubPublication::GitGateway,
                       Hive::Stages::PatrolFix::Publish.send(:default_git_gateway, config)
  end

  def test_diagnostic_storage_failure_cannot_revoke_publication
    task = Struct.new(:folder).new(Dir.pwd)
    with_replaced_singleton_method(
      Hive::AtomicFile, :write, ->(*) { raise IOError, "disk unavailable" }
    ) do
      assert_nil Hive::Stages::PatrolFix::Publish.send(
        :cleanup_after_receipt, task, nil, nil, {}
      )
    end
  end

  private

  def rewrite_receipts(task)
    path = File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME)
    rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    File.write(path, yield(rows).map { |row| JSON.generate(row) }.join("\n") + "\n")
  end

  def with_publish_task(review_rationale: "Independent review approved the exact patch.",
                        source_evidence: "bug", fixed_contents: "puts :fixed\n")
    PatrolFixStageFixture.with_task(
      stage: "5-publish", source_evidence: source_evidence
    ) do |task, root, manifest|
      remote = File.join(root, "remote.git")
      capture("git", "init", "--bare", remote)
      PatrolFixStageFixture.git(task.project_root, "remote", "add", "origin", remote)
      PatrolFixStageFixture.git(task.project_root, "push", "origin", "main")
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktree_root = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root,
        slug: task.slug, worktree_root: worktree_root
      )
      owner = custody.prepare!(
        generation: 1, evidence_digest: "a" * 64,
        base_revision: manifest.fetch("target_revision")
      )
      File.write(File.join(owner.fetch("worktree"), "app.rb"), fixed_contents)
      PatrolFixStageFixture.git(owner.fetch("worktree"), "add", "app.rb")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "commit", "-m", "fix")
      fix_payload = custody.capture!(generation: 1, evidence_digest: "a" * 64)
                           .merge("validation_commands" => [])
      fix = append_receipt(store, manifest, "fix", "fix", fix_payload, "fix-one")
      validation = append_receipt(
        store, manifest, "validation", "validate",
        { "verdict" => "passed", "worktree_head" => fix_payload.fetch("head_revision"),
          "commands" => [] }, "validation-one"
      )
      review = append_receipt(
        store, manifest, "decision", "review",
        {
          "route" => "publish", "rationale" => review_rationale,
          "evidence" => [ "Exact patch and validation are adequate." ],
          "blocker_owner" => "review_gate",
          "head_revision" => fix_payload.fetch("head_revision"),
          "diff_digest" => fix_payload.fetch("diff_digest"),
          "fix_receipt_id" => fix.fetch("receipt_id"),
          "validation_receipt_id" => validation.fetch("receipt_id")
        }, "review-one"
      )
      yield task, worktree_root, manifest, review, remote
    end
  end

  def append_receipt(store, manifest, kind, stage, payload, id)
    receipt = {
      "schema" => Hive::PatrolFix::ReceiptStore::SCHEMA,
      "schema_version" => Hive::PatrolFix::ReceiptStore::SCHEMA_VERSION,
      "receipt_id" => id, "kind" => kind, "stage" => stage,
      "task" => manifest.fetch("task"),
      "evidence_revision" => manifest.fetch("evidence_revision"),
      "recorded_at" => "2026-08-20T12:00:00Z", "payload" => payload
    }
    store.append!(receipt)
  end

  def config
    {
      "default_branch" => "main", "patrol" => { "draft_prs" => true },
      "agent_git_gate" => { "allow_local_transport" => true }
    }
  end

  def publication_receipt(task)
    Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.find do |row|
      row["kind"] == "publication"
    end
  end

  def publication_state_path(task)
    File.join(
      task.hive_state_path, "patrol-fix", "publications", task.slug,
      "generation-1.json"
    )
  end

  def remote_head(remote, branch)
    capture("git", "ls-remote", remote, "refs/heads/#{branch}").split.first
  end

  def capture(*args)
    out, err, status = Open3.capture3(*args)
    raise "#{args.join(' ')}: #{err}" unless status.success?
    out
  end
end
