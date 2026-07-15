require "test_helper"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/honeycomb/lockfile"
require "hive/workflows/loader"
require "hive/workflows/project"
require_relative "../support/honeycomb_registry_helper"

class HoneycombWorkflowManagementTest < Minitest::Test
  include HiveTestHelper
  include HoneycombRegistryHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_install_offline_list_update_noop_and_remove_lifecycle
    with_honeycomb_registry do |fixture|
      first = fixture.publish(version: "1.0.0", instruction: "old line\n")
      with_initialized_project do |project|
        registry = fixture.registry
        initial_commits = state_commit_count(project)

        install_out = StringIO.new
        installed = Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, stdout: install_out,
          yes: true, registry: registry
        ).call!

        assert_equal true, installed.fetch("changed")
        assert_equal first.fetch("sha"), installed.fetch("sha")
        assert_equal initial_commits + 1, state_commit_count(project)
        assert_equal %w[assets/badge.bin instructions/work.md workflow.yml], managed_files(project, "demo")
        refute File.exist?(File.join(workflows_dir(project), "demo", "manifest.yml"))
        entry = lock_entries(project).fetch("demo")
        assert_equal Hive::Honeycomb::SOURCE, entry.source
        assert_equal "1.0.0", entry.version
        assert_equal first.fetch("digest"), entry.digest
        assert_equal :demo, Hive::Workflows::Loader.load_dir(workflows_dir(project)).fetch(:demo).id

        no_network = Object.new
        no_network.define_singleton_method(:method_missing) do |name, *|
          raise "offline list touched registry collaborator: #{name}"
        end
        list_out = StringIO.new
        local = Hive::Commands::Workflow.new(
          "list", nil, project_root: project, stdout: list_out, registry: no_network,
          catalog_path: registry.catalog_path
        ).call!
        assert_equal false, local.fetch("workflows").first.fetch("update_available")
        assert_equal "clean", local.fetch("workflows").first.fetch("integrity")
        assert_includes list_out.string, "workflows/.honeycomb.lock#workflows.demo.security"

        second = fixture.publish(
          version: "2.0.0", instruction: "new line\nextra\n", tools: %w[Read Bash]
        )
        update_out = StringIO.new
        updated = Hive::Commands::Workflow.new(
          "update", "demo", project_root: project, stdout: update_out,
          yes: true, registry: registry
        ).call!
        assert_equal true, updated.fetch("changed")
        assert_includes update_out.string, "PERMISSION ESCALATION"
        assert_includes update_out.string, "-old line"
        assert_includes update_out.string, "+new line"
        assert_equal second.fetch("sha"), lock_entries(project).fetch("demo").sha
        assert_equal initial_commits + 2, state_commit_count(project)

        noop = Hive::Commands::Workflow.new(
          "update", "demo", project_root: project, stdout: StringIO.new,
          yes: true, registry: registry
        ).call!
        assert_equal false, noop.fetch("changed")
        assert_equal initial_commits + 2, state_commit_count(project)

        removed = Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: StringIO.new, yes: true
        ).call!
        assert_equal true, removed.fetch("changed")
        refute File.exist?(File.join(workflows_dir(project), "demo"))
        assert_empty lock_entries(project)
        assert_equal initial_commits + 3, state_commit_count(project)
      end
    end
  end

  def test_invalid_packages_and_missing_approval_preserve_installed_revision
    with_honeycomb_registry do |fixture|
      fixture.publish(version: "1.0.0", instruction: "safe\n")
      with_initialized_project do |project|
        registry = fixture.registry
        before = project_revision(project)
        approval_out = StringIO.new
        error = assert_raises(Hive::Honeycomb::ApprovalError) do
          Hive::Commands::Workflow.new(
            "install", "honeycomb/demo", project_root: project, stdout: approval_out,
            stdin: StringIO.new, registry: registry
          ).call!
        end
        assert_includes error.message, "--yes"
        assert_includes approval_out.string, "Install honeycomb/demo"
        assert_equal before, project_revision(project)

        Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, stdout: StringIO.new,
          yes: true, registry: registry
        ).call!
        installed = project_revision(project)
        fixture.publish(version: "2.0.0", instruction: "tampered\n", fault: :bad_hash)

        assert_raises(Hive::Honeycomb::IntegrityError) do
          Hive::Commands::Workflow.new(
            "update", "demo", project_root: project, stdout: StringIO.new,
            yes: true, registry: registry
          ).call!
        end
        assert_equal installed, project_revision(project)
      end
    end
  end

  def test_dirty_force_and_unknown_best_effort_removal_contracts
    with_honeycomb_registry do |fixture|
      fixture.publish(version: "1.0.0", instruction: "managed\n")
      with_initialized_project do |project|
        registry = fixture.registry
        Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, stdout: StringIO.new,
          yes: true, registry: registry
        ).call!
        instruction = File.join(workflows_dir(project), "demo", "instructions", "work.md")
        File.write(instruction, "local edit\n")

        assert_raises(Hive::Honeycomb::CollisionError) do
          Hive::Commands::Workflow.new(
            "remove", "demo", project_root: project, stdout: StringIO.new, yes: true
          ).call!
        end
        assert File.file?(instruction)
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: StringIO.new, yes: true, force: true
        ).call!
        refute File.exist?(File.join(workflows_dir(project), "demo"))

        Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, stdout: StringIO.new,
          yes: true, registry: registry
        ).call!
        FileUtils.rm_f(File.join(workflows_dir(project), ".honeycomb.lock"))
        _out, _err, status = with_captured_exit do
          Hive::Commands::Workflow.new(
            "remove", "demo", project_root: project, json: true, yes: true, force: true
          ).call
        end
        assert_equal Hive::ExitCodes::GENERIC, status
        refute File.exist?(File.join(workflows_dir(project), "demo"))
      end
    end
  end

  def test_adversarial_registry_trees_preserve_an_empty_project
    with_honeycomb_registry do |fixture|
      faults = %i[bad_hash undeclared symlink path_escape submodule invalid_descriptor]
      faults.each do |fault|
        fixture.publish(
          name: fault.to_s.tr("_", "-"), version: "1.0.0",
          instruction: "unsafe fixture\n", fault: fault
        )
      end
      with_initialized_project do |project|
        registry = fixture.registry
        before = project_revision(project)

        faults.each do |fault|
          name = fault.to_s.tr("_", "-")
          assert_raises(Hive::Error, "#{fault} must fail verification") do
            Hive::Commands::Workflow.new(
              "install", "honeycomb/#{name}", project_root: project,
              stdout: StringIO.new, yes: true, registry: registry
            ).call!
          end
          assert_equal before, project_revision(project), "#{fault} changed project state"
        end
      end
    end
  end

  def test_authored_collision_needs_force_and_builtin_ids_are_never_replaceable
    with_honeycomb_registry do |fixture|
      fixture.publish(version: "1.0.0", instruction: "managed replacement\n")
      fixture.publish(name: "coding", version: "1.0.0", instruction: "reserved\n")
      with_initialized_project do |project|
        registry = fixture.registry
        authored_root = File.join(workflows_dir(project), "demo")
        FileUtils.mkdir_p(authored_root)
        File.write(File.join(authored_root, "work.md"), "authored\n")
        File.write(File.join(workflows_dir(project), "demo.yml"), <<~YAML)
          id: demo
          stages:
            - name: work
              kind: agent
              state_file: work.md
              instruction: ./demo/work.md
            - name: done
              kind: terminal
              state_file: done.md
        YAML

        assert_raises(Hive::Honeycomb::CollisionError) do
          Hive::Commands::Workflow.new(
            "install", "honeycomb/demo", project_root: project, stdout: StringIO.new,
            yes: true, registry: registry
          ).call!
        end
        assert File.file?(File.join(workflows_dir(project), "demo.yml"))

        Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, stdout: StringIO.new,
          yes: true, force: true, registry: registry
        ).call!
        refute File.exist?(File.join(workflows_dir(project), "demo.yml"))
        assert File.file?(File.join(authored_root, "workflow.yml"))

        assert_raises(Hive::Honeycomb::CollisionError) do
          Hive::Commands::Workflow.new(
            "install", "honeycomb/coding", project_root: project, stdout: StringIO.new,
            yes: true, force: true, registry: registry
          ).call!
        end
      end
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project).call }
        yield project
      end
    end
  end

  def workflows_dir(project)
    File.join(project, ".hive-state", "workflows")
  end

  def managed_files(project, name)
    root = File.join(workflows_dir(project), name)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| %w[. ..].include?(File.basename(path)) }
      .select { |path| File.file?(File.join(root, path)) }.sort
  end

  def lock_entries(project)
    Hive::Honeycomb::Lockfile.new(File.join(workflows_dir(project), ".honeycomb.lock")).read
  end

  def state_commit_count(project)
    run!("git", "-C", File.join(project, ".hive-state"), "rev-list", "--count", "HEAD").strip.to_i
  end

  def project_revision(project)
    state = File.join(project, ".hive-state")
    [
      run!("git", "-C", state, "rev-parse", "HEAD").strip,
      run!("git", "-C", state, "status", "--porcelain=v1").lines.sort,
      Dir.glob("**/*", File::FNM_DOTMATCH, base: workflows_dir(project)).sort.filter_map do |relative|
        path = File.join(workflows_dir(project), relative)
        [ relative, File.binread(path) ] if File.file?(path)
      end
    ]
  end
end
