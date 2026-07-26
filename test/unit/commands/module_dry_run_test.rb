require "test_helper"
require_relative "../../support/module_helpers"
require "hive/commands/module/dry_run"
require "hive/module_package/managed_store"
require "hive/module_package/preview"

class ModuleDryRunCommandTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 12)

  def test_injected_evaluator_builds_json_and_human_projections
    calls = []
    evaluator = Object.new
    evaluator.define_singleton_method(:evaluate) do |**attributes|
      calls << attributes
      {
        "event" => { "event_name" => attributes.fetch(:event_name) },
        "decisions" => [ { "hook" => "task", "outcome" => "skip", "reason" => "disabled" } ]
      }
    end
    identity = { "project_id" => "project-1", "name" => "demo" }
    output = StringIO.new
    payload = Hive::Commands::Module::DryRun.new(
      "demo", event_name: "task.completed", hook_id: "task", occurred_at: NOW,
      evaluator: evaluator, project_identity: identity,
      project_root: Dir.pwd, json: true, stdout: output
    ).call!

    assert_equal "hive-module-dry-run", payload.fetch("schema")
    assert_equal "task.completed", calls.first.fetch(:event_name)
    assert_equal "task", calls.first.fetch(:hook_id)
    assert_equal payload, JSON.parse(output.string)

    human = StringIO.new
    Hive::Commands::Module::DryRun.new(
      "demo", event_name: "task.completed", evaluator: evaluator, project_identity: identity,
      project_root: Dir.pwd, json: false, stdout: human
    ).call!
    assert_equal "task skip reason=disabled\n", human.string
  end

  def test_registered_identity_ignores_stale_rows_and_requires_a_match
    with_tmp_dir do |project|
      stale = File.join(project, "gone")
      valid = { "name" => "demo", "project_id" => "project-1", "path" => project }
      rows = [ { "name" => "gone", "project_id" => "project-0", "path" => stale }, valid ]
      command = Hive::Commands::Module::DryRun.new(
        "demo", event_name: "task.completed", evaluator: Object.new,
        project_root: project, json: true, stdout: StringIO.new
      )
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { rows }) do
        assert_equal valid, command.send(:registered_identity)
      end
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        assert_raises(Hive::ConfigError) { command.send(:registered_identity) }
      end
    end
  end

  def test_default_evaluator_reads_the_project_store_without_persisting
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      package = File.join(project, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(state)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      before = tree_digest(state)

      payload = Hive::Commands::Module::DryRun.new(
        "demo", event_name: "task.completed", hook_id: "schedule", occurred_at: NOW,
        project_identity: { "project_id" => "project-1", "name" => "demo" },
        project_root: project, json: true, stdout: StringIO.new, store: store
      ).call!

      assert_equal "no_match", payload.fetch("decisions").first.fetch("reason")
      assert_equal before, tree_digest(state)
    end
  end

  private

  def tree_digest(root)
    files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
               .select { |path| File.file?(path) }.sort
    Digest::SHA256.hexdigest(files.map { |path| [ path.delete_prefix(root), File.binread(path) ] }.flatten.join("\0"))
  end
end
