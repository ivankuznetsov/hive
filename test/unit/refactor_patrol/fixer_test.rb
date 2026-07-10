require "test_helper"
require "hive/config"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/thesis"

class RefactorPatrolFixerTest < Minitest::Test
  include HiveTestHelper

  def test_success_starts_at_exact_analysis_sha_and_leaves_registered_trunk_unchanged
    with_repo do |repo, analysis_sha|
      before = snapshot(repo)
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :fixed\nend\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?
      assert_equal analysis_sha, patch.analysis_sha
      assert_equal analysis_sha, patch.publication_base_sha
      assert_equal [ "lib/checkout.rb" ], patch.changed_paths
      assert File.directory?(patch.worktree_path)
      assert_equal before, snapshot(repo)
      assert_equal analysis_sha, run!("git", "-C", patch.worktree_path, "merge-base", analysis_sha, "HEAD").strip
    end
  end

  def test_retry_recovers_a_clean_committed_patch_without_rerunning_agent
    with_repo do |repo, analysis_sha|
      calls = 0
      first_agent = lambda do |worktree_path:, **|
        calls += 1
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :fixed\nend\n")
        { status: :ok }
      end
      subject = fixer(repo, agent: first_agent)
      first = subject.attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)
      assert first.publishable?

      retry_subject = fixer(repo, agent: ->(**) { flunk "committed retry must not rerun the fix agent" })
      recovered = retry_subject.attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert recovered.publishable?, recovered.to_h.inspect
      assert_equal 1, calls
      assert_equal first.commit_sha, recovered.commit_sha
      assert_equal first.changed_paths, recovered.changed_paths
    end
  end

  def test_recovered_commit_is_amended_when_formatter_converges_new_bytes
    with_repo do |repo, analysis_sha|
      first = fixer(repo, agent: lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\nend\n")
        { status: :ok }
      end).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)
      assert first.publishable?

      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            validations += 1
            if validations == 1
              File.write(File.join(path, "lib/checkout.rb"), "module Checkout\n  FORMATTED = true\nend\n")
            end
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      recovered = fixer(
        repo, agent: ->(**) { flunk "recovery must not rerun agent" }, validator: validator
      ).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert recovered.publishable?, recovered.to_h.inspect
      refute_equal first.commit_sha, recovered.commit_sha
      assert_includes run!("git", "-C", recovered.worktree_path, "show", "HEAD:lib/checkout.rb"), "FORMATTED = true"
      assert_empty run!("git", "-C", recovered.worktree_path, "status", "--porcelain")
    end
  end

  def test_no_diff_is_terminal_and_removes_worktree
    with_repo do |repo, analysis_sha|
      patch = fixer(repo, agent: ->(**) { { status: :ok } })
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "no_diff", patch.outcome
      assert patch.terminal
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_fix_prompt_names_the_isolated_worktree_not_registered_checkout
    with_repo do |repo, analysis_sha|
      captured = nil
      agent = lambda do |prompt:, worktree_path:, **|
        captured = prompt
        assert_includes prompt, worktree_path
        refute_includes prompt, "rooted at `#{repo}`"
        { status: :ok }
      end

      fixer(repo, agent: agent).attempt(
        thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha
      )

      assert_includes captured, "isolated git\nworktree"
    end
  end

  def test_low_confidence_thesis_never_creates_a_worktree
    with_repo do |repo, analysis_sha|
      item = thesis
      item.confidence = "low"
      agent_called = false

      patch = fixer(repo, agent: ->(**) { agent_called = true })
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "not_accepted", patch.outcome
      assert patch.terminal
      refute agent_called
    end
  end

  def test_fix_provider_without_workspace_write_capability_fails_closed
    with_repo do |repo, _analysis_sha|
      subject = fixer(
        repo, agent: ->(**) { flunk "injected runner is not used by profile lookup" },
        cfg_overrides: { "refactor_patrol" => { "auto_fix" => { "agent" => "claude" } } }
      )

      error = assert_raises(Hive::ConfigError) { subject.send(:fix_profile) }

      assert_includes error.message, "cannot enforce workspace-write isolation"
    end
  end

  def test_agent_shared_git_config_mutation_is_a_terminal_safety_violation
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\nend\n")
        run!("git", "-C", repo, "config", "patrol.compromised", "yes")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "agent_control_plane_violation", patch.outcome
      assert patch.terminal
      assert_includes patch.details.fetch("changed"), "shared_git_config"
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_agent_sibling_ref_mutation_is_a_terminal_safety_violation
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\nend\n")
        run!("git", "-C", repo, "update-ref", "refs/heads/agent-owned", analysis_sha)
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "agent_control_plane_violation", patch.outcome
      assert patch.terminal
      assert_includes patch.details.fetch("changed"), "shared_git_refs"
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_agent_worktree_git_pointer_mutation_is_a_terminal_safety_violation
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, ".git"), "gitdir: /untrusted/repository\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "agent_control_plane_violation", patch.outcome
      assert patch.terminal
      assert_includes patch.details.fetch("changed"), "worktree_git_pointer"
    end
  end

  def test_actual_out_of_boundary_change_is_terminal_before_validation
    with_repo do |repo, analysis_sha|
      validator_called = false
      validator = lambda do |_commands|
        validator_called = true
        raise "must not validate"
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "README.md"), "outside\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "boundary_violation", patch.outcome
      assert patch.terminal
      refute validator_called
    end
  end

  def test_missing_named_validation_fails_closed
    with_repo do |repo, analysis_sha|
      item = thesis
      item.required_validation = { "commands" => [ "docs" ] }
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\nend\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "missing_validation", patch.outcome
      assert patch.terminal
    end
  end

  def test_mutating_formatter_is_reaudited_and_exact_converged_bytes_are_committed
    with_repo do |repo, analysis_sha|
      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            validations += 1
            if validations == 1
              File.write(
                File.join(path, "lib/checkout.rb"),
                "module Checkout\n  FORMATTED = true\nend\n"
              )
            end
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout;end\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal 2, validations
      assert_equal 2, patch.validation.fetch("stabilization_passes")
      assert_includes run!("git", "-C", patch.worktree_path, "show", "HEAD:lib/checkout.rb"), "FORMATTED = true"
      assert_empty run!("git", "-C", patch.worktree_path, "status", "--porcelain")
    end
  end

  def test_nonconvergent_validation_mutation_is_terminal_and_never_committed
    with_repo do |repo, analysis_sha|
      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            validations += 1
            File.open(File.join(path, "lib/checkout.rb"), "a") { |file| file.puts("# pass #{validations}") }
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\nend\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "validation_mutated_worktree", patch.outcome
      assert patch.terminal
      assert_equal 2, validations
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_actual_diff_caps_are_enforced_before_validation
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "lib/checkout.rb"),
          "module Checkout\n  def one = 1\n  def two = 2\nend\n"
        )
        { status: :ok }
      end

      patch = fixer(
        repo, agent: agent,
        cfg_overrides: { "refactor_patrol" => { "caps" => { "max_diff_lines" => 1 } } }
      ).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "caps_exceeded", patch.outcome
      assert patch.terminal
    end
  end

  def test_dependency_manifest_change_is_terminal_before_validation
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(repo, "pom.xml", "<project/>\n")
      item = thesis(boundary_file: "pom.xml")
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "pom.xml"), "<project><dependency/></project>\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "dependency_change", patch.outcome
      assert patch.terminal
    end
  end

  def test_language_neutral_public_contract_change_is_terminal
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(repo, "cmd/tool/main.go", "package main\nfunc main() {}\n")
      item = thesis(boundary_file: "cmd/tool/main.go")
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "cmd/tool/main.go"), "package main\nfunc main() { println(\"changed\") }\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "public_contract_change", patch.outcome
      assert patch.terminal
    end
  end

  def test_new_exported_declaration_is_a_public_contract_change
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(
        repo, "pkg/client/client.go", "package client\n\nfunc helper() {}\n"
      )
      item = thesis(boundary_file: "pkg/client/client.go")
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "pkg/client/client.go"),
          "package client\n\nfunc helper() {}\nfunc NewClient() *Client { return nil }\n"
        )
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "public_contract_change", patch.outcome
      assert patch.terminal
    end
  end

  def test_internal_declaration_change_is_not_mistaken_for_a_public_contract
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(
        repo, "pkg/client/client.go", "package client\n\nfunc helper() {}\n"
      )
      item = thesis(boundary_file: "pkg/client/client.go")
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "pkg/client/client.go"),
          "package client\n\nfunc helper() {}\nfunc newClient() *Client { return nil }\n"
        )
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
    end
  end

  def test_protected_workflow_change_trips_fix_guardrail
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(repo, ".github/workflows/build.yml", "name: build\n")
      item = thesis(boundary_file: ".github/workflows/build.yml")
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, ".github/workflows/build.yml"), "name: deploy\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "fix_guardrail", patch.outcome, patch.to_h.inspect
      assert patch.terminal
    end
  end

  def test_secret_scan_blocks_when_the_shared_guardrail_secret_pattern_is_disabled
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "TOKEN = 'sk-#{'a' * 48}'\n")
        { status: :ok }
      end
      overrides = {
        "review" => {
          "fix" => { "guardrail" => { "patterns_override" => { "secrets_pattern_match" => false } } }
        }
      }

      patch = fixer(repo, agent: agent, cfg_overrides: overrides)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "secret_detected", patch.outcome
      assert patch.terminal
    end
  end

  def test_overlapping_trunk_advance_requires_reanalysis_instead_of_rebase
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :fixed\nend\n")
        File.write(File.join(repo, "lib/checkout.rb"), "module Checkout\n  def self.call = :trunk\nend\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "trunk_overlap_reanalysis_required", patch.outcome
      assert patch.terminal
      assert_equal [ "lib/checkout.rb" ], patch.details.fetch("overlap")
    end
  end

  def test_disjoint_trunk_advance_rebases_and_reruns_validation
    with_repo do |repo, analysis_sha|
      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |_path, names:|
            validations += 1
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :fixed\nend\n")
        File.write(File.join(repo, "README.md"), "advanced\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "advance docs", "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?
      assert_equal 2, validations
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip, patch.publication_base_sha
    end
  end

  def test_post_rebase_formatter_mutation_is_reaudited_and_amended
    with_repo do |repo, analysis_sha|
      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            validations += 1
            if validations == 2
              File.write(
                File.join(path, "lib/checkout.rb"),
                "module Checkout\n  FORMATTED_AFTER_REBASE = true\nend\n"
              )
            end
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout; end\n")
        File.write(File.join(repo, "README.md"), "advanced\n")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "advance docs", "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal 3, validations
      assert_includes(
        run!("git", "-C", patch.worktree_path, "show", "HEAD:lib/checkout.rb"),
        "FORMATTED_AFTER_REBASE"
      )
      assert_empty run!("git", "-C", patch.worktree_path, "status", "--porcelain")
    end
  end

  private

  def with_repo
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "lib"))
      File.write(File.join(repo, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\nend\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "checkout", "--quiet")
      yield repo, run!("git", "-C", repo, "rev-parse", "HEAD").strip
    end
  end

  def cfg(repo, overrides = {})
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "master",
        "worktree_root" => "#{repo}-worktrees",
        "refactor_patrol" => {
          "commands" => { "test" => "ruby -c lib/checkout.rb" },
          "caps" => { "max_files" => 4, "max_diff_lines" => 80 }
        }
      }.then { |base| Hive::Config.deep_merge(base, overrides) }
    )
  end

  def fixer(repo, agent:, validator: nil, cfg_overrides: {})
    Hive::RefactorPatrol::Fixer.new(
      repo, cfg: cfg(repo, cfg_overrides), agent_runner: agent,
      validator_factory: validator
    )
  end

  def thesis(boundary_file: "lib/checkout.rb")
    Hive::RefactorPatrol::Thesis.new(
      id: "extract-checkout", feature_id: "checkout", feature: "Checkout",
      problem: "Checkout mixes concerns", cost: "Every change fans out",
      evidence: [ { "file" => boundary_file, "signal" => "churn", "value" => 10 } ],
      proposed_refactor: "Extract the internal orchestration",
      feature_boundary: { "owned_files" => [ boundary_file ], "entrypoints" => [ boundary_file ] },
      expected_leverage: { "score" => 0.8, "breakdown" => { "churn" => 0.8 } },
      confidence: "medium",
      risk: { "flags" => [], "caps" => { "est_files" => 1, "est_diff_lines" => 10 } },
      required_validation: { "commands" => [ "test" ] }, admissible: true,
      admissibility_reason: "", follow_up_approval_state: "pending",
      fingerprint: "abcdef1234567890"
    )
  end

  def commit_file(repo, path, content)
    full = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    run!("git", "-C", repo, "add", ".")
    run!("git", "-C", repo, "commit", "-m", "add #{path}", "--quiet")
    run!("git", "-C", repo, "rev-parse", "HEAD").strip
  end

  def snapshot(repo)
    {
      head: run!("git", "-C", repo, "rev-parse", "HEAD").strip,
      status: run!("git", "-C", repo, "status", "--porcelain=v1")
    }
  end
end
