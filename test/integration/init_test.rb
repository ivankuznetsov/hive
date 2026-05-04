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

  # --- ADR-023 / U4: rendered template carries the new stage-agent blocks
  # and the bumped-generous limits, with execute_review dropped. -----------

  def test_init_renders_stage_agent_blocks
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = Hive::Config.load(dir)

        assert_equal "claude", cfg.dig("brainstorm", "agent"),
                     "brainstorm.agent must default to claude"
        assert_equal "claude", cfg.dig("plan", "agent"),
                     "plan.agent must default to claude"
        assert_equal "codex",  cfg.dig("execute", "agent"),
                     "execute.agent must be the recommended-default codex in fresh templates"
      end
    end
  end

  def test_init_renders_bumped_generous_limit_defaults
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = Hive::Config.load(dir)

        assert_equal 50,    cfg.dig("budget_usd", "brainstorm")
        assert_equal 100,   cfg.dig("budget_usd", "plan")
        assert_equal 500,   cfg.dig("budget_usd", "execute_implementation")
        assert_equal 14400, cfg.dig("timeout_sec", "execute_implementation")
      end
    end
  end

  def test_init_drops_deprecated_execute_review_key_from_template
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        # Parse the YAML and check structurally — comments mentioning
        # execute_review are fine; the rendered key/value is not.
        parsed = YAML.safe_load(File.read(cfg_path))
        refute parsed["budget_usd"].key?("execute_review"),
               "rendered budget_usd must not include the deprecated execute_review key"
        refute parsed["timeout_sec"].key?("execute_review"),
               "rendered timeout_sec must not include the deprecated execute_review key"
      end
    end
  end

  # All three default reviewers must land when the multiselect was not
  # tightened (non-TTY init = recommended defaults = all enabled).
  def test_init_renders_all_three_default_reviewers_under_non_tty
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = Hive::Config.load(dir)
        names = cfg.dig("review", "reviewers").map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review codex-ce-code-review pr-review-toolkit], names
      end
    end
  end

  # --- U5: piped interactive flow ----------------------------------------

  # Build a Prompts instance backed by a tty-flagged StringIO so we can
  # exercise the interactive code path inside Init#call without touching
  # the real $stdin. Mirrors the test helper in
  # test/unit/commands/init/prompts_test.rb but inlined here so init_test
  # stays self-contained.
  def make_tty_prompts(input_text)
    require "stringio"
    input = StringIO.new(input_text)
    input.define_singleton_method(:tty?) { true }
    Hive::Commands::Init::Prompts.new(input: input, output: StringIO.new)
  end

  def test_init_with_piped_user_choices_writes_matching_config
    # Order matches Prompts#collect: planning, development, reviewers,
    # 8 limit prompts, confirm. Choose codex for both, only first +
    # third reviewer, override `plan` budget/timeout, accept the rest.
    inputs = "codex\n2\n1,3\n\n30,900\n\n\n\n\n\n\n\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        assert_equal "codex", cfg.dig("brainstorm", "agent")
        assert_equal "codex", cfg.dig("plan", "agent")
        assert_equal "codex", cfg.dig("execute", "agent")
        assert_equal 30,  cfg.dig("budget_usd", "plan")
        assert_equal 900, cfg.dig("timeout_sec", "plan")

        names = cfg.dig("review", "reviewers").map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review pr-review-toolkit], names,
                     "only the two selected reviewers should be rendered"
      end
    end
  end

  def test_init_aborts_with_zero_disk_state_when_user_says_n
    # Blank for everything until confirmation; answer `n` at the end.
    inputs = ([ "" ] * 11).join("\n") + "\nn\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        _, err, status = with_captured_exit do
          Hive::Commands::Init.new(dir, prompts: prompts).call
        end
        assert_equal 1, status, "abort must exit 1"
        assert_includes err, "aborted"

        # Critical: nothing on disk. No orphan branch, no worktree, no
        # master .gitignore commit, no global registry entry.
        refute File.directory?(File.join(dir, ".hive-state")),
               ".hive-state must not exist after abort"
        log = `git -C #{dir} log --format=%s 2>&1`.strip
        refute_includes log, "chore: ignore .hive-state worktree",
                        "master must not have the gitignore commit"
        branches = `git -C #{dir} branch --list`
        refute_includes branches, "hive/state",
                        "orphan hive/state branch must not exist after abort"
        refute Hive::Config.find_project(File.basename(dir)),
               "global registry must not list the aborted project"
      end
    end
  end

  def test_init_already_initialized_short_circuits_before_any_prompt
    # On a re-run of `hive init` the AlreadyInitialized guard must fire
    # BEFORE the prompt module reads anything from stdin. We feed an
    # input stream that would crash the prompt validator if consumed
    # ('crash'), then assert it's still pristine after the second init.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        require "stringio"
        input = StringIO.new("crash-on-this-input\n")
        input.define_singleton_method(:tty?) { true }
        prompts = Hive::Commands::Init::Prompts.new(input: input, output: StringIO.new)

        _, err, status = with_captured_exit do
          Hive::Commands::Init.new(dir, prompts: prompts).call
        end
        assert_equal Hive::ExitCodes::ALREADY_INITIALIZED, status
        assert_includes err, "already initialized"
        assert_equal "crash-on-this-input", input.gets&.chomp,
                     "no input should have been consumed by the second init"
      end
    end
  end
end
