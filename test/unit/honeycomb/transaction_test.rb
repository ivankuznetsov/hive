require "test_helper"
require "digest"
require "hive/honeycomb/transaction"

class HoneycombTransactionTest < Minitest::Test
  include HiveTestHelper

  SimulatedCrash = Class.new(Exception)

  def test_installs_replaces_and_removes_with_one_scoped_commit_each
    with_state_project do |project, workflows|
      transaction = transaction_for(project)
      result = transaction.apply(installs: [ verified_package(workflows, body: "one\n") ], action: "installed")
      assert_equal true, result.changed
      assert_equal "one\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))
      assert_equal "1" * 40, lockfile(workflows).read.fetch("demo").sha
      assert_equal 2, commit_count(project)

      transaction.apply(installs: [ verified_package(workflows, body: "two\n", sha: "2" * 40) ], action: "updated")
      assert_equal "two\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))
      assert_equal "2" * 40, lockfile(workflows).read.fetch("demo").sha
      assert_equal 3, commit_count(project)

      transaction.apply(removals: [ "demo" ], action: "removed")
      refute File.exist?(File.join(workflows, "demo"))
      assert_empty lockfile(workflows).read
      assert_equal 4, commit_count(project)
    end
  end

  def test_refuses_dirty_and_unmanaged_collisions_without_force
    with_state_project do |project, workflows|
      transaction_for(project).apply(installs: [ verified_package(workflows, body: "one\n") ], action: "installed")
      File.write(File.join(workflows, "demo", "instructions", "work.md"), "local\n")

      assert_raises(Hive::Honeycomb::CollisionError) do
        transaction_for(project).apply(
          installs: [ verified_package(workflows, body: "two\n", sha: "2" * 40) ], action: "updated"
        )
      end
      assert_equal "local\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))

      transaction_for(project).apply(
        installs: [ verified_package(workflows, body: "two\n", sha: "2" * 40) ], force: true, action: "updated"
      )
      assert_equal "two\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))

      File.write(File.join(workflows, "local.yml"), "authored\n")
      FileUtils.mkdir_p(File.join(workflows, "local"))
      package = verified_package(workflows, name: "local")
      assert_raises(Hive::Honeycomb::CollisionError) do
        transaction_for(project).apply(installs: [ package ], action: "installed")
      end
    end
  end

  def test_failure_after_swap_restores_files_lock_index_and_history
    with_state_project do |project, workflows|
      transaction_for(project).apply(installs: [ verified_package(workflows, body: "one\n") ], action: "installed")
      before_lock = File.binread(lockfile(workflows).path)
      before_commits = commit_count(project)
      fault = lambda do |phase|
        raise "injected" if phase == :after_swap
      end

      assert_raises(RuntimeError) do
        transaction_for(project, fault: fault).apply(
          installs: [ verified_package(workflows, body: "two\n", sha: "2" * 40) ], action: "updated"
        )
      end

      assert_equal "one\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))
      assert_equal before_lock, File.binread(lockfile(workflows).path)
      assert_equal before_commits, commit_count(project)
      assert_empty git_status(project)
      refute File.exist?(File.join(workflows, ".honeycomb-transaction.yml"))
    end
  end

  def test_next_mutation_recovers_a_process_death_before_proceeding
    with_state_project do |project, workflows|
      transaction_for(project).apply(installs: [ verified_package(workflows, body: "one\n") ], action: "installed")
      crashing = lambda do |phase|
        raise SimulatedCrash, "dead" if phase == :after_swap
      end

      assert_raises(SimulatedCrash) do
        transaction_for(project, fault: crashing).apply(
          installs: [ verified_package(workflows, body: "two\n", sha: "2" * 40) ], action: "updated"
        )
      end
      assert File.file?(File.join(workflows, ".honeycomb-transaction.yml"))

      transaction_for(project).apply(
        installs: [ verified_package(workflows, body: "three\n", sha: "3" * 40) ], action: "updated"
      )
      assert_equal "three\n", File.read(File.join(workflows, "demo", "instructions", "work.md"))
      assert_equal "3" * 40, lockfile(workflows).read.fetch("demo").sha
      refute File.exist?(File.join(workflows, ".honeycomb-transaction.yml"))
      assert_empty git_status(project)
    end
  end

  def test_unknown_removal_is_best_effort_and_partial
    with_state_project do |project, workflows|
      root = File.join(workflows, "orphan")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "workflow.yml"), "id: orphan\n")

      result = transaction_for(project).apply(
        removals: [ "orphan" ], force: true, allow_unknown_removals: true, action: "removed"
      )
      assert_equal true, result.partial
      refute File.exist?(root)
    end
  end

  def test_multi_package_failure_restores_every_package_and_old_lock
    with_state_project do |project, workflows|
      transaction_for(project).apply(
        installs: [ verified_package(workflows, name: "alpha", body: "a1\n"),
                    verified_package(workflows, name: "beta", body: "b1\n") ],
        action: "installed"
      )
      before_lock = File.binread(lockfile(workflows).path)
      fault = ->(phase) { raise "second revision failed" if phase == :after_swap }

      assert_raises(RuntimeError) do
        transaction_for(project, fault: fault).apply(
          installs: [ verified_package(workflows, name: "alpha", body: "a2\n", sha: "2" * 40),
                      verified_package(workflows, name: "beta", body: "b2\n", sha: "2" * 40) ],
          action: "updated"
        )
      end

      assert_equal "a1\n", File.read(File.join(workflows, "alpha", "instructions", "work.md"))
      assert_equal "b1\n", File.read(File.join(workflows, "beta", "instructions", "work.md"))
      assert_equal before_lock, File.binread(lockfile(workflows).path)
      assert_empty git_status(project)
    end
  end

  private

  def with_state_project
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      workflows = File.join(state, "workflows")
      FileUtils.mkdir_p(workflows)
      run!("git", "-C", state, "init", "-b", "hive/state", "--quiet")
      run!("git", "-C", state, "config", "user.email", "test@example.com")
      run!("git", "-C", state, "config", "user.name", "Test")
      run!("git", "-C", state, "config", "commit.gpgsign", "false")
      File.write(File.join(state, ".gitignore"), ".commit-lock\nworkflows/.honeycomb-stage-*\n")
      run!("git", "-C", state, "add", ".gitignore")
      run!("git", "-C", state, "commit", "-m", "initial", "--quiet")
      yield project, workflows
    end
  end

  def verified_package(workflows, name: "demo", body: "work\n", sha: "1" * 40)
    stage = Dir.mktmpdir(".honeycomb-stage-", workflows)
    FileUtils.mkdir_p(File.join(stage, "instructions"))
    descriptor = <<~YAML
      id: #{name}
      stages:
        - name: work
          kind: agent
          state_file: work.md
          instruction: ./instructions/work.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    File.write(File.join(stage, "workflow.yml"), descriptor)
    File.write(File.join(stage, "instructions", "work.md"), body)
    files = %w[workflow.yml instructions/work.md].to_h do |path|
      [ path, Digest::SHA256.file(File.join(stage, path)).hexdigest ]
    end
    manifest = Hive::Honeycomb::Manifest.load({ "version" => 1, "files" => files }.to_yaml)
    pin = Hive::Honeycomb::ResolvedPin.new(
      source: Hive::Honeycomb::SOURCE, name: name, sha: sha, version: "1.0.0",
      tag: "#{name}/v1.0.0", digest: manifest.package_digest, selector_kind: "latest", selector_value: nil
    )
    workflow = Hive::Workflows::DescriptorParser.parse_file(File.join(stage, "workflow.yml"), expected_id: name)
    report = Hive::Honeycomb::SecurityReport.build(workflow: workflow, package_root: stage)
    Hive::Honeycomb::VerifiedPackage.new(
      pin: pin, manifest: manifest, files: files.to_h { |path, _hash| [ path, File.binread(File.join(stage, path)) ] },
      hashes: files, modes: files.keys.to_h { |path| [ path, "100644" ] }, descriptor: workflow,
      security_report: report, staging_dir: stage
    )
  end

  def transaction_for(project, fault: nil)
    Hive::Honeycomb::Transaction.new(project_root: project, fault: fault)
  end

  def lockfile(workflows)
    Hive::Honeycomb::Lockfile.new(File.join(workflows, ".honeycomb.lock"))
  end

  def commit_count(project)
    run!("git", "-C", File.join(project, ".hive-state"), "rev-list", "--count", "HEAD").to_i
  end

  def git_status(project)
    run!("git", "-C", File.join(project, ".hive-state"), "status", "--porcelain").lines
  end
end
