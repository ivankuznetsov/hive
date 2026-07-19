require "test_helper"
require "hive/web/workflow_lifecycle"

class WebWorkflowLifecycleTest < Minitest::Test
  include HiveTestHelper

  CommandResult = Struct.new(:payload) do
    def call! = payload
  end
  Resolution = Data.define(:name, :version, :catalog_commit, :source_commit, :manifest_digest)

  def setup
    @root = Dir.mktmpdir("hive-web-workflow-lifecycle")
    @state = File.join(@root, ".hive-state")
    FileUtils.mkdir_p(File.join(@state, "stages"))
    File.write(
      File.join(@state, "config.yml"),
      { "hive_state_path" => ".hive-state", "default_workflow" => "demo" }.to_yaml
    )
    @project = { "path" => @root }
    @registry = Object.new
    @registry.define_singleton_method(:fetch) do |_source, destination:|
      FileUtils.mkdir_p(destination)
      @resolution
    end
    @lifecycle = Hive::Web::WorkflowLifecycle.new(registry_client_factory: -> { @registry })
  end

  def teardown
    FileUtils.rm_rf(@root)
    Hive::Workflows::Project.reset!
  end

  def test_preview_registry_binds_the_reviewed_candidate_identity
    resolution = resolution()
    use_resolution(resolution)
    expected = resolution.to_h.transform_keys(&:to_s)
    registry = Hive::Web::WorkflowLifecycle::PreviewRegistry.new(@registry, expected)

    assert_same resolution, registry.fetch("honeycomb/demo", destination: File.join(@root, "exact"))

    registry = Hive::Web::WorkflowLifecycle::PreviewRegistry.new(
      @registry, expected.merge("name" => "changed")
    )
    error = assert_raises(Hive::Web::WorkflowLifecycle::PreviewChanged) do
      registry.fetch("honeycomb/demo", destination: File.join(@root, "changed"))
    end
    assert_match "preview it again", error.message
  end

  def test_preview_registry_rejects_an_incomplete_identity
    error = assert_raises(ArgumentError) do
      Hive::Web::WorkflowLifecycle::PreviewRegistry.new(@registry, {})
    end

    assert_match(/identity is missing/, error.message)
  end

  def test_templates_list_and_scaffold_delegate_to_the_cli_contract
    assert_includes @lifecycle.templates, "blank"

    rows = [
      { "name" => "demo", "selection" => "selected" },
      { "name" => "demo", "selection" => "retained" },
      { "name" => "other", "selection" => nil }
    ]
    with_command(Hive::Commands::Workflow::List, { "workflows" => rows }) do |called|
      listed = @lifecycle.list(@project)

      assert_equal [ true, false, false ], listed.map { |row| row.fetch("default") }
      assert_equal File.expand_path(@root), called.call.fetch(:kwargs).fetch(:project_root)
      assert called.call.fetch(:kwargs).fetch(:json)
    end

    with_command(Hive::Commands::Workflow, { "id" => "launch" }) do |called|
      assert_equal({ "id" => "launch" }, @lifecycle.scaffold(@project, id: "launch", template: "writing"))
      assert_equal [ "new", "launch" ], called.call.fetch(:args)
      assert_equal "writing", called.call.fetch(:kwargs).fetch(:template)
    end
  end

  def test_install_preview_and_apply_use_the_exact_reviewed_registry_candidate
    reviewed = resolution()
    use_resolution(reviewed)
    preview = { "status" => "dry_run" }
    with_command(Hive::Commands::Workflow::Install, preview) do |called|
      assert_equal preview, @lifecycle.preview_install(@project, source: "honeycomb/demo@1.0.0")
      assert called.call.fetch(:kwargs).fetch(:dry_run)
      assert_same @registry, called.call.fetch(:kwargs).fetch(:registry_client)
    end

    expected = reviewed.to_h.transform_keys(&:to_s)
    with_command(Hive::Commands::Workflow::Install, { "status" => "installed" }) do |called|
      result = @lifecycle.install(@project, source: "honeycomb/demo@1.0.0", expected: expected)

      assert_equal "installed", result.fetch("status")
      options = called.call.fetch(:kwargs)
      assert options.fetch(:yes)
      bound_registry = options.fetch(:registry_client)
      assert_same reviewed, bound_registry.fetch("honeycomb/demo@1.0.0", destination: File.join(@root, "install"))
    end
  end

  def test_update_preview_rechecks_selection_and_apply_passes_both_identities
    current_commit = "a" * 40
    current_digest = "b" * 64
    write_selection(source_commit: current_commit, manifest_digest: current_digest)
    payload = { "status" => "update_available", "from_commit" => current_commit }
    with_command(Hive::Commands::Workflow::Update, payload) do |called|
      preview = @lifecycle.preview_update(@project, name: "demo")

      assert_equal current_digest, preview.fetch("from_manifest_digest")
      assert called.call.fetch(:kwargs).fetch(:dry_run)
    end

    with_command(Hive::Commands::Workflow::Update, payload.merge("from_commit" => "f" * 40)) do
      assert_raises(Hive::Web::WorkflowLifecycle::PreviewChanged) do
        @lifecycle.preview_update(@project, name: "demo")
      end
    end

    target = resolution(source_commit: "c" * 40, manifest_digest: "d" * 64)
    use_resolution(target)
    expected = {
      "from_commit" => current_commit,
      "from_manifest_digest" => current_digest,
      "to_commit" => target.source_commit,
      "manifest_digest" => target.manifest_digest
    }
    with_command(Hive::Commands::Workflow::Update, { "status" => "updated" }) do |called|
      result = @lifecycle.update(@project, name: "demo", expected: expected, allow_escalation: true)

      assert_equal "updated", result.fetch("status")
      options = called.call.fetch(:kwargs)
      assert options.fetch(:allow_escalation)
      assert_equal(
        { "source_commit" => current_commit, "manifest_digest" => current_digest },
        options.fetch(:expected_current)
      )
      assert_same target,
                  options.fetch(:registry_client).fetch("honeycomb/demo", destination: File.join(@root, "update"))
    end

    incomplete = expected.reject { |key, _value| key == "from_manifest_digest" }
    assert_raises(KeyError) do
      @lifecycle.update(@project, name: "demo", expected: incomplete, allow_escalation: true)
    end
  end

  def test_remove_preview_and_apply_recheck_the_selected_generation
    current_commit = "a" * 40
    current_digest = "b" * 64
    write_selection(source_commit: current_commit, manifest_digest: current_digest)

    with_command(Hive::Commands::Workflow::Remove, { "status" => "dry_run" }) do |called|
      assert_equal "dry_run", @lifecycle.preview_remove(@project, name: "demo").fetch("status")
      assert called.call.fetch(:kwargs).fetch(:dry_run)
    end

    expected = { "source_commit" => current_commit, "manifest_digest" => current_digest }
    with_command(Hive::Commands::Workflow::Remove, { "status" => "removed" }) do |called|
      assert_equal "removed", @lifecycle.remove(@project, name: "demo", expected: expected).fetch("status")
      assert_equal expected, called.call.fetch(:kwargs).fetch(:expected_current)
    end

    FileUtils.rm_f(File.join(@state, "workflows", "demo", Hive::WorkflowPackage::ManagedStore::LOCK_FILE))
    error = assert_raises(Hive::Commands::Workflow::OwnershipError) do
      @lifecycle.preview_update(@project, name: "demo")
    end
    assert_match "is not installed", error.message
  end

  private

  def with_command(command_class, payload)
    called = nil
    constructor = lambda do |*args, **kwargs|
      called = { args: args, kwargs: kwargs }
      CommandResult.new(payload)
    end
    with_replaced_singleton_method(command_class, :new, constructor) do
      yield -> { called || flunk("#{command_class} was not constructed") }
    end
  end

  def resolution(source_commit: "a" * 40, manifest_digest: "b" * 64)
    Resolution.new(
      name: "demo", version: "1.0.0", catalog_commit: "c" * 40,
      source_commit: source_commit, manifest_digest: manifest_digest
    )
  end

  def use_resolution(value)
    @registry.instance_variable_set(:@resolution, value)
  end

  def write_selection(source_commit:, manifest_digest:)
    path = File.join(@state, "workflows", "demo", Hive::WorkflowPackage::ManagedStore::LOCK_FILE)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({
      "schema_version" => 1,
      "name" => "demo",
      "version" => "1.0.0",
      "catalog_commit" => "c" * 40,
      "source_commit" => source_commit,
      "manifest_digest" => manifest_digest,
      "summary" => "Demo",
      "permissions" => {}
    }))
  end
end
