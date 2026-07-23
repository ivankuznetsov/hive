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
require "hive/workflows/project"

class InitTest < Minitest::Test
  include HiveTestHelper

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_init_persists_canonical_origin_identity_in_registry
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        remote = File.join(File.dirname(dir), "origin.git")
        run!("git", "init", "--bare", "--quiet", remote)
        run!("git", "-C", dir, "remote", "add", "origin", remote)

        capture_io { Hive::Commands::Init.new(dir).call }

        entry = Hive::Config.registered_projects.find { |project| project["path"] == File.expand_path(dir) }
        assert_equal Hive::RepositoryIdentity.normalize(remote), entry["repository_identity"]
      end
    end
  end

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

  # Writes a real, parseable workflow descriptor under <state_path>/workflows —
  # the on-disk dir that Loader.load_dir actually reads. (with_registered_workflow
  # only fills the in-memory Registry, so it can't exercise load_dir's .empty?
  # term.) A single terminal stage is the minimal descriptor the parser accepts.
  def write_custom_workflow_descriptor(state_path)
    workflows_dir = File.join(state_path, "workflows")
    FileUtils.mkdir_p(workflows_dir)
    File.write(File.join(workflows_dir, "mine.yml"), <<~YAML)
      id: mine
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
    YAML
    workflows_dir
  end

  # Replace Loader.load_dir with a raising singleton method for the block, then
  # restore it (minitest/mock isn't bundled — same singleton-override pattern as
  # the reviewer/digest tests). Lets us drive no_custom_workflow_yet?'s rescue
  # arm without an exotic on-disk fault. Pass `only_under:` to raise only for
  # load_dir calls whose path sits under that directory (e.g. the new project's
  # .hive-state); other loads delegate to the real implementation, so a full
  # Init#call's advisory hint load can fail while unrelated loads still resolve.
  def with_load_dir_raising(error, only_under: nil)
    original = Hive::Workflows::Loader.method(:load_dir)
    scope = only_under && File.expand_path(only_under)
    Hive::Workflows::Loader.define_singleton_method(:load_dir) do |dir = nil, *rest|
      raise error if scope.nil? || (dir && File.expand_path(dir.to_s).start_with?(scope))

      original.call(dir, *rest)
    end
    begin
      yield
    ensure
      Hive::Workflows::Loader.singleton_class.send(:remove_method, :load_dir)
      Hive::Workflows::Loader.define_singleton_method(:load_dir, &original)
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
        assert_includes out, "→ next: hive new #{name} '<short task description>'"
        # PR-562 writing-workflow dogfooding: a fresh coding-default project
        # should teach that project-local workflow authoring exists.
        assert_includes out,
                        "tip: custom workflows live in this project — author one with `hive workflow new <id>`"
        # Pin count + ordering (plan Requirements Trace: "exactly one extra tip
        # line below next:"): the authoring tip must appear exactly once, and
        # strictly below the `→ next:` line — never duplicated or hoisted above it.
        lines = out.lines.map(&:chomp)
        next_idx = lines.index { |l| l.include?("→ next: hive new #{name}") }
        tip_indices = lines.each_index.select do |i|
          lines[i].include?("tip: custom workflows live in this project")
        end
        assert next_idx, "the `→ next:` line must be present"
        assert_equal 1, tip_indices.size,
                     "the workflow-authoring tip must appear exactly once, not duplicated"
        assert_operator tip_indices.first, :>, next_idx,
                        "the authoring tip must render below the `→ next:` line"

        # capture_io yields a non-tty StringIO; ANSI must be suppressed there
        # so piped/CI output stays clean. Load-bearing safety property of the
        # styled summary.
        refute_match(/\e\[/, out, "ANSI escapes must not appear in non-tty output")

        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox"))
        assert File.exist?(File.join(dir, ".hive-state", "config.yml"))
        refute_includes File.read(File.join(dir, ".hive-state", "config.yml")), "default_workflow:"
        assert_equal 60, Hive::Config.load(dir).dig("gh", "network_timeout_sec"),
                     "fresh generated config, including its no-default gh section, must load immediately"

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
          out, _err = capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }

          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")

          name = File.basename(dir)
          assert_includes out, "→ next: hive new #{name} '<short task description>'"
          refute_includes out, "hive workflow new",
                          "non-coding defaults already prove workflow selection, so the authoring tip should not nag"
        end
      end
    end
  end

  def test_init_workflow_prompt_persists_selected_default
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("4\n")
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
          assert_includes workflow_output.string, "3) bench"
          assert_includes workflow_output.string, "4) content_fixture"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow")
        end
      end
    end
  end

  def test_init_workflow_prompt_pick_selects_the_named_index
    # Discriminator against a "selection ignored, always writes the one
    # registered non-coding default" regression: with BOTH content (built-in,
    # index 2) and content_fixture (index 4) on the menu, picking "2" must bind
    # content — not whatever single non-coding default a broken loop might emit.
    # The sibling test above pins "4" → content_fixture, so the two together
    # prove the chosen index actually drives the on-disk default.
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("2\n")
          workflow_input.define_singleton_method(:tty?) { true }
          prompts = Hive::Commands::Init::Prompts.new(
            input: StringIO.new,
            output: StringIO.new,
            summary_io: StringIO.new
          )

          capture_io do
            Hive::Commands::Init.new(dir, prompts: prompts, workflow_input: workflow_input).call
          end

          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content", config.fetch("default_workflow"),
                       "picking index 2 must bind content, not the index-3 content_fixture"
        end
      end
    end
  end

  def test_init_workflow_prompt_accepts_case_insensitive_name
    # resolve_workflow_answer's name branch matches case-insensitively, so a
    # name typed with different casing still resolves to its descriptor.
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("Content_Fixture\n")
          workflow_input.define_singleton_method(:tty?) { true }
          prompts = Hive::Commands::Init::Prompts.new(
            input: StringIO.new,
            output: StringIO.new,
            summary_io: StringIO.new
          )

          capture_io do
            Hive::Commands::Init.new(dir, prompts: prompts, workflow_input: workflow_input).call
          end

          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content_fixture", config.fetch("default_workflow"),
                       "a workflow name must resolve regardless of case"
        end
      end
    end
  end

  def test_init_workflow_prompt_reprompts_on_unknown_name
    # The selection loop's unknown-input branch: an answer that is neither the
    # author entry, an in-range index, nor a known name must re-prompt with the
    # "unknown workflow … pick a name … or 1..N" hint, then accept the follow-up.
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          workflow_input = StringIO.new("nonexistent\n2\n")
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

          assert_includes workflow_output.string, "unknown workflow \"nonexistent\""
          assert_includes workflow_output.string, "1..#{author_index}",
                          "the re-prompt hint must show the selectable 1..N range"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content", config.fetch("default_workflow"),
                       "the selection loop must accept a valid pick after re-prompting"
        end
      end
    end
  end

  def test_init_workflow_prompt_reprompts_on_out_of_range_index
    # resolve_workflow_answer's numeric-but-out-of-range branch returns nil
    # (rather than indexing past the menu), so the loop re-prompts the same way
    # an unknown name does, then accepts the follow-up pick.
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          out_of_range = author_index + 5
          workflow_input = StringIO.new("#{out_of_range}\n2\n")
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

          assert_includes workflow_output.string, "unknown workflow #{out_of_range.to_s.inspect}",
                          "an out-of-range index must re-prompt, not index past the menu"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "content", config.fetch("default_workflow"),
                       "the loop must accept a valid pick after an out-of-range index"
        end
      end
    end
  end

  def test_init_non_tty_workflow_input_skips_prompt_and_keeps_coding_fieldless
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          workflow_input = StringIO.new("3\n")
          workflow_output = StringIO.new

          capture_io do
            Hive::Commands::Init.new(
              dir,
              workflow_input: workflow_input,
              workflow_output: workflow_output
            ).call
          end

          assert_empty workflow_output.string, "non-TTY workflow input must not render the workflow prompt"
          assert_equal "3", workflow_input.gets&.chomp, "non-TTY workflow input must not be consumed"
          refute_includes File.read(File.join(dir, ".hive-state", "config.yml")), "default_workflow:",
                          "implicit non-TTY coding default should keep config.yml fieldless"
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

  def test_init_workflow_prompt_author_entry_scaffolds_binds_and_runs_questionnaire
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          # Derive the author entry's index from the live workflow count rather
          # than hardcoding "4": a change to the built-in count would otherwise
          # make a literal "4" silently select a real workflow at that position.
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          workflow_input = StringIO.new("#{author_index}\nwriting\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new
          setup_inputs = ([ "codex", "", "", "", "", "", "", "", "", "", "", "" ] +
                          ([ "" ] * Hive::Commands::Init::Prompts::LIMIT_KEYS.size) +
                          [ "", "", "", "" ]).join("\n") + "\n"
          prompts = make_tty_prompts(setup_inputs)

          capture_io do
            Hive::Commands::Init.new(
              dir,
              prompts: prompts,
              workflow_input: workflow_input,
              workflow_output: workflow_output
            ).call
          end

          hive_state = File.join(dir, ".hive-state")
          descriptor_path = File.join(hive_state, "workflows", "writing.yml")
          instruction_path = File.join(hive_state, "workflows", "writing", "work.md")
          config = YAML.safe_load(File.read(File.join(hive_state, "config.yml")))
          assert_includes workflow_output.string, "Workflow:"
          assert_includes workflow_output.string, "#{author_index}) author a new workflow"
          assert_equal "writing", config.fetch("default_workflow"),
                       "inline authoring must bind the newly scaffolded workflow as the project default"
          assert File.file?(descriptor_path), "inline authoring must create the workflow descriptor"
          assert File.file?(instruction_path), "inline authoring must create the workflow instruction"
          assert_equal "codex", Hive::Config.load(dir).dig("brainstorm", "agent"),
                       "inline authoring must continue through the full setup questionnaire"
          assert Hive::Config.registered_projects.any? { |project| project["path"] == File.expand_path(dir) },
                 "inline authoring must still register the initialized project"
        end
      end
    end
  end

  def test_init_workflow_prompt_author_reprompts_on_reserved_id
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          workflow_input = StringIO.new("#{author_index}\ncoding\nwriting\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new

          capture_io do
            Hive::Commands::Init.new(
              dir,
              prompts: make_tty_prompts(default_setup_prompt_input),
              workflow_input: workflow_input,
              workflow_output: workflow_output
            ).call
          end

          assert_includes workflow_output.string, "workflow id \"coding\" is reserved by a built-in workflow"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "writing", config.fetch("default_workflow"),
                       "reserved inline author ids must re-prompt and accept the next valid id"
        end
      end
    end
  end

  def test_init_workflow_prompt_author_reprompts_on_invalid_format
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          # Two invalid ids in a row prove the re-prompt is a real loop boundary:
          # the SECOND bad entry must re-prompt again, not abort after one retry.
          workflow_input = StringIO.new("#{author_index}\nBad Id!\nWorse Id!\nwriting\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new

          capture_io do
            Hive::Commands::Init.new(
              dir,
              prompts: make_tty_prompts(default_setup_prompt_input),
              workflow_input: workflow_input,
              workflow_output: workflow_output
            ).call
          end

          assert_includes workflow_output.string, "invalid workflow id \"Bad Id!\""
          assert_includes workflow_output.string, "invalid workflow id \"Worse Id!\"",
                          "a second invalid id must re-prompt again, not abort after one retry"
          config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
          assert_equal "writing", config.fetch("default_workflow"),
                       "invalid inline author ids must re-prompt and accept the next valid id"
        end
      end
    end
  end

  def test_rerun_init_workflow_prompt_author_reprompts_on_scaffold_collision
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        scaffold = Hive::Commands::Workflow.scaffold_files!("writing", project_root: dir)
        author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
        workflow_input = StringIO.new("#{author_index}\nwriting\nwriting2\n")
        workflow_input.define_singleton_method(:tty?) { true }
        workflow_output = StringIO.new

        capture_io do
          Hive::Commands::Init.new(
            dir,
            workflow_input: workflow_input,
            workflow_output: workflow_output
          ).call
        end

        assert_includes workflow_output.string, "workflow scaffold already exists for \"writing\""
        config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
        assert_equal "writing2", config.fetch("default_workflow"),
                     "colliding inline author ids must re-prompt and bind the next valid free id"
        assert File.file?(File.join(dir, ".hive-state", "workflows", "writing2.yml")),
               "the accepted post-collision id must be scaffolded"
        Hive::Commands::Workflow.rollback_scaffold(scaffold.fetch(:paths))
      end
    end
  end

  def test_rerun_init_workflow_prompt_author_scaffolds_binds_and_warns_in_one_commit
    # The inline-author re-init happy path (operator picks "author a new
    # workflow" at the prompt on an already-initialized project) routes through
    # scaffold_and_bind_existing — the same path as `hive init --new-workflow X`,
    # but reached via the prompt rather than the flag. The flag path is covered
    # by test_init_new_workflow_existing_scaffolds_and_rebinds_in_one_commit; this
    # pins the prompt-driven entry against the SAME contract: a single commit that
    # scaffolds + rebinds, a preserved project registration, and the field-less
    # in-flight-task rebind warning.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        before_count = run!("git", "-C", hive_state, "rev-list", "--count", "HEAD").to_i
        # A field-less in-flight task so the rebind must emit the guard.
        task_dir = File.join(hive_state, "stages", "1-inbox", "fieldless-task-260620-abcd")
        FileUtils.mkdir_p(task_dir)
        File.write(File.join(task_dir, "idea.md"), "fieldless\n")

        author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
        workflow_input = StringIO.new("#{author_index}\nwriting\n")
        workflow_input.define_singleton_method(:tty?) { true }
        workflow_output = StringIO.new
        _out, err = capture_io do
          Hive::Commands::Init.new(
            dir,
            workflow_input: workflow_input,
            workflow_output: workflow_output
          ).call
        end

        descriptor_path = File.join(hive_state, "workflows", "writing.yml")
        instruction_path = File.join(hive_state, "workflows", "writing", "work.md")
        config = YAML.safe_load(File.read(File.join(hive_state, "config.yml")))
        assert_equal "writing", config.fetch("default_workflow"),
                     "the inline-author re-init must rebind default_workflow on disk"
        assert File.file?(descriptor_path), "the inline-authored descriptor must be scaffolded"
        assert File.file?(instruction_path), "the inline-authored instruction stub must be scaffolded"

        # Single commit: scaffold + config rebind land together, like the flag path.
        assert_equal before_count + 1, run!("git", "-C", hive_state, "rev-list", "--count", "HEAD").to_i,
                     "scaffold + rebind must be exactly one commit"
        assert_equal "hive: workflows/writing created",
                     run!("git", "-C", hive_state, "log", "--format=%s", "-1").strip
        changed = run!("git", "-C", hive_state, "show", "--name-only", "--format=", "HEAD")
        assert_includes changed, "config.yml"
        assert_includes changed, "workflows/writing.yml"

        # The field-less in-flight task triggers the same rebind warning the flag path emits.
        assert_includes err, "changing default_workflow from coding to writing"
        assert_includes err, "1-inbox/fieldless-task-260620-abcd"

        # Registration survives the re-init.
        assert Hive::Config.registered_projects.any? { |project| project["path"] == File.expand_path(dir) },
               "the inline-author re-init must keep the project registered"
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

        # The scaffold commit must include config.yml so the fresh
        # `default_workflow: writing` binding is durable against a hive-state
        # reset/clean (symmetric with the existing-project path).
        changed = run!("git", "-C", File.join(dir, ".hive-state"), "show", "--name-only", "--format=", "HEAD")
        assert_includes changed, "config.yml"
        assert_includes changed, "workflows/writing.yml"

        assert Hive::Config.registered_projects.any? { |project| project["path"] == File.expand_path(dir) }
      end
    end
  end

  def test_init_new_workflow_fresh_json_emits_paths_and_bound_workflow
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        out, _err = capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing", json: true).call }
        payload = JSON.parse(out)
        descriptor_path = File.join(dir, ".hive-state", "workflows", "writing.yml")
        instruction_path = File.join(dir, ".hive-state", "workflows", "writing", "work.md")

        assert_equal 1, out.lines.size
        refute_includes out, "hive: initialized"
        assert_equal "hive-init", payload.fetch("schema")
        assert_equal true, payload.fetch("ok")
        assert_equal "writing", payload.fetch("workflow")
        assert_equal descriptor_path, payload.fetch("descriptor_path")
        assert_equal instruction_path, payload.fetch("instruction_path")

        schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
        errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
        assert_empty errors, "hive init --new-workflow --json payload must validate: #{errors.inspect}"
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

  def test_init_new_workflow_existing_json_emits_paths_and_bound_workflow
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")

        out, _err = capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing", json: true).call }
        payload = JSON.parse(out)
        descriptor_path = File.join(hive_state, "workflows", "writing.yml")
        instruction_path = File.join(hive_state, "workflows", "writing", "work.md")

        assert_equal 1, out.lines.size
        refute_includes out, "hive: already initialized"
        assert_equal "hive-init", payload.fetch("schema")
        assert_equal true, payload.fetch("already_initialized")
        assert_equal "writing", payload.fetch("workflow")
        assert_equal descriptor_path, payload.fetch("descriptor_path")
        assert_equal instruction_path, payload.fetch("instruction_path")

        schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
        errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
        assert_empty errors, "hive init --new-workflow --json existing payload must validate: #{errors.inspect}"
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

  def test_init_new_workflow_existing_restores_config_and_resets_index_on_commit_failure
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")
        before_config = File.binread(cfg_path)

        # Fail at the git layer (a rejecting pre-commit hook) so hive_commit's
        # `git add -A` staging runs FIRST and the .hive-state index is genuinely
        # polluted — unlike a stub that raises before staging ever runs. Only
        # this ordering exercises the index-reset half of the rollback.
        hook = File.join(dir, ".git", "hooks", "pre-commit")
        File.write(hook, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook)
        begin
          assert_raises(Hive::GitError) do
            capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }
          end
        ensure
          FileUtils.rm_f(hook)
        end

        # Working tree fully unwound.
        assert_equal before_config, File.binread(cfg_path)
        refute File.exist?(File.join(hive_state, "workflows", "writing.yml"))
        refute File.exist?(File.join(hive_state, "workflows", "writing"))

        # The leak-catcher: a failed commit that left config.yml + descriptor
        # STAGED would otherwise ride the next bare `git commit` in this
        # long-lived worktree and silently re-bind default_workflow. The rescue
        # must reset the index for those pathspecs.
        _out, _err, cached = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        assert cached.success?,
               "a failed --new-workflow commit must leave the .hive-state index clean, but staged: " \
               "#{run!('git', '-C', hive_state, 'diff', '--cached', '--name-only')}"

        assert File.directory?(hive_state), "pre-existing hive state must remain attached"
        assert Hive::Config.find_project(File.basename(dir)), "existing project registration should remain intact"
      end
    end
  end

  def test_init_new_workflow_existing_surfaces_commit_error_when_config_restore_fails
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")

        # Fail the workflow commit at the git layer...
        hook = File.join(dir, ".git", "hooks", "pre-commit")
        File.write(hook, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook)

        # ...AND make the config.yml working-tree restore fail inside the
        # rollback. The rescue-within-rescue must warn without masking the
        # original GitError the caller re-raises.
        warnings = []
        begin
          init = Hive::Commands::Init.new(dir, new_workflow: "writing")
          original_atomic_write = init.method(:atomic_write)
          config_writes = 0
          init.define_singleton_method(:atomic_write) do |path, content|
            config_writes += 1 if path == cfg_path
            raise Errno::EACCES, path.to_s if path == cfg_path && config_writes > 1

            original_atomic_write.call(path, content)
          end
          init.define_singleton_method(:write_warn) { |line| warnings << line }
          assert_raises(Hive::GitError) do
            capture_io { init.call }
          end
        ensure
          FileUtils.rm_f(hook)
        end

        assert(warnings.any? { |w| w.include?("could not restore config.yml after a failed default_workflow commit") },
               "a failed config restore must warn, not silently swallow: #{warnings.inspect}")
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

  def test_init_new_workflow_quotes_keyword_like_id_so_flagless_new_resolves
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        # `no` is a SAFE_SLUG workflow id that YAML.safe_load coerces to `false`
        # when written unquoted — the exact regression the quoting in BOTH
        # config.yml (default_workflow) and the descriptor (id) prevents. Without
        # quoting, this init would either bind `false` or fail descriptor parse.
        capture_io { Hive::Commands::Init.new(dir, new_workflow: "no").call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")

        # The config.yml line is quoted, so YAML round-trips it as the String.
        assert_includes File.read(cfg_path), %(default_workflow: "no")
        config = YAML.safe_load(File.read(cfg_path))
        assert_equal "no", config.fetch("default_workflow"),
                     "a keyword-like id must survive YAML.safe_load as a String, not coerce to false"

        # The descriptor parses and its id resolves back to the String id.
        descriptor = Hive::Workflows::DescriptorParser.parse_file(File.join(hive_state, "workflows", "no.yml"))
        assert_equal :no, descriptor.id

        # And a flag-less `hive new` resolves the bound default to the scaffolded
        # workflow rather than failing to find `false`.
        Hive::Workflows::Project.reset!
        capture_io { Hive::Commands::New.new(project, "coercion default task").call }
        inbox = Dir[File.join(hive_state, "stages", "1-inbox", "coercion-default-task-*")].first
        assert inbox, "flag-less hive new must route through the quoted keyword-like default workflow"
        assert_equal "no", Hive::TaskMeta.read(inbox)[:workflow]
        assert_equal :no, Hive::Task.new(inbox).workflow.id
      end
    end
  end

  def test_init_new_workflow_fresh_binding_survives_hive_state_reset_and_clean
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }
        hive_state = File.join(dir, ".hive-state")
        cfg_path = File.join(hive_state, "config.yml")

        # Behaviorally simulate a destructive hive-state reset: clobber the
        # binding in the working tree, drop the descriptor, then restore the
        # committed tree with `reset --hard` + `clean`. Because the fresh path
        # commits config.yml alongside the descriptor, both must come back.
        File.write(cfg_path, "---\nhive_state_path: .hive-state\n")
        FileUtils.rm_rf(File.join(hive_state, "workflows"))
        run!("git", "-C", hive_state, "reset", "--hard", "HEAD")
        run!("git", "-C", hive_state, "clean", "-fd")

        config = YAML.safe_load(File.read(cfg_path))
        assert_equal "writing", config.fetch("default_workflow"),
                     "the committed fresh-path binding must survive a hive-state reset --hard/clean"
        assert File.file?(File.join(hive_state, "workflows", "writing.yml")),
               "the committed descriptor must also be restored by the reset"

        Hive::Workflows::Project.reset!
        assert_equal :writing,
                     Hive::WorkflowSelection.fetch!(config.fetch("default_workflow"), project_root: dir).id,
                     "the restored binding must still resolve under flag-less hive new"
      end
    end
  end

  def test_init_new_workflow_fresh_inline_rollback_scaffold_runs_on_commit_failure
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        rolled_back = []
        original_rollback = Hive::Commands::Workflow.method(:rollback_scaffold)
        # Fail the scaffold commit AFTER scaffold_files! has written the files,
        # so the unwind goes through scaffold_descriptor_commit!'s OWN inline
        # rescue (rollback_scaffold) — not rollback_partial_init's whole-worktree
        # teardown. A regression in that specific rescue would otherwise be
        # masked by the partial-init rollback.
        with_replaced_singleton_method(Hive::Commands::Workflow, :commit_workflow_scaffold,
                                       lambda { |_ops, slug:, pathspecs:| raise Hive::GitError, "commit boom" }) do
          with_replaced_singleton_method(Hive::Commands::Workflow, :rollback_scaffold, lambda { |paths|
            rolled_back << paths
            original_rollback.call(paths)
          }) do
            capture_io do
              error = assert_raises(Hive::GitError) do
                Hive::Commands::Init.new(dir, new_workflow: "writing").call
              end
              assert_includes error.message, "commit boom"
            end
          end
        end

        assert(rolled_back.any? { |paths| paths[:descriptor].end_with?("workflows/writing.yml") },
               "scaffold_descriptor_commit!'s inline rollback_scaffold must run on commit failure: #{rolled_back.inspect}")
        assert_clean_failed_init(dir)
        refute File.exist?(File.join(dir, ".hive-state", "workflows", "writing.yml"))
      end
    end
  end

  def test_reset_hive_state_index_warns_with_full_git_stderr_on_failure
    with_tmp_dir do |dir|
      # A non-git directory makes `git -C <dir> reset` exit non-zero, exercising
      # the best-effort reset-failure warn branch (and the full-stderr surfacing).
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { dir }
      init = Hive::Commands::Init.new(dir)
      warnings = []
      init.define_singleton_method(:write_warn) { |line| warnings << line }

      init.send(:reset_hive_state_index, ops, [ "config.yml", "workflows/writing.yml" ])

      assert(warnings.any? { |w| w.include?("could not unstage config.yml, workflows/writing.yml") },
             "a failed index reset must warn so a staged rebind is not silently left: #{warnings.inspect}")
      assert(warnings.any? { |w| w.include?("not a git repository") },
             "the warning must surface git's stderr detail, not swallow it: #{warnings.inspect}")
      assert(warnings.none? { |w| w.include?("\n") },
             "the warning must be flattened to a single line: #{warnings.inspect}")
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

  def test_init_new_workflow_existing_warns_about_fieldless_in_flight_tasks
    # The --new-workflow existing-project rebind (scaffold_and_bind_existing) emits
    # the SAME fieldless-task guard as the --workflow path, but on its own code
    # path (init.rb warn_on_fieldless_tasks_rebinding call). The --workflow tests
    # drive update_existing_default_workflow!, so without this a regression that
    # dropped/mis-warned the in-flight rebind on `hive init --new-workflow X` over
    # an existing project — the one guard against silent task-load failures after
    # a default change — would go uncaught.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "fieldless-task-260620-abcd")
        FileUtils.mkdir_p(task_dir)
        File.write(File.join(task_dir, "idea.md"), "fieldless\n")

        _out, err = capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing").call }

        assert_includes err, "changing default_workflow from coding to writing"
        assert_includes err, "1-inbox/fieldless-task-260620-abcd"
        config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
        assert_equal "writing", config.fetch("default_workflow")
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

  def test_init_workflow_prompt_author_aborts_on_eof_at_new_id_with_usage_and_zero_state
    # EOF at the inline `New workflow id:` sub-prompt is a DISTINCT Prompts::Aborted
    # raise site from the top-level workflow prompt (prompt_new_workflow_id vs
    # prompt_workflow): it is reached only AFTER selecting the author entry and
    # must honor the same USAGE(64) + zero-disk-state contract.
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          author_index = Hive::WorkflowSelection.valid_names(project_root: dir).size + 1
          # Select the author entry, then feed nothing — gets returns nil (EOF) at
          # the inline new-id sub-prompt.
          workflow_input = StringIO.new("#{author_index}\n")
          workflow_input.define_singleton_method(:tty?) { true }
          workflow_output = StringIO.new

          _out, err, status = with_captured_exit do
            Hive::Commands::Init.new(dir, workflow_input: workflow_input, workflow_output: workflow_output).call
          end

          assert_includes workflow_output.string, "New workflow id:",
                          "the author entry must reach the inline new-id sub-prompt before EOF"
          assert_equal Hive::ExitCodes::USAGE, status
          assert_includes err, "aborted"
          refute File.exist?(File.join(dir, ".hive-state")),
                 "EOF at the inline new-id prompt must leave zero disk state (prompt runs before any writes)"
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

      assert_equal %(default_workflow: "content_fixture"\n), File.read(cfg).lines[1],
                   "with no hive_state_path: line, the default_workflow line lands right after the --- marker"
    end
  end

  def test_write_default_workflow_handles_markerless_file
    with_tmp_dir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "foo: bar\n")
      Hive::Commands::Init.new(dir).send(:write_default_workflow!, cfg, "content_fixture")

      assert_equal %(default_workflow: "content_fixture"\n), File.read(cfg).lines.first,
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
        assert_equal 2, payload.fetch("schema_version")
        assert_equal true, payload.fetch("ok")
        assert_equal File.basename(dir), payload.fetch("project")
        assert_equal File.expand_path(dir), payload.fetch("path")
        assert_equal File.join(dir, ".hive-state"), payload.fetch("hive_state_path")
        assert_equal "coding", payload.fetch("workflow"),
                     "a fresh init must report the bound default workflow in JSON"
        hints = payload.fetch("hints")
        assert_equal 1, hints.length
        assert_equal "custom_workflow", hints.first.fetch("kind")
        assert_equal "hive workflow new <id>", hints.first.fetch("command")
        assert_equal "custom workflows live in this project — author one with `hive workflow new <id>`",
                     hints.first.fetch("message")
        assert_equal "claude", payload.fetch("answers").fetch("planning_agent")
        assert_equal "medium", payload.fetch("answers").fetch("patrol_mode")
        assert_equal "medium", payload.fetch("patrol_mode")
        assert_equal true, payload.fetch("answers").fetch("refactor_patrol_enabled")
        assert_equal true, payload.fetch("refactor_patrol_enabled")
        assert_equal payload.fetch("answers").fetch("budgets"), payload.fetch("budgets")
        assert_equal false, payload.fetch("daemon_autostart_requested")

        schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
        errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
        assert_empty errors, "hive init --json payload must validate: #{errors.inspect}"
      end
    end
  end

  def test_init_json_suppresses_workflow_authoring_hints_for_non_coding_default
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          out, _err = capture_io { Hive::Commands::Init.new(dir, json: true, workflow: "content_fixture").call }
          payload = JSON.parse(out)

          assert_equal 1, out.lines.size
          assert_equal "content_fixture", payload.fetch("workflow")
          assert_equal [], payload.fetch("hints")

          schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
          errors = JSONSchemer.schema(schema).validate(payload).map { |e| e["error"] }
          assert_empty errors, "hive init --workflow --json payload must validate: #{errors.inspect}"
        end
      end
    end
  end

  # The OTHER half of no_custom_workflow_yet? — the `load_dir(...).empty?` term.
  # Every suppression test above feeds a NON-coding default, which short-circuits
  # on coding_id? before load_dir ever runs. Here the default IS coding, but the
  # workflows dir already holds a parseable descriptor, so the JSON hint must be
  # empty: deleting or inverting the `&& ...empty?` term (the predicate's whole
  # reason to exist) would otherwise ship green.
  def test_init_json_suppresses_workflow_authoring_hints_when_custom_workflow_authored
    Dir.mktmpdir("hive-init-hints") do |dir|
      state_path = File.join(dir, ".hive-state")
      write_custom_workflow_descriptor(state_path)
      ops = Struct.new(:default_branch, :hive_state_path).new("main", state_path)
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => state_path }
      answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
      payload = Hive::Commands::Init.new(dir, json: true).send(
        :success_payload, entry: entry, ops: ops, answers: answers, workflow: :coding
      )

      assert_equal [], payload.fetch("hints"),
                   "a coding default whose workflows dir already holds a descriptor must emit no authoring hint"
    end
  end

  def test_non_tty_default_prompt_summary_mentions_adhoc_auto_fix
    summary = StringIO.new
    answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: summary).collect

    assert_equal false, answers.fetch("adhoc_auto_fix")
    assert_includes summary.string, "adhoc_auto_fix=disabled"
  end

  def test_non_tty_default_prompt_summary_recommends_refactor_patrol
    summary = StringIO.new
    answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: summary).collect

    assert_equal true, answers.fetch("refactor_patrol_enabled")
    assert_includes summary.string, "refactor_patrol=enabled"
  end

  def test_non_tty_prompt_override_disables_refactor_patrol_before_rendering
    summary = StringIO.new
    answers = Hive::Commands::Init::Prompts.new(
      input: StringIO.new,
      summary_io: summary,
      refactor_patrol_enabled: false
    ).collect

    assert_equal false, answers.fetch("refactor_patrol_enabled")
    assert_includes summary.string, "refactor_patrol=disabled"
  end

  def test_non_tty_default_prompt_summary_mentions_enabled_adhoc_auto_fix
    prompts = Hive::Commands::Init::Prompts
    original = prompts.const_get(:DEFAULT_ADHOC_AUTO_FIX)
    prompts.send(:remove_const, :DEFAULT_ADHOC_AUTO_FIX)
    prompts.const_set(:DEFAULT_ADHOC_AUTO_FIX, true)
    summary = StringIO.new

    answers = prompts.new(input: StringIO.new, summary_io: summary).collect

    assert_equal true, answers.fetch("adhoc_auto_fix")
    assert_includes summary.string, "adhoc_auto_fix=enabled"
  ensure
    if defined?(prompts) && defined?(original)
      prompts.send(:remove_const, :DEFAULT_ADHOC_AUTO_FIX)
      prompts.const_set(:DEFAULT_ADHOC_AUTO_FIX, original)
    end
  end

  # Same on-disk-descriptor arm, human path: the `tip:` line must be suppressed
  # while the rest of the summary still renders.
  def test_print_summary_suppresses_workflow_authoring_tip_when_custom_workflow_authored
    Dir.mktmpdir("hive-init-tip") do |dir|
      state_path = File.join(dir, ".hive-state")
      write_custom_workflow_descriptor(state_path)
      ops = Struct.new(:default_branch, :hive_state_path).new("main", state_path)
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => state_path }
      answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect

      out, _err = capture_io do
        Hive::Commands::Init.new(dir, json: false).send(
          :print_summary, entry: entry, ops: ops, answers: answers, workflow: :coding
        )
      end

      assert_includes out, "hive: initialized",
                      "the summary must still render — only the authoring tip is suppressed"
      refute_includes out, "tip: custom workflows live in this project",
                       "a coding default with an authored custom workflow must not nag with the authoring tip"
      refute_includes out, "hive workflow new"
    end
  end

  # Direct 2×2 truth table over no_custom_workflow_yet? — {coding, non-coding} ×
  # {empty, populated dir}. Only coding+empty applies the hint; the populated arm
  # (exercised only at the payload/summary level by the suppression cases above,
  # pinned here at the predicate level) and both non-coding arms
  # (short-circuited on coding_id?) suppress it.
  def test_no_custom_workflow_yet_truth_table
    Dir.mktmpdir("hive-no-custom") do |dir|
      empty_state = File.join(dir, "empty", ".hive-state")
      FileUtils.mkdir_p(File.join(empty_state, "workflows"))
      populated_state = File.join(dir, "populated", ".hive-state")
      write_custom_workflow_descriptor(populated_state)

      cmd = Hive::Commands::Init.new(dir)

      assert cmd.send(:no_custom_workflow_yet?, empty_state, :coding),
             "coding default + empty workflows dir → authoring hint applies"
      refute cmd.send(:no_custom_workflow_yet?, populated_state, :coding),
             "coding default + on-disk descriptor → authoring hint suppressed " \
             "(predicate-level pin of the payload/summary suppression cases above)"
      refute cmd.send(:no_custom_workflow_yet?, empty_state, :content_fixture),
             "non-coding default short-circuits on coding_id? even with an empty dir"
      refute cmd.send(:no_custom_workflow_yet?, populated_state, :content_fixture),
             "non-coding default short-circuits on coding_id? regardless of dir contents"
    end
  end

  # The `rescue StandardError` arm of no_custom_workflow_yet? (added by 78a9ce50):
  # an error escaping Loader.load_dir — a filesystem fault OR a genuine
  # programming bug in the coding_id?/load_dir/parser chain — must degrade the
  # advisory hint to "no hint" with a stderr breadcrumb rather than crash an
  # already-committed init. The on-disk truth-table cases above never hit this
  # path (load_dir succeeds), so without this the rescue's two lines stay
  # uncovered and the project's 100% line-coverage gate fails.
  def test_no_custom_workflow_yet_degrades_when_load_dir_raises
    Dir.mktmpdir("hive-no-custom-raise") do |dir|
      state_path = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(File.join(state_path, "workflows"))
      cmd = Hive::Commands::Init.new(dir)

      predicate = nil
      hints = nil
      _out, err = capture_io do
        with_load_dir_raising(RuntimeError.new("boom from load_dir")) do
          predicate = cmd.send(:no_custom_workflow_yet?, state_path, :coding)
          hints = cmd.send(:workflow_authoring_hints, state_path, :coding)
        end
      end

      refute predicate,
             "a coding default whose load_dir raises must degrade to false, not crash"
      assert_equal [], hints,
                   "a raised load_dir must suppress the authoring hint entirely"
      assert_includes err, "hive: skipped workflow-authoring hint",
                      "the degrade must leave a stderr breadcrumb for the operator"
      assert_includes err, "RuntimeError: boom from load_dir",
                      "the breadcrumb must name the swallowed exception class and message"
    end
  end

  # End-to-end companion to the predicate-level degrade test above: drives a
  # FULL Init#call with the new project's workflow load raising, and pins the
  # load-bearing no-crash property the rescue exists for — an already-committed
  # init still finishes (no InternalError), prints its summary, leaves the
  # degrade breadcrumb, and still reaches register_daemon_service!. The predicate
  # test proves the rescue degrades to false+warn; this proves that degrade does
  # not abort the post-commit best-effort steps. `only_under:` scopes the raise
  # to the new project's .hive-state so it lands at the post-commit hint load.
  def test_init_completes_when_workflow_hint_load_raises
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        out, err = capture_io do
          with_load_dir_raising(RuntimeError.new("boom from load_dir"),
                                only_under: File.join(dir, ".hive-state")) do
            Hive::Commands::Init.new(dir).call
          end
        end

        assert_includes out, "hive: initialized",
                        "the success summary must still render after the hint load degrades"
        assert_includes err, "hive: skipped workflow-authoring hint",
                        "the degrade must leave its breadcrumb on the full path too"
        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox")),
               "the hive/state branch must still be committed despite the degraded hint"
        assert File.exist?(File.join(home, ".config/systemd/user/hive-daemon.service")),
               "register_daemon_service! must still run after the degraded hint, not be skipped by a crash"
      end
    end
  end

  def test_init_json_mirrors_non_default_prompt_answers
    # Order: planning, claude_mode, claude_permission_mode, development,
    # reviewers, patrol_reviewers, patrol_mode, triage, ad-hoc auto-fix,
    # architecture patrol discovery,
    # then limits, daemon-enable, babysitter-enable, daemon-autostart, confirm.
    # Two blank slots after claude_permission_mode accept the model/effort
    # defaults. patrol_reviewers index 3 = claude-ce-code-review
    # (1=codex-native-review, 2=codex-ce-code-review, 3=claude-ce-code-review).
    inputs = ([ "codex", "2", "", "", "", "pi", "2", "3", "high", "safetyist", "y", "", "60,120" ] +
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
        assert_equal true, answers.fetch("adhoc_auto_fix")
        assert_equal true, answers.fetch("refactor_patrol_enabled")
        assert_equal 60, answers.fetch("budgets").fetch("brainstorm")
        assert_equal 120, answers.fetch("timeouts").fetch("brainstorm")
        assert_equal false, answers.fetch("daemon_enabled")
        assert_equal true, answers.fetch("babysitter_enabled")
        assert_equal false, answers.fetch("daemon_autostart")

        %w[
          planning_agent claude_mode development_agent enabled_reviewers patrol_reviewers
          patrol_mode triage_bias adhoc_auto_fix refactor_patrol_enabled budgets timeouts daemon_enabled babysitter_enabled
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
          compile_log_script = File.join(dir, ".llm-wiki", "compile-log.sh")
          assert File.executable?(refresh_script)
          assert File.executable?(post_commit_script)
          refresh_contents = File.read(refresh_script)
          assert_includes refresh_contents, "rev-parse --path-format=absolute --git-common-dir"
          assert_includes refresh_contents, '--project "$project_root" --drain'
          refute_match(/\b(?:codex exec|claude -p|pi )\b/, refresh_contents)
          # Post-commit refreshes run only in a disposable managed worktree on
          # llm-wiki/refresh. The source commit is queued before lock acquisition.
          assert_includes File.read(post_commit_script), 'add_dir_args=( --add-dir "$LLM_WIKI_QMD_CACHE_DIR" )'
          assert_includes File.read(post_commit_script), 'codex exec "${add_dir_args[@]}" -C "$refresh_root"'
          assert_includes File.read(post_commit_script), 'refresh_branch="${LLM_WIKI_REFRESH_BRANCH:-llm-wiki/refresh}"'
          assert_includes File.read(post_commit_script), 'mv -f "$queue_tmp" "$pending_dir/$sha"'
          refute_includes File.read(post_commit_script), 'wiki_root="$main_checkout"'
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_CACHE_DIR"
          assert_includes File.read(post_commit_script), 'export XDG_CACHE_HOME="$state_dir/cache"'
          assert_includes File.read(post_commit_script), "LLM_WIKI_CODEX_TIMEOUT"
          assert_includes File.read(post_commit_script), "LLM_WIKI_QMD_TIMEOUT"
          assert_includes File.read(post_commit_script), "git rev-parse --local-env-vars"
          assert_includes File.read(post_commit_script), 'run_without_git_env "$timeout_bin" -k "$kill_after"'
          assert_includes File.read(post_commit_script), 'if [ "$drain_mode" -eq 1 ]; then'
          assert_includes File.read(post_commit_script), "scheduled drain skipped; no queued sources"
          assert_includes File.read(post_commit_script), "qmd embed --max-docs-per-batch 64 --max-batch-mb 64"
          assert_includes File.read(post_commit_script), "Do not run\nqmd; the wrapper handles bounded index maintenance"
          assert_includes File.read(post_commit_script), "wiki/log.d/<timestamp>-<slug>.md"
          assert_includes File.read(post_commit_script), "without\nediting compiled wiki/log.md"
          refute_includes File.read(post_commit_script), "QMD_LLAMA_GPU"

          common_dir = Hive::LlmWikiBootstrap.git_common_dir(dir)
          shared_dir = File.join(common_dir, "llm-wiki")
          shared_post_commit = File.join(shared_dir, "post-commit-refresh.sh")
          shared_compile_log = File.join(shared_dir, "compile-log.sh")
          shared_config = File.join(shared_dir, "config.json")
          shared_scheduler_service = File.join(shared_dir, "scheduler-service")
          assert_equal File.binread(post_commit_script), File.binread(shared_post_commit)
          assert_equal File.binread(compile_log_script), File.binread(shared_compile_log)
          assert_equal File.binread(File.join(dir, ".llm-wiki", "config.json")), File.binread(shared_config)
          assert File.executable?(shared_post_commit)
          assert File.executable?(shared_compile_log)
          assert_match(/\Allm-wiki-.+\.service\n\z/, File.read(shared_scheduler_service))

          hook = File.read(File.join(common_dir, "hooks", "post-commit"))
          assert_includes hook, "# BEGIN LLM WIKI POST-COMMIT"
          assert_includes hook, 'shared_runner="$common_dir/llm-wiki/post-commit-refresh.sh"'
          assert_includes hook, 'local_runner="$project_root/.llm-wiki/post-commit-refresh.sh"'
          assert_includes hook, '"$shared_runner" --project "$project_root"'
          assert_operator hook.index('"$shared_runner" --project "$project_root"'), :<,
                          hook.index('"$local_runner" --project "$project_root"')

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
      shared_cfg = JSON.parse(
        File.read(File.join(Hive::LlmWikiBootstrap.git_common_dir(dir), "llm-wiki", "config.json"))
      )
      assert_equal cfg, shared_cfg
    end
  end

  def test_llm_wiki_bootstrap_replaces_stale_main_wiki_path_when_fallback_exists
    with_tmp_home do |global_home|
      with_tmp_git_repo do |dir|
        config_dir = File.join(dir, ".llm-wiki")
        fallback = File.join(global_home, "wikis", "master", "wiki")
        FileUtils.mkdir_p(config_dir)
        FileUtils.mkdir_p(fallback)
        File.write(
          File.join(config_dir, "config.json"),
          JSON.pretty_generate("main_wiki_path" => File.join(global_home, "missing", "wiki"))
        )

        Hive::LlmWikiBootstrap.ensure_config(dir)

        cfg = JSON.parse(File.read(File.join(config_dir, "config.json")))
        assert_equal fallback, cfg.fetch("main_wiki_path")
      end
    end
  end

  def test_llm_wiki_bootstrap_preserves_existing_custom_main_wiki_path
    with_tmp_home do |global_home|
      with_tmp_git_repo do |dir|
        config_dir = File.join(dir, ".llm-wiki")
        custom = File.join(global_home, "custom-wiki")
        FileUtils.mkdir_p(config_dir)
        FileUtils.mkdir_p(custom)
        FileUtils.mkdir_p(File.join(global_home, "wikis", "master", "wiki"))
        File.write(
          File.join(config_dir, "config.json"),
          JSON.pretty_generate("main_wiki_path" => custom)
        )

        Hive::LlmWikiBootstrap.ensure_config(dir)

        cfg = JSON.parse(File.read(File.join(config_dir, "config.json")))
        assert_equal custom, cfg.fetch("main_wiki_path")
      end
    end
  end

  def test_llm_wiki_shared_runtime_copy_is_safe_with_utf8_default_internal_encoding
    with_tmp_git_repo do |dir|
      original_internal = Encoding.default_internal
      Encoding.default_internal = Encoding::UTF_8

      Hive::LlmWikiBootstrap.ensure_config(dir)
      Hive::LlmWikiBootstrap.ensure_refresh_scripts(dir)
      Hive::LlmWikiBootstrap.ensure_shared_runtime(dir)

      common_dir = Hive::LlmWikiBootstrap.git_common_dir(dir)
      local_compile_log = File.join(dir, ".llm-wiki", "compile-log.sh")
      shared_compile_log = File.join(common_dir, "llm-wiki", "compile-log.sh")
      assert_equal File.binread(local_compile_log), File.binread(shared_compile_log)
    ensure
      Encoding.default_internal = original_internal
    end
  end

  def test_llm_wiki_shared_runtime_uses_primary_worktree_instead_of_stale_linked_copy
    with_tmp_git_repo do |dir|
      linked_dir = "#{dir}-linked-runtime"
      Hive::LlmWikiBootstrap.ensure_config(dir)
      Hive::LlmWikiBootstrap.ensure_refresh_scripts(dir)
      run!("git", "-C", dir, "add", ".llm-wiki")
      run!("git", "-C", dir, "commit", "-m", "add managed wiki runtime", "--quiet")
      run!("git", "-C", dir, "worktree", "add", "-b", "linked-runtime-test", linked_dir, "HEAD", "--quiet")

      linked_config = File.join(linked_dir, ".llm-wiki", "config.json")
      linked_runner = File.join(linked_dir, ".llm-wiki", "post-commit-refresh.sh")
      File.binwrite(linked_config, "{\"stale_linked_copy\":true}\n")
      File.binwrite(linked_runner, "#!/usr/bin/env bash\n# stale linked runner\n")

      Hive::LlmWikiBootstrap.ensure_shared_runtime(linked_dir)

      shared_dir = File.join(Hive::LlmWikiBootstrap.git_common_dir(dir), "llm-wiki")
      assert_equal File.binread(File.join(dir, ".llm-wiki", "config.json")),
                   File.binread(File.join(shared_dir, "config.json"))
      assert_equal File.binread(File.join(dir, ".llm-wiki", "post-commit-refresh.sh")),
                   File.binread(File.join(shared_dir, "post-commit-refresh.sh"))
      refute_includes File.binread(File.join(shared_dir, "config.json")), "stale_linked_copy"
      refute_includes File.binread(File.join(shared_dir, "post-commit-refresh.sh")), "stale linked runner"
    ensure
      if linked_dir && File.directory?(linked_dir)
        Open3.capture3("git", "-C", dir, "worktree", "remove", "--force", linked_dir)
      end
    end
  end

  def test_llm_wiki_runtime_hook_install_restores_local_and_shared_runtime_first
    with_tmp_git_repo do |dir|
      Hive::LlmWikiBootstrap.install_runtime_hooks!(dir)

      local_dir = File.join(dir, ".llm-wiki")
      shared_dir = File.join(Hive::LlmWikiBootstrap.git_common_dir(dir), "llm-wiki")
      %w[post-commit-refresh.sh compile-log.sh].each do |name|
        assert_equal File.binread(File.join(local_dir, name)), File.binread(File.join(shared_dir, name))
        assert File.executable?(File.join(shared_dir, name))
      end
      assert_equal File.binread(File.join(local_dir, "config.json")),
                   File.binread(File.join(shared_dir, "config.json"))
      assert File.exist?(File.join(Hive::LlmWikiBootstrap.git_common_dir(dir), "hooks", "post-commit"))
    end
  end

  def test_llm_wiki_common_hook_prefers_shared_runner_for_linked_worktree
    with_tmp_git_repo do |dir|
      linked_dir = nil
      Hive::LlmWikiBootstrap.install!(dir, scheduler: false)
      common_dir = Hive::LlmWikiBootstrap.git_common_dir(dir)
      shared_runner = File.join(common_dir, "llm-wiki", "post-commit-refresh.sh")
      linked_dir = "#{dir}-linked"
      runner_log = File.join(dir, "runner.log")

      File.write(shared_runner, <<~BASH)
        #!/usr/bin/env bash
        printf 'shared:%s\n' "$*" > "${HIVE_TEST_SHARED_RUNNER_LOG:?}"
      BASH
      File.chmod(0o755, shared_runner)
      run!("git", "-C", dir, "worktree", "add", "-b", "linked-wiki-test", linked_dir, "HEAD", "--quiet")
      local_runner = File.join(linked_dir, ".llm-wiki", "post-commit-refresh.sh")
      FileUtils.mkdir_p(File.dirname(local_runner))
      File.write(local_runner, <<~BASH)
        #!/usr/bin/env bash
        printf 'stale:%s\n' "$*" > "${HIVE_TEST_SHARED_RUNNER_LOG:?}"
      BASH
      File.chmod(0o755, local_runner)
      File.write(File.join(linked_dir, "linked-change.md"), "linked worktree\n")
      run!("git", "-C", linked_dir, "add", "linked-change.md")

      with_env("HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "0", "HIVE_TEST_SHARED_RUNNER_LOG" => runner_log) do
        run!("git", "-C", linked_dir, "commit", "-m", "linked worktree change", "--quiet")
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.02 until File.exist?(runner_log) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      assert File.exist?(runner_log), "the common hook should launch the shared runner"
      assert_equal "shared:--project #{linked_dir}\n", File.read(runner_log)
    ensure
      if dir && linked_dir && File.directory?(linked_dir)
        run!("git", "-C", dir, "worktree", "remove", "--force", linked_dir)
      end
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
    shared_runner = File.join(Hive::LlmWikiBootstrap.git_common_dir(project_dir), "llm-wiki", "post-commit-refresh.sh")
    assert_includes service_contents, "ConditionFileIsExecutable=#{shared_runner}"
    assert_includes service_contents, "WorkingDirectory=#{project_dir}"
    flock_path = Hive::LlmWikiBootstrap::Scheduler.executable_path("flock")
    assert_includes service_contents,
                    "ExecStart=#{flock_path} --nonblock --conflict-exit-code 0 " \
                    "%t/llm-wiki-refresh.lock #{shared_runner} --project #{project_dir} --drain"
    assert_includes service_contents, "TimeoutStartSec=4h"
    assert_includes service_contents, "MemoryMax=4G"
    assert_includes service_contents, "MemorySwapMax=0"
    assert_includes service_contents, "Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1"
    refute_includes service_contents, 'WorkingDirectory="'
    timer_contents = File.read(timer)
    assert_includes timer_contents, "X-HiveManaged=yes"
    assert_includes timer_contents, "OnActiveSec=10min"
    assert_includes timer_contents, "OnUnitActiveSec=1d"
    assert_includes timer_contents, "RandomizedDelaySec=6h"
    refute_includes timer_contents, "OnBootSec="
    refute_includes timer_contents, "Persistent=true"
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
        git_common_dir = run!("git", "-C", dir, "rev-parse", "--git-common-dir").strip
        git_common_dir = File.expand_path(git_common_dir, dir)
        refresh_log_path = File.join(git_common_dir, "llm-wiki", "post-commit-refresh.log")
        refresh_log = File.exist?(refresh_log_path) ? File.read(refresh_log_path) : "(missing)"
        env_var_names.each do |name|
          assert_includes log, "codex:#{name}=\n",
                          "codex must observe scrubbed #{name}; refresh log:\n#{refresh_log}"
          assert_includes log, "qmd:#{name}=\n",
                          "qmd must observe scrubbed #{name}; refresh log:\n#{refresh_log}"
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
        assert_equal 28_800,       cfg.dig("review", "max_wall_clock_sec")

        raw = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
        refute raw.fetch("open_pr").key?("agent")
        refute raw.dig("review", "ci").key?("agent")
        refute raw.dig("review", "fix").key?("agent")
        assert_equal "claude", raw.dig("review", "triage", "agent")
        assert_equal "claude", raw.dig("review", "browser_test", "agent")
      end
    end
  end

  def test_generated_config_loads_with_project_workflow_stage_override
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        workflows_dir = File.join(dir, ".hive-state", "workflows")
        instruction_dir = File.join(workflows_dir, "delivery")
        FileUtils.mkdir_p(instruction_dir)
        File.write(File.join(instruction_dir, "assemble.md"), "Assemble the delivery.\n")
        File.write(File.join(workflows_dir, "delivery.yml"), <<~YAML)
          id: delivery
          stages:
            - name: inbox
              kind: terminal
              state_file: idea.md
            - name: assemble
              kind: agent
              state_file: assemble.md
              instruction: ./delivery/assemble.md
            - name: done
              kind: terminal
              state_file: task.md
        YAML

        config_path = File.join(dir, ".hive-state", "config.yml")
        raw = YAML.safe_load(File.read(config_path))
        raw["assemble"] = { "agent" => "codex", "timeout_sec" => 75 }
        File.write(config_path, raw.to_yaml)

        cfg = Hive::Config.load(dir)

        assert_equal({ "agent" => "codex", "timeout_sec" => 75 }, cfg.fetch("assemble"))
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

  def test_init_renders_recommended_refactor_patrol_with_auto_fix_and_issue_output
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        out, _err = capture_io { Hive::Commands::Init.new(dir).call }
        raw = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
        resolved = Hive::Config.load(dir)

        assert_equal true, raw.dig("refactor_patrol", "enabled")
        assert_equal true, raw.dig("refactor_patrol", "auto_fix", "enabled")
        assert_nil raw.dig("refactor_patrol", "commands", "public_contract")
        assert_equal true, raw.dig("refactor_patrol", "issue_filing", "enabled")
        assert_equal true, resolved.dig("refactor_patrol", "enabled")
        assert_nil resolved.dig("refactor_patrol", "commands", "public_contract")
        assert_includes out, "architecture patrol"
        assert_includes out, "enabled"
      end
    end
  end

  def test_init_explicitly_disables_refactor_patrol_before_writing_state
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir, refactor_patrol: false).call }
        raw = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))

        assert_equal false, raw.dig("refactor_patrol", "enabled")
        assert_equal false, raw.dig("refactor_patrol", "auto_fix", "enabled")
        assert_equal false, raw.dig("refactor_patrol", "issue_filing", "enabled")
      end
    end
  end

  def test_refactor_patrol_init_selectors_reject_every_existing_project_reinit_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        state_root = File.join(dir, ".hive-state")
        config_path = File.join(state_root, "config.yml")
        before_config = File.binread(config_path)
        before_head = run!("git", "-C", state_root, "rev-parse", "HEAD")

        [
          { refactor_patrol: false },
          { workflow: "coding", refactor_patrol: false },
          { new_workflow: "writing", refactor_patrol: true }
        ].each do |options|
          error = assert_raises(Hive::ConfigError) do
            capture_io { Hive::Commands::Init.new(dir, **options).call }
          end
          assert_match(/only valid for a fresh project/, error.message)
          assert_match(/refactor_patrol\.enabled/, error.message)
        end

        assert_equal before_config, File.binread(config_path)
        assert_equal before_head, run!("git", "-C", state_root, "rev-parse", "HEAD")
        refute File.exist?(File.join(state_root, "workflows", "writing.yml")),
               "a rejected existing-project selector must not scaffold a workflow"
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

  def default_setup_prompt_input
    (([ "" ] * 12) + ([ "" ] * Hive::Commands::Init::Prompts::LIMIT_KEYS.size) +
      [ "", "", "", "" ]).join("\n") + "\n"
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

  def with_tmp_linked_git_worktree
    with_tmp_git_repo do |main_dir|
      linked_dir = File.join(File.dirname(main_dir), "#{File.basename(main_dir)}-linked")
      run!("git", "-C", main_dir, "worktree", "add", "-b", "init-rollback-linked", linked_dir, "HEAD", "--quiet")
      yield(main_dir, linked_dir)
    ensure
      if linked_dir && File.directory?(linked_dir)
        _out, _err, status = Open3.capture3("git", "-C", main_dir, "worktree", "remove", "--force", linked_dir)
        FileUtils.rm_rf(linked_dir) unless status.success?
      end
    end
  end

  def fail_linked_init_after_bootstrap(linked_dir)
    command = Hive::Commands::Init.new(linked_dir)
    ops = Hive::GitOps.new(linked_dir)
    _out, err = capture_io do
      error = assert_raises(RuntimeError) do
        command.send(
          :initialize_project_state,
          ops,
          content: "---\nhive_state_path: .hive-state\n"
        ) { raise "boom after shared runtime install" }
      end
      assert_equal "boom after shared runtime install", error.message
    end
    assert_includes err, "partial init failed; rolled back"
  end

  def test_init_with_piped_user_choices_writes_matching_config
    # Order matches Prompts#collect. Choose codex for planning, default
    # claude_mode, codex for development, safetyist triage, only first +
    # third normal reviewer, default patrol reviewer, high patrol mode, override `plan`
    # budget/timeout, keep ad-hoc PR auto-fix disabled, accept the rest.
    inputs = [
      "codex", "", "", "", "", "2", "1,3", "", "high", "safetyist",
      "", "", "", "30,900", "", "", "", "", "", "", "", "",
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
        assert_equal true, cfg.dig("review", "github_publish", "enabled")
        assert_equal false, cfg.dig("review", "adhoc", "fix")
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
    # triage=blank, ad-hoc auto-fix=blank, architecture patrol=blank,
    # limit blanks, daemon-enable=blank,
    # babysitter-enable=blank, daemon-autostart=blank, confirm=blank.
    inputs = ([ "", "2", "", "", "", "", "", "", "", "", "", "" ] +
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
    # dev/reviewers/patrol_reviewers/patrol_mode/triage/ad-hoc auto-fix/
    # architecture patrol=blank, limits blank,
    # daemon/babysitter/autostart/confirm blank.
    inputs = ([ "", "", "2", "", "", "", "", "", "", "", "", "" ] +
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
    # reviewers, patrol reviewers, patrol mode, triage bias, ad-hoc auto-fix,
    # architecture patrol, limits. Then "n" for daemon-enable and blanks for
    # babysitter-enable, daemon-autostart, and confirm.
    inputs = (([ "" ] * (12 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
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
    # reviewers, patrol reviewers, patrol mode, triage bias, ad-hoc auto-fix,
    # architecture patrol, limits, daemon-enable, babysitter-enable,
    # daemon-autostart.
    inputs = (([ "" ] * (15 + Hive::Commands::Init::Prompts::LIMIT_KEYS.size)) +
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

  def test_init_late_failure_in_linked_worktree_restores_existing_common_llm_wiki_runtime
    with_tmp_global_config do
      with_tmp_linked_git_worktree do |_main_dir, linked_dir|
        assert File.file?(File.join(linked_dir, ".git")), "linked worktree must exercise a .git file"

        common_dir = Hive::LlmWikiBootstrap.git_common_dir(linked_dir)
        hook_path = File.join(common_dir, "hooks", "post-commit")
        shared_dir = File.join(common_dir, "llm-wiki")
        shared_runner = File.join(shared_dir, "post-commit-refresh.sh")
        shared_compile_log = File.join(shared_dir, "compile-log.sh")
        shared_config = File.join(shared_dir, "config.json")
        unrelated_state = File.join(shared_dir, "pending", "keep-me")

        original_hook = "#!/usr/bin/env bash\n# existing project hook\n"
        original_runner = "#!/usr/bin/env bash\n# existing shared runner\n"
        original_compile_log = "#!/usr/bin/env bash\n# existing shared log compiler\n"
        original_config = "{\"existing\":true}\n"
        FileUtils.mkdir_p(File.dirname(hook_path))
        File.binwrite(hook_path, original_hook)
        File.chmod(0o751, hook_path)
        FileUtils.mkdir_p(File.dirname(unrelated_state))
        File.binwrite(shared_runner, original_runner)
        File.chmod(0o701, shared_runner)
        File.binwrite(shared_compile_log, original_compile_log)
        File.chmod(0o705, shared_compile_log)
        File.binwrite(shared_config, original_config)
        File.chmod(0o604, shared_config)
        File.binwrite(unrelated_state, "queued state that init does not own\n")
        File.chmod(0o640, unrelated_state)
        File.chmod(0o710, shared_dir)

        fail_linked_init_after_bootstrap(linked_dir)

        assert_equal original_hook, File.binread(hook_path)
        assert_equal 0o751, File.stat(hook_path).mode & 0o7777
        assert_equal original_runner, File.binread(shared_runner)
        assert_equal 0o701, File.stat(shared_runner).mode & 0o7777
        assert_equal original_compile_log, File.binread(shared_compile_log)
        assert_equal 0o705, File.stat(shared_compile_log).mode & 0o7777
        assert_equal original_config, File.binread(shared_config)
        assert_equal 0o604, File.stat(shared_config).mode & 0o7777
        assert_equal "queued state that init does not own\n", File.binread(unrelated_state)
        assert_equal 0o640, File.stat(unrelated_state).mode & 0o7777
        assert_equal 0o710, File.stat(shared_dir).mode & 0o7777
        assert_equal "", run!("git", "-C", linked_dir, "status", "--porcelain").strip
      end
    end
  end

  def test_init_late_failure_in_linked_worktree_removes_new_common_llm_wiki_runtime
    with_tmp_global_config do
      with_tmp_linked_git_worktree do |_main_dir, linked_dir|
        common_dir = Hive::LlmWikiBootstrap.git_common_dir(linked_dir)
        hook_path = File.join(common_dir, "hooks", "post-commit")
        shared_dir = File.join(common_dir, "llm-wiki")
        refute File.exist?(hook_path)
        refute File.exist?(shared_dir)

        fail_linked_init_after_bootstrap(linked_dir)

        refute File.exist?(hook_path), "rollback must remove the hook created by failed init"
        refute File.exist?(shared_dir), "rollback must remove the entire newly created shared runtime directory"
        refute File.exist?(File.join(linked_dir, ".llm-wiki", "post-commit-refresh.sh")),
               "rollback must leave no checkout-local runner that a future commit could launch"
        assert_equal "", run!("git", "-C", linked_dir, "status", "--porcelain").strip
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
        with_env("HIVE_INVOKED_BIN" => nil) do
          $PROGRAM_NAME = hive
          assert_equal hive, Hive::Commands::Init.new(dir).send(:current_binary_path)
        end
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
