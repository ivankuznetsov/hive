require "test_helper"
require "json_schemer"
require "pathname"
require "hive/operational_action"
require "hive/patrol_fix/secret_rework"
require "hive/stages/patrol_fix/publish"
require "hive/stages/patrol_fix/review"
require "hive/stages/patrol_fix/validate"
require "hive/task_action"
require_relative "../stages/patrol_fix/fix_test"

# Patrol Fix secret-policy rework: the pre-publication gate in Validate, its
# shared rework bound, and the operator-attested release of a current block.
# Betterleaks runs for real; every test proves the matched value never
# reaches a receipt, transition, prompt, or result.
class PatrolFixSecretReworkTest < Minitest::Test
  include HiveTestHelper

  LOGIN_TEST = "test/login_test.rb".freeze
  SECRET = "password123".freeze
  LEAK = %(post login_path, params: { email: @user.email, password: "#{SECRET}" }\n).freeze
  OTHER_SECRET = "Xk9#mQ2!vL8pR4tZ".freeze
  OTHER_LEAK = %(post login_path, params: { email: @user.email, password: "#{OTHER_SECRET}" }\n).freeze
  SAFE = "post login_path, params: { email: @user.email, password: TEST_PASSWORD }\n".freeze
  TOKEN = "ghp_aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6".freeze
  SecretRework = Hive::PatrolFix::SecretRework

  def test_pre_publication_finding_routes_to_rework_and_a_clean_rework_validates
    with_fixed_task(stage: "3-validate", contents: LEAK) do |task, worktree_root, _manifest, _fix|
      result = validate!(task, worktree_root: worktree_root)

      moved = Hive::Task.new(result.fetch(:moved_task_folder))
      assert_equal "fix", moved.stage_name
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: moved.folder).read_all
      gate = receipts.find { |row| row["kind"] == "decision" && row["stage"] == "validate" }
      assert_equal "rework", gate.dig("payload", "route")
      assert_equal "fix_agent", gate.dig("payload", "blocker_owner")
      assert_equal [ { "path" => LOGIN_TEST, "line" => 1, "rule_id" => "generic-password" } ],
                   gate.dig("payload", "findings")
      assert_equal [ "#{LOGIN_TEST}:1 rule=generic-password" ], gate.dig("payload", "evidence")
      %w[Do\ not\ add\ credential-like\ literals existing\ test\ constants scanner-safe amend\ or\ squash].each do |phrase|
        assert_includes gate.dig("payload", "rationale"), phrase
      end
      assert valid_receipt?(gate)
      reopen = receipts.find { |row| row["kind"] == "reopen" }
      assert_equal [ "validate", SecretRework::SCAN_OPERATOR, gate.fetch("receipt_id") ],
                   [ reopen.fetch("stage"), reopen.dig("payload", "operator"), reopen.dig("payload", "outcome_receipt_id") ]
      assert valid_receipt?(reopen)
      refute receipts.any? { |row| row["kind"] == "validation" }, "validation commands must not run on a flagged range"
      assert_equal 2, Hive::PatrolFix::TaskManifest.new(task_folder: moved.folder).read.dig("task", "generation")
      assert_equal 1, Hive::PatrolFix::Projection.new(task_folder: moved.folder, stage: "2-fix").to_h.dig("timing", "rework_count")
      refute_secret_persisted(moved)

      prompts = []
      fixed = Hive::Stages::PatrolFix::Fix.run!(
        moved, {}, agent_runner: rewrite_runner(SAFE, prompts), worktree_root: worktree_root
      )
      assert_equal 2, fixed.dig(:receipt, "task", "generation")
      assert_includes prompts.first, "secret_scan_feedback"
      assert_includes prompts.first, "rewrite every flagged commit since Base"
      assert_includes prompts.first, "#{LOGIN_TEST}:1 rule=generic-password"
      refute_includes prompts.first, "review_feedback"
      refute_includes prompts.first, SECRET

      revalidate = move_task(moved, "3-validate")
      validated = validate!(revalidate, worktree_root: worktree_root, runner: ->(*) { { "commands" => [] } })
      assert_equal :complete, validated.fetch(:status)
      assert_equal "validation", validated.dig(:receipt, "kind")
    end
  end

  def test_shared_rework_bound_parks_for_the_operator_who_can_release_it_once
    cfg = { "patrol" => { "max_rework_cycles" => 1 } }
    with_fixed_task(stage: "3-validate", contents: LEAK) do |task, worktree_root, _manifest, _fix|
      first = validate!(task, cfg, worktree_root: worktree_root)
      reworked = Hive::Task.new(first.fetch(:moved_task_folder))
      Hive::Stages::PatrolFix::Fix.run!(
        reworked, {}, agent_runner: rewrite_runner(OTHER_LEAK, []), worktree_root: worktree_root
      )
      second = move_task(reworked, "3-validate")

      parked = validate!(second, cfg, worktree_root: worktree_root)

      assert_equal :parked, parked.fetch(:status)
      gate = parked.fetch(:receipt)
      assert_equal [ "blocked", "operator" ], gate.dig("payload").values_at("route", "blocker_owner")
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: second.folder)
      assert_equal 1, Hive::PatrolFix::ReworkBudget.spent(store.read_all)
      refute_includes Hive::Stages::PatrolFix::Review.allowed_routes(store, 1), "rework",
                      "review and the secret gate share one rework budget"
      projection = Hive::PatrolFix::Projection.new(task_folder: second.folder, stage: "3-validate").to_h
      assert_equal [ "publication_blocked", "operator", "parked" ],
                   [ projection.dig("outcome", "kind"), projection.fetch("blocker_owner"), projection.dig("action", "kind") ]
      assert_equal [ SecretRework::CODE, SecretRework::ESCALATION_SUMMARY ],
                   projection.fetch("diagnostic").values_at("code", "summary")
      assert JSONSchemer.schema(
        Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-projection"))
      ).valid?(JSON.parse(JSON.generate(projection)))
      action = Hive::TaskAction.for(second, Hive::Markers::State.new(name: :none, attrs: {}, raw: nil))
      assert_equal Hive::Schemas::TaskActionKind::PATROL_FIX_PUBLICATION_BLOCKED, action.key
      replay = with_replaced_singleton_method(SecretRework, :scan, ->(**) { flunk "a parked gate must not rescan" }) do
        validate!(second, cfg, worktree_root: worktree_root)
      end
      assert_equal gate, replay.fetch(:receipt)
      refute_secret_persisted(second, OTHER_SECRET)

      block = SecretRework.current_block(task_folder: second.folder)
      assert_equal({ "stage" => "3-validate", "receipt" => gate }, block)
      token = SecretRework.observation_token(project: "demo", slug: second.slug, block: block)
      outcome = SecretRework.operator_rework!(
        second, cfg: cfg, project: "demo", observation_token: token, worktree_root: worktree_root,
        transition: committed_transition(second, worktree_root)
      )
      assert_equal({ "status" => "reworked", "generation" => 3, "findings" => 1 }, outcome)
      released = Hive::Task.new(File.join(second.hive_state_path, "stages", "2-fix", second.slug))
      reopen = Hive::PatrolFix::ReceiptStore.new(task_folder: released.folder).read_all.last
      assert_equal [ "validate", SecretRework::ACTION_OPERATOR, gate.fetch("receipt_id") ],
                   [ reopen.fetch("stage"), reopen.dig("payload", "operator"), reopen.dig("payload", "outcome_receipt_id") ]
      timing = Hive::PatrolFix::Projection.new(task_folder: released.folder, stage: "2-fix").to_h.fetch("timing")
      assert_nil timing.fetch("parked_since")
      prompts = []
      Hive::Stages::PatrolFix::Fix.run!(
        released, {}, agent_runner: rewrite_runner(SAFE, prompts), worktree_root: worktree_root
      )
      assert_includes prompts.first, "secret_scan_feedback"
      refute_includes prompts.first, OTHER_SECRET
    end
  end

  def test_secret_rework_must_rewrite_the_flagged_commits
    with_fixed_task(stage: "3-validate", contents: LEAK) do |task, worktree_root, _manifest, _fix|
      moved = Hive::Task.new(validate!(task, worktree_root: worktree_root).fetch(:moved_task_folder))
      unchanged = lambda do |**values|
        File.write(values.fetch(:output_path), JSON.generate(fix_report))
        { status: :ok, custody: :clean }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Fix.run!(moved, {}, agent_runner: unchanged, worktree_root: worktree_root)
      end

      assert_includes error.message, "secret rework did not rewrite the flagged commits"
    end
  end

  def test_unavailable_scanner_fails_validation_without_a_receipt
    with_fixed_task(stage: "3-validate", contents: LEAK) do |task, worktree_root, _manifest, _fix|
      unavailable = ->(**) { raise Hive::SecretScanner::Unavailable, "Betterleaks could not run" }
      error = with_replaced_singleton_method(Hive::GithubPublication, :commit_secret_findings, unavailable) do
        assert_raises(Hive::StageError) { validate!(task, worktree_root: worktree_root) }
      end

      assert_equal "pre-publication secret scan is unavailable: Betterleaks could not run", error.message
      refute Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.any? { |row| row["stage"] == "validate" }
    end
  end

  def test_gate_and_publication_scan_the_same_range_through_one_seam
    with_publish_task(contents: SAFE) do |task, worktree_root, _manifest, fix|
      calls = []
      original = Hive::GithubPublication.method(:commit_secret_findings)
      recorder = lambda do |**values|
        calls << values
        original.call(**values)
      end
      with_replaced_singleton_method(Hive::GithubPublication, :commit_secret_findings, recorder) do
        owner = Hive::PatrolFix::WorktreeReceipt.new(
          task_folder: task.folder, project_root: task.project_root, slug: task.slug,
          worktree_root: worktree_root
        ).read
        store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
        assert_nil SecretRework.pre_publication_gate!(
          task, publish_config, manifest: manifest, store: store, fix: fix, owner: owner
        )
        result = Hive::Stages::PatrolFix::Publish.run!(
          task, publish_config, git_gateway: identity_git, github_gateway: OkGithub.new,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )
        assert_equal :complete, result.fetch(:status), "a clean range still publishes"
      end

      assert_operator calls.length, :>=, 2
      assert_equal 1, calls.uniq.length, "the gate and publication must scan the identical range"
      assert_equal fix.dig("payload", "head_revision"), calls.first.fetch(:head_oid)
      assert_equal fix.dig("payload", "base_revision"), calls.first.fetch(:base_oid)
      assert_equal "main", calls.first.fetch(:base_branch)
    end
  end

  def test_operator_releases_a_publication_block_once_and_replays_idempotently
    with_blocked_publication(contents: LEAK) do |task, worktree_root, block|
      assert_equal [ "diff" ], block.dig("payload", "blocked_fields")
      current = SecretRework.current_block(task_folder: task.folder)
      assert_equal({ "stage" => "5-publish", "receipt" => block }, current)
      token = SecretRework.observation_token(project: "demo", slug: task.slug, block: current)

      outcome = SecretRework.operator_rework!(
        task, cfg: publish_config, project: "demo", observation_token: token,
        worktree_root: worktree_root, transition: committed_transition(task, worktree_root)
      )

      assert_equal({ "status" => "reworked", "generation" => 2, "findings" => 1 }, outcome)
      moved = Hive::Task.new(File.join(task.hive_state_path, "stages", "2-fix", task.slug))
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: moved.folder).read_all
      decision = receipts.find { |row| row["kind"] == "decision" && row["stage"] == "publish" }
      assert_equal [ "rework", block.fetch("receipt_id"), [ { "path" => LOGIN_TEST, "line" => 1, "rule_id" => "generic-password" } ] ],
                   decision.fetch("payload").values_at("route", "blocked_receipt_id", "findings")
      assert valid_receipt?(decision)
      reopen = receipts.find { |row| row["kind"] == "reopen" }
      assert_equal [ "publish", SecretRework::ACTION_OPERATOR, [] ],
                   [ reopen.fetch("stage"), reopen.dig("payload", "operator"), reopen.dig("payload", "carried_receipts") ]
      timing = Hive::PatrolFix::Projection.new(task_folder: moved.folder, stage: "2-fix").to_h.fetch("timing")
      assert_nil timing.fetch("parked_since")
      assert_equal 1, timing.fetch("rework_count")
      refute_secret_persisted(moved)
      bytes = File.binread(File.join(moved.folder, Hive::PatrolFix::ReceiptStore::FILENAME))

      replay = SecretRework.operator_rework!(
        moved, cfg: publish_config, project: "demo", observation_token: token,
        worktree_root: worktree_root, transition: committed_transition(moved, worktree_root)
      )

      assert_equal({ "status" => "already_reworked", "generation" => 2, "findings" => 1 }, replay)
      assert_equal bytes, File.binread(File.join(moved.folder, Hive::PatrolFix::ReceiptStore::FILENAME))
      assert_raises(Hive::PatrolFix::SecretRework::Refused) do
        SecretRework.operator_rework!(
          moved, cfg: publish_config, project: "demo", observation_token: "f" * 64,
          worktree_root: worktree_root, transition: committed_transition(moved, worktree_root)
        )
      end
      prompts = []
      Hive::Stages::PatrolFix::Fix.run!(moved, {}, agent_runner: rewrite_runner(SAFE, prompts), worktree_root: worktree_root)
      assert_includes prompts.first, "secret_scan_feedback"
      refute_includes prompts.first, SECRET
    end
  end

  def test_operator_release_reuses_an_interrupted_publish_decision
    with_blocked_publication(contents: LEAK) do |task, worktree_root, block|
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      fix = store.read_all.find { |row| row["kind"] == "fix" }
      interrupted = store.append!(SecretRework.decision(
        manifest: manifest, stage: "publish", route: "rework",
        findings: [ { "path" => "earlier.rb", "line" => 3, "rule_id" => "generic-password" } ],
        fix: fix, blocked_receipt_id: block.fetch("receipt_id")
      ))
      token = SecretRework.observation_token(
        project: "demo", slug: task.slug, block: SecretRework.current_block(task_folder: task.folder)
      )

      with_replaced_singleton_method(SecretRework, :scan, ->(**) { flunk "the recorded decision is reused" }) do
        SecretRework.operator_rework!(
          task, cfg: publish_config, project: "demo", observation_token: token,
          worktree_root: worktree_root, transition: committed_transition(task, worktree_root)
        )
      end

      moved = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      reopen = Hive::PatrolFix::ReceiptStore.new(task_folder: moved).read_all.last
      assert_equal interrupted.fetch("receipt_id"), reopen.dig("payload", "outcome_receipt_id")
    end
  end

  # A September block whose literal an operator has since excepted by exact
  # fingerprint no longer reproduces on the same HEAD. Publish reopens in a
  # new generation under the block's own review and publishes the clean range.
  def test_stale_publication_block_reopens_publish_which_publishes_a_clean_range
    with_blocked_publication(contents: LEAK) do |task, worktree_root, block|
      with_operator_exception_for(task, worktree_root) do
        current = SecretRework.current_block(task_folder: task.folder)
        token = SecretRework.observation_token(project: "demo", slug: task.slug, block: current)

        outcome = release(task, worktree_root, current)

        assert_equal({ "status" => "republished", "generation" => 2, "findings" => 0 }, outcome)
        assert File.directory?(task.folder), "a republish stays in 5-publish"
        assert_equal 2, Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read.dig("task", "generation")
        receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all
        refute receipts.any? { |row| row["kind"] == "decision" && row["stage"] == "publish" },
               "a clean range records no rework decision"
        reopen = receipts.last
        assert_equal [ "reopen", "publish", SecretRework::REPUBLISH_OPERATOR, block.fetch("receipt_id"), [ "review-one" ] ],
                     [ reopen.fetch("kind"), reopen.fetch("stage"), reopen.dig("payload", "operator"),
                       reopen.dig("payload", "outcome_receipt_id"), reopen.dig("payload", "carried_receipts") ]
        assert valid_receipt?(reopen)
        projection = Hive::PatrolFix::Projection.new(task_folder: task.folder, stage: "5-publish").to_h
        assert_nil projection["outcome"]
        assert_equal({ "kind" => "ready", "runnable" => true }, projection.fetch("action"))
        assert_nil projection.dig("timing", "parked_since")
        assert_nil SecretRework.current_block(task_folder: task.folder)
        bytes = File.binread(File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME))

        replay = release(task, worktree_root, current, token: token)

        assert_equal({ "status" => "already_republished", "generation" => 2, "findings" => 0 }, replay)
        assert_equal bytes, File.binread(File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME))

        published = Hive::Stages::PatrolFix::Publish.run!(
          task, publish_config, git_gateway: identity_git, github_gateway: OkGithub.new,
          worktree_root: worktree_root, cleanup: ->(*) { true }
        )

        assert_equal :complete, published.fetch(:status)
        assert_equal [ "publication", 2, 2 ],
                     [ published.dig(:receipt, "kind"), published.dig(:receipt, "task", "generation"),
                       published.dig(:receipt, "evidence_revision", "generation") ]
        assert_equal "https://github.com/acme/demo/pull/7", published.fetch(:pr_url)
        assert_equal "advance", Hive::PatrolFix::Projection.new(task_folder: task.folder, stage: "5-publish").to_h.dig("action", "kind")
        refute_secret_persisted(task)
      end
    end
  end

  def test_republished_publish_rescans_title_and_body_and_can_block_again
    with_blocked_publication(contents: SAFE, review_rationale: "token #{TOKEN}") do |task, worktree_root, block|
      assert_equal [ "body" ], block.dig("payload", "blocked_fields")
      current = SecretRework.current_block(task_folder: task.folder)
      token = SecretRework.observation_token(project: "demo", slug: task.slug, block: current)

      assert_equal "republished", release(task, worktree_root, current).fetch("status")
      reblocked = Hive::Stages::PatrolFix::Publish.run!(
        task, publish_config, git_gateway: identity_git, github_gateway: Object.new,
        worktree_root: worktree_root, cleanup: ->(*) { flunk "a blocked publication must not clean up" }
      )

      assert_equal :parked, reblocked.fetch(:status)
      fresh = reblocked.fetch(:receipt)
      assert_equal [ 2, [ "body" ] ], [ fresh.dig("task", "generation"), fresh.dig("payload", "blocked_fields") ]
      refute_equal block.fetch("receipt_id"), fresh.fetch("receipt_id")
      next_block = SecretRework.current_block(task_folder: task.folder)
      assert_equal fresh, next_block.fetch("receipt")
      refute_equal token, SecretRework.observation_token(project: "demo", slug: task.slug, block: next_block)
      assert_equal "already_republished", release(task, worktree_root, current, token: token).fetch("status")
      # The fixture's review rationale carries the token (agent input); the
      # reopen and the fresh block this flow wrote must not.
      written = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.select do |row|
        row.dig("task", "generation") == 2 || row["kind"] == "reopen"
      end
      assert_equal %w[publication_block reopen], written.map { |row| row.fetch("kind") }.sort
      refute_includes JSON.generate(written), TOKEN
    end
  end

  def test_republish_authority_must_bind_the_blocked_review
    with_blocked_publication(contents: SAFE, review_rationale: "token #{TOKEN}") do |task, worktree_root, block|
      receipts_path = File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME)
      original = File.binread(receipts_path)
      File.write(receipts_path, original.gsub('"receipt_id":"review-one"', '"receipt_id":"review-renamed"'))
      current = SecretRework.current_block(task_folder: task.folder)
      error = assert_raises(SecretRework::Refused) { release(task, worktree_root, current) }
      assert_equal "the blocked review approval is unavailable", error.message
      File.binwrite(receipts_path, original)

      transition = committed_transition(task, worktree_root)
      review = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.find { |row| row["receipt_id"] == "review-one" }
      [
        [ block, review.merge("receipt_id" => "review-other") ],
        [ block.merge("evidence_revision" => { "generation" => 1, "digest" => "f" * 64 }), review ],
        [ review, review ]
      ].each do |candidate, approval|
        error = assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
          transition.apply_secret_republish!(candidate, review: approval)
        end
        assert_includes error.message, "exact current publication block and its review"
      end

      commits = []
      Hive::PatrolFix::Transition.new(task, worktree_root: worktree_root, commit: ->(**values) { commits << values })
                                 .apply_secret_republish!(block, review: review)
      assert_equal "operator secret republish", commits.first.fetch(:action)
      tampered = File.binread(receipts_path).sub(
        '"review_receipt_id":"review-one"', '"review_receipt_id":"review-elsewhere"'
      )
      File.binwrite(receipts_path, tampered)
      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Publish.publication_request(
          task, publish_config, git_gateway: identity_git, worktree_root: worktree_root
        )
      end
      assert_equal "republish authorization does not bind the blocked review approval", error.message
    end
  end

  def test_operator_release_refuses_anything_but_a_current_secret_block
    with_blocked_publication(contents: LEAK) do |task, worktree_root, _block|
      current = SecretRework.current_block(task_folder: task.folder)
      assert_raises(Hive::StaleOperationalObservation) { release(task, worktree_root, current, token: "0" * 64) }

      moved_elsewhere = Object.new
      moved_elsewhere.define_singleton_method(:reconcile!) { { task_folder: File.join(task.folder, "elsewhere") } }
      error = assert_raises(Hive::StaleOperationalObservation) do
        release(task, worktree_root, current, transition: moved_elsewhere)
      end
      assert_includes error.message, "pending Patrol Fix transition"

      git_read = Hive::AgentGitGate.method(:read)
      failing_status = lambda do |path, operation, **options|
        next Struct.new(:success?, :stdout).new(false, "") if operation == :status

        git_read.call(path, operation, **options)
      end
      with_replaced_singleton_method(Hive::AgentGitGate, :read, failing_status) do
        error = assert_raises(SecretRework::Refused) { release(task, worktree_root, current) }
        assert_equal "the blocked worktree status is unavailable", error.message
      end

      receipts_path = File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME)
      original = File.binread(receipts_path)
      File.write(receipts_path, original.gsub('"receipt_id":"fix-one"', '"receipt_id":"fix-renamed"'))
      error = assert_raises(SecretRework::Refused) { release(task, worktree_root, current) }
      assert_equal "the blocked fix receipt is unavailable", error.message
      File.binwrite(receipts_path, original)

      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug, worktree_root: worktree_root
      ).read
      File.write(File.join(owner.fetch("worktree"), "late.rb"), "puts :late\n")
      git(owner.fetch("worktree"), "add", "late.rb")
      git(owner.fetch("worktree"), "commit", "-m", "Late change")
      error = assert_raises(SecretRework::Refused) { release(task, worktree_root, current) }
      assert_includes error.message, "changed after the block"

      File.delete(File.join(task.folder, Hive::PatrolFix::WorktreeReceipt::FILENAME))
      error = assert_raises(SecretRework::Refused) { release(task, worktree_root, current) }
      assert_includes error.message, "custody is invalid"
    end

    with_fixed_task(stage: "3-validate", contents: SAFE) do |task, worktree_root, _manifest, _fix|
      assert_nil SecretRework.current_block(task_folder: task.folder)
      error = assert_raises(SecretRework::Refused) do
        SecretRework.operator_rework!(
          task, cfg: {}, project: "demo", observation_token: "0" * 64, worktree_root: worktree_root,
          transition: committed_transition(task, worktree_root)
        )
      end
      assert_equal "the task has no current Patrol Fix secret_detected block", error.message
    end
  end

  def test_scan_keeps_only_redacted_path_line_and_rule
    hits = [
      { name: "generic-password", line: 4, column: 9, path: "b.rb", fingerprint: "c:b.rb:generic-password:4",
        sha256: "f" * 64, snippet: "[REDACTED]" },
      { name: "generic-password", line: 4, column: 9, path: "b.rb", fingerprint: "d:b.rb:generic-password:4",
        sha256: "e" * 64, snippet: "[REDACTED]" },
      { name: "bad rule!", line: -1, path: "a\tb.rb", sha256: "d" * 64 },
      { name: "github-pat", line: "7", path: "", sha256: "c" * 64 },
      { name: "github-pat", line: 2, path: "é" * 300, sha256: "b" * 64 }
    ]
    findings = with_replaced_singleton_method(Hive::GithubPublication, :commit_secret_findings, ->(**) { hits }) do
      SecretRework.scan(worktree: "/repo", base_revision: "1" * 40, head_revision: "2" * 40, base_branch: "main")
    end

    assert_equal 4, findings.length
    assert(findings.all? { |row| row.keys.sort == %w[line path rule_id] })
    assert_includes findings, { "path" => "a?b.rb", "line" => 0, "rule_id" => "unknown-rule" }
    assert_includes findings, { "path" => "(unknown path)", "line" => 0, "rule_id" => "github-pat" }
    assert_includes findings, { "path" => "b.rb", "line" => 4, "rule_id" => "generic-password" }
    long = findings.find { |row| row["rule_id"] == "github-pat" && row["line"] == 2 }
    assert_operator long.fetch("path").bytesize, :<=, SecretRework::MAX_PATH_BYTES
    assert long.fetch("path").valid_encoding?
    refute_includes JSON.generate(findings), "f" * 64
  end

  def test_decision_bounds_findings_and_validates_its_closed_shape
    manifest = { "task" => { "slug" => "repair-one", "generation" => 1 },
                 "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 } }
    fix = { "receipt_id" => "fix-1", "payload" => { "head_revision" => "b" * 40, "diff_digest" => "c" * 64 } }
    findings = (1..40).map { |line| { "path" => "x.rb", "line" => line, "rule_id" => "generic-password" } }

    receipt = SecretRework.decision(manifest: manifest, stage: "validate", route: "blocked", findings: findings, fix: fix,
                                    recorded_at: Time.utc(2026, 11, 14))

    assert_equal SecretRework::MAX_FINDINGS, receipt.dig("payload", "findings").length
    assert_equal 8, receipt.dig("payload", "omitted_findings")
    assert_equal "8 more finding(s) omitted", receipt.dig("payload", "evidence").last
    assert_equal 40, SecretRework.finding_count(receipt)
    assert valid_receipt?(receipt)
    Dir.mktmpdir do |dir|
      assert_equal receipt, Hive::PatrolFix::ReceiptStore.new(task_folder: dir).append!(receipt)
    end
    [
      receipt.fetch("payload").merge("blocker_owner" => "fix_agent"),
      receipt.fetch("payload").merge("findings" => []),
      receipt.fetch("payload").merge("findings" => [ { "path" => "x.rb", "line" => 1, "rule_id" => "bad rule" } ]),
      receipt.fetch("payload").merge("blocked_receipt_id" => "publication-block-1"),
      receipt.fetch("payload").merge("secret" => SECRET)
    ].each do |payload|
      assert_raises(SecretRework::InvalidDecision) { SecretRework.validate_payload!("validate", payload) }
      Dir.mktmpdir do |dir|
        assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
          Hive::PatrolFix::ReceiptStore.new(task_folder: dir).append!(receipt.merge("payload" => payload))
        end
      end
    end
    assert_raises(SecretRework::InvalidDecision) do
      SecretRework.validate_payload!("publish", receipt.fetch("payload").merge("route" => "rework", "blocker_owner" => "fix_agent"))
    end
  end

  def test_secret_reopens_are_limited_to_the_gate_and_operator
    base = {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1, "receipt_id" => "reopen-1",
      "kind" => "reopen", "task" => { "slug" => "repair-one", "generation" => 2 },
      "evidence_revision" => { "generation" => 2, "digest" => "a" * 64 },
      "recorded_at" => "2026-11-14T12:00:00Z"
    }
    valid = [
      [ "validate", SecretRework::SCAN_OPERATOR, [] ], [ "validate", SecretRework::ACTION_OPERATOR, [] ],
      [ "publish", SecretRework::ACTION_OPERATOR, [] ], [ "publish", SecretRework::REPUBLISH_OPERATOR, [ "review-1" ] ]
    ]
    invalid = [
      [ "publish", SecretRework::SCAN_OPERATOR, [] ], [ "validate", "controller:review", [] ],
      [ "publish", SecretRework::ACTION_OPERATOR, [ "fix-1" ] ], [ "publish", SecretRework::REPUBLISH_OPERATOR, [] ],
      [ "publish", SecretRework::REPUBLISH_OPERATOR, %w[review-1 fix-1] ],
      [ "validate", SecretRework::REPUBLISH_OPERATOR, [ "review-1" ] ]
    ]
    valid.each do |stage, operator, carried|
      receipt = base.merge("stage" => stage, "payload" => {
        "outcome_receipt_id" => "secret-1", "operator" => operator, "carried_receipts" => carried
      })
      Dir.mktmpdir { |dir| Hive::PatrolFix::ReceiptStore.new(task_folder: dir).append!(receipt) }
      assert valid_receipt?(receipt), "#{stage} #{operator}"
    end
    invalid.each do |stage, operator, carried|
      receipt = base.merge("stage" => stage, "payload" => {
        "outcome_receipt_id" => "secret-1", "operator" => operator, "carried_receipts" => carried
      })
      Dir.mktmpdir do |dir|
        assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
          Hive::PatrolFix::ReceiptStore.new(task_folder: dir).append!(receipt)
        end
      end
      refute valid_receipt?(receipt), "#{stage} #{operator} #{carried.inspect}"
    end
  end

  def test_rework_budget_limit_is_validated_and_shared
    assert_equal 2, Hive::PatrolFix::ReworkBudget.limit({})
    assert_equal 2, Hive::PatrolFix::ReworkBudget.limit(nil)
    assert_equal 0, Hive::PatrolFix::ReworkBudget.limit({ "patrol" => { "max_rework_cycles" => 0 } })
    assert_equal 3, Hive::PatrolFix::ReworkBudget.limit({ "patrol" => { "max_rework_cycles" => 0 } }, 3)
    assert_raises(Hive::ConfigError) { Hive::PatrolFix::ReworkBudget.limit({ "patrol" => { "max_rework_cycles" => "2" } }) }
    receipts = [
      { "kind" => "decision", "stage" => "review", "payload" => { "route" => "rework" } },
      { "kind" => "decision", "stage" => "validate", "payload" => { "route" => "rework" } },
      { "kind" => "decision", "stage" => "validate", "payload" => { "route" => "blocked" } },
      { "kind" => "reopen", "stage" => "publish", "payload" => { "route" => "rework" } }
    ]
    assert_equal 2, Hive::PatrolFix::ReworkBudget.spent(receipts)
    refute Hive::PatrolFix::ReworkBudget.remaining?(receipts, 2)
  end

  def test_transition_accepts_only_the_exact_current_secret_decision
    with_fixed_task(stage: "3-validate", contents: LEAK) do |task, worktree_root, manifest, fix|
      transition = committed_transition(task, worktree_root)
      gate = SecretRework.decision(
        manifest: manifest, stage: "validate", route: "rework",
        findings: [ { "path" => LOGIN_TEST, "line" => 1, "rule_id" => "generic-password" } ], fix: fix
      )
      error = assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.apply_secret_rework!(gate, operator: SecretRework::ACTION_OPERATOR)
      end
      assert_includes error.message, "exact secret-policy decision"
      stale = gate.merge("evidence_revision" => { "generation" => 1, "digest" => "f" * 64 })
      error = assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.apply_secret_rework!(stale, operator: SecretRework::SCAN_OPERATOR)
      end
      assert_equal "secret rework decision is stale", error.message

      commits = []
      transition = Hive::PatrolFix::Transition.new(task, worktree_root: worktree_root, commit: ->(**values) { commits << values })
      transition.apply_secret_rework!(gate, operator: SecretRework::SCAN_OPERATOR)
      assert_equal "secret scan rework", commits.first.fetch(:action)
      assert_includes commits.first.fetch(:pathspecs), File.join("stages", "3-validate", task.slug)
    end
  end

  def test_hive_act_runs_the_confirmed_operator_rework_locally_and_replays
    with_blocked_publication(contents: LEAK) do |task, worktree_root, _block|
      File.write(File.join(task.hive_state_path, "config.yml"),
                 Hive::Config::DEFAULTS.merge("default_branch" => "main").to_yaml)
      project = { "name" => "demo", "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      token = SecretRework.observation_token(
        project: "demo", slug: task.slug, block: SecretRework.current_block(task_folder: task.folder)
      )
      target = "demo:#{task.slug}"
      action = Hive::OperationalAction::SECRET_REWORK_ACTION_ID
      transition = committed_transition(task, worktree_root)
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        with_replaced_singleton_method(Hive::PatrolFix::Transition, :new, ->(*, **) { transition }) do
          executor = Hive::OperationalAction::Executor.new
          error = assert_raises(Hive::OperationalActionUsageError) do
            executor.execute(action_id: action, target: target, observation_token: token)
          end
          assert_includes error.message, "pass --confirm"
          remote = Hive::OperationalAction::Executor.new(remote_authority: { "principal" => "api" })
          error = assert_raises(Hive::OperationalActionUsageError) do
            remote.execute(action_id: action, target: target, observation_token: token, confirm: true)
          end
          assert_includes error.message, "run it locally"
          refute Hive::OperationalAction::EXECUTABLE_ACTION_IDS.include?(action)

          result = executor.execute(action_id: action, target: target, observation_token: token, confirm: true)

          assert_equal "2-fix", result.fetch("stage")
          assert_equal [ "ready_to_run", "none" ], result.values_at("task_state", "marker"),
                       "the reworked generation is immediately dispatchable to Fix"
          assert_equal({ "status" => "reworked", "generation" => 2, "findings" => 1 }, result.fetch("secret_rework"))
          payload = {
            "schema" => "hive-act", "schema_version" => 2, "ok" => true, "action_id" => action,
            "target" => target, "observation_token" => token, "result" => result
          }
          schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))
          assert schema.valid?(payload), schema.validate(payload).map { |row| row.fetch("error") }.inspect
          replay = executor.execute(action_id: action, target: target, observation_token: token, confirm: true)
          assert_equal "already_reworked", replay.dig("secret_rework", "status")
          refute_includes JSON.generate([ result, replay ]), SECRET
        end
      end
    end
  end

  def test_hive_act_refuses_other_workflows_and_reports_refusals_as_usage
    executor = Hive::OperationalAction::Executor.new
    executor.define_singleton_method(:registered_project) { |_name| { "name" => "demo" } }
    coding = Struct.new(:workflow).new(Struct.new(:id).new(:coding))
    executor.define_singleton_method(:resolve_task) { |*| coding }
    error = assert_raises(Hive::OperationalActionUsageError) do
      executor.execute(action_id: SecretRework::ACTION_ID, target: "demo:task", observation_token: "a" * 64, confirm: true)
    end
    assert_equal "demo:task is not a Patrol Fix task", error.message

    patrol = Struct.new(:workflow, :project_root).new(Struct.new(:id).new(:"patrol-fix"), "/repo")
    executor.define_singleton_method(:resolve_task) { |*| patrol }
    refuse = ->(*, **) { raise SecretRework::Refused, "the blocked review approval is unavailable" }
    error = with_replaced_singleton_method(Hive::Config, :load, ->(*) { {} }) do
      with_replaced_singleton_method(SecretRework, :operator_rework!, refuse) do
        assert_raises(Hive::OperationalActionUsageError) do
          executor.execute(action_id: SecretRework::ACTION_ID, target: "demo:task", observation_token: "a" * 64, confirm: true)
        end
      end
    end
    assert_equal "workflow.secret_rework refused: the blocked review approval is unavailable", error.message
  end

  def test_current_block_ignores_other_stages
    with_fixed_task(stage: "2-fix", contents: LEAK) do |task, _worktree_root, _manifest, _fix|
      assert_nil SecretRework.current_block(task_folder: task.folder)
    end
    with_blocked_publication(contents: SAFE, block: false) do |task, _worktree_root, _block|
      assert_nil SecretRework.current_block(task_folder: task.folder)
    end
  end

  private

  class OkGithub
    def initialize = @records = []
    def authenticate!(**) = true
    def list_pull_requests(**) = @records

    def create_pull_request(request:, **)
      @records << {
        "number" => 7, "url" => "https://github.com/acme/demo/pull/7", "state" => "OPEN", "draft" => true,
        "head_branch" => request.branch, "head_oid" => request.head_oid, "head_repository" => request.repository,
        "base_branch" => request.base_branch, "base_repository" => request.repository,
        "title" => request.title, "body" => request.published_body
      }
      true
    end
  end

  def identity_git
    delegate = Hive::GithubPublication::GitGateway.new(remote: "origin", allow_local_transport: true)
    git = Object.new
    git.define_singleton_method(:repository_identity) { |**| { "host" => "github.com", "repository" => "acme/demo" } }
    git.define_singleton_method(:observe) { |**values| delegate.observe(**values) }
    git.define_singleton_method(:push_exact) { |**values| delegate.push_exact(**values) }
    git
  end

  def publish_config
    { "default_branch" => "main", "patrol" => { "draft_prs" => true },
      "agent_git_gate" => { "allow_local_transport" => true } }
  end

  def release(task, worktree_root, block, token: nil, transition: nil)
    token ||= SecretRework.observation_token(project: "demo", slug: task.slug, block: block)
    SecretRework.operator_rework!(
      task, cfg: publish_config, project: "demo", observation_token: token, worktree_root: worktree_root,
      transition: transition || committed_transition(task, worktree_root)
    )
  end

  # Models the operator's own exact-fingerprint exception, written outside
  # task worktrees under Hive's config home. Production code never writes it.
  def with_operator_exception_for(task, worktree_root)
    owner = Hive::PatrolFix::WorktreeReceipt.new(
      task_folder: task.folder, project_root: task.project_root, slug: task.slug, worktree_root: worktree_root
    ).read
    head = git(owner.fetch("worktree"), "rev-parse", "HEAD").strip
    fingerprints = Hive::SecretScanner.git_findings(
      owner.fetch("worktree"), base_oid: owner.fetch("base_revision"), head_oid: head, upstream_branch: "main"
    ).map { |hit| hit.fetch(:fingerprint) }
    refute_empty fingerprints
    Dir.mktmpdir("hive-operator-config") do |home|
      with_env("HIVE_HOME" => home) do
        File.write(File.join(Hive::Paths.config_home, "betterleaks.ignore"), fingerprints.join("\n") + "\n")
        assert_empty Hive::SecretScanner.git_findings(
          owner.fetch("worktree"), base_oid: owner.fetch("base_revision"), head_oid: head, upstream_branch: "main"
        ), "the exact-fingerprint exception must make the blocked range clean"
        yield
      end
    end
  end

  def committed_transition(task, worktree_root)
    Hive::PatrolFix::Transition.new(task, worktree_root: worktree_root, commit: ->(**) { :committed })
  end

  def validate!(task, cfg = {}, worktree_root:, runner: ->(*) { flunk "validation commands must not run on a flagged range" })
    Hive::Stages::PatrolFix::Validate.run!(
      task, cfg, command_runner: runner, worktree_root: worktree_root,
      transition: committed_transition(task, worktree_root)
    )
  end

  def move_task(task, stage_dir)
    destination = File.join(task.hive_state_path, "stages", stage_dir, task.slug)
    FileUtils.mkdir_p(File.dirname(destination))
    File.rename(task.folder, destination)
    Hive::Task.new(destination)
  end

  def fix_report
    { "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1, "status" => "fixed",
      "summary" => "Replaced the credential literal.", "validation_commands" => [] }
  end

  # The agent squashes its fix onto Base, so no commit in the range keeps
  # the literal it was told about.
  def rewrite_runner(contents, prompts)
    report = fix_report
    lambda do |**values|
      prompts << values.fetch(:prompt)
      worktree = values.fetch(:owner).fetch("worktree")
      PatrolFixStageFixture.git(worktree, "reset", "--soft", values.fetch(:owner).fetch("base_revision"))
      File.write(File.join(worktree, LOGIN_TEST), contents)
      PatrolFixStageFixture.git(worktree, "add", "-A")
      PatrolFixStageFixture.git(worktree, "commit", "-m", "Fix login without credential literals")
      File.write(values.fetch(:output_path), JSON.generate(report))
      { status: :ok, custody: :clean }
    end
  end

  def with_fixed_task(stage:, contents:)
    PatrolFixStageFixture.with_task(stage: stage) do |task, root, manifest|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktree_root = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug, worktree_root: worktree_root
      )
      owner = custody.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: manifest.fetch("target_revision"))
      FileUtils.mkdir_p(File.join(owner.fetch("worktree"), "test"))
      File.write(File.join(owner.fetch("worktree"), LOGIN_TEST), contents)
      git(owner.fetch("worktree"), "add", LOGIN_TEST)
      git(owner.fetch("worktree"), "commit", "-m", "Fix login and add a regression")
      payload = custody.capture!(generation: 1, evidence_digest: "a" * 64).merge("validation_commands" => [])
      fix = store.append!(receipt(manifest, "fix", "fix", payload, "fix-one"))
      yield task, worktree_root, manifest, fix
    end
  end

  def with_publish_task(contents:, review_rationale: "Independent review approved the exact patch.")
    with_fixed_task(stage: "5-publish", contents: contents) do |task, worktree_root, manifest, fix|
      origin = File.join(File.dirname(task.project_root), "remote.git")
      git(File.dirname(task.project_root), "init", "--bare", "--quiet", origin)
      git(task.project_root, "remote", "add", "origin", origin)
      git(task.project_root, "push", "--quiet", "origin", "main")
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      validation = store.append!(receipt(manifest, "validation", "validate", {
        "verdict" => "passed", "worktree_head" => fix.dig("payload", "head_revision"), "commands" => []
      }, "validation-one"))
      store.append!(receipt(manifest, "decision", "review", {
        "route" => "publish", "rationale" => review_rationale, "evidence" => [ "Exact patch is adequate." ],
        "blocker_owner" => "review_gate", "head_revision" => fix.dig("payload", "head_revision"),
        "diff_digest" => fix.dig("payload", "diff_digest"), "fix_receipt_id" => fix.fetch("receipt_id"),
        "validation_receipt_id" => validation.fetch("receipt_id")
      }, "review-one"))
      yield task, worktree_root, manifest, fix
    end
  end

  def with_blocked_publication(contents:, review_rationale: "Independent review approved the exact patch.", block: true)
    with_publish_task(contents: contents, review_rationale: review_rationale) do |task, worktree_root, _manifest, _fix|
      receipt = nil
      if block
        result = Hive::Stages::PatrolFix::Publish.run!(
          task, publish_config, git_gateway: identity_git, github_gateway: Object.new,
          worktree_root: worktree_root, cleanup: ->(*) { flunk "a blocked publication must not clean up" }
        )
        assert_equal :parked, result.fetch(:status)
        receipt = result.fetch(:receipt)
      end
      yield task, worktree_root, receipt
    end
  end

  def receipt(manifest, kind, stage, payload, id)
    {
      "schema" => Hive::PatrolFix::ReceiptStore::SCHEMA, "schema_version" => Hive::PatrolFix::ReceiptStore::SCHEMA_VERSION,
      "receipt_id" => id, "kind" => kind, "stage" => stage, "task" => manifest.fetch("task"),
      "evidence_revision" => manifest.fetch("evidence_revision"), "recorded_at" => "2026-11-14T12:00:00Z",
      "payload" => payload
    }
  end

  def valid_receipt?(receipt)
    JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-receipt")))
               .valid?(JSON.parse(JSON.generate(receipt)))
  end

  # Receipts, transition intents, worktree custody, and the manifest are the
  # controller-owned bytes; none may carry the matched value.
  def refute_secret_persisted(task, secret = SECRET)
    files = Dir[File.join(task.folder, "**", "*")] +
            Dir[File.join(task.hive_state_path, "patrol-fix", "**", "*")]
    files.select { |path| File.file?(path) && !path.end_with?(".log") }.each do |path|
      refute_includes File.binread(path), secret, path
    end
  end

  def git(path, *args) = PatrolFixStageFixture.git(path, *args)
end
