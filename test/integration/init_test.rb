require "test_helper"
require "json"
require "hive/commands/init"
require "hive/llm_wiki_bootstrap"

class InitTest < Minitest::Test
  include HiveTestHelper

  def with_tmp_home
    Dir.mktmpdir("hive-home") do |dir|
      old = ENV["HOME"]
      ENV["HOME"] = dir
      begin
        yield(dir)
      ensure
        old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
      end
    end
  end

  def test_initializes_project_with_orphan_branch_and_global_registration
    # `with_tmp_global_config` overrides HOME alongside HIVE_HOME so
    # ServiceInstaller (which writes launchd/systemd units under the
    # real user home, not HIVE_HOME) lands the unit inside the sandbox.
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        out, _err = capture_io { Hive::Commands::Init.new(dir).call }

        # Summary content contract — agents and humans both rely on these tokens
        # surviving future refactors of print_summary's layout.
        name = File.basename(dir)
        assert_includes out, "hive: initialized"
        assert_includes out, name
        assert_includes out, dir
        assert_includes out, "next: hive new #{name}"

        # capture_io yields a non-tty StringIO; ANSI must be suppressed there
        # so piped/CI output stays clean. Load-bearing safety property of the
        # styled summary.
        refute_match(/\e\[/, out, "ANSI escapes must not appear in non-tty output")

        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox"))
        assert File.exist?(File.join(dir, ".hive-state", "config.yml"))

        log = `git -C #{dir} log --format=%s hive/state`.strip
        assert_includes log, "hive: bootstrap"

        master_log = `git -C #{dir} log --format=%s master`.strip
        assert_includes master_log, "chore: ignore .hive-state worktree"
        assert_includes master_log, "chore: initialize llm-wiki"

        gitignore = File.read(File.join(dir, ".gitignore"))
        assert_includes gitignore, "/.hive-state/"

        projects = Hive::Config.registered_projects
        assert(projects.any? { |p| p["path"] == File.expand_path(dir) })

        assert File.exist?(File.join(home, ".config/systemd/user/hive-daemon.service")),
               "init should register the per-user daemon service unit"
        global = YAML.safe_load(File.read(File.join(home, "config.yml")))
        assert_equal false, global.dig("daemon", "autostart"),
                     "non-TTY init writes the service unit but does not start it by default"
      end
    end
  end

  def test_initializes_managed_llm_wiki_with_codex_headless_agent_and_scheduler
    with_tmp_home do |home|
      ENV.delete("HIVE_SKIP_LLM_WIKI_SCHEDULER")
      with_tmp_global_config do |global_home|
        FileUtils.mkdir_p(File.join(global_home, "wikis", "master", "wiki"))
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }

          llm_wiki_config = JSON.parse(File.read(File.join(dir, ".llm-wiki", "config.json")))
          assert_equal "codex", llm_wiki_config.fetch("headless_agent")
          assert_equal %w[claude codex pi], llm_wiki_config.fetch("context_agents")
          assert_equal "hive", llm_wiki_config.fetch("created_by")
          assert_equal File.join(global_home, "wikis", "master", "wiki"), llm_wiki_config.fetch("main_wiki_path")

          assert File.exist?(File.join(dir, "wiki", "index.md"))
          assert File.exist?(File.join(dir, "wiki", "log.md"))
          assert File.exist?(File.join(dir, "wiki", "gaps.md"))
          assert File.exist?(File.join(dir, "raw", "notes", ".gitkeep"))
          tracked = `git -C #{dir} ls-files .llm-wiki/config.json .llm-wiki/refresh-wiki.sh AGENTS.md CLAUDE.md wiki/index.md`
          assert_includes tracked, ".llm-wiki/config.json"
          assert_includes tracked, ".llm-wiki/refresh-wiki.sh"
          assert_includes tracked, "AGENTS.md"
          assert_includes tracked, "CLAUDE.md"
          assert_includes tracked, "wiki/index.md"

          agents = File.read(File.join(dir, "AGENTS.md"))
          claude = File.read(File.join(dir, "CLAUDE.md"))
          assert_includes agents, "<!-- BEGIN LLM WIKI -->"
          assert_includes agents, "/llm-wiki:wiki-plan"
          assert_includes claude, "<!-- BEGIN LLM WIKI -->"

          settings = JSON.parse(File.read(File.join(dir, ".claude", "settings.json")))
          hook_commands = settings.dig("hooks", "SessionStart").flat_map { |entry| entry.fetch("hooks") }
                                  .map { |hook| hook.fetch("command") }
          assert hook_commands.any? { |command| command.include?("wiki/index.md") }
          assert hook_commands.any? { |command| command.include?("LLM WIKI SESSION START") }

          refresh_script = File.join(dir, ".llm-wiki", "refresh-wiki.sh")
          post_commit_script = File.join(dir, ".llm-wiki", "post-commit-refresh.sh")
          assert File.executable?(refresh_script)
          assert File.executable?(post_commit_script)
          assert_includes File.read(refresh_script), 'codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root"'
          assert_includes File.read(post_commit_script), 'codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root"'
          assert_includes File.read(refresh_script), "LLM_WIKI_QMD_CACHE_DIR"
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_CACHE_DIR"
          assert_includes File.read(refresh_script), ".llm-wiki/qmd-cache"
          assert_includes File.read(post_commit_script), ".llm-wiki/qmd-cache"
          assert_includes File.read(refresh_script), "LLM_WIKI_CODEX_TIMEOUT"
          assert_includes File.read(refresh_script), "LLM_WIKI_QMD_TIMEOUT"
          assert_includes File.read(refresh_script), "qmd embed --max-docs-per-batch 64 --max-batch-mb 64"
          assert_includes File.read(refresh_script), "Do not run qmd update or qmd embed yourself"
          assert_includes File.read(post_commit_script), "LLM_WIKI_CODEX_TIMEOUT"
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_TIMEOUT"
          assert_includes File.read(post_commit_script), "qmd embed --max-docs-per-batch 64 --max-batch-mb 64"
          assert_includes File.read(post_commit_script), "Do not run qmd update or qmd embed yourself"
          refute_includes File.read(refresh_script), "QMD_LLAMA_GPU"
          refute_includes File.read(post_commit_script), "QMD_LLAMA_GPU"
          refute_includes File.read(refresh_script), "claude -p"
          refute_includes File.read(post_commit_script), "claude -p"

          hook = File.read(File.join(dir, ".git", "hooks", "post-commit"))
          assert_includes hook, "# BEGIN LLM WIKI POST-COMMIT"
          assert_includes hook, ".llm-wiki/post-commit-refresh.sh"

          assert_llm_wiki_scheduler_files(global_home, dir)
        end
      end
    ensure
      ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
    end
  end

  def test_llm_wiki_bootstrap_recovers_from_invalid_existing_config_json
    with_tmp_git_repo do |dir|
      FileUtils.mkdir_p(File.join(dir, ".llm-wiki"))
      File.write(File.join(dir, ".llm-wiki", "config.json"), "not-json")

      Hive::LlmWikiBootstrap.install!(dir, post_commit_hook: false, scheduler: false)

      cfg = JSON.parse(File.read(File.join(dir, ".llm-wiki", "config.json")))
      assert_equal "codex", cfg.fetch("headless_agent")
      assert_equal %w[claude codex pi], cfg.fetch("context_agents")
      assert_equal "hive", cfg.fetch("created_by")
    end
  end

  def assert_llm_wiki_scheduler_files(home, project_dir)
    skip "systemd user timers are Linux-only" unless RbConfig::CONFIG["host_os"].include?("linux")

    slug = Hive::LlmWikiBootstrap.project_slug(project_dir)
    user_dir = File.join(home, ".config", "systemd", "user")
    service = File.join(user_dir, "llm-wiki-#{slug}.service")
    timer = File.join(user_dir, "llm-wiki-#{slug}.timer")
    wants = File.join(user_dir, "timers.target.wants", "llm-wiki-#{slug}.timer")

    assert File.exist?(service)
    assert File.exist?(timer)
    assert File.symlink?(wants)
    service_contents = File.read(service)
    assert_includes service_contents, "WorkingDirectory=#{project_dir}"
    assert_includes service_contents, "ExecStart=#{File.join(project_dir, ".llm-wiki", "refresh-wiki.sh")}"
    assert_includes service_contents, "TimeoutStartSec=45min"
    refute_includes service_contents, 'WorkingDirectory="'
    assert_includes File.read(timer), "OnUnitActiveSec=1d"
  end

  def test_init_preserves_existing_post_commit_hook_when_adding_managed_wiki_block
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        hook_path = File.join(dir, ".git", "hooks", "post-commit")
        File.write(hook_path, "#!/usr/bin/env bash\nprintf 'existing hook\\n'\n")
        File.chmod(0o755, hook_path)

        capture_io { Hive::Commands::Init.new(dir).call }
        Hive::LlmWikiBootstrap.install!(dir)

        hook = File.read(hook_path)
        assert_includes hook, "printf 'existing hook\\n'"
        assert_equal 1, hook.scan("# BEGIN LLM WIKI POST-COMMIT").length
        assert_equal 1, hook.scan("# END LLM WIKI POST-COMMIT").length
      end
    end
  end

  def test_initializes_project_with_populated_review_reviewers
    # U2 closes doc-review C-3: hive init scaffolds a live review.reviewers
    # block (not commented). Verifies the YAML is parseable and lands the
    # 3-entry recommended set (claude-ce-code-review, codex-ce-code-review,
    # pr-review-toolkit) so a fresh project can run 6-review without
    # additional hand-edit.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = Hive::Config.load(dir)

        reviewers = cfg.dig("review", "reviewers")
        assert_kind_of Array, reviewers
        names = reviewers.map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review codex-ce-code-review pr-review-toolkit], names
        assert_equal [ 3600 ], reviewers.map { |r| r["timeout_sec"] }.uniq

        # Each entry references a registered AgentProfile.
        reviewers.each do |entry|
          assert Hive::AgentProfiles.registered?(entry["agent"]),
                 "reviewer #{entry['name'].inspect} agent #{entry['agent'].inspect} must be a registered profile"
        end

        # Other defaults present.
        assert_equal "courageous", cfg.dig("review", "triage", "bias")
        assert_equal 2,            cfg.dig("review", "max_passes")
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
        raw_cfg = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))

        assert_equal "claude", cfg.dig("brainstorm", "agent"),
                     "brainstorm.agent must default to claude"
        assert_equal "tmux", cfg.dig("claude", "mode"),
                     "claude.mode must default to tmux in fresh templates"
        refute raw_cfg.fetch("brainstorm").key?("runtime"),
               "fresh templates must not render legacy brainstorm.runtime"
        assert_equal "claude", cfg.dig("plan", "agent"),
                     "plan.agent must default to claude"
        assert_equal "codex",  cfg.dig("execute", "agent"),
                     "execute.agent must be the recommended-default codex in fresh templates"
        assert_equal "claude", cfg.dig("artifacts", "agent"),
                     "artifacts.agent must default to claude in fresh templates"
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
        assert_equal 100,   cfg.dig("budget_usd", "artifacts")
        assert_equal 14400, cfg.dig("timeout_sec", "execute_implementation")
        assert_equal 3600,  cfg.dig("timeout_sec", "artifacts")
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
    Hive::Commands::Init::Prompts.new(
      input: input,
      output: StringIO.new,
      summary_io: StringIO.new
    )
  end

  def test_init_with_piped_user_choices_writes_matching_config
    # Order matches Prompts#collect. Choose codex for planning, default
    # claude_mode, codex for development, safetyist triage, only first +
    # third reviewer, override `plan` budget/timeout, accept the rest.
    inputs = [
      "codex", "", "2", "1,3", "safetyist",
      "", "30,900", "", "", "", "", "", "", "", "",
      "", "", ""
    ].join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        assert_equal "codex", cfg.dig("brainstorm", "agent")
        assert_equal "headless", cfg.dig("brainstorm", "runtime")
        assert_equal "codex", cfg.dig("plan", "agent")
        assert_equal "codex", cfg.dig("execute", "agent")
        assert_equal "safetyist", cfg.dig("review", "triage", "bias")
        assert_equal 30,  cfg.dig("budget_usd", "plan")
        assert_equal 900, cfg.dig("timeout_sec", "plan")

        names = cfg.dig("review", "reviewers").map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review pr-review-toolkit], names,
                     "only the two selected reviewers should be rendered"

        # ADR-024: daemon prompt defaults to Y at the prompt; rendered
        # template must carry `daemon: { enabled: true }` so the daemon
        # picks up new projects out of the box.
        assert_equal true, cfg.dig("daemon", "enabled"),
                     "blank daemon prompt → enabled true rendered into config"
      end
    end
  end

  def test_init_with_headless_claude_mode_writes_matching_config
    # planning=blank(claude), claude_mode="2"(headless), dev=blank,
    # reviewers=blank, triage=blank, limit blanks, daemon-enable=blank,
    # daemon-autostart=blank, confirm=blank.
    inputs = ([ "", "2", "", "", "" ] +
              ([ "" ] * Hive::Commands::Init::Prompts::LIMIT_KEYS.size) +
              [ "", "", "" ]).join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        config_path = File.join(dir, ".hive-state", "config.yml")
        raw_cfg = YAML.safe_load(File.read(config_path))
        assert_equal "claude", cfg.dig("brainstorm", "agent")
        assert_equal "headless", cfg.dig("claude", "mode")
        refute raw_cfg.fetch("brainstorm").key?("runtime"),
               "fresh init config must not render legacy brainstorm.runtime"
      end
    end
  end

  def test_init_with_daemon_disabled_writes_disabled_config
    # Same shape as above but explicitly answer `n` to the daemon prompt.
    # Blanks: planning (claude), claude mode, dev, reviewers,
    # triage bias, limits. Then "n" for daemon-enable, blank for
    # daemon-autostart, blank for confirm.
    inputs = (([ "" ] * (5 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
              [ "n", "", "" ]).join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        assert_equal false, cfg.dig("daemon", "enabled"),
                     "explicit n at daemon prompt → enabled false rendered"
      end
    end
  end

  def test_init_aborts_with_zero_disk_state_when_user_says_n
    # Blank for everything until confirmation; answer `n` at the end.
    # Blanks: planning (claude), claude mode, dev, reviewers,
    # triage bias, limits, daemon-enable, daemon-autostart.
    inputs = (([ "" ] * (7 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
              [ "n" ]).join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        _, err, status = with_captured_exit do
          Hive::Commands::Init.new(dir, prompts: prompts).call
        end
        assert_equal Hive::ExitCodes::USAGE, status,
                     "abort must exit USAGE (64), distinct from generic crashes (1)"
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

  def test_current_binary_path_uses_invoked_hive_binary
    with_tmp_dir do |dir|
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, hive)
      old_program_name = $PROGRAM_NAME
      begin
        $PROGRAM_NAME = hive
        assert_equal hive, Hive::Commands::Init.new(dir).send(:current_binary_path)
      ensure
        $PROGRAM_NAME = old_program_name
      end
    end
  end
end
