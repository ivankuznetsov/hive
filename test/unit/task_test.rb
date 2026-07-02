require "test_helper"
require "hive/config"
require "hive/task"

class TaskTest < Minitest::Test
  include HiveTestHelper

  def test_parses_valid_path
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      assert_equal "add-foo", task.slug
      assert_equal "brainstorm", task.stage_name
      assert_equal 2, task.stage_index
      assert_equal File.join(folder, "brainstorm.md"), task.state_file
      assert_equal dir, task.project_root
    end
  end

  def test_path_helpers_use_task_and_state_directories
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)

      assert_equal File.join(folder, ".lock"), task.lock_file
      assert_equal File.join(dir, ".hive-state", ".commit-lock"), task.commit_lock_file
    end
  end

  def test_state_file_per_stage
    with_tmp_dir do |dir|
      mappings = {
        "1-inbox" => "idea.md",
        "2-brainstorm" => "brainstorm.md",
        "3-plan" => "plan.md",
        "4-execute" => "task.md",
        "5-open-pr" => "pr.md",
        "6-review" => "task.md",
        "7-artifacts" => "artifact.md",
        "8-finalize" => "pr.md",
        "9-done" => "task.md"
      }
      mappings.each do |stage_dir, state_file|
        folder = File.join(dir, ".hive-state", "stages", stage_dir, "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        task = Hive::Task.new(folder)
        stage_name = stage_dir.split("-", 2).last

        assert_equal :coding, task.workflow.id
        # Anchor against an independent literal — comparing task.stage_names to
        # Hive::Task::STAGE_NAMES would be self-referential (both derive from
        # Registry.default).
        assert_equal %w[inbox brainstorm plan execute open-pr review artifacts finalize done],
                     task.stage_names
        assert_equal File.join(folder, Hive::Task::STATE_FILES.fetch(stage_name)), task.state_file
        assert_equal state_file, File.basename(task.state_file)
      end
    end
  end

  def test_rejects_stage_index_mismatch
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "3-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/stage directory 3-brainstorm/, error.message)
      assert_match(/expected 2-brainstorm/, error.message)
    end
  end

  def test_invalid_path_without_hive_state_segment
    assert_raises(Hive::InvalidTaskPath) { Hive::Task.new("/tmp/random/path") }
  end

  def test_invalid_path_without_slug
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm")
      FileUtils.mkdir_p(folder)
      assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
    end
  end

  def test_invalid_stage_format
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
    end
  end

  def test_invalid_stage_name
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-nonsense", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_match(/unknown stage name: 4-nonsense/, error.message)
      assert_match(/workflow :coding/, error.message)
    end
  end

  def test_unknown_stage_name_validates_against_resolved_non_coding_workflow
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        # research has no `execute` stage; the raise must name the RESOLVED
        # workflow (:research), not Registry.default (:coding).
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "4-execute", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)

        error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

        assert_match(/unknown stage name: 4-execute/, error.message)
        assert_match(/workflow :research/, error.message)
      end
    end
  end

  def test_stage_index_mismatch_validates_against_resolved_non_coding_workflow
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        # `gather` is index 2 in research; a 1-gather dir is an index mismatch
        # that must be measured against the resolved workflow, not coding.
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "1-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)

        error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

        assert_match(/stage directory 1-gather/, error.message)
        assert_match(/expected 2-gather/, error.message)
        assert_match(/workflow :research/, error.message)
      end
    end
  end

  def test_meta_workflow_selector_resolves_task_workflow
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: research\n")

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
        assert_equal %w[intake gather report], task.stage_names
        assert_equal File.join(folder, "notes.md"), task.state_file
      end
    end
  end

  # A per-task `workflow:` pin to a descriptor that was SKIPPED at load (here a
  # bad stage kind) must surface its REAL ConfigError, not a misleading
  # UnknownWorkflow → InvalidTaskPath "unknown workflow" — the same boundary
  # rule the `--workflow` / `hive init` path uses (U9-3). resolve_workflow now
  # routes the pin through Project.assert_descriptor_loadable! to re-raise it.
  def test_meta_workflow_pin_to_malformed_descriptor_surfaces_real_config_error
    with_tmp_dir do |dir|
      Hive::Workflows::Project.reset!
      workflows_dir = File.join(dir, ".hive-state", "workflows")
      FileUtils.mkdir_p(workflows_dir)
      File.write(File.join(workflows_dir, "badflow.yml"), <<~YAML)
        id: badflow
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: boguskind
            state_file: work.md
      YAML
      folder = File.join(dir, ".hive-state", "stages", "2-work", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: badflow\n")

      error = nil
      capture_io do
        error = assert_raises(Hive::ConfigError) { Hive::Task.new(folder) }
      end

      assert_match(/boguskind/, error.message,
                   "the pin must surface the descriptor's real parse error, not 'unknown workflow'")
      refute_match(/unknown workflow/, error.message)
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  def test_project_default_workflow_resolves_fieldless_task
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
        assert_equal %w[intake gather report], task.stage_names
        assert_equal File.join(folder, "notes.md"), task.state_file
      end
    end
  end

  # The (mtime, size) cache stamp must invalidate when a long-lived reader's
  # config.yml is rewritten mid-run. Force the SAME mtime so only the file size
  # differs — proving the size component closes the coarse-mtime window where
  # mtime-alone keying would serve the stale default until process restart.
  def test_project_default_workflow_cache_invalidates_on_same_mtime_size_change
    Hive::Task.project_default_workflow_cache.clear
    with_tmp_dir do |dir|
      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      cfg = File.join(state, "config.yml")
      File.write(cfg, "default_workflow: coding\n")
      folder = File.join(state, "stages", "2-brainstorm", "x-260620-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      original_mtime = File.mtime(cfg)

      assert_equal "coding", task.send(:project_default_workflow)

      # Rewrite to a longer default but force the original mtime back, so the
      # cache can only notice the change via the size component of the stamp.
      File.write(cfg, "default_workflow: research\n")
      File.utime(File.atime(cfg), original_mtime, cfg)

      resolved = nil
      _out, err = capture_io { resolved = task.send(:project_default_workflow) }

      assert_equal "research", resolved,
                   "a same-mtime config rewrite that changes the file size must invalidate the cache"
      assert_includes err, "not a registered workflow"
    end
  end

  def test_blank_task_workflow_selector_falls_back_to_project_default
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: \"  \"\n")

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
      end
    end
  end

  def test_task_selector_wins_over_project_default_workflow
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        # Both selectors name a *different* known workflow: the per-task
        # meta.workflow must win over the project default (selector ||= default).
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: coding\n")
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: research\n")

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
      end
    end
  end

  def test_blank_project_default_workflow_resolves_to_coding
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: \"  \"\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)

      assert_equal :coding, task.workflow.id
    end
  end

  def test_unknown_workflow_selector_raises_invalid_task_path
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: nope\n")

      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/unknown workflow :nope/, error.message)
    end
  end

  def test_unknown_project_default_workflow_warns_and_raises_invalid_task_path
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: nope\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      error = nil
      _out, err = capture_io do
        error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
      end

      # D1 fail-loud is preserved (the typo'd default still raises)...
      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/unknown workflow :nope/, error.message)
      # ...but the whole-project blast radius is now observable via a warn.
      assert_match(/project default_workflow "nope"/, err)
      assert_match(/not a registered workflow/, err)
    end
  end

  def test_malformed_meta_yaml_falls_back_to_coding
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: [unterminated\n")

      task = nil
      _out, err = capture_io { task = Hive::Task.new(folder) }

      assert_equal :coding, task.workflow.id
      assert_match(/task_meta: failed to read/, err)
    end
  end

  def test_broken_project_config_default_workflow_falls_back_to_coding
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "dependency_gate_stage: 7-artifacts\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      task = nil
      _out, err = capture_io { task = Hive::Task.new(folder) }

      assert_equal :coding, task.workflow.id
      assert_match(/failed to read default_workflow/, err)
      assert_match(/falling back to coding/, err)
    end
  end

  def test_malformed_project_config_yaml_falls_back_to_coding
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      # Unparseable YAML (unterminated flow sequence) exercises the
      # Psych::Exception arm of project_default_workflow's rescue, distinct from
      # the ConfigError arm covered above.
      File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: [unterminated\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      task = nil
      _out, err = capture_io { task = Hive::Task.new(folder) }

      assert_equal :coding, task.workflow.id
      assert_match(/failed to read default_workflow/, err)
      assert_match(/falling back to coding/, err)
    end
  end

  def test_worktree_path_uses_yml_when_present
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => "/some/where/add-foo", "branch" => "add-foo" }.to_yaml)
      task = Hive::Task.new(folder)
      assert_equal "/some/where/add-foo", task.worktree_path
    end
  end

  def test_meta_readers_use_sidecar_when_present
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"),
                 { "id" => 42, "slug" => "add-foo", "display_name" => "Add Foo" }.to_yaml)

      task = Hive::Task.new(folder)

      assert_equal File.join(folder, "meta.yml"), task.meta_yml_path
      assert_equal 42, task.id
      assert_equal "Add Foo", task.display_name
      assert_nil task.depends_on
      assert_equal "Add Foo", task.display_label
    end
  end

  def test_depends_on_reader_uses_sidecar
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"),
                 { "id" => 42, "slug" => "add-foo", "depends_on" => "base-task" }.to_yaml)

      task = Hive::Task.new(folder)

      assert_equal "base-task", task.depends_on
    end
  end

  def test_meta_readers_fall_back_when_sidecar_absent_or_malformed
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)
      assert_nil task.id
      assert_nil task.display_name
      assert_nil task.depends_on
      assert_equal "add-foo", task.display_label

      File.write(File.join(folder, "meta.yml"), ":\n:not yaml")
      # The U3 ctor reads meta eagerly, so the malformed-YAML warn fires here —
      # wrap in capture_io and assert it (matching the sibling tests above and
      # task_meta_test.rb) so it isn't leaked to stderr.
      _out, err = capture_io { task = Hive::Task.new(folder) }
      assert_nil task.id
      assert_nil task.display_name
      assert_nil task.depends_on
      assert_equal "add-foo", task.display_label
      assert_match(/depends_on, workflow dropped/, err)
    end
  end

  def test_worktree_path_returns_nil_for_low_stages
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      assert_nil task.worktree_path
    end
  end

  def test_worktree_path_derives_from_template_when_yml_absent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"),
                 { "worktree_root" => "/work/%{slug}" }.to_yaml)
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      derived = task.worktree_path
      assert_includes derived, "add-foo"
    end
  end
end
