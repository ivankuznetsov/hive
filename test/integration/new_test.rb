require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/task"
require "hive/task_counter"
require "hive/task_meta"

class NewTest < Minitest::Test
  include HiveTestHelper

  def setup_project
    @prev_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = @prev_stdout
  end

  def initialize_project(dir)
    Hive::Commands::Init.new(dir).call
  end

  def test_creates_idea_in_inbox
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        _, _err = capture_io { Hive::Commands::New.new(project, "add inbox filter").call }

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "add-inbox-filter-*")]
        assert_equal 1, glob.size, "expected one task folder, got #{glob.inspect}"
        idea = File.read(File.join(glob.first, "idea.md"))
        assert_includes idea, "add inbox filter"
        assert_includes idea, "<!-- WAITING -->"
        meta = Hive::TaskMeta.read(glob.first)
        assert_equal 1, meta[:id]
        assert_equal File.basename(glob.first), meta[:slug]
        assert_nil meta[:display_name]
        assert_nil meta[:depends_on]
        assert_nil meta[:workflow]
        refute_includes File.read(File.join(glob.first, "meta.yml")), "depends_on:"
        refute_includes File.read(File.join(glob.first, "meta.yml")), "workflow:"
        refute File.directory?(File.join(glob.first, "assets")),
               "plain CLI-compatible ideas must not create an empty assets directory"

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 1-inbox/add-inbox-filter-\d{6}-[0-9a-f]{4} captured\z}, log)
        diff_files = run!("git", "-C", File.join(dir, ".hive-state"), "show", "--name-only", "--format=")
        assert_includes diff_files, "stages/1-inbox/#{File.basename(glob.first)}/meta.yml"
      end
    end
  end

  def test_new_workflow_override_seeds_descriptor_entry_and_pins_meta
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          capture_io { Hive::Commands::New.new(project, "write article", workflow: "content_fixture").call }

          folders = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "write-article-*")]
          assert_equal 1, folders.size
          meta = Hive::TaskMeta.read(folders.first)
          assert_equal "content_fixture", meta[:workflow]
          assert_equal :content_fixture, Hive::Task.new(folders.first).workflow.id
          refute_includes File.read(File.join(folders.first, "idea.md")), "<!-- WAITING -->"
          assert_includes File.read(File.join(folders.first, "idea.md")), "<!-- COMPLETE -->"
        end
      end
    end
  end

  def test_new_workflow_override_with_agent_entry_seeds_markerless_state
    with_registered_workflow(agent_entry_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          capture_io { Hive::Commands::New.new(project, "agent entry task", workflow: "agent_entry").call }

          folders = Dir[File.join(dir, ".hive-state", "stages", "1-draft", "agent-entry-task-*")]
          assert_equal 1, folders.size
          state = File.read(File.join(folders.first, "draft.md"))
          refute_includes state, "<!-- WAITING -->"
          refute_includes state, "<!-- COMPLETE -->"
        end
      end
    end
  end

  def test_new_single_stage_workflow_prints_run_hint_without_move
    with_registered_workflow(single_stage_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          out, = capture_io { Hive::Commands::New.new(project, "single stage", workflow: "single").call }

          folder = Dir[File.join(dir, ".hive-state", "stages", "1-only", "single-stage-*")].first
          assert File.directory?(folder)
          assert_includes out, "next: hive run 1"
          refute_includes out, "next: mv"
        end
      end
    end
  end

  def test_new_without_override_in_non_coding_default_project_pins_effective_workflow
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }
          project = File.basename(dir)

          capture_io { Hive::Commands::New.new(project, "content default task").call }

          folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "content-default-task-*")].first
          assert_equal "content_fixture", Hive::TaskMeta.read(folder)[:workflow]
          assert_equal :content_fixture, Hive::Task.new(folder).workflow.id

          cfg_path = File.join(dir, ".hive-state", "config.yml")
          config = YAML.safe_load(File.read(cfg_path))
          config["default_workflow"] = "coding"
          File.write(cfg_path, config.to_yaml)

          assert_equal :content_fixture, Hive::Task.new(folder).workflow.id,
                       "pinned non-coding task must not re-resolve after project default changes"
        end
      end
    end
  end

  def test_new_workflow_override_allows_coding_in_non_coding_default_project
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }
          project = File.basename(dir)

          capture_io { Hive::Commands::New.new(project, "coding override task", workflow: "coding").call }

          folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "coding-override-task-*")].first
          assert_equal "coding", Hive::TaskMeta.read(folder)[:workflow]
          assert_equal :coding, Hive::Task.new(folder).workflow.id
          assert_includes File.read(File.join(folder, "idea.md")), "<!-- WAITING -->"
        end
      end
    end
  end

  def test_new_unknown_workflow_fails_without_seeding
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          _out, err, status = with_captured_exit do
            Hive::Commands::New.new(project, "bad workflow", workflow: "bogus").call
          end

          assert_equal Hive::ExitCodes::USAGE, status,
                       "a typo'd --workflow is a USAGE (64) error so an agent can tell it from a transient failure"
          assert_includes err, "unknown workflow \"bogus\""
          assert_includes err, "content_fixture"
          assert_empty Dir[File.join(dir, ".hive-state", "stages", "*", "bad-workflow-*")]
        end
      end
    end
  end

  def test_new_unregistered_project_default_names_config_without_seeding
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        # A hand-edit (or a later-removed workflow) leaves the project default
        # pointing at an unregistered workflow. Without an override, `hive new`
        # must fail with a typed error that names config.yml — not a bare
        # UnknownWorkflow that escapes the rescue and blocks all task creation.
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        config = YAML.safe_load(File.read(cfg_path))
        config["default_workflow"] = "ghost"
        File.write(cfg_path, config.to_yaml)

        _out, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "orphaned default").call
        end

        assert_equal 1, status
        assert_includes err, "config.yml"
        assert_includes err, "not a registered workflow"
        assert_empty Dir[File.join(dir, ".hive-state", "stages", "*", "orphaned-default-*")]
      end
    end
  end

  def test_new_corrupt_config_fails_typed_without_seeding
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        # A corrupt config.yml makes Config.load raise Psych::SyntaxError, which
        # is neither a Hive::Error nor in call's rescue list — it would crash
        # with a raw backtrace. It must instead fail with a typed error naming
        # config.yml, and seed nothing.
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: [unclosed\n")

        _out, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "corrupt config probe").call
        end

        assert_equal 1, status
        assert_includes err, "config.yml"
        assert_empty Dir[File.join(dir, ".hive-state", "stages", "*", "corrupt-config-probe-*")]
      end
    end
  end

  def test_new_with_explicit_workflow_ignores_corrupt_config
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          # An explicit --workflow never reads the project default, so a corrupt
          # config.yml must not block a fully-specified `hive new`.
          File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: [unclosed\n")

          capture_io { Hive::Commands::New.new(project, "explicit workflow", workflow: "content_fixture").call }

          folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "explicit-workflow-*")].first
          assert folder, "an explicit --workflow must create the task despite a corrupt config"
          assert_equal "content_fixture", Hive::TaskMeta.read(folder)[:workflow]
        end
      end
    end
  end

  def test_creates_idea_with_dependency
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        capture_io { Hive::Commands::New.new(project, "dependent task", depends_on: "base-task").call }

        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "dependent-task-*")].first
        assert_equal "base-task", Hive::TaskMeta.read(folder)[:depends_on]
        assert_includes File.read(File.join(folder, "meta.yml")), "depends_on: base-task"
      end
    end
  end

  def test_creates_ideas_with_numeric_and_cross_project_dependency_syntax
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        capture_io { Hive::Commands::New.new(project, "numeric dependency", depends_on: "42").call }
        capture_io do
          Hive::Commands::New.new(
            project,
            "cross project dependency",
            depends_on: "api:base-task"
          ).call
        end

        folders = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        dependencies = folders.map { |folder| Hive::TaskMeta.read(folder)[:depends_on] }
        assert_includes dependencies, "42"
        assert_includes dependencies, "api:base-task"
      end
    end
  end

  def test_rejects_numeric_cross_project_dependency
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        _, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "bad cross dependency", depends_on: "api:42").call
        end

        assert_equal 1, status
        assert_includes err, "project:slug"
      end
    end
  end

  def test_rejects_invalid_dependency
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        _, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "dependent task", depends_on: "../base").call
        end

        assert_equal 1, status
        assert_includes err, "invalid dependency"
        assert_empty Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "dependent-task-*")]
      end
    end
  end

  def test_two_new_ideas_receive_distinct_ids
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        capture_io { Hive::Commands::New.new(project, "first task").call }
        capture_io { Hive::Commands::New.new(project, "second task").call }

        ids = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
              .map { |folder| Hive::TaskMeta.read(folder)[:id] }
        assert_equal [ 1, 2 ], ids.sort
      end
    end
  end

  def test_new_serializes_hive_state_commit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        lock_paths = []

        with_replaced_singleton_method(
          Hive::Lock,
          :with_commit_lock,
          lambda do |path, &block|
            lock_paths << path
            block.call
          end
        ) do
          capture_io { Hive::Commands::New.new(project, "serialized capture").call }
        end

        assert_equal [ File.join(dir, ".hive-state") ], lock_paths
      end
    end
  end

  def test_counter_failure_writes_null_id_and_still_captures
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        error = Hive::ConcurrentRunError.new("busy", lock_path: "/tmp/counter")

        with_replaced_singleton_method(Hive::TaskCounter, :next!, -> { raise error }) do
          capture_io { Hive::Commands::New.new(project, "counter busy").call }
        end

        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "counter-busy-*")].first
        assert_nil Hive::TaskMeta.read(folder)[:id]
        assert File.exist?(File.join(folder, "idea.md"))
      end
    end
  end

  def test_spawns_name_generator_once_after_commit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        calls = []
        previous = Hive::Commands::New.instance_variable_get(:@name_generator_spawn)
        previous_bin = ENV["HIVE_BIN"]
        # Pin HIVE_BIN so the spawn argv is deterministic and we verify the
        # background generator resolves the same bin path the parent used
        # (matches StatusWatcher / ChildSupervisor), not a hardcoded "hive".
        ENV["HIVE_BIN"] = "/opt/hive/bin/hv"
        Hive::Commands::New.name_generator_spawn = lambda do |*argv, **opts|
          calls << [ argv, opts ]
          12_345
        end

        capture_io { Hive::Commands::New.new(project, "name me").call }

        assert_equal 1, calls.size
        argv, opts = calls.first
        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "name-me-*")].first
        assert_equal [ "/opt/hive/bin/hv", "generate-name", folder ], argv
        assert_equal true, opts[:pgroup]
        assert_equal "a", opts[:out].last
        assert_equal opts[:out], opts[:err]
      ensure
        Hive::Commands::New.name_generator_spawn = previous
        ENV["HIVE_BIN"] = previous_bin
      end
    end
  end

  def test_name_generator_spawn_failure_is_swallowed
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        previous = Hive::Commands::New.instance_variable_get(:@name_generator_spawn)
        Hive::Commands::New.name_generator_spawn = lambda do |*_argv, **_opts|
          raise Errno::ENOENT, "hive binary missing"
        end

        # A failure to spawn the background namer must not blow up `new`:
        # the task folder is still created and committed.
        capture_io { Hive::Commands::New.new(project, "spawn boom").call }

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "spawn-boom-*")]
        assert_equal 1, glob.size, "task must be created even when the name generator fails to spawn"
        assert File.exist?(File.join(glob.first, "idea.md")), "idea.md must be written despite spawn failure"
      ensure
        Hive::Commands::New.name_generator_spawn = previous
      end
    end
  end

  def test_unicode_text_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "добавить inbox фильтр").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        # Cyrillic strips to "inbox"; final slug starts with "inbox-".
        assert_match(/\Ainbox-/, File.basename(glob.first))
      end
    end
  end

  def test_only_punctuation_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "!!! ???").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        assert_match(/\Atask-\d{6}-[0-9a-f]{4}\z/, File.basename(glob.first))
      end
    end
  end

  def test_digit_leading_text_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        # The derived prefix "404-page-broken" leaves a digit as the leading
        # char, which fails SLUG_RE's leading-letter rule — derive_slug swaps
        # in the `task-` prefix rather than emit an invalid slug.
        capture_io { Hive::Commands::New.new(project, "404 page broken").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        assert_match(/\Atask-\d{6}-[0-9a-f]{4}\z/, File.basename(glob.first))
      end
    end
  end

  def test_very_long_words_do_not_overflow_slug_regex
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        # Two single "words" that together exceed the 64-char slug limit.
        long_text = "#{'a' * 80} #{'b' * 80}"
        capture_io { Hive::Commands::New.new(project, long_text).call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size, "long text must not cause new to reject its own derived slug"
        slug = File.basename(glob.first)
        assert_operator slug.length, :<=, 64, "derived slug must always fit SLUG_RE max length"
        assert_match(/\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/, slug)
      end
    end
  end

  def test_long_text_truncates_to_five_words
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "one two three four five six seven eight").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        slug = File.basename(glob.first)
        assert_match(/\Aone-two-three-four-five-\d{6}-[0-9a-f]{4}\z/, slug)
      end
    end
  end

  def test_unregistered_project_fails
    with_tmp_global_config do
      _, err, status = with_captured_exit { Hive::Commands::New.new("nope", "x").call }
      assert_equal 1, status
      assert_includes err, "not initialized"
    end
  end

  def test_call_bang_raises_typed_project_not_found
    with_tmp_global_config do
      err = assert_raises(Hive::Commands::New::ProjectNotFound) do
        Hive::Commands::New.new("nope", "x").call!
      end
      assert_includes err.message, "project not initialized"
    end
  end

  def test_slug_override
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "x", slug_override: "manual-slug-260424-aaaa").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox", "manual-slug-260424-aaaa"))
      end
    end
  end

  def test_invalid_slug_override_rejected
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        _, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "x", slug_override: "invalid_slug").call
        end
        assert_equal 1, status
        assert_includes err, "invalid slug"
      end
    end
  end

  def test_call_bang_raises_typed_invalid_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        assert_raises(Hive::Commands::New::InvalidSlugError) do
          Hive::Commands::New.new(project, "x", slug_override: "invalid_slug").call!
        end
      end
    end
  end

  def test_call_bang_raises_typed_reserved_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)

        err = assert_raises(Hive::Commands::New::InvalidSlugError) do
          Hive::Commands::New.new(project, "x", slug_override: "main").call!
        end

        assert_includes err.message, "reserved or unsafe slug"
        assert_equal "main", err.value
      end
    end
  end

  def test_call_bang_raises_typed_slug_collision
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        hive_state = File.join(dir, ".hive-state")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "1-inbox", "duplicate-slug"))

        err = assert_raises(Hive::Commands::New::SlugCollisionError) do
          Hive::Commands::New.new(project, "x", slug_override: "duplicate-slug").call!
        end

        assert_includes err.message, "slug collision"
        assert_equal "duplicate-slug", err.value
      end
    end
  end

  def test_body_override_and_attachments_are_captured_in_one_commit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        fixture = File.join(dir, "fixture.png")
        File.binwrite(fixture, "png-fixture".b)
        project = File.basename(dir)

        capture_io do
          Hive::Commands::New.new(
            project,
            "title",
            body_override: "see ![](assets/bug-1.png)",
            attachments: [ [ fixture, "bug-1.png" ] ]
          ).call!
        end

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "title-*")]
        assert_equal 1, glob.size
        idea = File.read(File.join(glob.first, "idea.md"))
        assert_includes idea, "original_text: |\n  title"
        assert_includes idea, "see ![](assets/bug-1.png)"
        refute_match(/^title$/m, idea.split("<!-- WAITING -->").first.lines.last(4).join)

        asset = File.join(glob.first, "assets", "bug-1.png")
        assert_equal "png-fixture", File.binread(asset)

        hive_state = File.join(dir, ".hive-state")
        log = run!("git", "-C", hive_state, "log", "--format=%s", "-1").strip
        assert_match(%r{\Ahive: 1-inbox/title-\d{6}-[0-9a-f]{4} captured\z}, log)
        diff_files = run!("git", "-C", hive_state, "show", "--name-only", "--format=")
        assert_includes diff_files, "stages/1-inbox/#{File.basename(glob.first)}/idea.md"
        assert_includes diff_files, "stages/1-inbox/#{File.basename(glob.first)}/assets/bug-1.png"
      end
    end
  end

  def test_attachments_accept_absolute_sources_outside_tmpdir
    source_dir = Dir.mktmpdir("hive-new-src-", Dir.home)
    begin
      fixture = File.join(source_dir, "fixture.png")
      File.binwrite(fixture, "outside-tmp".b)
      refute File.expand_path(fixture).start_with?("#{File.expand_path(Dir.tmpdir)}#{File::SEPARATOR}")

      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          setup_project { initialize_project(dir) }
          project = File.basename(dir)

          capture_io do
            Hive::Commands::New.new(
              project,
              "outside attachment",
              body_override: "see ![](assets/bug-1.png)",
              attachments: [ [ fixture, "bug-1.png" ] ]
            ).call!
          end

          glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "outside-attachment-*")]
          assert_equal 1, glob.size
          assert_equal "outside-tmp", File.binread(File.join(glob.first, "assets", "bug-1.png"))
        end
      end
    ensure
      FileUtils.rm_rf(source_dir) if source_dir
    end
  end

  # Defense-in-depth: copy_attachments! refuses dest_name values that
  # contain a directory separator or `..` segment so a malformed TUI
  # caller cannot escape `<task_dir>/assets/`. Raises the dedicated
  # `InvalidAttachmentError` (separate from real slug failures).
  def test_call_bang_rejects_dest_name_with_path_traversal
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        fixture = File.join(dir, "fixture.png")
        File.binwrite(fixture, "png".b)
        project = File.basename(dir)

        err = assert_raises(Hive::Commands::New::InvalidAttachmentError) do
          Hive::Commands::New.new(
            project,
            "title-traversal",
            attachments: [ [ fixture, "../escape.png" ] ]
          ).call!
        end
        assert_match(/invalid attachment filename/, err.message)
        # Rollback should have removed the partial task dir on failure.
        assert_empty Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "title-traversal-*")],
          "attachment guard failure must roll back the partial task directory"
      end
    end
  end

  def test_call_bang_rejects_dest_name_with_slash
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        fixture = File.join(dir, "fixture.png")
        File.binwrite(fixture, "png".b)
        project = File.basename(dir)

        err = assert_raises(Hive::Commands::New::InvalidAttachmentError) do
          Hive::Commands::New.new(
            project,
            "title-slash",
            attachments: [ [ fixture, "nested/file.png" ] ]
          ).call!
        end
        assert_match(/invalid attachment filename/, err.message)
      end
    end
  end
end
