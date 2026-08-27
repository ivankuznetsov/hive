require "test_helper"
require "shellwords"
require "hive/cli"
require "hive/attempts/context"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatcher"
require_relative "../support/daemon_e2e_harness"

class ContentWorkflowDaemonE2ETest < Minitest::Test
  include HiveTestHelper
  include HiveDaemonE2EHarness

  def test_content_fixture_advances_from_init_new_to_terminal_stage
    descriptor = content_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          project = File.basename(project_root)
          capture_io { Hive::Commands::Init.new(project_root, workflow: "content_fixture").call }
          capture_io { Hive::Commands::New.new(project, "draft launch post").call }

          slug = File.basename(Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "draft-launch-post-*")].first)
          ran = []
          with_deterministic_content_agent(record: ran) do
            with_attempt_context(
              attempt_id: "content-fixture-test-attempt",
              task_generation: "content-fixture-test-generation"
            ) do
              supervisor = InlineSupervisor.new(
                run: ->(command) { capture_io { Hive::CLI.start(Shellwords.split(command).drop(1)) }; 0 }
              )
              logger = CollectingLogger.new
              dispatcher = Hive::Daemon::Dispatcher.new(
                config: { "daemon" => { "edit_debounce_sec" => 0, "poll_interval_sec" => 30 } },
                controller: Hive::Daemon::ConcurrencyController.new(
                  max_concurrent_runs: 5,
                  max_concurrent_per_project: 5,
                  max_runs_per_day_per_project: 100
                ),
                supervisor: supervisor,
                status_consumer: LiveStatusConsumer.new(fetch: method(:status_snapshot)),
                logger: logger
              )
              24.times do
                break if File.file?(File.join(task_folder(project_root, "4-done", slug), "done.md"))

                advance_tick(dispatcher, supervisor)
              end

              @spawned_commands = supervisor.spawned.map { |s| s[:command] }
            end
          end

          final = task_folder(project_root, "4-done", slug)
          assert File.directory?(final), "task should end in the content fixture terminal stage"
          assert_equal %w[research draft done], ran
          %w[idea.md research.md draft.md done.md].each do |artifact|
            assert File.file?(File.join(final, artifact)), "#{artifact} should be carried into the final task folder"
          end

          # Defense-in-depth parity with the generic sibling: assert the daemon —
          # not a direct CLI call — drove both the run and the advancing approve
          # through the supervisor's spawn.
          assert(@spawned_commands.any? { |c| c.start_with?("hive run") },
                 "daemon must have dispatched at least one `hive run` through the supervisor")
          assert(@spawned_commands.any? { |c| c.start_with?("hive approve") },
                 "daemon must have dispatched the advancing `hive approve` through the supervisor")

          log_subjects = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s")
          approve_commits = log_subjects.lines.grep(/ approve /)
          assert_equal 3, approve_commits.size, "one approve commit should be recorded per stage transition"
          assert_includes log_subjects, "hive: 1-inbox/#{slug} approve 1-inbox -> 2-research"
          assert_includes log_subjects, "hive: 2-research/#{slug} approve 2-research -> 3-draft"
          assert_includes log_subjects, "hive: 3-draft/#{slug} approve 3-draft -> 4-done"
        end
      end
    end
  end
end
