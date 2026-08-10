require_relative "support"

class BabysitterAcceptanceWipLabelTest < Minitest::Test
  include HiveTestHelper
  include BabysitterAcceptanceSupport

  def test_wip_label_is_skipped_before_agent_spawn
    with_tmp_dir do |dir|
      project = babysitter_project(dir)
      write_babysitter_config(dir)
      prs = [
        babysitter_pr("number" => 9, "labels" => [ { "name" => "WIP" } ])
      ]
      spawned = false

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |*_args, **_kwargs|
          spawned = true
          :untouched
        }) do
          summary = Hive::Babysitter::ProjectTick.run(
            project,
            dry_run: true,
            logger: acceptance_logger,
            inflight: Set.new
          )
          assert_equal({ total: 0, fixed: 0, untouched: 0, needs_human: 0 }, summary)
        end
      end

      refute spawned
      assert babysitter_events(project).any? { |event|
        event["action"] == "skipped" && event["outcome"] == "label_ignored" && event["pr"] == 9
      }
    end
  end
end
