require "test_helper"
require "hive/config"
require "hive/patrol/fixer"
require "hive/patrol/finding"
require "hive/usage_db"

class HivePatrolFixerTest < Minitest::Test
  include HiveTestHelper

  def cfg(repo)
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "master",
        "worktree_root" => File.join(File.dirname(repo), "worktrees"),
        "patrol" => {
          "commands" => { "test" => "ruby -c app.rb && ruby test/patrol_regression_test.rb" }
        }
      }
    )
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "route-users-1",
      feature_id: "route-users",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Syntax fix",
      description: "app has a bug",
      recommendation: "write valid ruby",
      scope: "feature",
      contract: "The app must parse before it can start.",
      impact: "Every invocation fails during startup.",
      root_cause: "The generated entrypoint contains invalid syntax.",
      reproduction: "Run ruby -c app.rb and observe a syntax error.",
      validation: "Run ruby -c app.rb before and after the fix.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "abcdef1234567890"
    )
  end

  def write_fix_proof(output_path, status: "fixed",
                      regression_paths: [ "test/patrol_regression_test.rb" ],
                      audited_paths: [ "app.rb", "test/patrol_regression_test.rb" ])
    payload = if status == "fixed"
                {
                  "status" => "fixed",
                  "root_cause" => "The entrypoint contains invalid syntax.",
                  "audited_paths" => audited_paths,
                  "regression_paths" => regression_paths,
                  "validation_key" => "test"
                }
    else
      { "status" => "rejected", "reason" => "The current base no longer reproduces the finding." }
    end
    File.write(output_path, JSON.generate(payload))
  end

  def write_regression(worktree_path, expected: "puts 'fixed'\n")
    path = File.join(worktree_path, "test", "patrol_regression_test.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      <<~RUBY
        expected = #{expected.dump}
        actual = File.read(File.expand_path("../app.rb", __dir__))
        abort "unexpected app.rb: \#{actual.inspect}" unless actual == expected
      RUBY
    )
  end

  def with_usage_db
    old_path = Hive::UsageDb.path
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      yield
    ensure
      Hive::UsageDb.path = old_path
    end
  end

  def usage_rows
    require "sqlite3"

    db = SQLite3::Database.new(Hive::UsageDb.path)
    db.results_as_hash = true
    db.execute("SELECT agent, model, project_slug, task_slug, stage, input, output, cached FROM token_usage")
  ensure
    db&.close
  end

  def test_successful_fix_is_committed_and_patch_recorded
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      assert_equal true, patch.passed
      assert_equal run!("git", "-C", repo, "rev-parse", "master").strip, patch.base_sha
      assert_match(/app\.rb/, patch.diffstat)
      assert File.directory?(patch.worktree_path), "passed fix worktree remains for PR creation"
      assert File.exist?(Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")].first)
      proof = patch.validation.fetch("fix_proof")
      assert_equal "test", proof.fetch("validation_key")
      assert_equal [ "test/patrol_regression_test.rb" ], proof.fetch("regression_paths")
      refute_equal 0, proof.dig("before", "exit_code")
      assert_equal 0, proof.dig("after", "exit_code")
      assert_equal cfg(repo).dig("patrol", "commands", "test"), proof.dig("after", "command")
      assert_equal "if\n", File.read(File.join(repo, "app.rb")),
                   "managed repo worktree must stay untouched"
    end
  end

  def test_validation_failure_removes_worktree_and_opens_no_pr_path
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      bad_cfg = cfg(repo)
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "if\n")
        write_regression(worktree_path)
        write_fix_proof(
          output_path,
          audited_paths: [ "README.md", "test/patrol_regression_test.rb" ]
        )
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: bad_cfg, agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed
      refute File.directory?(patch.worktree_path), "failed fix worktree should be removed"
      assert_empty Dir.glob(File.join(File.dirname(patch.worktree_path), ".control-*")),
                   "machine-proof control worktree must always be removed"
    end
  end

  def test_failed_fix_agent_run_is_not_validated_or_shipped
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      # Agent#run! reports a non-zero exit via status :error rather than
      # raising, yet still leaves a (would-be valid) change behind.
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        { status: :error, error_message: "exit_code=1" }
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed, "a failed fix agent must never produce a validated patch"
      assert_equal "fix_agent_failed", patch.validation["reason"]
      refute_nil patch.base_sha
      refute File.directory?(patch.worktree_path), "failed-agent worktree should be removed"
    end
  end

  def test_timed_out_fix_agent_run_is_not_validated_or_shipped
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      validator = Object.new
      validator.define_singleton_method(:validate) do |*_args, **_kwargs|
        raise "a timed-out fix agent's changes must never be validated"
      end
      # Agent#run! reports a timeout via status :timeout (not :error), yet
      # still leaves a half-finished (would-be valid) change behind.
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        { status: :timeout }
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: cfg(repo), validator: validator, agent_runner: agent
      ).attempt(finding)

      assert_equal false, patch.passed, "a timed-out fix agent must never produce a validated patch"
      assert_equal "fix_agent_failed", patch.validation["reason"]
      assert_includes patch.validation["error"], "timed out"
      refute_empty Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")],
                   "the timed-out attempt must still be recorded as an agent failure"
      refute File.directory?(patch.worktree_path), "timed-out-agent worktree should be removed"
    end
  end

  def test_missing_validation_commands_fails_closed
    with_tmp_git_repo do |repo|
      empty_cfg = cfg(repo)
      empty_cfg["patrol"]["commands"] = {}
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "README.md"), "changed\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: empty_cfg, agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "no_validation_commands", patch.validation["reason"]
    end
  end

  def test_attempt_records_failed_patch_when_worktree_creation_raises
    with_tmp_git_repo do |repo|
      worktree = Object.new
      def worktree.path = "/tmp/hive-missing-worktree"
      def worktree.create_exact!(*)
        raise Hive::GitError, "create failed"
      end
      def worktree.remove!(**)
        raise Hive::GitError, "remove failed"
      end

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        worktree_factory: ->(**) { worktree }
      ).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "fix_error", patch.validation["reason"]
      assert_match(/\A[0-9a-f]{40}\z/, patch.base_sha)
    end
  end

  def test_attempt_fails_when_created_worktree_is_not_the_exact_base
    with_tmp_git_repo do |repo|
      base_sha = run!("git", "-C", repo, "rev-parse", "master").strip
      run!("git", "-C", repo, "checkout", "-b", "feature", "--quiet")
      File.write(File.join(repo, "feature.txt"), "advanced\n")
      run!("git", "-C", repo, "add", "feature.txt")
      run!("git", "-C", repo, "commit", "-m", "feature", "--quiet")
      worktree = Object.new
      worktree.define_singleton_method(:path) { repo }
      worktree.define_singleton_method(:create_exact!) { |*| nil }
      worktree.define_singleton_method(:remove!) { |**| nil }

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        worktree_factory: ->(**) { worktree }
      ).attempt(finding)

      refute patch.passed
      assert_equal base_sha, patch.base_sha
      assert_includes patch.validation.fetch("error"), "patrol worktree started at"
    end
  end

  def test_missing_fix_proof_is_never_validated_or_shipped
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      agent = ->(worktree_path:, **) { File.write(File.join(worktree_path, "app.rb"), "puts 'changed'\n") }

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "missing_fix_proof", patch.validation["reason"]
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_fixer_can_reject_a_stale_or_unreproducible_finding_without_a_patch
    with_tmp_git_repo do |repo|
      agent = ->(output_path:, **) { write_fix_proof(output_path, status: "rejected") }

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "fix_agent_rejected", patch.validation["reason"]
      assert_match(/no longer reproduces/, patch.validation["error"])
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_fix_proof_loader_rejects_malformed_incomplete_and_oversized_output
    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))
      path = File.join(dir, "fix.json")
      cases = {
        "[]" => /JSON object/,
        '{"status":"unknown"}' => /status must be fixed or rejected/,
        '{"status":"fixed","root_cause":" "}' => /identify the root cause/,
        '{"status":"fixed","root_cause":"cause","audited_paths":[]}' => /audited sibling paths/,
        JSON.generate(
          "status" => "fixed",
          "root_cause" => "cause",
          "audited_paths" => [ "app.rb" ],
          "regression_paths" => [ "quality/startup.flux" ],
          "validation_key" => " "
        ) => /configured validation key/,
        JSON.generate(
          "status" => "fixed",
          "root_cause" => "cause",
          "audited_paths" => [ "app.rb" ],
          "validation_key" => "test"
        ) => /regression paths/,
        JSON.generate(
          "status" => "fixed",
          "root_cause" => "cause",
          "audited_paths" => [ "app.rb" ],
          "regression_paths" => Array.new(Hive::Patrol::Fixer::MAX_REGRESSION_PATHS + 1) { |index| "qa/#{index}.flux" },
          "validation_key" => "test"
        ) => /at most/,
        JSON.generate(
          "status" => "fixed",
          "root_cause" => "cause",
          "audited_paths" => Array.new(Hive::Patrol::Fixer::MAX_AUDITED_PATHS + 1) { |index| "lib/#{index}.flux" },
          "regression_paths" => [ "qa/case.flux" ],
          "validation_key" => "test"
        ) => /at most/,
        JSON.generate(
          "status" => "fixed",
          "root_cause" => "cause",
          "audited_paths" => [ "app.rb" ],
          "regression_paths" => [ "../escape.flux" ],
          "validation_key" => "test"
        ) => /confined relative repository paths/,
        "{" => /invalid fix proof/
      }

      cases.each do |content, message|
        File.write(path, content)
        proof, error = fixer.send(:load_fix_proof, path)
        assert_nil proof
        assert_equal "missing_fix_proof", error.fetch("reason")
        assert_match message, error.fetch("error")
      end

      File.write(path, "x" * (Hive::Patrol::Fixer::MAX_FIX_PROOF_BYTES + 1))
      proof, error = fixer.send(:load_fix_proof, path)
      assert_nil proof
      assert_match(/exceeds/, error.fetch("error"))

      proof, error = fixer.send(:load_fix_proof, dir)
      assert_nil proof
      assert_match(/invalid fix proof/, error.fetch("error"))
    end
  end

  def test_fix_proof_loader_does_not_follow_a_symlinked_output
    skip "File::NOFOLLOW is unavailable" unless File.const_defined?(:NOFOLLOW)

    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))
      target = File.join(dir, "agent-controlled.json")
      output_path = File.join(dir, "fix.json")
      write_fix_proof(target)
      File.symlink(target, output_path)

      proof, error = fixer.send(:load_fix_proof, output_path)

      assert_nil proof
      assert_equal "missing_fix_proof", error.fetch("reason")
      assert_match(/invalid fix proof/, error.fetch("error"))
    end
  end

  def test_fix_proof_loader_rejects_a_fifo_without_blocking
    skip "File::NONBLOCK is unavailable" unless File.const_defined?(:NONBLOCK)

    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))
      output_path = File.join(dir, "fix.json")
      File.mkfifo(output_path, 0o600)

      proof, error = fixer.send(:load_fix_proof, output_path)

      assert_nil proof
      assert_equal "missing_fix_proof", error.fetch("reason")
      assert_match(/not a regular file/, error.fetch("error"))
    end
  end

  def test_fix_proof_loader_rejects_a_non_regular_output
    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))

      proof, error = fixer.send(:load_fix_proof, dir)

      assert_nil proof
      assert_equal "missing_fix_proof", error.fetch("reason")
      assert_match(/not a regular file/, error.fetch("error"))
    end
  end

  def test_rejected_fix_proof_defaults_an_empty_reason
    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))
      path = File.join(dir, "fix.json")
      File.write(path, JSON.generate("status" => "rejected", "reason" => " "))

      proof, error = fixer.send(:load_fix_proof, path)

      assert_nil proof
      assert_equal "fix_agent_rejected", error.fetch("reason")
      assert_match(/could not reproduce/, error.fetch("error"))
    end
  end

  def test_fix_prompt_requires_a_coherent_root_cause_proof
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      prompt = fixer.send(:render_prompt, finding, File.join(repo, "fix.json"))

      assert_includes prompt, "smallest complete root-cause fix"
      assert_includes prompt, '"audited_paths"'
      assert_includes prompt, '"regression_paths"'
      assert_includes prompt, '"validation_key"'
      assert_includes prompt, "Hive will run that operator-configured command"
      assert_includes prompt, "Available operator-configured validation keys: test"
      assert_includes prompt, "These are agent-reported paths"
      refute_includes prompt, '"before"'
      assert_includes prompt, '"status": "rejected"'
    end
  end

  def test_agent_cannot_supply_an_arbitrary_validation_command
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      marker = File.join(repo, "agent-command-ran")
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        File.write(
          output_path,
          JSON.generate(
            "status" => "fixed",
            "root_cause" => "invalid syntax",
            "audited_paths" => [ "app.rb" ],
            "regression_paths" => [ "test/patrol_regression_test.rb" ],
            "validation_key" => "ruby -e 'File.write(#{marker.dump}, 1)'"
          )
        )
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "invalid_validation_key", patch.validation["reason"]
      refute File.exist?(marker), "agent-authored command text must never execute"
    end
  end

  def test_machine_diff_guard_blocks_hard_forbidden_patrol_changes
    hazards = {
      "hive state" => lambda do |path|
        target = File.join(path, ".hive-state", "owned.txt")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "owned\n")
      end,
      "GitHub workflow" => lambda do |path|
        target = File.join(path, ".github", "workflows", "ci.yml")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "name: owned\n")
      end,
      "secret" => lambda do |path|
        File.write(File.join(path, "leak.txt"), "AKIA1234567890ABCDEF\n")
      end,
      "mode" => ->(path) { File.chmod(0o755, File.join(path, "app.rb")) }
    }

    hazards.each do |label, mutate|
      with_tmp_git_repo do |repo|
        File.write(File.join(repo, "app.rb"), "if\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
        agent = lambda do |worktree_path:, output_path:, **|
          File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
          write_regression(worktree_path)
          mutate.call(worktree_path)
          write_fix_proof(output_path)
        end

        patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

        refute patch.passed, "#{label} hazard must fail closed"
        assert_equal "fix_guardrail", patch.validation["reason"], label
        refute_empty patch.validation["matches"], label
      end
    end
  end

  def test_retry_discards_stale_patrol_branch_and_fetches_advanced_default
    with_tmp_git_repo do |repo|
      origin = "#{repo}.origin.git"
      scratch = nil
      begin
        File.write(File.join(repo, "app.rb"), "if\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "broken app", "--quiet")
        run!("git", "clone", "--bare", repo, origin)
        run!("git", "-C", repo, "remote", "add", "origin", origin)
        attempts = 0
        observed_upstream = []
        agent = lambda do |worktree_path:, output_path:, **|
          attempts += 1
          observed_upstream << File.exist?(File.join(worktree_path, "upstream.txt"))
          if attempts == 1
            { status: :error, error_message: "simulated failed attempt" }
          else
            File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
            write_regression(worktree_path)
            write_fix_proof(output_path)
            { status: :ok }
          end
        end
        fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent)

        first = fixer.attempt(finding)
        refute first.passed

        scratch = Dir.mktmpdir("patrol-origin-pusher")
        run!("git", "clone", origin, scratch)
        run!("git", "-C", scratch, "config", "user.email", "test@example.com")
        run!("git", "-C", scratch, "config", "user.name", "Test")
        File.write(File.join(scratch, "upstream.txt"), "advanced\n")
        run!("git", "-C", scratch, "add", ".")
        run!("git", "-C", scratch, "commit", "-m", "advance origin", "--quiet")
        run!("git", "-C", scratch, "push", "origin", "master:master")

        second = fixer.attempt(finding)

        assert second.passed
        assert_equal [ false, true ], observed_upstream,
                     "retry must recreate from freshly fetched origin/master, not the stale local patrol branch"
        assert File.exist?(File.join(second.worktree_path, "upstream.txt"))
      ensure
        FileUtils.rm_rf(scratch) if scratch
        FileUtils.rm_rf(origin)
      end
    end
  end

  def test_review_handoff_retry_reuses_the_exact_validated_patch
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "broken app", "--quiet")
      attempts = 0
      agent = lambda do |worktree_path:, output_path:, **|
        attempts += 1
        raise "fix agent must not rerun for a handoff-only retry" if attempts > 1

        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end
      state = Hive::Patrol::StateStore.new(repo)
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), state: state, agent_runner: agent)

      first = fixer.attempt(finding)
      ledger = state.fingerprints
      Hive::Patrol::Fingerprint.record_seen(
        ledger, finding.fingerprint, branch: first.branch,
        state: "review_handoff_failed", finding: finding
      )
      state.write_fingerprints(ledger)
      second = fixer.attempt(finding)

      assert first.passed
      assert second.passed
      assert_equal first.id, second.id
      assert_equal first.base_sha, second.base_sha
      assert_equal first.head_sha, second.head_sha
      assert_equal 1, attempts
    end
  end

  def test_reconciliation_retry_reuses_the_receipted_validated_patch
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "broken app", "--quiet")
      attempts = 0
      agent = lambda do |worktree_path:, output_path:, **|
        attempts += 1
        raise "fix agent must not rerun for a reconciliation-only retry" if attempts > 1

        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end
      state = Hive::Patrol::StateStore.new(repo)
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), state: state, agent_runner: agent)

      first = fixer.attempt(finding)
      ledger = state.fingerprints
      Hive::Patrol::Fingerprint.record_seen(
        ledger, finding.fingerprint, branch: first.branch,
        pr_url: "https://example.com/pr/2",
        state: "reconciliation_pending", finding: finding
      )
      ledger.fetch(finding.fingerprint)["publication_receipt"] = {
        "patch_id" => first.id,
        "worktree_path" => first.worktree_path,
        "base_sha" => first.base_sha,
        "head_sha" => first.head_sha
      }
      state.write_fingerprints(ledger)

      second = nil
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise "exact receipt must not scan patch history" }) do
        second = fixer.attempt(finding)
      end

      assert first.passed
      assert second.passed
      assert_equal first.id, second.id
      assert_equal first.worktree_path, second.worktree_path
      assert_equal first.base_sha, second.base_sha
      assert_equal first.head_sha, second.head_sha
      assert_equal 1, attempts
    end
  end

  def test_review_handoff_retry_ignores_missing_and_unreadable_patch_receipts
    with_tmp_git_repo do |repo|
      state = Hive::Patrol::StateStore.new(repo)
      branch = "hive-patrol/#{finding.feature_id}-#{finding.fingerprint[0, 8]}"
      state.write_fingerprints(
        finding.fingerprint => {
          "state" => "review_handoff_failed",
          "branch" => branch
        }
      )
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), state: state)
      worktree = Struct.new(:path).new(repo)

      assert_nil fixer.send(:reusable_publication_patch, finding, branch, worktree)
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::EACCES, "denied" }) do
        assert_nil fixer.send(:reusable_publication_patch, finding, branch, worktree)
      end
    end
  end

  def test_review_handoff_receipt_is_not_reused_when_git_state_is_unreadable
    with_tmp_dir do |dir|
      fixer = Hive::Patrol::Fixer.new(dir, cfg: cfg(dir))
      record = {
        "passed" => true,
        "fingerprint" => finding.fingerprint,
        "branch" => "hive-patrol/example",
        "worktree_path" => dir,
        "validation" => { "passed" => true },
        "base_sha" => "a" * 40,
        "head_sha" => "b" * 40
      }

      refute fixer.send(
        :reusable_patch_record?, record, finding, "hive-patrol/example", dir
      )
    end
  end

  def test_remote_fetch_failure_does_not_fall_back_to_a_stale_local_default
    with_tmp_git_repo do |repo|
      missing_origin = File.join(File.dirname(repo), "missing-origin.git")
      run!("git", "-C", repo, "remote", "add", "origin", missing_origin)
      agent_ran = false

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        agent_runner: lambda do |**|
          agent_ran = true
        end
      ).attempt(finding)

      refute patch.passed
      refute agent_ran
      assert_equal "fix_error", patch.validation.fetch("reason")
      assert_includes patch.validation.fetch("error"), "cannot fetch fresh patrol base"
      assert_nil patch.base_sha
    end
  end

  def test_machine_proof_requires_a_declared_changed_regression_file
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_fix_proof(output_path, audited_paths: [ "app.rb" ])
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "missing_regression", patch.validation["reason"]
    end
  end

  def test_machine_proof_rejects_a_regression_that_passes_on_the_base
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      syntax_cfg = cfg(repo)
      syntax_cfg["patrol"]["commands"]["test"] = "ruby -c app.rb"
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: syntax_cfg, agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "regression_not_reproduced", patch.validation["reason"]
      assert_equal 0, patch.validation.dig("fix_proof", "before", "exit_code")
      assert_nil patch.validation.dig("fix_proof", "after")
    end
  end

  def test_machine_proof_rejects_a_regression_path_that_also_contains_the_fix
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      syntax_cfg = cfg(repo)
      syntax_cfg["patrol"]["commands"]["test"] = "ruby -c app.rb"
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_fix_proof(
          output_path,
          regression_paths: [ "app.rb" ],
          audited_paths: [ "app.rb" ]
        )
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: syntax_cfg, agent_runner: agent
      ).attempt(finding)

      refute patch.passed
      assert_equal "regression_not_reproduced", patch.validation["reason"]
      assert_equal [ "app.rb" ], patch.validation.dig("fix_proof", "regression_paths")
      assert_equal 0, patch.validation.dig("fix_proof", "before", "exit_code")
    end
  end

  def test_machine_proof_rejects_abnormal_base_failures
    abnormal = [
      { "exit_code" => 124, "signal" => nil, "timed_out" => true },
      { "exit_code" => 143, "signal" => 15, "timed_out" => false },
      { "exit_code" => 127, "signal" => nil, "timed_out" => false }
    ]

    abnormal.each do |result|
      with_tmp_git_repo do |repo|
        File.write(File.join(repo, "app.rb"), "if\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
        validator = Object.new
        validator.define_singleton_method(:validate) do |path, names: nil|
          if names
            control = File.basename(path).start_with?(".control-")
            command = if control
                        result.merge("name" => "test", "command" => "configured")
            else
                        {
                          "name" => "test", "command" => "configured", "exit_code" => 0,
                          "signal" => nil, "timed_out" => false
                        }
            end
            { "passed" => !control, "commands" => [ command ] }
          else
            { "passed" => true, "commands" => [] }
          end
        end
        agent = lambda do |worktree_path:, output_path:, **|
          File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
          write_regression(worktree_path)
          write_fix_proof(output_path)
        end

        patch = Hive::Patrol::Fixer.new(
          repo, cfg: cfg(repo), validator: validator, agent_runner: agent
        ).attempt(finding)

        refute patch.passed, result.inspect
        assert_equal "regression_not_reproduced", patch.validation["reason"], result.inspect
        assert_nil patch.validation.dig("fix_proof", "after"), result.inspect
      end
    end
  end

  def test_machine_proof_rejects_unverifiable_agent_reported_audit_paths
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      File.write(File.join(repo, ".gitignore"), "ignored.audit\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        File.write(File.join(worktree_path, "ignored.audit"), "agent-created, not repository state\n")
        write_regression(worktree_path)
        write_fix_proof(output_path, audited_paths: [ "ignored.audit" ])
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "missing_fix_proof", patch.validation["reason"]
      assert_match(/agent-reported audited paths/, patch.validation["error"])
    end
  end

  def test_hard_guardrails_cannot_be_disabled_by_review_configuration
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      guarded_cfg = cfg(repo)
      guarded_cfg["review"] ||= {}
      guarded_cfg["review"]["fix"] ||= {}
      guarded_cfg["review"]["fix"]["guardrail"] ||= {}
      guarded_cfg["review"]["fix"]["guardrail"]["patterns_override"] = {
        "secrets_pattern_match" => false
      }
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        File.write(File.join(worktree_path, "leak.txt"), "AKIA1234567890ABCDEF\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: guarded_cfg, agent_runner: agent).attempt(finding)

      refute patch.passed
      assert_equal "fix_guardrail", patch.validation["reason"]
      assert patch.validation["matches"].any? do |match|
        match["pattern_name"] == "secrets_pattern_match.aws_access_key"
      end
    end
  end

  def test_guard_reruns_after_broader_validation_mutates_the_patch
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      validator = Object.new
      validator.define_singleton_method(:validate) do |path, names: nil|
        if names
          passed = !File.basename(path).start_with?(".control-")
          {
            "passed" => passed,
            "commands" => [
              {
                "name" => "test", "command" => "configured test/patrol_regression_test.rb",
                "exit_code" => passed ? 0 : 1
              }
            ]
          }
        else
          workflow = File.join(path, ".github", "workflows", "owned.yml")
          FileUtils.mkdir_p(File.dirname(workflow))
          File.write(workflow, "name: owned\n")
          { "passed" => true, "commands" => [] }
        end
      end
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: cfg(repo), validator: validator, agent_runner: agent
      ).attempt(finding)

      refute patch.passed
      assert_equal "fix_guardrail", patch.validation["reason"]
      assert patch.validation.key?("fix_proof")
    end
  end

  def test_validation_mutation_must_converge_after_one_retry
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      validator = Object.new
      validator.define_singleton_method(:validate) do |path, names: nil|
        if names
          passed = !File.basename(path).start_with?(".control-")
          {
            "passed" => passed,
            "commands" => [
              {
                "name" => "test", "command" => "configured test/patrol_regression_test.rb",
                "exit_code" => passed ? 0 : 1
              }
            ]
          }
        else
          File.open(File.join(path, "README.md"), "a") { |file| file << "validation mutation\n" }
          { "passed" => true, "commands" => [] }
        end
      end
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        write_regression(worktree_path)
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: cfg(repo), validator: validator, agent_runner: agent
      ).attempt(finding)

      refute patch.passed
      assert_equal "validation_mutated_worktree", patch.validation["reason"]
      assert_equal 0, patch.validation.dig("fix_proof", "after", "exit_code")
    end
  end

  def test_machine_proof_accepts_an_unknown_language_regression_in_a_custom_root
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.flux"), "broken\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "flux app", "--quiet")
      custom_cfg = cfg(repo)
      custom_cfg["patrol"]["commands"]["test"] = "ruby quality/cases/startup.flux"
      regression = "quality/cases/startup.flux"
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.flux"), "fixed\n")
        regression_path = File.join(worktree_path, regression)
        FileUtils.mkdir_p(File.dirname(regression_path))
        File.write(
          regression_path,
          <<~RUBY
            actual = File.read(File.expand_path("../../app.flux", __dir__))
            abort "unexpected app.flux: \#{actual.inspect}" unless actual == "fixed\\n"
          RUBY
        )
        write_fix_proof(
          output_path,
          regression_paths: [ regression ],
          audited_paths: [ "app.flux", regression ]
        )
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: custom_cfg, agent_runner: agent
      ).attempt(finding)

      assert patch.passed
      assert_equal [ regression ], patch.validation.dig("fix_proof", "regression_paths")
      refute_equal 0, patch.validation.dig("fix_proof", "before", "exit_code")
      assert_equal 0, patch.validation.dig("fix_proof", "after", "exit_code")
    end
  end

  def test_machine_proof_rejects_an_unexecuted_regression_file
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "if\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "broken app", "--quiet")
      unrelated_cfg = cfg(repo)
      unrelated_cfg["patrol"]["commands"]["test"] = "ruby -c app.rb"
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        regression = File.join(worktree_path, "quality", "unused.flux")
        FileUtils.mkdir_p(File.dirname(regression))
        File.write(regression, "this command never reads me\n")
        write_fix_proof(
          output_path,
          regression_paths: [ "quality/unused.flux" ],
          audited_paths: [ "app.rb", "quality/unused.flux" ]
        )
      end

      patch = Hive::Patrol::Fixer.new(
        repo, cfg: unrelated_cfg, agent_runner: agent
      ).attempt(finding)

      refute patch.passed
      assert_equal "regression_not_reproduced", patch.validation.fetch("reason")
      assert_includes patch.validation.fetch("error"), "did not identify"
    end
  end

  def test_machine_proof_rejects_regressions_through_symlinked_directories
    with_tmp_git_repo do |repo|
      outside = Dir.mktmpdir("patrol-regression-outside")
      begin
        File.write(File.join(repo, "app.rb"), "if\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "broken app", "--quiet")
        agent = lambda do |worktree_path:, output_path:, **|
          File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
          File.symlink(outside, File.join(worktree_path, "quality"))
          File.write(File.join(outside, "escape.flux"), "external\n")
          write_fix_proof(
            output_path,
            regression_paths: [ "quality/escape.flux" ],
            audited_paths: [ "app.rb" ]
          )
        end

        patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

        refute patch.passed
        assert_equal "missing_regression", patch.validation.fetch("reason")
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  def test_regression_overlay_rejects_a_missing_source
    with_tmp_dir do |source|
      with_tmp_dir do |control|
        fixer = Hive::Patrol::Fixer.new(source, cfg: cfg(source))

        error = assert_raises(Hive::GitError) do
          fixer.send(:overlay_regression_paths!, source, control, [ "quality/missing.flux" ])
        end
        assert_match(/cannot overlay missing or symlinked regression/, error.message)
      end
    end
  end

  def test_branch_retry_reset_is_patrol_owned_and_fails_loudly
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      fake = Object.new
      fake.define_singleton_method(:path) { repo }
      fake.define_singleton_method(:exists?) { true }
      removed = false
      fake.define_singleton_method(:remove!) { |**| removed = true }

      assert_raises(Hive::GitError) do
        fixer.send(:prepare_branch_for_retry!, "feature/user-work", fake)
      end
      fixer.send(:prepare_branch_for_retry!, "hive-patrol/fresh", fake)
      assert removed, "registered stale patrol worktree must be removed before branch recreation"

      occupied = File.join(File.dirname(repo), "occupied-patrol-worktree")
      run!("git", "-C", repo, "worktree", "add", "-b", "hive-patrol/occupied", occupied, "master")
      error = assert_raises(Hive::GitError) do
        fixer.send(:prepare_branch_for_retry!, "hive-patrol/occupied", Object.new)
      end
      assert_match(/cannot reset stale patrol branch/, error.message)
    ensure
      run!("git", "-C", repo, "worktree", "remove", "--force", occupied) if repo && File.directory?(occupied)
    end
  end

  def test_branch_inspection_and_git_failures_fail_closed
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      original = Open3.method(:capture3)
      replacement = lambda do |*args, **kwargs|
        if args.include?("show-ref")
          [ "", "cannot inspect refs", status.new(2) ]
        else
          original.call(*args, **kwargs)
        end
      end

      with_replaced_singleton_method(Open3, :capture3, replacement) do
        error = assert_raises(Hive::GitError) do
          fixer.send(:prepare_branch_for_retry!, "hive-patrol/unreadable", Object.new)
        end
        assert_match(/cannot inspect stale patrol branch/, error.message)
      end

      assert_raises(Hive::GitError) do
        fixer.send(:with_control_worktree, "not-a-commit", repo) { flunk "must not yield" }
      end
      assert_raises(Hive::GitError) { fixer.send(:git_output!, repo, "not-a-git-command") }
      assert_raises(Hive::GitError) { fixer.send(:confined_path, repo, "../escape.rb") }
    end
  end

  def test_control_worktree_cleanup_failure_fails_closed
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      original = Open3.method(:capture3)
      replacement = lambda do |*args, **kwargs|
        if args.include?("worktree") && args.include?("remove")
          [ "", "simulated cleanup failure", status.new(1) ]
        else
          original.call(*args, **kwargs)
        end
      end

      with_replaced_singleton_method(Open3, :capture3, replacement) do
        error = assert_raises(Hive::GitError) do
          fixer.send(:with_control_worktree, base, repo) { |_path| nil }
        end
        assert_match(/cannot remove patrol control worktree/, error.message)
      end
      run!("git", "-C", repo, "worktree", "prune")
    end
  end

  def test_control_worktree_cleanup_failure_does_not_mask_the_block_error
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      original = Open3.method(:capture3)
      replacement = lambda do |*args, **kwargs|
        if args.include?("worktree") && args.include?("remove")
          [ "", "simulated cleanup failure", status.new(1) ]
        else
          original.call(*args, **kwargs)
        end
      end

      error = nil
      _out, err = capture_io do
        with_replaced_singleton_method(Open3, :capture3, replacement) do
          error = assert_raises(RuntimeError) do
            fixer.send(:with_control_worktree, base, repo) { raise "machine proof crashed" }
          end
        end
      end

      assert_equal "machine proof crashed", error.message,
                   "the ensure-block cleanup failure must not replace the in-flight exception"
      assert_match(/cannot remove patrol control worktree/, err)
      assert_match(/machine proof crashed/, err)
      run!("git", "-C", repo, "worktree", "prune")
    end
  end

  def test_machine_proof_before_run_executes_the_overlaid_regression_against_the_defect
    with_tmp_git_repo do |repo|
      # The base is VALID ruby and green on its own; only the behavioral
      # defect (the app prints 'old') distinguishes it from the fix, and the
      # configured validation runs ONLY the regression test. The "before"
      # receipt can therefore fail only if overlay_regression_paths! copied
      # the regression into the control checkout and it executed against the
      # defect itself.
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "valid but defective app", "--quiet")
      regression_cfg = cfg(repo)
      regression_cfg["patrol"]["commands"]["test"] = "ruby test/patrol_regression_test.rb"
      marker = "PATROL-REGRESSION-DEFECT: app.rb still carries the defect"
      agent = lambda do |worktree_path:, output_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        path = File.join(worktree_path, "test", "patrol_regression_test.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~RUBY)
          expected = "puts 'fixed'\\n"
          actual = File.read(File.expand_path("../app.rb", __dir__))
          abort #{marker.dump} unless actual == expected
        RUBY
        write_fix_proof(output_path)
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: regression_cfg, agent_runner: agent).attempt(finding)

      assert patch.passed, patch.validation.inspect
      before = patch.validation.dig("fix_proof", "before")
      refute_equal 0, before.fetch("exit_code")
      observed = [ before["stdout"], before["stderr"] ].join("\n")
      assert_includes observed, marker,
                      "the base 'before' run must fail with the overlaid regression's own message, " \
                      "proving the declared regression file was copied to the control checkout and executed"
      assert_equal 0, patch.validation.dig("fix_proof", "after", "exit_code")
    end
  end

  def test_staged_diff_inspection_failures_fail_closed
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      original = Open3.method(:capture3)
      replacement = lambda do |*args, **kwargs|
        if args.include?("diff") && args.include?("--cached") && args.include?("--quiet")
          [ "", "index unavailable", status.new(2) ]
        else
          original.call(*args, **kwargs)
        end
      end

      with_replaced_singleton_method(Open3, :capture3, replacement) do
        assert_raises(Hive::GitError) { fixer.send(:diff_present?, repo) }
        assert_raises(Hive::GitError) { fixer.send(:commit_changes, repo, finding) }
      end
    end
  end

  def test_agent_failed_cleanup_swallows_remove_failure
    with_tmp_git_repo do |repo|
      worktree = Object.new
      worktree.instance_variable_set(:@path, repo)
      def worktree.path = @path
      def worktree.create_exact!(*); end
      def worktree.remove!(**)
        raise Hive::GitError, "remove failed"
      end

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        worktree_factory: ->(**) { worktree },
        agent_runner: ->(**) { { status: :error, error_message: "bad" } }
      ).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "fix_agent_failed", patch.validation["reason"]
    end
  end

  def test_run_agent_wrapper_constructs_agent
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      fake_agent = Object.new
      def fake_agent.run! = { status: :ok }

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      profiles_singleton.define_method(:lookup) { |*| :profile }
      agent_singleton.define_method(:new) { |*| fake_agent }
      assert_equal({ status: :ok },
                   fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo))
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_new
    end
  end

  def test_run_agent_wrapper_records_patrol_fix_usage
    with_tmp_git_repo do |repo|
      with_usage_db do
        fixer_cfg = cfg(repo)
        fixer_cfg["patrol"]["agent"] = "codex"
        fixer = Hive::Patrol::Fixer.new(repo, cfg: fixer_cfg)
        fake_agent = Object.new
        def fake_agent.run!
          {
            status: :ok,
            model: "fallback-model",
            usage: { input: 80, output: 20, cached: 10 }
          }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profile = Struct.new(:name).new("codex")
        profiles_singleton.define_method(:lookup) { |*| profile }
        agent_singleton.define_method(:new) { |*| fake_agent }

        fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)

        rows = usage_rows
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "codex", row["agent"]
        assert_equal "fallback-model", row["model"]
        assert_equal File.basename(repo), row["project_slug"]
        assert_equal "patrol-fix", row["task_slug"]
        assert_equal "patrol-fix", row["stage"]
        assert_equal 80, row["input"]
        assert_equal 20, row["output"]
        assert_equal 10, row["cached"]
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_run_agent_wrapper_does_not_raise_when_usage_recording_fails
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      fake_agent = Object.new
      def fake_agent.run!
        { status: :ok, usage: { input: 1, output: 2, cached: 3 } }
      end

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      usage_singleton = class << Hive::UsageDb; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      usage_record = Hive::UsageDb.method(:record!)
      profiles_singleton.define_method(:lookup) { |*| Struct.new(:name).new("claude") }
      agent_singleton.define_method(:new) { |*| fake_agent }
      usage_singleton.define_method(:record!) { |**| raise "db locked" }

      result = nil
      _out, err = capture_io do
        result = fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)
      end

      assert_equal({ status: :ok, usage: { input: 1, output: 2, cached: 3 } }, result)
      assert_match(/usage record failed: db locked/, err)
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      usage_singleton.define_method(:record!, usage_record) if usage_singleton && usage_record
    end
  end

  def test_run_agent_wrapper_falls_back_to_config_agent_for_nameless_profile
    with_tmp_git_repo do |repo|
      with_usage_db do
        fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
        fake_agent = Object.new
        def fake_agent.run!
          { status: :ok, usage: { input: 1, output: 2, cached: 3 } }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        # A profile object WITHOUT #name exercises profile_name's config fallback.
        profiles_singleton.define_method(:lookup) { |*| Object.new }
        agent_singleton.define_method(:new) { |*| fake_agent }

        fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)

        rows = usage_rows
        assert_equal 1, rows.size
        assert_equal "claude", rows.first["agent"],
                     "a profile without #name must fall back to the configured patrol agent (default claude)"
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_committed_since_base_detects_branch_delta
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))

      assert_equal false, fixer.send(:committed_since_base?, repo)

      run!("git", "-C", repo, "checkout", "-b", "feature", "--quiet")
      File.write(File.join(repo, "feature.txt"), "changed\n")
      run!("git", "-C", repo, "add", "feature.txt")
      run!("git", "-C", repo, "commit", "-m", "feature", "--quiet")

      assert_equal true, fixer.send(:committed_since_base?, repo)
    end
  end


  def test_committed_since_base_raises_when_git_diff_cannot_compare
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      original = Open3.method(:capture3)
      replacement = lambda do |*args, **kwargs|
        if args.include?("diff") && args.include?("--quiet") && args.any? { |arg| arg.to_s.include?("...HEAD") }
          [ "", "cannot read object", status.new(2) ]
        else
          original.call(*args, **kwargs)
        end
      end

      with_replaced_singleton_method(Open3, :capture3, replacement) do
        error = assert_raises(Hive::GitError) do
          fixer.send(:committed_since_base?, repo)
        end
        assert_match(/cannot compare patrol branch/, error.message)
      end
    end
  end
end
