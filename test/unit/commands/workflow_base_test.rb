require "test_helper"
require "hive/commands/workflow/base"

class WorkflowBaseTest < Minitest::Test
  include HiveTestHelper

  class Probe < Hive::Commands::Workflow::Base
    attr_accessor :failure

    def call!
      raise failure if failure

      emit({ "ok" => true }, human_lines: [ "human result" ])
    end

    def confirm(prompt) = confirmed?(prompt)
    def commit(name, action) = commit_state(name, action)
    def kind(error) = error_kind(error)
    def envelope_schema = "hive-workflow-install"
  end

  def test_call_emits_json_and_human_errors_with_typed_exit_codes
    json_out = StringIO.new
    json = Probe.new(project_root: Dir.pwd, json: true, stdout: json_out)
    json.failure = Hive::Commands::Workflow::ConsentRequired.new("need consent")
    error = assert_raises(SystemExit) { json.call }
    assert_equal Hive::ExitCodes::USAGE, error.status
    assert_equal "consent_required", JSON.parse(json_out.string).fetch("error_kind")

    human = Probe.new(project_root: Dir.pwd, json: false, stdout: StringIO.new)
    human.failure = Hive::ConfigError.new("bad config")
    _out, err = capture_io { assert_raises(SystemExit) { human.call } }
    assert_includes err, "hive workflow: bad config"
  end

  def test_human_emit_and_interactive_confirmation
    output = StringIO.new
    input = StringIO.new("yes\n")
    input.define_singleton_method(:tty?) { true }
    command = Probe.new(project_root: Dir.pwd, json: false, stdout: output, stdin: input)

    assert_equal({ "ok" => true }, command.call!)
    assert command.confirm("Continue?")
    assert_includes output.string, "human result"
    assert_includes output.string, "Continue? [y/N]"

    declined = StringIO.new("no\n")
    declined.define_singleton_method(:tty?) { true }
    refute Probe.new(project_root: Dir.pwd, json: false, stdout: StringIO.new, stdin: declined).confirm("Continue?")
  end

  def test_default_commit_path_uses_scoped_git_commit_and_lock
    calls = []
    ops = Object.new
    ops.define_singleton_method(:hive_commit) { |**kwargs| calls << kwargs }
    with_tmp_dir do |project|
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(File.join(project, ".hive-state", "config.yml"),
                 Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { ops }) do
        with_replaced_singleton_method(Hive::Lock, :with_commit_lock, ->(_path, &block) { block.call }) do
          Probe.new(project_root: project, json: false, stdout: StringIO.new).commit("demo", "updated")
        end
      end
    end

    assert_equal [ "workflows/demo" ], calls.first.fetch(:pathspecs)
  end

  def test_error_kind_covers_every_lifecycle_recovery_category
    command = Probe.new(project_root: Dir.pwd, json: false, stdout: StringIO.new)
    cases = {
      Hive::Commands::Workflow::ConsentRequired.new("x") => "consent_required",
      Hive::Commands::Workflow::OwnershipError.new("x") => "ownership",
      Hive::Commands::Workflow::UpdateRequired.new("x") => "update_required",
      Hive::ConcurrentRunError.new("x") => "concurrent_run",
      Hive::GitError.new("x") => "git",
      Hive::ConfigError.new("x") => "config",
      Hive::WorkflowPackage::RegistryError.new("x") => "registry",
      RuntimeError.new("x") => "error"
    }

    cases.each { |error, expected| assert_equal expected, command.kind(error) }
  end
end
