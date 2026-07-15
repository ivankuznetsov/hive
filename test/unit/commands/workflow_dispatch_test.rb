require "test_helper"
require "hive/commands/workflow"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/publish"
require "hive/commands/workflow/remove"
require "hive/commands/workflow/update"

class WorkflowDispatchTest < Minitest::Test
  def test_dispatcher_builds_each_lifecycle_command
    cases = {
      "install" => [ "demo", Hive::Commands::Workflow::Install ],
      "list" => [ nil, Hive::Commands::Workflow::List ],
      "remove" => [ "demo", Hive::Commands::Workflow::Remove ],
      "update" => [ "demo", Hive::Commands::Workflow::Update ],
      "publish" => [ "demo", Hive::Commands::Workflow::Publish ]
    }
    cases.each do |subcommand, (id, type)|
      command = Hive::Commands::Workflow.new(
        subcommand, id, project_root: Dir.pwd, stdout: StringIO.new, version: "1.0.0"
      )
      assert_instance_of type, command.send(:lifecycle_command)
    end
  end

  def test_list_rejects_an_id
    command = Hive::Commands::Workflow.new("list", "unexpected", stdout: StringIO.new)

    assert_raises(Hive::Commands::Workflow::UsageError) { command.send(:lifecycle_command) }
  end
end
