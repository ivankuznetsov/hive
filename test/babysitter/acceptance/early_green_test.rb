require_relative "support"

class BabysitterAcceptanceEarlyGreenTest < Minitest::Test
  include HiveTestHelper
  include BabysitterAcceptanceSupport

  def test_green_pr_noops_without_spawning_agent
    with_tmp_dir do |dir|
      project = babysitter_project(dir)
      pr = babysitter_pr
      status = {
        "mergeable" => "MERGEABLE",
        "statusCheckRollup" => [ { "name" => "ci", "conclusion" => "SUCCESS" } ]
      }
      spawned = false

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_path, _number, **_kwargs) { status }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { spawned = true }) do
          outcome = Hive::Babysitter::PrFixer.run(
            pr,
            project,
            babysitter_cfg,
            dry_run: false,
            logger: acceptance_logger,
            inflight: Set.new
          )
          assert_equal :already_green, outcome
        end
      end

      refute spawned
      assert babysitter_events(project).any? { |event|
        event["action"] == "noop" && event["outcome"] == "already-green" && event["pr"] == 42
      }
    end
  end
end
