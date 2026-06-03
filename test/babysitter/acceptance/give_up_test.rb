require_relative "support"
require "hive/babysitter/gh_ops"

class BabysitterAcceptanceGiveUpTest < Minitest::Test
  include HiveTestHelper
  include BabysitterAcceptanceSupport

  def test_failed_agent_labels_comments_and_records_give_up
    with_tmp_dir do |dir|
      project = babysitter_project(dir)
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      pr = babysitter_pr
      labels = []
      comments = []

      with_non_green_babysitter_context(project, worktree_path, pr) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { { status: :error, final_message: "still red" } }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, lambda { |_worktree, pr_number, label, **_kwargs|
            labels << [ pr_number, label ]
            Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
          }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :post_pr_comment, lambda { |_worktree, pr_number, body, **_kwargs|
              comments << [ pr_number, body ]
              Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
            }) do
              outcome = Hive::Babysitter::PrFixer.run(
                pr,
                project,
                babysitter_cfg,
                dry_run: false,
                logger: acceptance_logger,
                inflight: Set.new
              )
              assert_equal :failure, outcome
            end
          end
        end
      end

      assert_equal [ [ 42, "babysitter/needs-human" ] ], labels
      assert_equal 1, comments.size
      assert_includes comments.first.last, "still red"
      assert babysitter_events(project).any? { |event|
        event["action"] == "give-up" && event["outcome"] == "failure" && event["pr"] == 42
      }
    end
  end
end
