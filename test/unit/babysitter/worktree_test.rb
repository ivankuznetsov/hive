require "test_helper"
require "hive/gh"
require "hive/babysitter/worktree"

class BabysitterWorktreeTest < Minitest::Test
  include HiveTestHelper

  def test_materialize_fetches_head_and_adds_dedicated_worktree_branch
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      pr = { "number" => 42, "headRefName" => "feature" }
      calls = []
      status = Hive::Gh::CommandStatus.new(exitstatus: 0)

      with_replaced_singleton_method(Open3, :capture3, lambda { |*cmd|
        calls << cmd
        [ "", "", status ]
      }) do
        result = Hive::Babysitter::Worktree.materialize(project, pr)
        assert_equal File.join(project.fetch("hive_state_path"), "babysitter", "worktrees", "42"), result.path
        assert_equal "hive-babysitter/pr-42", result.branch
      end

      assert calls.any? { |cmd| cmd.include?("fetch") && cmd.include?("+pull/42/head:refs/hive-babysitter/pr-42") },
             "expected force-updating `git fetch origin +pull/42/head:...` so rebased PR heads do not wedge babysitter"
      assert calls.any? { |cmd| cmd.include?("worktree") && cmd.include?("-B") && cmd.include?("hive-babysitter/pr-42") }
    end
  end

  def test_path_resolves_relative_state_path_from_project_root
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => "state" }
      pr = { "number" => 42 }

      assert_equal File.join(dir, "state", "babysitter", "worktrees", "42"),
                   Hive::Babysitter::Worktree.new(project, pr).path
    end
  end

  def test_materialize_quarantines_residue_that_cannot_be_deleted
    with_tmp_dir do |dir|
      state_path = File.join(dir, ".hive-state")
      project = { "name" => "demo", "path" => dir, "hive_state_path" => state_path }
      pr = { "number" => 42, "headRefName" => "feature" }
      worktree = Hive::Babysitter::Worktree.new(project, pr)
      residue = File.join(worktree.path, "tmp", "container-cache")
      FileUtils.mkdir_p(File.dirname(residue))
      File.write(residue, "root-owned in production")

      success = Hive::Gh::CommandStatus.new(exitstatus: 0)
      failure = Hive::Gh::CommandStatus.new(exitstatus: 1)
      original_rm_rf = FileUtils.method(:rm_rf)
      commands = []

      capture = lambda do |*cmd|
        commands << cmd
        status = cmd.include?("remove") ? failure : success
        [ cmd.include?("rev-parse") ? "abc123\n" : "", "permission denied", status ]
      end
      refuse_residue_cleanup = lambda do |target, *args|
        next if File.expand_path(target) == worktree.path

        original_rm_rf.call(target, *args)
      end

      _stdout, stderr = capture_io do
        with_replaced_singleton_method(Open3, :capture3, capture) do
          with_replaced_singleton_method(FileUtils, :rm_rf, refuse_residue_cleanup) do
            Hive::Babysitter::Worktree.materialize(project, pr)
          end
        end
      end

      refute File.exist?(worktree.path), "the canonical path must be clear before worktree add"
      quarantined = Dir.glob(
        File.join(state_path, "babysitter", "quarantine", "worktrees", "pr-42-*")
      )
      assert_equal 1, quarantined.length
      assert_equal "root-owned in production",
                   File.read(File.join(quarantined.fetch(0), "tmp", "container-cache"))
      assert_includes stderr, "preserved cleanup residue"
      assert commands.any? { |cmd| cmd.include?("prune") && cmd.include?("--expire") && cmd.include?("now") }
    end
  end

  def test_materialize_fails_when_stale_worktree_metadata_cannot_be_pruned
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      pr = { "number" => 42, "headRefName" => "feature" }
      success = Hive::Gh::CommandStatus.new(exitstatus: 0)
      failure = Hive::Gh::CommandStatus.new(exitstatus: 1)

      capture = lambda do |*cmd|
        if cmd.include?("prune")
          [ "", "administrative metadata is locked", failure ]
        else
          [ cmd.include?("rev-parse") ? "abc123\n" : "", "", success ]
        end
      end

      error = with_replaced_singleton_method(Open3, :capture3, capture) do
        assert_raises(Hive::WorktreeError) do
          Hive::Babysitter::Worktree.materialize(project, pr)
        end
      end

      assert_includes error.message, "git worktree prune failed"
      assert_includes error.message, "administrative metadata is locked"
    end
  end

  def test_materialize_fails_when_cleanup_residue_cannot_be_quarantined
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      pr = { "number" => 42, "headRefName" => "feature" }
      worktree = Hive::Babysitter::Worktree.new(project, pr)
      FileUtils.mkdir_p(worktree.path)

      success = Hive::Gh::CommandStatus.new(exitstatus: 0)
      original_rm_rf = FileUtils.method(:rm_rf)
      refuse_residue_cleanup = lambda do |target, *args|
        next if File.expand_path(target) == worktree.path

        original_rm_rf.call(target, *args)
      end
      refuse_quarantine = lambda do |_source, _destination|
        raise Errno::EACCES, "simulated rename denial"
      end

      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*_cmd) { [ "", "", success ] }
      ) do
        with_replaced_singleton_method(FileUtils, :rm_rf, refuse_residue_cleanup) do
          with_replaced_singleton_method(File, :rename, refuse_quarantine) do
            assert_raises(Hive::WorktreeError) do
              Hive::Babysitter::Worktree.materialize(project, pr)
            end
          end
        end
      end

      assert_includes error.message, "cleanup residue could not be quarantined"
      assert_includes error.message, "simulated rename denial"
    end
  end
end
