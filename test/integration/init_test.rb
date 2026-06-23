require "test_helper"
require "json"
require "stringio"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
require "hive/llm_wiki_bootstrap"
require "hive/reviewers/agent"
require "hive/task"
require "hive/task_meta"
require "hive/workflows/descriptor_parser"

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
        refute_includes File.read(File.join(dir, ".hive-state", "config.yml")), "default_workflow:"

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
                     "init registers the daemon service unit but leaves autostart off unless requested"
      end
    end
  end

  def test_init_workflow_flag_writes_non_coding_project_default
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_init_workflow_prompt_persists_selected_default
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("3\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new
          prompts = Hive::Commands::Init::Prompts.new(
            input: StringIO.new,
            output: StringIO.new,
            summary_io: StringIO.new
          )

          capture_io do
            Hive::Commands::Init.new(
              dir,
              prompts: prompts,
              workflow_input: workflow_input,
              workflow_output: workflow_output
            ).call
          end

          assert_includes workflow_output.string, "1) coding"
          assert_includes workflow_output.string, "2) content"
          assert_includes workflow_output.string, "3) content_fixture"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_init_workflow_prompt_default_keeps_coding_config_fieldless
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("\n")
          workflow_input.define_singleton_method(:tty?) { true }
          prompts = Hive::Commands::Init::Prompts.new(
            input: StringIO.new,
            output: StringIO.new,
            summary_io: StringIO.new
          )

          capture_io do
            Hive::Commands::Init.new(dir, prompts: prompts, workflow_input: workflow_input).call
          end

          refute_includes File.read(File.join(dir, ".hive-state", "config.yml")), "default_workflow:"
        end
      end
    end
  end

  def test_init_unknown_workflow_fails_before_writing_state
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          _out, err, status = with_captured_exit do
            Hive::Commands::Init.new(dir, workflow: "bogus").call
          end

          # USAGE (64), not GENERIC (1): a bad --workflow is a do-not-retry
          # usage error, so UnknownWorkflow overrides exit_code like
          # InvalidTaskPath/WrongStage/AlreadyInitialized.
          assert_equal Hive::ExitCodes::USAGE, status
          assert_includes err, "unknown workflow \"bogus\""
          assert_includes err, "coding"
          assert_includes err, "content_fixture"
          refute File.exist?(File.join(dir, ".hive-state"))
        end
      end
    end
  end

  def test_init_new_workflow_fresh_scaffolds_and_binds_default
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        out, _err = capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }

        descriptor_path = File.join(dir, ".hive-state", "workflows", "writing.yml")
        instruction_path = File.join(dir, ".hive-state", "workflows", "writing", "work.md")
        config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
        assert_equal "writing", config.fetch("default_workflow")
        assert File.file?(descriptor_path)
        assert File.file?(instruction_path)
        assert_equal "Edit this file to define what the `work` stage should do.\n", File.read(instruction_path)

        workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
        assert_equal :writing, workflow.id
        assert_equal %w[inbox work done], workflow.stage_names
        assert_equal :inert, workflow.stages.first.kind

        assert_includes out, "workflow"
        assert_includes out, "writing"
        assert_includes out, descriptor_path
        assert_includes out, instruction_path
        assert_includes out, "edit the descriptor above, then hive new #{File.basename(dir)} '<idea>'"

        log = run!("git", "-C", File.join(dir, ".hive-state"), "log", "--format=%s").lines.map(&:chomp)
        assert_includes log, "hive: workflows/writing created"
        assert Hive::Config.registered_projects.any? { |project| project["path"] == File.expand_path(dir) }
      end
    end
  end

  def test_init_new_workflow_existing_scaffolds_and_rebinds_in_one_commit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        before_count = run!("git", "-C", hive_state, "rev-list", "--count", "HEAD").to_i

        out, _err = capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }

        descriptor_path = File.join(hive_state, "workflows", "writing.yml")
        instruction_path = File.join(hive_state, "workflows", "writing", "work.md")
        config = YAML.safe_load(File.read(File.join(hive_state, "config.yml")))
        assert_equal "writing", config.fetch("default_workflow")
        assert File.file?(descriptor_path)
        assert File.file?(instruction_path)
        assert_includes out, "hive: already initialized"
        assert_includes out, "workflow: writing"
        assert_includes out, descriptor_path
        assert_includes out, instruction_path

        assert_equal before_count + 1, run!("git", "-C", hive_state, "rev-list", "--count", "HEAD").to_i
        assert_equal "hive: workflows/writing created",
                     run!("git", "-C", hive_state, "log", "--format=%s", "-1").strip
        changed = run!("git", "-C", hive_state, "show", "--name-only", "--format=", "HEAD")
        assert_includes changed, "config.yml"
        assert_includes changed, "workflows/writing.yml"
        assert_includes changed, "workflows/writing/work.md"
      end
    end
  end

  def test_init_new_workflow_default_routes_flagless_new_through_scaffolded_workflow
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }
        Hive::Workflows::Project.reset!

        capture_io { Hive::Commands::New.new(project, "custom default task").call }

        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "custom-default-task-*")].first
        assert inbox, "flag-less hive new should create a task in the custom workflow entry stage"
        assert_equal "writing", Hive::TaskMeta.read(inbox)[:workflow]
        assert_equal :writing, Hive::Task.new(inbox).workflow.id
        assert_includes File.read(File.join(inbox, "idea.md")), "<!-- COMPLETE -->"

        Hive::Workflows::Project.reset!
        capture_io { Hive::Commands::Approve.new(File.basename(inbox), project: project, from: "1-inbox").call }
        work = Dir[File.join(dir, ".hive-state", "stages", "2-work", "custom-default-task-*")].first
        assert work, "approving the custom workflow entry stage should advance to 2-work"
        assert_equal "writing", Hive::TaskMeta.read(work)[:workflow]
      end
    end
  end

  def test_init_new_workflow_rejects_reserved_id_before_writing_state
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _out, err, status = with_captured_exit do
          Hive::Commands::Init.new(dir, new_workflow: "coding").call
        end

        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "workflow id \"coding\" is reserved by a built-in workflow"
        refute File.exist?(File.join(dir, ".hive-state"))
        assert_empty run!("git", "-C", dir, "branch", "--list", "hive/state").strip
        refute Hive::Config.find_project(File.basename(dir))
      end
    end
  end

  def test_init_new_workflow_rejects_workflow_flag_mutual_exclusivity_before_writing_state
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _out, err, status = with_captured_exit do
          Hive::Commands::Init.new(dir, workflow: "content", new_workflow: "writing").call
        end

        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "--workflow and --new-workflow are mutually exclusive"
        refute File.exist?(File.join(dir, ".hive-state"))
        assert_empty run!("git", "-C", dir, "branch", "--list", "hive/state").strip
        refute Hive::Config.find_project(File.basename(dir))
      end
    end
  end

  def test_init_new_workflow_fresh_rolls_back_when_scaffold_commit_fails
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        with_replaced_singleton_method(Hive::Commands::Workflow, :scaffold_files!, lambda { |_id, project_root:|
          paths = {
            descriptor: File.join(project_root, ".hive-state", "workflows", "writing.yml"),
            instruction_dir: File.join(project_root, ".hive-state", "workflows", "writing"),
            instruction: File.join(project_root, ".hive-state", "workflows", "writing", "work.md")
          }
          FileUtils.mkdir_p(paths.fetch(:instruction_dir))
          File.write(paths.fetch(:descriptor), "id: writing\n")
          File.write(paths.fetch(:instruction), "work\n")
          raise Hive::GitError, "scaffold boom"
        }) do
          _out, err = capture_io do
            error = assert_raises(Hive::GitError) do
              Hive::Commands::Init.new(dir, new_workflow: "writing").call
            end
            assert_includes error.message, "scaffold boom"
          end
          assert_includes err, "partial init failed; rolled back"
        end

        assert_clean_failed_init(dir)
        refute File.exist?(File.join(dir, ".hive-state", "workflows", "writing.yml"))
      end
    end
  end

  def test_init_new_workflow_existing_restores_config_and_scaffold_on_commit_failure
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")
        before_config = File.binread(cfg_path)
        original_new = Hive::GitOps.method(:new)

        with_replaced_singleton_method(Hive::GitOps, :new, lambda { |path|
          ops = original_new.call(path)
          original_commit = ops.method(:hive_commit)
          ops.define_singleton_method(:hive_commit) do |**kwargs|
            if kwargs[:stage_name] == "workflows" && kwargs[:slug] == "writing"
              raise Hive::GitError, "commit boom"
            end
            original_commit.call(**kwargs)
          end
          ops
        }) do
          error = assert_raises(Hive::GitError) do
            capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }
          end
          assert_includes error.message, "commit boom"
        end

        assert_equal before_config, File.binread(cfg_path)
        refute File.exist?(File.join(hive_state, "workflows", "writing.yml"))
        refute File.exist?(File.join(hive_state, "workflows", "writing"))
        assert File.directory?(hive_state), "pre-existing hive state must remain attached"
        assert Hive::Config.find_project(File.basename(dir)), "existing project registration should remain intact"
      end
    end
  end

  def test_init_new_workflow_existing_collision_leaves_descriptor_and_config_unchanged
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")
        before_config = File.binread(cfg_path)
        descriptor_path = File.join(hive_state, "workflows", "writing.yml")
        instruction_dir = File.join(hive_state, "workflows", "writing")
        FileUtils.mkdir_p(instruction_dir)
        File.write(descriptor_path, "custom descriptor\n")
        File.write(File.join(instruction_dir, "work.md"), "custom work\n")

        error = assert_raises(Hive::Commands::Workflow::UsageError) do
          capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }
        end

        assert_equal Hive::ExitCodes::USAGE, error.exit_code
        assert_includes error.message, "workflow scaffold already exists"
        assert_equal before_config, File.binread(cfg_path)
        assert_equal "custom descriptor\n", File.read(descriptor_path)
        assert_equal "custom work\n", File.read(File.join(instruction_dir, "work.md"))
      end
    end
  end

  def test_rerun_init_with_workflow_warns_about_fieldless_in_flight_tasks
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "fieldless-task-260620-abcd")
          FileUtils.mkdir_p(task_dir)
          File.write(File.join(task_dir, "idea.md"), "fieldless\n")

          _out, err = capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          assert_includes err, "changing default_workflow from coding to content_fixture"
          assert_includes err, "1-inbox/fieldless-task-260620-abcd"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_rerun_init_with_workflow_skips_warning_when_tasks_are_pinned
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "pinned-task-260620-abcd")
          Hive::TaskMeta.write(task_dir, id: 1, slug: File.basename(task_dir), display_name: nil, workflow: "coding")
          File.write(File.join(task_dir, "idea.md"), "pinned\n")

          _out, err = capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          refute_includes err, "re-binds"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_rerun_init_warns_and_truncates_beyond_five_fieldless_tasks
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          slugs = (1..6).map { |n| "fieldless-#{n}-260620-aaaa" }
          slugs.each do |slug|
            task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", slug)
            FileUtils.mkdir_p(task_dir)
            File.write(File.join(task_dir, "idea.md"), "x\n")
          end

          _out, err = capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          assert_includes err, "... and 1 more"
          listed = slugs.count { |slug| err.include?(slug) }
          assert_equal 5, listed, "only the first 5 field-less tasks are listed; the rest collapse into '... and N more'"
        end
      end
    end
  end

  def test_rerun_init_same_workflow_is_a_silent_no_op
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }
          # A field-less task that WOULD warn on a real rebind — proves the
          # no-op skips the warning, not just that there were no tasks.
          task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "fieldless-task-260620-abcd")
          FileUtils.mkdir_p(task_dir)
          File.write(File.join(task_dir, "idea.md"), "x\n")

          _out, err = capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          refute_includes err, "re-binds"
          refute_includes err, "changing default_workflow"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_rerun_init_workflow_json_emits_already_initialized_payload
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }

          out, _err = capture_io do
            Hive::Commands::Init.new(dir, workflow: "content_fixture", json: true).call
          end
          payload = JSON.parse(out)

          assert_equal "hive-init", payload.fetch("schema")
          assert_equal true, payload.fetch("ok")
          assert_equal true, payload.fetch("already_initialized")
          assert_equal "content_fixture", payload.fetch("workflow")
          assert_equal File.basename(dir), payload.fetch("project")

          schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
          errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
          assert_empty errors, "already-initialized hive-init payload must validate: #{errors.inspect}"
        end
      end
    end
  end

  def test_rerun_init_prompt_empty_keeps_current_non_coding_default
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          workflow_input = StringIO.new("\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new

          out, _err = capture_io do
            Hive::Commands::Init.new(dir, workflow_input: workflow_input, workflow_output: workflow_output).call
          end

          assert_includes workflow_output.string, "Default workflow [content_fixture]:"
          assert_includes out, "workflow: content_fixture"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow"),
                       "a bare Enter at re-init must keep the current default, not reset it to coding"
        end
      end
    end
  end

  def test_init_workflow_prompt_aborts_on_closed_stdin_with_usage_and_zero_state
    # Two workflows registered so the prompt actually fires (a single registered
    # workflow now short-circuits to :implicit without prompting).
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("") # gets returns nil immediately (EOF)
          workflow_input.define_singleton_method(:tty?) { true }

          _out, err, status = with_captured_exit do
            Hive::Commands::Init.new(dir, workflow_input: workflow_input, workflow_output: StringIO.new).call
          end

          assert_equal Hive::ExitCodes::USAGE, status
          assert_includes err, "aborted"
          refute File.exist?(File.join(dir, ".hive-state")),
                 "an aborted workflow prompt must leave zero disk state (prompt runs before any writes)"
        end
      end
    end
  end

  def test_init_single_registered_workflow_skips_prompt_even_on_tty
    # With only one workflow registered, a tty-flagged stdin
    # must NOT block on the numbered prompt (it offers no real choice) — init
    # proceeds with the implicit coding default.
    with_replaced_singleton_method(Hive::Workflows::Registry, :ids, -> { [ :coding ] }) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("crash-if-read\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new

          capture_io do
            Hive::Commands::Init.new(dir, workflow_input: workflow_input, workflow_output: workflow_output).call
          end

          assert_empty workflow_output.string, "no workflow prompt should print when only one workflow is registered"
          assert_equal "crash-if-read", workflow_input.gets&.chomp, "stdin must not be consumed by a skipped prompt"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml"))) || {}
          assert_nil config["default_workflow"], "implicit coding default writes no default_workflow line"
        end
      end
    end
  end

  def test_rerun_init_coding_repairs_corrupt_config_despite_idempotency
    # A corrupt config masks as coding (Config.load Psych-rescue), so
    # `hive init --workflow coding` would hit the idempotency short-circuit
    # (coding == coding) and leave the unparseable file untouched. The
    # corrupt-flag override must force the repair rewrite anyway.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg, "default_workflow: [unclosed\nfoo: bar\n")

        _out, err = capture_io { Hive::Commands::Init.new(dir, workflow: "coding").call }

        assert_includes err, "could not read default_workflow"
        assert YAML.safe_load(File.read(cfg)).is_a?(Hash),
               "the corrupt-config repair gesture must rewrite the unparseable file even when coding == coding"
        refute_match(/\[unclosed/, File.read(cfg), "the corrupt default_workflow line must be gone after repair")
      end
    end
  end

  def test_current_default_workflow_flags_corrupt_config
    with_tmp_dir do |dir|
      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), "default_workflow: [unclosed\n")
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { state }
      init = Hive::Commands::Init.new(dir)

      value = corrupt = nil
      _out, err = capture_io { value, corrupt = init.send(:current_default_workflow_with_status, ops) }

      assert_equal "coding", value
      assert corrupt, "a corrupt config must be flagged so the caller forces a repair"
      assert_includes err, "could not read default_workflow"
    end
  end

  def test_update_default_workflow_restores_config_when_commit_fails
    with_tmp_dir do |dir|
      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      cfg = File.join(state, "config.yml")
      File.write(cfg, "---\nhive_state_path: #{state}\n")
      before = File.read(cfg)

      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { state }
      ops.define_singleton_method(:hive_commit) { |**| raise Hive::GitError, "commit boom" }

      init = Hive::Commands::Init.new(dir)
      capture_io do
        assert_raises(Hive::GitError) { init.send(:update_existing_default_workflow!, ops, :content_fixture) }
      end

      assert_equal before, File.read(cfg),
                   "a commit failure after atomic_write must restore the pre-write config.yml"
    end
  end

  def test_write_default_workflow_deletes_line_when_rebinding_to_coding
    with_tmp_dir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "---\nhive_state_path: /x\ndefault_workflow: content_fixture\n")
      Hive::Commands::Init.new(dir).send(:write_default_workflow!, cfg, "coding")
      result = File.read(cfg)

      refute_match(/default_workflow:/, result, "rebinding to coding must delete the default_workflow line")
      assert_match(%r{hive_state_path: /x}, result, "unrelated config lines must be preserved")
    end
  end

  def test_write_default_workflow_inserts_after_hive_state_path
    with_tmp_dir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "---\nhive_state_path: /x\nfoo: bar\n")
      Hive::Commands::Init.new(dir).send(:write_default_workflow!, cfg, "content_fixture")
      lines = File.read(cfg).lines

      assert_equal lines.index { |l| l.start_with?("hive_state_path:") } + 1,
                   lines.index { |l| l.start_with?("default_workflow:") },
                   "a new default_workflow line is inserted right after hive_state_path"
    end
  end

  def test_write_default_workflow_inserts_after_marker_when_no_state_path
    with_tmp_dir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "---\nfoo: bar\n")
      Hive::Commands::Init.new(dir).send(:write_default_workflow!, cfg, "content_fixture")

      assert_equal "default_workflow: content_fixture\n", File.read(cfg).lines[1],
                   "with no hive_state_path: line, the default_workflow line lands right after the --- marker"
    end
  end

  def test_write_default_workflow_handles_markerless_file
    with_tmp_dir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "foo: bar\n")
      Hive::Commands::Init.new(dir).send(:write_default_workflow!, cfg, "content_fixture")

      assert_equal "default_workflow: content_fixture\n", File.read(cfg).lines.first,
                   "a marker-less file gets the default_workflow line at the top"
    end
  end

  def test_init_json_emits_parseable_success_payload_without_prose
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        out, _err = capture_io { Hive::Commands::Init.new(dir, json: true).call }
        payload = JSON.parse(out)

        assert_equal 1, out.lines.size
        refute_includes out, "hive: using defaults"
        refute_includes out, "hive: initialized"
        assert_equal "hive-init", payload.fetch("schema")
        assert_equal 1, payload.fetch("schema_version")
        assert_equal true, payload.fetch("ok")
        assert_equal File.basename(dir), payload.fetch("project")
        assert_equal File.expand_path(dir), payload.fetch("path")
        assert_equal File.join(dir, ".hive-state"), payload.fetch("hive_state_path")
        assert_equal "coding", payload.fetch("workflow"),
                     "a fresh init must report the bound default workflow in JSON"
        assert_equal "claude", payload.fetch("answers").fetch("planning_agent")
        assert_equal "medium", payload.fetch("answers").fetch("patrol_mode")
        assert_equal "medium", payload.fetch("patrol_mode")
        assert_equal payload.fetch("answers").fetch("budgets"), payload.fetch("budgets")
        assert_equal false, payload.fetch("daemon_autostart_requested")

        schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
        errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
        assert_empty errors, "hive init --json payload must validate: #{errors.inspect}"
      end
    end
  end

  def test_init_json_mirrors_non_default_prompt_answers
    # Order: planning, claude_mode, claude_permission_mode, development,
    # reviewers, patrol_reviewers, patrol_mode, triage, then limits, daemon-enable, babysitter-enable,
    # daemon-autostart, confirm.
    # Two blank slots after claude_permission_mode accept the model/effort
    # defaults. patrol_reviewers index 3 = claude-ce-code-review
    # (1=codex-native-review, 2=codex-ce-code-review, 3=claude-ce-code-review).
    inputs = ([ "codex", "2", "", "", "", "pi", "2", "3", "high", "safetyist", "60,120" ] +
              ([ "" ] * (Hive::Commands::Init::Prompts::LIMIT_KEYS.size - 1)) +
              [ "n", "", "", "" ]).join("\n") + "\n"

    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        out, _err = capture_io { Hive::Commands::Init.new(dir, json: true, prompts: prompts).call }
        payload = JSON.parse(out)
        answers = payload.fetch("answers")

        assert_equal "codex", answers.fetch("planning_agent")
        assert_equal "headless", answers.fetch("claude_mode")
        assert_equal "pi", answers.fetch("development_agent")
        assert_equal [ "codex-ce-code-review" ], answers.fetch("enabled_reviewers")
        assert_equal [ "claude-ce-code-review" ], answers.fetch("patrol_reviewers")
        assert_equal "high", answers.fetch("patrol_mode")
        assert_equal "safetyist", answers.fetch("triage_bias")
        assert_equal 60, answers.fetch("budgets").fetch("brainstorm")
        assert_equal 120, answers.fetch("timeouts").fetch("brainstorm")
        assert_equal false, answers.fetch("daemon_enabled")
        assert_equal true, answers.fetch("babysitter_enabled")
        assert_equal false, answers.fetch("daemon_autostart")

        %w[
          planning_agent claude_mode development_agent enabled_reviewers patrol_reviewers
          patrol_mode triage_bias budgets timeouts daemon_enabled babysitter_enabled
        ].each do |key|
          assert_equal answers.fetch(key), payload.fetch(key), "top-level #{key} must mirror answers"
        end
        assert_equal false, payload.fetch("daemon_autostart_requested")
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
          assert File.exist?(File.join(dir, "wiki", "log.d", ".gitkeep"))
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
          # The worktree-safe post-commit script reads the just-committed code in
          # the committing tree (-C "$committing_tree") and assembles its --add-dir
          # list (qmd cache always, plus the main checkout when run from a linked
          # worktree) into an array rather than the static refresh-wiki.sh form.
          assert_includes File.read(post_commit_script), 'add_dir_args=( --add-dir "$LLM_WIKI_QMD_CACHE_DIR" )'
          assert_includes File.read(post_commit_script), 'codex exec "${add_dir_args[@]}" -C "$committing_tree"'
          assert_includes File.read(refresh_script), "LLM_WIKI_QMD_CACHE_DIR"
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_CACHE_DIR"
          assert_includes File.read(refresh_script), ".llm-wiki/qmd-cache"
          assert_includes File.read(post_commit_script), ".llm-wiki/qmd-cache"
          assert_includes File.read(refresh_script), "LLM_WIKI_CODEX_TIMEOUT"
          assert_includes File.read(refresh_script), "LLM_WIKI_QMD_TIMEOUT"
          assert_includes File.read(refresh_script), "qmd embed --max-docs-per-batch 64 --max-batch-mb 64"
          assert_includes File.read(refresh_script), "Do not run qmd update or qmd embed yourself"
          assert_includes File.read(refresh_script), "wiki/log.d/<timestamp>-<slug>.md"
          assert_includes File.read(refresh_script), "without editing compiled wiki/log.md"
          assert_includes File.read(post_commit_script), "LLM_WIKI_CODEX_TIMEOUT"
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_TIMEOUT"
          assert_includes File.read(refresh_script), "git rev-parse --local-env-vars"
          assert_includes File.read(post_commit_script), "git rev-parse --local-env-vars"
          assert_includes File.read(post_commit_script), "run_without_git_env timeout"
          assert_includes File.read(refresh_script), "run_without_git_env timeout"
          [ refresh_script, post_commit_script ].each do |script_path|
            File.read(script_path).each_line.with_index(1) do |line, n|
              next unless line.include?("codex exec")
              assert_includes line, "run_without_git_env",
                "#{script_path}:#{n}: `codex exec` must be wrapped with run_without_git_env: #{line.strip}"
            end
          end
          assert_includes File.read(post_commit_script), "qmd embed --max-docs-per-batch 64 --max-batch-mb 64"
          assert_includes File.read(post_commit_script), "Do not run qmd update or qmd embed yourself"
          assert_includes File.read(post_commit_script), "wiki/log.d/<timestamp>-<slug>.md"
          assert_includes File.read(post_commit_script), "without editing compiled wiki/log.md"
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

  def test_init_places_managed_post_commit_hook_before_existing_terminal_exit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        hook_path = File.join(dir, ".git", "hooks", "post-commit")
        File.write(hook_path, "#!/usr/bin/env bash\nprintf 'existing hook\n'\nexit 0\n")
        File.chmod(0o755, hook_path)

        Hive::LlmWikiBootstrap.install!(dir, scheduler: false)

        hook = File.read(hook_path)
        assert_includes hook, "printf 'existing hook\n'"
        assert_equal 1, hook.scan("# BEGIN LLM WIKI POST-COMMIT").length
        assert_equal 1, hook.scan("# END LLM WIKI POST-COMMIT").length
        assert_operator hook.index("# BEGIN LLM WIKI POST-COMMIT"), :<, hook.rindex("exit 0")
      end
    end
  end

  def test_init_places_managed_post_commit_hook_before_terminal_non_zero_exit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        hook_path = File.join(dir, ".git", "hooks", "post-commit")
        File.write(hook_path, "#!/usr/bin/env bash\nprintf 'existing hook\n'\nexit 1\n")
        File.chmod(0o755, hook_path)

        Hive::LlmWikiBootstrap.install!(dir, scheduler: false)

        hook = File.read(hook_path)
        assert_includes hook, "printf 'existing hook\n'"
        assert_equal 1, hook.scan("# BEGIN LLM WIKI POST-COMMIT").length
        assert_equal 1, hook.scan("# END LLM WIKI POST-COMMIT").length
        assert_operator hook.index("# BEGIN LLM WIKI POST-COMMIT"), :<, hook.rindex("exit 1")
      end
    end
  end

  def test_llm_wiki_post_commit_refresh_clears_git_hook_environment_for_nested_tools
    with_tmp_home do
      with_tmp_git_repo do |dir|
        Hive::LlmWikiBootstrap.install!(dir, post_commit_hook: false, scheduler: false)

        env_var_names = `git -C #{dir} rev-parse --local-env-vars`
                        .split("\n").map(&:strip).reject(&:empty?)
        assert_includes env_var_names, "GIT_INDEX_FILE",
                        "sanity check: git must expose at least GIT_INDEX_FILE"

        fake_bin = File.join(dir, "fake-bin")
        FileUtils.mkdir_p(fake_bin)
        %w[codex qmd].each do |tool|
          tool_path = File.join(fake_bin, tool)
          File.write(tool_path, <<~BASH)
            #!/usr/bin/env bash
            {
              while IFS= read -r name; do
                [ -n "$name" ] || continue
                printf '#{tool}:%s=%s\\n' "$name" "${!name-}"
              done < <(git rev-parse --local-env-vars 2>/dev/null || true)
            } >> "${HIVE_TEST_HOOK_ENV_LOG:?}"
          BASH
          File.chmod(0o755, tool_path)
        end

        FileUtils.mkdir_p(File.join(dir, "docs"))
        File.write(File.join(dir, "docs", "change.md"), "changed\n")
        run!("git", "-C", dir, "add", "docs/change.md")
        run!("git", "-C", dir, "commit", "-m", "docs", "--quiet")

        # Each var must be non-empty so the scrub is observable. A few vars
        # (object/common dirs, config-parameters/count, replace-ref base) would
        # crash the parent `git diff-tree HEAD` inside post-commit-refresh.sh if
        # set to garbage, so they get non-empty values that still let git
        # function. The assertion remains: the *child* (codex/qmd) must see
        # each name as empty after run_without_git_env.
        polluted_env = env_var_names.to_h { |name| [ name, "polluted" ] }
        polluted_env.merge!(
          "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR),
          "HIVE_TEST_HOOK_ENV_LOG" => File.join(dir, "hook-env.log"),
          "GIT_INDEX_FILE" => File.join(dir, "foreign.index"),
          "GIT_DIR" => File.join(dir, ".git"),
          "GIT_WORK_TREE" => dir,
          "GIT_OBJECT_DIRECTORY" => File.join(dir, ".git", "objects"),
          "GIT_COMMON_DIR" => File.join(dir, ".git"),
          "GIT_CONFIG_COUNT" => "0",
          "GIT_CONFIG_PARAMETERS" => "'core.bare=false'",
          "GIT_REPLACE_REF_BASE" => "refs/replace/"
        )

        log_path = polluted_env.fetch("HIVE_TEST_HOOK_ENV_LOG")
        with_env(polluted_env) do
          run!(File.join(dir, ".llm-wiki", "post-commit-refresh.sh"))
        end

        log = File.read(log_path)
        env_var_names.each do |name|
          assert_includes log, "codex:#{name}=\n",
                          "codex must observe scrubbed #{name}"
          assert_includes log, "qmd:#{name}=\n",
                          "qmd must observe scrubbed #{name}"
        end
        refute_includes log, "foreign.index"
        refute_includes log, dir
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
        assert_equal [ Hive::Reviewers::Agent::DEFAULT_TIMEOUT_SEC ], reviewers.map { |r| r["timeout_sec"] }.uniq

        patrol_reviewers = cfg.dig("patrol", "review", "reviewers")
        assert_kind_of Array, patrol_reviewers
        assert_equal [ "codex-native-review" ], patrol_reviewers.map { |r| r["name"] }
        assert_equal "codex_review", patrol_reviewers.first["kind"]

        # Each entry references a registered AgentProfile.
        (reviewers + patrol_reviewers).each do |entry|
          assert Hive::AgentProfiles.registered?(entry["agent"]),
                 "reviewer #{entry['name'].inspect} agent #{entry['agent'].inspect} must be a registered profile"
        end

        # Other defaults present.
        assert_equal "courageous", cfg.dig("review", "triage", "bias")
        assert_equal 2,            cfg.dig("review", "max_passes")
        assert_equal 14_400,       cfg.dig("review", "max_wall_clock_sec")
      end
    end
  end

  def test_init_renders_patrol_mode_without_explicit_scheduler_knobs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        config_path = File.join(dir, ".hive-state", "config.yml")
        raw_cfg = YAML.safe_load(File.read(config_path))
        raw_patrol = raw_cfg.fetch("patrol")
        cfg = Hive::Config.load(dir)

        assert_equal "medium", raw_patrol.fetch("mode")
        refute raw_patrol.key?("trigger"), "fresh init config must let patrol.mode derive trigger"
        refute raw_patrol.key?("poll_interval_sec"), "fresh init config must let patrol.mode derive poll cadence"
        refute raw_patrol.key?("enabled"), "fresh init config must let patrol.mode derive enabled"
        assert_equal "timer", cfg.dig("patrol", "trigger")
        assert_equal 14_400, cfg.dig("patrol", "poll_interval_sec")
        assert_equal true, cfg.dig("patrol", "enabled")
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

  def test_rejects_non_git_repo_with_json_flag_using_legacy_stderr_contract
    with_tmp_global_config do
      with_tmp_dir do |dir|
        out, err, status = with_captured_exit { Hive::Commands::Init.new(dir, json: true).call }
        assert_equal "", out
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

  def test_rejects_dirty_tree_with_json_flag_using_legacy_stderr_contract
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        File.write(File.join(dir, "README.md"), "modified\n")
        out, err, status = with_captured_exit { Hive::Commands::Init.new(dir, json: true).call }
        assert_equal "", out
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

  def test_double_init_with_json_flag_uses_legacy_stderr_contract
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        out, err, status = with_captured_exit { Hive::Commands::Init.new(dir, json: true).call }
        assert_equal "", out
        assert_equal Hive::ExitCodes::ALREADY_INITIALIZED, status
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
        assert_equal "bypassPermissions", cfg.dig("claude", "permission_mode"),
                     "claude.permission_mode must default to bypassPermissions in fresh templates"
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
    input = StringIO.new(input_text)
    input.define_singleton_method(:tty?) { true }
    Hive::Commands::Init::Prompts.new(
      input: input,
      output: StringIO.new,
      summary_io: StringIO.new
    )
  end

  def make_incomplete_prompts(missing_key)
    prompts = Object.new
    prompts.define_singleton_method(:collect) do
      input = StringIO.new
      input.define_singleton_method(:tty?) { false }
      answers = Hive::Commands::Init::Prompts.new(
        input: input,
        output: StringIO.new,
        summary_io: StringIO.new
      ).collect
      answers.delete(missing_key)
      answers
    end
    prompts
  end

  def assert_clean_failed_init(dir)
    refute File.exist?(File.join(dir, ".hive-state"))
    assert_empty `git -C #{dir} branch --list hive/state`.strip
    assert_equal "", `git -C #{dir} status --porcelain`.strip
    refute Hive::Config.find_project(File.basename(dir))
  end

  def test_init_with_piped_user_choices_writes_matching_config
    # Order matches Prompts#collect. Choose codex for planning, default
    # claude_mode, codex for development, safetyist triage, only first +
    # third normal reviewer, default patrol reviewer, high patrol mode, override `plan`
    # budget/timeout, accept the rest.
    inputs = [
      "codex", "", "", "", "", "2", "1,3", "", "high", "safetyist",
      "", "30,900", "", "", "", "", "", "", "", "",
      "", "", "", ""
    ].join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        assert_equal "codex", cfg.dig("brainstorm", "agent")
        assert_equal "headless", cfg.dig("brainstorm", "runtime")
        assert_equal "bypassPermissions", cfg.dig("claude", "permission_mode")
        assert_equal "codex", cfg.dig("plan", "agent")
        assert_equal "codex", cfg.dig("execute", "agent")
        assert_equal "safetyist", cfg.dig("review", "triage", "bias")
        assert_equal 30,  cfg.dig("budget_usd", "plan")
        assert_equal 900, cfg.dig("timeout_sec", "plan")

        names = cfg.dig("review", "reviewers").map { |r| r["name"] }.sort
        assert_equal %w[claude-ce-code-review pr-review-toolkit], names,
                     "only the two selected reviewers should be rendered"
        patrol_names = cfg.dig("patrol", "review", "reviewers").map { |r| r["name"] }
        assert_equal %w[codex-native-review], patrol_names,
                     "blank patrol reviewer prompt should render the codex native-review default"
        assert_equal "high", cfg.dig("patrol", "mode")
        assert_equal "timer", cfg.dig("patrol", "trigger")
        assert_equal 7200, cfg.dig("patrol", "poll_interval_sec")

        # ADR-024: daemon prompt defaults to Y at the prompt; rendered
        # template must carry `daemon: { enabled: true }` so the daemon
        # picks up new projects out of the box.
        assert_equal true, cfg.dig("daemon", "enabled"),
                     "blank daemon prompt → enabled true rendered into config"
        assert_equal true, cfg.dig("babysitter", "enabled"),
                     "blank babysitter prompt → enabled true rendered into config"
      end
    end
  end

  def test_init_with_headless_claude_mode_writes_matching_config
    # planning=blank(claude), claude_mode="2"(headless), claude_permission_mode=blank,
    # dev=blank, reviewers=blank, patrol_reviewers=blank, patrol_mode=blank,
    # triage=blank, limit blanks, daemon-enable=blank,
    # babysitter-enable=blank, daemon-autostart=blank, confirm=blank.
    inputs = ([ "", "2", "", "", "", "", "", "", "", "" ] +
              ([ "" ] * Hive::Commands::Init::Prompts::LIMIT_KEYS.size) +
              [ "", "", "", "" ]).join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        config_path = File.join(dir, ".hive-state", "config.yml")
        raw_cfg = YAML.safe_load(File.read(config_path))
        assert_equal "claude", cfg.dig("brainstorm", "agent")
        assert_equal "headless", cfg.dig("claude", "mode")
        assert_equal "bypassPermissions", cfg.dig("claude", "permission_mode")
        refute raw_cfg.fetch("brainstorm").key?("runtime"),
               "fresh init config must not render legacy brainstorm.runtime"
      end
    end
  end

  def test_init_with_claude_permission_mode_auto_writes_matching_config
    # planning=blank, claude_mode=blank, claude_permission_mode="2"(auto),
    # dev/reviewers/patrol_reviewers/patrol_mode/triage=blank, limits blank,
    # daemon/babysitter/autostart/confirm blank.
    inputs = ([ "", "", "2", "", "", "", "", "", "", "" ] +
              ([ "" ] * Hive::Commands::Init::Prompts::LIMIT_KEYS.size) +
              [ "", "", "", "" ]).join("\n") + "\n"
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        prompts = make_tty_prompts(inputs)
        capture_io { Hive::Commands::Init.new(dir, prompts: prompts).call }

        cfg = Hive::Config.load(dir)
        assert_equal "tmux", cfg.dig("claude", "mode")
        assert_equal "auto", cfg.dig("claude", "permission_mode")
      end
    end
  end

  def test_init_with_daemon_disabled_writes_disabled_config
    # Same shape as above but explicitly answer `n` to the daemon prompt.
    # Blanks: planning (claude), claude mode, Claude permission mode, dev,
    # reviewers, patrol reviewers, patrol mode, triage bias, limits. Then "n" for daemon-enable and blanks for
    # babysitter-enable, daemon-autostart, and confirm.
    inputs = (([ "" ] * (10 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
              [ "n", "", "", "" ]).join("\n") + "\n"
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
    # Blanks: planning (claude), claude mode, Claude permission mode, dev,
    # reviewers, patrol reviewers, patrol mode, triage bias, limits, daemon-enable, babysitter-enable,
    # daemon-autostart.
    inputs = (([ "" ] * (13 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
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

  def test_init_incomplete_prompt_answers_fail_before_disk_side_effects
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        error = assert_raises(Hive::InternalError) do
          capture_io do
            Hive::Commands::Init.new(dir, prompts: make_incomplete_prompts("claude_mode")).call
          end
        end
        assert_includes error.message, "KeyError"
        assert_includes error.message, "claude_mode"

        refute File.directory?(File.join(dir, ".hive-state")),
               ".hive-state must not exist after an incomplete prompt answer hash"
        log = `git -C #{dir} log --format=%s 2>&1`.strip
        refute_includes log, "chore: ignore .hive-state worktree",
                        "master must not have the gitignore commit"
        branches = `git -C #{dir} branch --list`
        refute_includes branches, "hive/state",
                        "orphan hive/state branch must not exist after incomplete prompt answers"
        refute Hive::Config.find_project(File.basename(dir)),
               "global registry must not list the failed project"
      end
    end
  end

  def test_init_rolls_back_hive_state_when_disk_step_fails_after_orphan_init
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        command = Hive::Commands::Init.new(dir)
        command.define_singleton_method(:write_per_project_config) do |_ops, content:|
          raise "boom after hive_state_init"
        end

        _out, err = capture_io do
          error = assert_raises(Hive::InternalError) { command.call }
          assert_includes error.message, "RuntimeError: boom after hive_state_init"
        end

        assert_includes err, "partial init failed; rolled back"
        refute File.exist?(File.join(dir, ".hive-state"))
        assert_empty `git -C #{dir} branch --list hive/state`.strip
        refute Hive::Config.find_project(File.basename(dir))

        capture_io { Hive::Commands::Init.new(dir).call }
        assert File.directory?(File.join(dir, ".hive-state"))
      end
    end
  end

  def test_init_rolls_back_when_hive_state_init_raises_after_partial_create
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        original_new = Hive::GitOps.method(:new)
        with_replaced_singleton_method(Hive::GitOps, :new, lambda { |path|
          ops = original_new.call(path)
          original_init = ops.method(:hive_state_init)
          ops.define_singleton_method(:hive_state_init) do
            original_init.call
            raise "boom inside hive_state_init"
          end
          ops
        }) do
          _out, err = capture_io do
            error = assert_raises(Hive::InternalError) { Hive::Commands::Init.new(dir).call }
            assert_includes error.message, "RuntimeError: boom inside hive_state_init"
          end
          assert_includes err, "partial init failed; rolled back"
        end

        assert_clean_failed_init(dir)
        capture_io { Hive::Commands::Init.new(dir).call }
        assert File.directory?(File.join(dir, ".hive-state"))
      end
    end
  end

  def test_init_rolls_back_main_checkout_side_effects_when_later_step_fails
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        original_head = `git -C #{dir} rev-parse HEAD`.strip
        with_replaced_singleton_method(Hive::LlmWikiBootstrap, :install!, lambda { |project_root, **_kwargs|
          FileUtils.mkdir_p(File.join(project_root, ".llm-wiki"))
          File.write(File.join(project_root, ".llm-wiki", "config.json"), "{}\n")
          raise "boom after gitignore commit"
        }) do
          _out, err = capture_io do
            error = assert_raises(Hive::InternalError) { Hive::Commands::Init.new(dir).call }
            assert_includes error.message, "RuntimeError: boom after gitignore commit"
          end
          assert_includes err, "main checkout commits"
          assert_includes err, "main checkout side effects"
        end

        assert_equal original_head, `git -C #{dir} rev-parse HEAD`.strip
        assert_clean_failed_init(dir)
        refute File.exist?(File.join(dir, ".gitignore"))
        refute File.exist?(File.join(dir, ".llm-wiki"))

        capture_io { Hive::Commands::Init.new(dir).call }
        assert File.directory?(File.join(dir, ".hive-state"))
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
  def test_init_renders_model_and_effort_pins_through_to_cli_flags
    answers_stub = Object.new
    answers_stub.define_singleton_method(:collect) do
      input = StringIO.new
      input.define_singleton_method(:tty?) { false }
      defaults = Hive::Commands::Init::Prompts.new(
        input: input, output: StringIO.new, summary_io: StringIO.new
      ).collect
      defaults.merge("claude_model" => "sonnet", "claude_effort" => "low")
    end

    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir, prompts: answers_stub).call }

        cfg = Hive::Config.load(dir)
        assert_equal "sonnet", cfg.dig("claude", "model"), "the chosen model must land in the project config"
        assert_equal "low", cfg.dig("claude", "effort"), "the chosen effort must render as valid YAML"
        assert_equal [ "--model", "sonnet", "--effort", "low" ],
                     Hive::Config.claude_cli_flags(cfg),
                     "the rendered config must resolve to the launch flags"
      end
    end
  end
end
