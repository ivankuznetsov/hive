require "test_helper"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/commands/workflow/git_install"

class WorkflowGitInstallTest < Minitest::Test
  include HiveTestHelper

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_installs_exact_git_objects_with_provenance_without_running_hooks
    with_source_and_project do |source, project|
      commit = run!("git", "-C", source, "rev-parse", "HEAD").strip
      report = install(source, project)
      state = File.join(project, ".hive-state")
      assert_equal "installed", report.fetch("status")
      assert_equal "authored", report.fetch("origin")
      assert_equal commit, report.fetch("source_commit")
      assert_schema(report)
      receipt = JSON.parse(File.read(File.join(state, "workflows/news/hive-source.json")))
      assert_equal commit, receipt.fetch("commit")
      assert_equal "Research this week.\n", File.read(File.join(state, "workflows/news/work.md"))
      assert File.executable?(File.join(state, "workflows/news/helper.sh"))
      refute File.exist?(File.join(state, "workflows/other.yml"))
      assert_equal "hive: workflows/news created", run!("git", "-C", state, "log", "-1", "--format=%s").strip
      assert_empty run!("git", "-C", state, "status", "--porcelain", "--", "workflows/news", "workflows/news.yml")
      validation = Hive::Commands::Workflow.new("validate", "news", project_root: project, stdout: StringIO.new).call!
      assert validation.fetch("valid")
    end
  end

  def test_preview_does_not_change_project_and_can_pin_an_older_commit
    with_source_and_project do |source, project|
      old = run!("git", "-C", source, "rev-parse", "HEAD").strip
      File.write(File.join(source, "workflows/news/work.md"), "Changed\n")
      run!("git", "-C", source, "commit", "-am", "new prompt")
      state = File.join(project, ".hive-state")
      before = run!("git", "-C", state, "rev-parse", "HEAD")
      before_status = run!("git", "-C", state, "status", "--porcelain")
      report = install(source, project, dry_run: true, ref: old)
      assert_equal "dry_run", report.fetch("status")
      assert_equal old, report.fetch("source_commit")
      assert_schema(report)
      assert_equal before, run!("git", "-C", state, "rev-parse", "HEAD")
      assert_equal before_status, run!("git", "-C", state, "status", "--porcelain")
      refute File.exist?(File.join(state, "workflows/news.yml"))
      install(source, project, ref: old)
      assert_equal "Research this week.\n", File.read(File.join(state, "workflows/news/work.md"))
    end
  end

  def test_cli_routes_private_source_preview_and_ref
    with_source_and_project do |source, project|
      commit = run!("git", "-C", source, "rev-parse", "HEAD").strip
      command = [ Gem.ruby, File.expand_path("../../../bin/hive", __dir__), "workflow", "install", "news",
                  "--from", source, "--ref", commit, "--dry-run", "--json" ]
      out, err, status = Open3.capture3(*command, chdir: project)
      assert status.success?, err
      report = JSON.parse(out)
      assert_equal commit, report.fetch("source_commit")
      assert_equal "dry_run", report.fetch("status")
      assert_schema(report)
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
    end
  end

  def test_existing_workflow_is_preserved
    with_source_and_project do |source, project|
      install(source, project)
      path = File.join(project, ".hive-state/workflows/news/work.md")
      File.write(path, "Owner edits\n")
      assert_raises(Hive::Commands::Workflow::OwnershipError) { install(source, project) }
      assert_equal "Owner edits\n", File.read(path)
    end
  end

  def test_rejects_symlinks_and_invalid_graph_before_writing
    with_source_and_project do |source, project|
      File.symlink("/etc/passwd", File.join(source, "workflows/news/link"))
      run!("git", "-C", source, "add", ".")
      run!("git", "-C", source, "commit", "-m", "link")
      assert_raises(Hive::ConfigError) { install(source, project) }
      refute File.exist?(File.join(project, ".hive-state/workflows/news"))
      run!("git", "-C", source, "rm", "workflows/news/link")
      File.write(File.join(source, "workflows/news.yml"), "id: news\nstages: []\n")
      run!("git", "-C", source, "commit", "-am", "invalid")
      assert_raises(Hive::ConfigError) { install(source, project) }
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
    end
  end

  def test_rejects_credential_urls_unsafe_refs_and_wrong_command_options
    with_source_and_project do |source, project|
      error = assert_raises(Hive::ConfigError) { install("https://secret@github.com/owner/repo", project) }
      refute_includes error.message, "secret@"
      assert_raises(Hive::ConfigError) { install(source, project, ref: "--upload-pack=evil") }
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("new", "news", project_root: project, from: source).call!
      end
    end
  end

  def test_commit_failure_removes_only_owned_import_files
    with_source_and_project do |source, project|
      unrelated = File.join(project, ".hive-state/workflows/keep.txt")
      FileUtils.mkdir_p(File.dirname(unrelated))
      File.write(unrelated, "keep\n")
      with_replaced_singleton_method(Hive::Commands::Workflow, :commit_workflow_scaffold, ->(*) { raise Hive::GitError, "commit failed" }) do
        assert_raises(Hive::GitError) { install(source, project) }
      end
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
      refute File.exist?(File.join(project, ".hive-state/workflows/news"))
      assert_equal "keep\n", File.read(unrelated)
    end
  end

  def test_rejects_managed_overrides_for_git_sources
    with_source_and_project do |source, project|
      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("install", "news", project_root: project,
                                    from: source, allow_escalation: true).call!
      end
      assert_includes error.message, "authored descriptor settings"
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
    end
  end

  def test_rejects_symlink_workflow_root_without_writing_to_target
    with_source_and_project do |source, project|
      root = File.join(project, ".hive-state/workflows")
      FileUtils.rm_rf(root)
      Dir.mktmpdir do |target|
        File.symlink(target, root)
        error = assert_raises(Hive::ConfigError) { install(source, project) }
        assert_includes error.message, "real directory"
        assert_empty Dir.children(target)
      end
    end
  end

  def test_invalid_id_is_reported_as_json_usage_error
    with_source_and_project do |source, project|
      output = StringIO.new
      command = Hive::Commands::Workflow::GitInstall.new(
        "../escape", repository: source, project_root: project, json: true, stdout: output
      )
      assert_raises(SystemExit) { command.call }
      report = JSON.parse(output.string)
      assert_equal "usage", report.fetch("error_kind")
      refute report.fetch("ok")
    end
  end

  def test_source_rejects_invalid_id_and_malformed_url_before_materializing
    Dir.mktmpdir do |destination|
      source = Hive::WorkflowPackage::GitSource.new(repository: "/unused")
      error = assert_raises(Hive::ConfigError) { source.fetch("../escape", destination: destination) }
      assert_includes error.message, "invalid Git workflow id"
      source = Hive::WorkflowPackage::GitSource.new(repository: "https://[invalid")
      error = assert_raises(Hive::ConfigError) { source.fetch("news", destination: destination) }
      assert_includes error.message, "invalid Git repository URL"
      assert_empty Dir.children(destination)
    end
  end

  def test_rejects_oversized_blob_before_installing
    with_source_and_project do |source, project|
      File.write(File.join(source, "workflows/news/large.txt"), "x" * (Hive::WorkflowPackage::Manifest::MAX_FILE_BYTES + 1))
      run!("git", "-C", source, "add", ".")
      run!("git", "-C", source, "commit", "-m", "oversized asset")
      error = assert_raises(Hive::ConfigError) { install(source, project) }
      assert_includes error.message, "package size limit"
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
    end
  end

  def test_missing_ref_emits_redacted_git_error_envelope
    with_source_and_project do |source, project|
      output = StringIO.new
      command = Hive::Commands::Workflow::GitInstall.new(
        "news", repository: source, ref: "missing-ref", project_root: project, json: true, stdout: output
      )
      assert_raises(SystemExit) { command.call }
      report = JSON.parse(output.string)
      assert_equal "git", report.fetch("error_kind")
      refute report.fetch("ok")
      refute File.exist?(File.join(project, ".hive-state/workflows/news.yml"))
    end
  end

  def test_git_timeout_and_missing_executable_are_actionable_without_raw_diagnostics
    { Timeout::Error => "timed out", Errno::ENOENT => "Git is required" }.each do |exception, message|
      Dir.mktmpdir do |destination|
        source = Hive::WorkflowPackage::GitSource.new(repository: "/unused")
        with_replaced_singleton_method(Hive::WorkflowPackage::RuntimePolicy, :capture3_bounded,
                                       ->(*) { raise exception, "private diagnostic" }) do
          error = assert_raises(Hive::GitError) { source.fetch("news", destination: destination) }
          assert_includes error.message, message
          refute_includes error.message, "private diagnostic"
          assert_empty Dir.children(destination)
        end
      end
    end
  end

  private

  def install(source, project, **options)
    Hive::Commands::Workflow::GitInstall.new(
      "news", repository: source, project_root: project, stdout: StringIO.new, json: true, **options
    ).call!
  end

  def assert_schema(report)
    schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-install")))
    assert_empty JSONSchemer.schema(schema).validate(report).to_a
  end

  def with_source_and_project
    with_tmp_global_config do
      with_tmp_git_repo do |source|
        FileUtils.mkdir_p(File.join(source, "workflows/news"))
        File.write(File.join(source, "workflows/news.yml"), <<~YAML)
          id: news
          stages:
            - name: inbox
              kind: terminal
              state_file: idea.md
            - name: research
              kind: agent
              state_file: research.md
              instruction: ./news/work.md
            - name: done
              kind: terminal
              state_file: research.md
        YAML
        File.write(File.join(source, "workflows/news/work.md"), "Research this week.\n")
        File.write(File.join(source, "workflows/news/helper.sh"), "#!/bin/sh\nexit 99\n")
        File.chmod(0o755, File.join(source, "workflows/news/helper.sh"))
        File.write(File.join(source, "workflows/other.yml"), "unrelated\n")
        run!("git", "-C", source, "add", ".")
        run!("git", "-C", source, "commit", "-m", "workflow")
        with_tmp_git_repo do |project|
          capture_io { Hive::Commands::Init.new(project).call }
          yield source, project
        end
      end
    end
  end
end
