require "test_helper"
require "json"
require "hive/babysitter/dispatcher"

class BabysitterDispatcherTest < Minitest::Test
  include HiveTestHelper

  def write_project_config(project, babysitter:)
    FileUtils.mkdir_p(File.join(project, ".hive-state"))
    File.write(
      File.join(project, ".hive-state", "config.yml"),
      {
        "project_name" => File.basename(project),
        "babysitter" => babysitter
      }.to_yaml
    )
  end

  def test_tick_runs_only_enabled_projects_and_uses_min_interval
    with_tmp_global_config do |home|
      with_tmp_dir do |enabled|
        with_tmp_dir do |disabled|
          data = YAML.safe_load(File.read(File.join(home, "config.yml")))
          data["registered_projects"] = [
            { "name" => "enabled", "path" => enabled },
            { "name" => "disabled", "path" => disabled }
          ]
          File.write(File.join(home, "config.yml"), data.to_yaml)
          write_project_config(enabled, babysitter: { "enabled" => true, "interval" => "30s" })
          write_project_config(disabled, babysitter: { "enabled" => false, "interval" => "1h" })

          calls = []
          logger = Hive::Babysitter::Logger.new(path: File.join(home, "logs", "babysitter.log"))
          dispatcher = Hive::Babysitter::Dispatcher.new(logger: logger, dry_run: true)

          with_replaced_singleton_method(Hive::Babysitter::ProjectTick, :run, lambda { |project, **kwargs|
            calls << [ project["name"], kwargs[:dry_run] ]
          }) do
            assert_equal 1, dispatcher.tick
          end

          assert_equal [ [ "enabled", true ] ], calls
          docs = File.readlines(File.join(home, "logs", "babysitter.log")).map { |line| JSON.parse(line) }
          assert docs.any? { |doc| doc["event"] == "project_skipped" && doc["project"] == "disabled" }
          assert docs.any? { |doc| doc["event"] == "tick_end" && doc["next_interval_sec"] == 30 }
        ensure
          logger&.close
        end
      end
    end
  end

  def test_tick_scopes_to_one_project
    with_tmp_global_config do |home|
      with_tmp_dir do |one|
        with_tmp_dir do |two|
          data = YAML.safe_load(File.read(File.join(home, "config.yml")))
          data["registered_projects"] = [
            { "name" => "one", "path" => one },
            { "name" => "two", "path" => two }
          ]
          File.write(File.join(home, "config.yml"), data.to_yaml)
          write_project_config(one, babysitter: { "enabled" => true })
          write_project_config(two, babysitter: { "enabled" => true })

          calls = []
          logger = Hive::Babysitter::Logger.new(path: File.join(home, "logs", "babysitter.log"))
          dispatcher = Hive::Babysitter::Dispatcher.new(logger: logger, project_name: "two")

          with_replaced_singleton_method(Hive::Babysitter::ProjectTick, :run, lambda { |project, **_kwargs|
            calls << project["name"]
          }) do
            dispatcher.tick
          end

          assert_equal [ "two" ], calls
        ensure
          logger&.close
        end
      end
    end
  end
end
