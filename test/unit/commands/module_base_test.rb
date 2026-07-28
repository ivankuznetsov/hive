require "test_helper"
require "hive/commands/module/base"
require "hive/module_package/catalog_client"

class ModuleBaseCommandTest < Minitest::Test
  include HiveTestHelper

  class Harness < Hive::Commands::Module::Base
    attr_writer :failure

    def call!
      raise @failure if @failure
      :ok
    end
  end

  def test_call_emits_json_or_human_errors_and_exits_with_the_typed_status
    output = StringIO.new
    json = Harness.new(project_root: Dir.pwd, json: true, stdout: output)
    json.failure = Hive::ConfigError.new("bad config")
    error = assert_raises(SystemExit) { json.call }
    assert_equal Hive::ExitCodes::CONFIG, error.status
    payload = JSON.parse(output.string)
    assert_equal "config", payload.fetch("error_kind")

    human = Harness.new(project_root: Dir.pwd, json: false, stdout: StringIO.new)
    human.failure = Hive::ConfigError.new("human failure")
    _out, err = capture_io { assert_raises(SystemExit) { human.call } }
    assert_includes err, "hive module: human failure"

    assert_equal :ok, Harness.new(project_root: Dir.pwd, json: true, stdout: StringIO.new).call
  end

  def test_project_paths_human_emission_and_interactive_consent
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      output = StringIO.new
      command = Harness.new(project_root: project, json: false, stdout: output)

      assert_equal state, command.send(:hive_state_path)
      assert_equal({ "ok" => true }, command.send(:emit, { "ok" => true }, human_lines: %w[first second]))
      assert_equal "first\nsecond\n", output.string

      assert_raises(Hive::Commands::Module::ConsentRequired) do
        command.send(:confirm_mutation!, "Apply?")
      end

      accepted_input = StringIO.new("yes\n")
      accepted_input.define_singleton_method(:tty?) { true }
      accepted = Harness.new(
        project_root: project, json: false, stdout: output, stdin: accepted_input
      )
      assert accepted.send(:confirm_mutation!, "Apply?")
      assert_includes output.string, "Apply? [y/N]"

      declined_input = StringIO.new("no\n")
      declined_input.define_singleton_method(:tty?) { true }
      declined = Harness.new(
        project_root: project, json: false, stdout: StringIO.new, stdin: declined_input
      )
      assert_raises(Hive::Commands::Module::ConsentRequired) do
        declined.send(:confirm_mutation!, "Apply?")
      end
    end
  end

  def test_default_inspector_receives_the_registered_project_identity
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      entry = {
        "name" => "demo", "path" => project, "hive_state_path" => state,
        "project_id" => "project-1"
      }
      captured = nil

      stale = entry.merge(
        "name" => "stale", "path" => File.join(project, "missing")
      )
      with_replaced_singleton_method(
        Hive::Config, :registered_projects, -> { [ stale, entry ] }
      ) do
        with_replaced_singleton_method(
          Hive::Modules::Inspector, :new,
          ->(**options) { captured = options; :inspector }
        ) do
          command = Harness.new(project_root: project, json: true, stdout: StringIO.new)
          assert_equal :inspector, command.send(:inspector)
        end
      end

      assert_equal "project-1", captured.fetch(:project_id)
      assert_instance_of Hive::ModulePackage::ManagedStore, captured.fetch(:store)

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        command = Harness.new(project_root: project, json: true, stdout: StringIO.new)
        assert_raises(Hive::ConfigError) { command.send(:inspector) }
      end
    end
  end

  def test_default_committer_uses_the_project_commit_lock
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      commits = []
      lock_path = nil
      operations = Object.new
      operations.define_singleton_method(:hive_commit) do |**attributes|
        commits << attributes
      end

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_root) { operations }) do
        with_replaced_singleton_method(
          Hive::Lock, :with_commit_lock,
          ->(path, &block) { lock_path = path; block.call }
        ) do
          command = Harness.new(
            project_root: project, json: true, stdout: StringIO.new
          )
          command.send(:commit_state, "demo", "installed")
          command.send(:commit_workflow_state, "demo", "updated")
        end
      end

      assert_equal state, lock_path
      commit = commits.fetch(0)
      assert_equal "modules", commit.fetch(:stage_name)
      assert_equal "demo", commit.fetch(:slug)
      assert_equal [ File.join("modules", "demo") ], commit.fetch(:pathspecs)
      workflow_commit = commits.fetch(1)
      assert_equal "workflows", workflow_commit.fetch(:stage_name)
      assert_equal [ File.join("workflows", "demo") ],
                   workflow_commit.fetch(:pathspecs)
    end
  end

  def test_state_receipt_expiry_and_error_kinds_are_explicit
    issued_at = Time.utc(2026, 7, 22)
    seed = Harness.new(project_root: Dir.pwd, json: true, stdout: StringIO.new)
    preview = seed.send(:state_preview, "disable", { "enabled" => true }, issued_at: issued_at)
    command = Harness.new(
      project_root: Dir.pwd, json: true, stdout: StringIO.new,
      receipt: preview.fetch(:receipt)
    )
    assert_raises(Hive::ConfigError) do
      command.send(
        :verify_state_receipt!, "disable", { "enabled" => true },
        now: issued_at + Hive::ModulePackage::Preview::TTL_SECONDS + 1
      )
    end

    cases = {
      Hive::Commands::Module::ConsentRequired.new("consent") => "consent_required",
      Hive::Commands::Module::OwnershipError.new("ownership") => "ownership",
      Hive::ConcurrentRunError.new("busy") => "concurrent_run",
      Hive::ModulePackage::CatalogError.new("catalog") => "catalog",
      Hive::ConfigError.new("config") => "config",
      Hive::GitError.new("git") => "git",
      RuntimeError.new("other") => "error"
    }
    cases.each do |error, kind|
      assert_equal kind, command.send(:error_kind, error)
    end
    payload = command.send(:error_payload, Hive::ConfigError.new("bad"))
    assert_equal "hive-module-lifecycle", payload.fetch("schema")
    assert_equal "config", payload.fetch("error_kind")
  end
end
