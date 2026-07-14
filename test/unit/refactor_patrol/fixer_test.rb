require "test_helper"
require "hive/config"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/thesis"

class RefactorPatrolFixerTest < Minitest::Test
  include HiveTestHelper

  def test_repository_global_action_identity_controls_publication_branch
    action_id = "fix-#{'a' * 64}"
    subject = fixer("/tmp/project", agent: ->(**) { })

    first = subject.send(:branch_name, "job-one", "fingerprint", action_id)
    second = subject.send(:branch_name, "job-two", "different", action_id)

    assert_equal "hive-refactor/#{action_id}", first
    assert_equal first, second
  end

  def test_invalid_repository_global_action_identity_fails_before_materialization
    result = fixer("/tmp/project", agent: ->(**) { }).attempt(
      thesis: thesis, job_id: "job-one", analysis_sha: "a" * 40,
      canonical_action_id: "fix-short"
    )

    assert_equal "fix_error", result.outcome
    assert result.terminal
    assert_includes result.details.fetch("error"), "canonical fix action identity is invalid"
  end

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

  def test_retry_discards_a_dirty_incomplete_worktree
    with_repo do |repo, analysis_sha|
      first = fixer(repo, agent: lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "lib/checkout.rb"),
          "module Checkout\n  def self.call = :old\n  DIRTY = true\nend\n"
        )
        { status: :ok }
      end).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)
      assert first.publishable?
      File.write(File.join(first.worktree_path, "unfinished.tmp"), "partial\n")

      recovered = fixer(repo, agent: ->(**) { flunk "dirty retry must stop before the agent" })
                  .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "dirty_worktree_recovered", recovered.outcome
      assert_includes recovered.details.fetch("error"), "discarded an incomplete prior fix attempt"
      refute File.directory?(first.worktree_path)
    end
  end

  def test_recovered_commit_is_amended_when_formatter_converges_new_bytes
    with_repo do |repo, analysis_sha|
      first = fixer(repo, agent: lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  FIXED = true\nend\n")
        { status: :ok }
      end).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)
      assert first.publishable?

      validations = 0
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            validations += 1
            if validations == 1
              File.write(File.join(path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  FORMATTED = true\nend\n")
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

  def test_incomplete_leverage_measurement_never_creates_a_fix_worktree
    with_repo do |repo, analysis_sha|
      item = thesis
      item.feature_hotspot = {
        "measurement" => { "status" => "incomplete", "diagnostics" => [] }
      }
      item.risk["flags"] = [ "incomplete_leverage_measurement" ]
      item.admissible = false
      agent_called = false

      patch = fixer(repo, agent: ->(**) { agent_called = true })
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "not_accepted", patch.outcome
      assert patch.terminal
      refute agent_called
    end
  end

  def test_dirty_registered_checkout_fails_before_agent_or_worktree_mutation
    with_repo do |repo, analysis_sha|
      File.write(File.join(repo, "README.md"), "uncommitted\n")

      patch = fixer(repo, agent: ->(**) { flunk "dirty checkout must not run the agent" })
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "fix_error", patch.outcome
      refute patch.terminal
      assert_includes patch.details.fetch("error"), "must be clean"
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
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
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

  def test_unrelated_ref_movement_does_not_misclassify_the_agent_patch
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
        run!("git", "-C", repo, "update-ref", "refs/heads/agent-owned", analysis_sha)
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
    end
  end

  def test_agent_fix_branch_ref_mutation_is_a_terminal_safety_violation
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
        tree = run!("git", "-C", repo, "rev-parse", "#{analysis_sha}^{tree}").strip
        unrelated = run!("git", "-C", repo, "commit-tree", tree, "-m", "agent ref rewrite").strip
        branch = run!("git", "-C", worktree_path, "symbolic-ref", "HEAD").strip
        run!("git", "-C", repo, "update-ref", branch, unrelated)
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "agent_control_plane_violation", patch.outcome
      assert patch.terminal
      assert_includes patch.details.fetch("changed"), "fix_branch_ref"
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

  def test_staged_rename_cannot_hide_the_vacated_path_from_the_boundary_guard
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(
        repo, "legacy/notes.rb", "# memo one\n# memo two\n# memo three\n# memo four\n"
      )
      item = thesis(boundary_file: "lib/renamed_notes.rb")
      agent = lambda do |worktree_path:, **|
        run!("git", "-C", worktree_path, "mv", "legacy/notes.rb", "lib/renamed_notes.rb")
        File.open(File.join(worktree_path, "lib/renamed_notes.rb"), "a") { |file| file.puts("# memo five") }
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "boundary_violation", patch.outcome, patch.to_h.inspect
      assert patch.terminal
      assert_includes patch.details.fetch("outside"), "legacy/notes.rb"
    end
  end

  def test_staged_rename_of_a_public_api_file_trips_the_contract_guard
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(repo, "bin/deploy", "#!/bin/sh\necho deploy\n")
      item = thesis(boundary_files: [ "bin/deploy", "lib/deploy.rb" ])
      agent = lambda do |worktree_path:, **|
        run!("git", "-C", worktree_path, "mv", "bin/deploy", "lib/deploy.rb")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "public_contract_change", patch.outcome, patch.to_h.inspect
      assert patch.terminal
    end
  end

  def test_symlinked_changed_path_fails_the_audit_before_any_content_guard
    with_repo do |repo, analysis_sha|
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |**|
            flunk "symlinked paths must fail before validation"
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        replaced = File.join(worktree_path, "lib/checkout.rb")
        File.delete(replaced)
        File.symlink("/outside/secret", replaced)
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "symlinked_path", patch.outcome, patch.to_h.inspect
      assert patch.terminal
      assert_equal [ "lib/checkout.rb" ], patch.details.fetch("symlinked_paths")
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_public_contract_base_read_failure_is_not_treated_as_a_new_file
    with_repo do |repo, _analysis_sha|
      subject = fixer(repo, agent: ->(**) { })

      error = assert_raises(Hive::GitError) do
        subject.send(:public_declaration_changed?, repo, "0" * 40, "lib/checkout.rb")
      end

      assert_includes error.message, "cannot verify refactor audit base commit"
    end
  end

  def test_config_error_during_fix_is_terminal_with_error_details
    with_repo do |repo, analysis_sha|
      agent = lambda do |**|
        raise Hive::ConfigError, "auto-fix provider cannot enforce workspace-write isolation"
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "fix_error", patch.outcome
      assert patch.terminal
      assert_includes patch.details.fetch("error"), "Hive::ConfigError"
      assert_includes patch.details.fetch("error"), "workspace-write isolation"
    end
  end

  def test_missing_named_validation_fails_closed
    with_repo do |repo, analysis_sha|
      item = thesis
      item.required_validation = { "commands" => [ "docs" ] }
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "missing_validation", patch.outcome
      assert patch.terminal
    end
  end

  def test_failing_validation_is_terminal_with_the_validation_receipt
    with_repo do |repo, analysis_sha|
      validator = ->(_commands) {
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |_path, names:|
            { "passed" => false, "commands" => names.map { |name| { "name" => name, "exit_code" => 1 } } }
          end
        end
      }
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "lib/checkout.rb"),
          "module Checkout\n  def self.call = :old\n  FAILED = true\nend\n"
        )
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "validation_failed", patch.outcome
      assert_equal false, patch.validation.fetch("passed")
    end
  end

  def test_validation_that_moves_head_is_terminal
    with_repo do |repo, analysis_sha|
      git_run = method(:run!)
      validator = ->(_commands) {
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |path, names:|
            git_run.call(
              "git", "-C", path, "commit", "--allow-empty", "-m",
              "unexpected validation commit", "--quiet"
            )
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      }
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "lib/checkout.rb"),
          "module Checkout\n  def self.call = :old\n  MOVED = true\nend\n"
        )
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, validator: validator)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "validation_changed_head", patch.outcome, patch.to_h.inspect
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
                "module Checkout\n  def self.call = :old\n  FORMATTED = true\nend\n"
              )
            end
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
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
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
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

  def test_new_source_file_with_exported_declaration_is_a_public_contract_change
    with_repo do |repo, analysis_sha|
      item = thesis(boundary_file: "pkg/client/new_client.go")
      agent = lambda do |worktree_path:, **|
        path = File.join(worktree_path, "pkg/client/new_client.go")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "package client\n\nfunc NewClient() *Client { return nil }\n")
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

  def test_mapped_languages_without_public_contract_guards_are_report_only
    {
      "src/firmware/control.zig" => [ "fn helper() void {}\n", "pub fn helper() void {}\n" ],
      "src/legacy/control.cob" => [ "PROGRAM-ID. INTERNAL.\n", "PROGRAM-ID. PUBLIC.\n" ]
    }.each do |path, (before, after)|
      with_repo do |repo, _analysis_sha|
        analysis_sha = commit_file(repo, path, before)
        item = thesis(boundary_file: path)
        validations = 0
        validator = lambda do |_commands|
          Object.new.tap do |object|
            object.define_singleton_method(:validate) do |**|
              validations += 1
              flunk "unsupported contract safety must stop before validation"
            end
          end
        end
        agent = lambda do |worktree_path:, **|
          File.write(File.join(worktree_path, path), after)
          { status: :ok }
        end

        patch = fixer(repo, agent: agent, validator: validator)
                .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

        assert_equal "public_contract_safety_unavailable", patch.outcome, path
        assert patch.terminal, path
        assert_equal [ path ], patch.details.fetch("unsupported_paths")
        assert_equal 0, validations, path
        refute File.directory?(patch.worktree_path), path
      end
    end
  end

  def test_extensionless_shebang_changes_require_public_contract_certification
    scenarios = {
      "new shebang" => [ nil, "#!/usr/bin/env custom-runtime\nrelease --safe\n" ],
      "base shebang removed" => [ "#!/usr/bin/env custom-runtime\nrelease --old\n", "release --safe\n" ]
    }

    scenarios.each do |label, (before, after)|
      with_repo do |repo, analysis_sha|
        analysis_sha = commit_file(repo, "scripts/release", before) if before
        item = thesis(boundary_file: "scripts/release")
        agent = lambda do |worktree_path:, **|
          path = File.join(worktree_path, "scripts/release")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, after)
          { status: :ok }
        end

        patch = fixer(repo, agent: agent)
                .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

        assert_equal "public_contract_safety_unavailable", patch.outcome, label
        assert_equal [ "scripts/release" ], patch.details.fetch("unsupported_paths"), label
        assert patch.terminal, label
      end
    end
  end

  def test_configured_public_contract_command_certifies_extensionless_shebang_change
    with_repo do |repo, _analysis_sha|
      analysis_sha = commit_file(
        repo, "scripts/release", "#!/usr/bin/env custom-runtime\nrelease --old\n"
      )
      item = thesis(boundary_file: "scripts/release")
      validated_names = []
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |_worktree, names:|
            validated_names.concat(names)
            { "passed" => true, "commands" => [] }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, "scripts/release"),
          "#!/usr/bin/env custom-runtime\nrelease --safe\n"
        )
        { status: :ok }
      end

      patch = fixer(
        repo, agent: agent, validator: validator,
        cfg_overrides: {
          "refactor_patrol" => {
            "commands" => { "public_contract" => "bin/check-public-contract" }
          }
        }
      ).attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal %w[public_contract test], validated_names.sort
    end
  end

  def test_extensionless_non_source_and_unreadable_deleted_base_are_distinct
    with_tmp_dir do |dir|
      subject = fixer(dir, agent: ->(**) { })
      path = File.join(dir, "scripts", "generated")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "generated data\n")

      refute subject.send(:source_change_path?, dir, "f" * 40, "scripts/generated")

      File.delete(path)
      failed = Struct.new(:exitstatus) do
        def success? = false
      end.new(1)
      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { [ "base lookup failed", "", failed ] }
      ) do
        assert_raises(Hive::GitError) do
          subject.send(:source_change_path?, dir, "f" * 40, "scripts/generated")
        end
      end
      assert_includes error.message, "cannot inspect the base form"
      assert_includes error.message, "base lookup failed"
    end
  end

  def test_injected_public_contract_guard_can_certify_an_additional_language
    with_repo do |repo, _analysis_sha|
      path = "src/firmware/control.zig"
      analysis_sha = commit_file(repo, path, "fn helper() void { return; }\n")
      item = thesis(boundary_file: path)
      guard = Object.new
      guard.define_singleton_method(:public_api_path?) { |_changed| false }
      guard.define_singleton_method(:public_contract_guard_available?) do |changed|
        File.extname(changed) == ".zig"
      end
      guard.define_singleton_method(:public_declaration_signatures) do |_changed, content|
        content.lines.grep(/^\s*pub\s/).map(&:strip).sort
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, path), "fn helper() void { work(); }\n")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent, public_contract_guard: guard)
              .attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
    end
  end

  def test_configured_public_contract_command_certifies_an_unadapted_language
    with_repo do |repo, _analysis_sha|
      path = "src/firmware/control.zig"
      analysis_sha = commit_file(repo, path, "fn helper() void { return; }\n")
      item = thesis(boundary_file: path)
      validated_names = []
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |_worktree, names:|
            validated_names.concat(names)
            {
              "passed" => true,
              "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } }
            }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, path), "fn helper() void { work(); }\n")
        { status: :ok }
      end

      patch = fixer(
        repo, agent: agent, validator: validator,
        cfg_overrides: {
          "refactor_patrol" => {
            "commands" => { "public_contract" => "bin/check-public-contract" }
          }
        }
      ).attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal %w[test public_contract].sort, validated_names.sort
    end
  end

  def test_configured_public_contract_command_is_authoritative_for_supported_source_changes
    with_repo do |repo, _analysis_sha|
      path = "src/client.py"
      analysis_sha = commit_file(repo, path, "class Client:\n    def __init__(self, endpoint): pass\n")
      item = thesis(boundary_file: path)
      validated_names = []
      validator = lambda do |_commands|
        Object.new.tap do |object|
          object.define_singleton_method(:validate) do |_worktree, names:|
            validated_names.concat(names)
            {
              "passed" => true,
              "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } }
            }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(
          File.join(worktree_path, path),
          "class Client:\n    def __init__(self, endpoint, timeout=None): pass\n"
        )
        { status: :ok }
      end

      patch = fixer(
        repo, agent: agent, validator: validator,
        cfg_overrides: {
          "refactor_patrol" => {
            "commands" => { "public_contract" => "bin/check-public-contract" }
          }
        }
      ).attempt(thesis: item, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal %w[public_contract test], validated_names.sort
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
        File.open(File.join(worktree_path, "lib/checkout.rb"), "a") do |file|
          file.puts("TOKEN = 'sk-#{'a' * 48}'")
        end
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

  def test_overlapping_trunk_advance_reruns_the_fix_from_current_trunk
    with_repo do |repo, analysis_sha|
      calls = 0
      agent = lambda do |worktree_path:, **|
        calls += 1
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :fixed\nend\n")
        if calls == 1
          File.write(File.join(repo, "lib/checkout.rb"), "module Checkout\n  def self.call = :trunk\nend\n")
          run!("git", "-C", repo, "add", ".")
          run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")
        end
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert patch.publishable?, patch.to_h.inspect
      assert_equal 2, calls
      assert_equal analysis_sha, patch.analysis_sha
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip,
                   patch.publication_base_sha
      assert_equal true, patch.details.fetch("reanalyzed_after_trunk_overlap")
      assert_equal [ "lib/checkout.rb" ], patch.details.fetch("overlap")
    end
  end

  def test_second_overlapping_trunk_advance_returns_a_retryable_reanalysis_result
    with_repo do |repo, analysis_sha|
      calls = 0
      agent = lambda do |worktree_path:, **|
        calls += 1
        File.write(
          File.join(worktree_path, "lib/checkout.rb"),
          "module Checkout\n  def self.call = :fixed_#{calls}\nend\n"
        )
        File.write(
          File.join(repo, "lib/checkout.rb"),
          "module Checkout\n  def self.call = :trunk_#{calls}\nend\n"
        )
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "advance trunk #{calls}", "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal 2, calls
      assert_equal "trunk_overlap_reanalysis_required", patch.outcome
      refute patch.terminal
      assert_equal analysis_sha, patch.analysis_sha
    end
  end

  def test_registered_checkout_branch_switch_during_fix_fails_closed
    with_repo do |repo, analysis_sha|
      run!("git", "-C", repo, "branch", "diverted")
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
        run!("git", "-C", repo, "switch", "diverted", "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "fix_error", patch.outcome
      refute patch.terminal
      assert_includes patch.details.fetch("error"), "configured default branch"
      refute File.directory?(patch.worktree_path)
    end
  end

  def test_registered_default_branch_rewrite_during_fix_fails_closed
    with_repo do |repo, analysis_sha|
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
        tree = run!("git", "-C", repo, "rev-parse", "HEAD^{tree}").strip
        unrelated = run!("git", "-C", repo, "commit-tree", tree, "-m", "unrelated root").strip
        run!("git", "-C", repo, "reset", "--hard", unrelated, "--quiet")
        { status: :ok }
      end

      patch = fixer(repo, agent: agent)
              .attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert_equal "fix_error", patch.outcome
      refute patch.terminal
      assert_includes patch.details.fetch("error"), "no longer descends"
      refute File.directory?(patch.worktree_path)
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

  def test_retry_recovers_a_patch_that_was_already_rebased_onto_disjoint_trunk
    with_repo do |repo, analysis_sha|
      first = fixer(repo, agent: lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  FIXED = true\nend\n")
        File.write(File.join(repo, "README.md"), "advanced\n")
        run!("git", "-C", repo, "add", "README.md")
        run!("git", "-C", repo, "commit", "-m", "advance docs", "--quiet")
        { status: :ok }
      end).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)
      assert first.publishable?, first.to_h.inspect

      recovered = fixer(
        repo, agent: ->(**) { flunk "rebased recovery must not rerun the agent" }
      ).attempt(thesis: thesis, job_id: "job-7", analysis_sha: analysis_sha)

      assert recovered.publishable?, recovered.to_h.inspect
      assert_equal first.commit_sha, recovered.commit_sha
      assert_equal first.publication_base_sha, recovered.publication_base_sha
      assert_equal [ "lib/checkout.rb" ], recovered.changed_paths
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
                "module Checkout\n  def self.call = :old\n  FORMATTED_AFTER_REBASE = true\nend\n"
              )
            end
            { "passed" => true, "commands" => names.map { |name| { "name" => name, "exit_code" => 0 } } }
          end
        end
      end
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "lib/checkout.rb"), "module Checkout\n  def self.call = :old\n  UPDATED = true\nend\n")
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

  def test_private_safety_helpers_fail_closed_for_git_and_checkout_anomalies
    with_repo do |repo, analysis_sha|
      subject = fixer(repo, agent: ->(**) { })
      status = Struct.new(:exitstatus) do
        def success? = false
      end.new(2)
      with_replaced_singleton_method(Open3, :capture3, ->(*) { [ "", "broken index", status ] }) do
        error = assert_raises(Hive::GitError) { subject.send(:staged_changes?, repo) }
        assert_includes error.message, "cannot inspect staged refactor patch"
      end

      assert_equal [ "missing", nil, nil ], subject.send(:file_identity, File.join(repo, "missing"))

      run!("git", "-C", repo, "switch", "-c", "feature", "--quiet")
      assert_raises(Hive::GitError) { subject.send(:registered_checkout_snapshot!, analysis_sha) }
      run!("git", "-C", repo, "switch", "master", "--quiet")

      before = { branch: "master", head: analysis_sha, status: "" }
      File.write(File.join(repo, "uncommitted.txt"), "changed\n")
      error = assert_raises(Hive::GitError) { subject.send(:assert_registered_checkout!, before) }
      assert_includes error.message, "changed during refactor fix"
    end
  end

  def test_recovered_patch_must_be_one_non_merge_commit
    with_repo do |repo, analysis_sha|
      File.write(File.join(repo, "left.txt"), "left\n")
      run!("git", "-C", repo, "add", "left.txt")
      run!("git", "-C", repo, "commit", "-m", "left", "--quiet")
      run!("git", "-C", repo, "switch", "-c", "side", analysis_sha, "--quiet")
      File.write(File.join(repo, "side.txt"), "side\n")
      run!("git", "-C", repo, "add", "side.txt")
      run!("git", "-C", repo, "commit", "-m", "side", "--quiet")
      run!("git", "-C", repo, "switch", "master", "--quiet")
      run!("git", "-C", repo, "merge", "side", "--no-ff", "-m", "merge", "--quiet")

      assert_raises(Hive::GitError) do
        fixer(repo, agent: ->(**) { }).send(
          :recovered_patch_base!, repo, analysis_sha, run!("git", "-C", repo, "rev-parse", "HEAD").strip
        )
      end
    end
  end

  def test_default_agent_runner_uses_workspace_write_profile_and_run_directory
    with_tmp_dir do |dir|
      profile = Struct.new(:name) do
        def workspace_write_supported? = true
      end.new(:codex)
      captured = nil
      fake_agent = Object.new
      fake_agent.define_singleton_method(:run!) { { status: :ok } }
      subject = Hive::RefactorPatrol::Fixer.new(dir, cfg: cfg(dir))

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        with_replaced_singleton_method(Hive::Agent, :new, lambda { |**kwargs|
          captured = kwargs
          fake_agent
        }) do
          result = subject.send(
            :run_agent, prompt: "isolate policy", worktree_path: dir,
            run_dir: File.join(dir, "runs", "fix")
          )

          assert_equal :ok, result.fetch(:status)
        end
      end

      assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                   captured.fetch(:permission_mode)
      assert_equal dir, captured.fetch(:cwd)
      assert File.directory?(File.join(dir, "runs", "fix"))
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

  def fixer(repo, agent:, validator: nil, cfg_overrides: {}, public_contract_guard: Hive::RefactorPatrol::Caps)
    Hive::RefactorPatrol::Fixer.new(
      repo, cfg: cfg(repo, cfg_overrides), agent_runner: agent,
      validator_factory: validator, public_contract_guard: public_contract_guard
    )
  end

  def thesis(boundary_file: "lib/checkout.rb", boundary_files: nil)
    files = boundary_files || [ boundary_file ]
    Hive::RefactorPatrol::Thesis.new(
      id: "extract-checkout", feature_id: "checkout", feature: "Checkout",
      problem: "Checkout mixes concerns", cost: "Every change fans out",
      evidence: [ { "file" => files.first, "signal" => "churn", "value" => 10 } ],
      proposed_refactor: "Extract the internal orchestration",
      feature_boundary: { "owned_files" => files, "entrypoints" => [ files.first ] },
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
