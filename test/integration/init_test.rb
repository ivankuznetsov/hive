require "test_helper"
require "hive/commands/init"

class InitTest < Minitest::Test
  include HiveTestHelper

  def test_initializes_project_with_orphan_branch_and_global_registration
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox"))
        assert File.exist?(File.join(dir, ".hive-state", "config.yml"))

        log = `git -C #{dir} log --format=%s hive/state`.strip
        assert_includes log, "hive: bootstrap"

        master_log = `git -C #{dir} log --format=%s master`.strip
        assert_includes master_log, "chore: ignore .hive-state worktree"

        gitignore = File.read(File.join(dir, ".gitignore"))
        assert_includes gitignore, "/.hive-state/"

        projects = Hive::Config.registered_projects
        assert(projects.any? { |p| p["path"] == File.expand_path(dir) })
      end
    end
  end

  def test_initializes_project_with_populated_review_reviewers
    # U2 closes doc-review C-3: hive init scaffolds a live review.reviewers
    # block (not commented). Verifies the YAML is parseable and lands the
    # 3-entry recommended set (claude-ce-code-review, codex-ce-code-review,
    # pr-review-toolkit) so a fresh project can run 5-review without
    # additional hand-edit.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = Hive::Config.load(dir)

        reviewers = cfg.dig("review", "reviewers")
        assert_kind_of Array, reviewers
        names = reviewers.map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review codex-ce-code-review pr-review-toolkit], names

        # Each entry references a registered AgentProfile.
        reviewers.each do |entry|
          assert Hive::AgentProfiles.registered?(entry["agent"]),
                 "reviewer #{entry['name'].inspect} agent #{entry['agent'].inspect} must be a registered profile"
        end

        # Other defaults present.
        assert_equal "courageous", cfg.dig("review", "triage", "bias")
        assert_equal 4,            cfg.dig("review", "max_passes")
      end
    end
  end

  def test_rejects_non_git_repo
    with_tmp_global_config do
      with_tmp_dir do |dir|
        _, err, status = with_captured_exit { Hive::Commands::Init.new(dir).call }
        assert_equal 1, status
        assert_includes err, "not a git repository"
      end
    end
  end

  def test_rejects_dirty_tree_without_force
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        # Modify a tracked file to make the tree dirty (untracked files alone don't fail).
        File.write(File.join(dir, "README.md"), "modified\n")
        _, err, status = with_captured_exit { Hive::Commands::Init.new(dir).call }
        assert_equal 1, status
        assert_includes err, "uncommitted modifications"
      end
    end
  end

  def test_untracked_files_do_not_block_init
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        File.write(File.join(dir, "untracked.txt"), "x")
        capture_io { Hive::Commands::Init.new(dir).call }
        assert File.directory?(File.join(dir, ".hive-state"))
      end
    end
  end

  def test_force_skips_clean_check
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        File.write(File.join(dir, "untracked.txt"), "x")
        run!("git", "-C", dir, "add", ".")
        run!("git", "-C", dir, "commit", "-m", "untracked")
        capture_io { Hive::Commands::Init.new(dir, force: true).call }
        assert File.directory?(File.join(dir, ".hive-state"))
      end
    end
  end

  def test_double_init_raises_already_initialized_with_exit_2
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        _, err, status = with_captured_exit { Hive::Commands::Init.new(dir).call }
        assert_equal Hive::ExitCodes::ALREADY_INITIALIZED, status,
                     "second init must raise Hive::AlreadyInitialized (exit 2), not bare exit"
        assert_includes err, "already initialized"
      end
    end
  end
end
