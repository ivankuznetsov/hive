# frozen_string_literal: true

require "test_helper"
require "hive/agent_profiles"
require "hive/brainstorm_suggestions/runner"
require "hive/commands/answer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/brainstorm_suggestion_scheduler"
require "hive/daemon/status_consumer"
require "hive/tui/brainstorm_suggestions"

class BrainstormSuggestionAuthorityTest < Minitest::Test
  include HiveTestHelper

  CANDIDATE = "Use the task-local scheduler seam.\nKeep answer authority with the operator."

  def test_generation_json_and_tui_share_one_candidate_without_acquiring_authority
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        folder = task_at_brainstorm(project)
        brainstorm = File.join(folder, "brainstorm.md")
        baseline = authority_snapshot(folder)
        launch = nil
        transport = lambda do |observed, _cancellation|
          launch = observed
          Hive::BrainstormSuggestions::Runner::Execution.new(
            stdout: JSON.generate("structured_output" => {
              "disposition" => "suggestion",
              "text" => CANDIDATE,
              "rationale" => "The request keeps this boundary explicit.",
              "provenance" => [ "request" ]
            }),
            exit_code: 0,
            timed_out: false
          )
        end
        scheduler = scheduler_for(project, transport)

        scheduler.tick(rows: [ waiting_row(project, folder) ], now: fixture_time)

        assert_equal baseline, authority_snapshot(folder)
        refute launch.prompt.include?(project)
        refute launch.prompt.include?(folder)
        assert_equal %i[model effort prompt schema], launch.class.members
        inventory = Hive::Commands::Answer.inventory(
          File.basename(folder), project: File.basename(project)
        )
        suggestion = inventory.fetch("slots").first.fetch("suggestion")
        assert_equal "fresh", suggestion.fetch("state")
        assert_equal CANDIDATE, suggestion.fetch("text")

        lease = Hive::Tui::BrainstormSuggestions.project!(task_root: folder, path: brainstorm)
        assert_equal CANDIDATE, lease.regions.fetch(0).text
        assert_equal baseline, authority_snapshot(folder)

        region = lease.regions.fetch(0)
        adopted = region.source
                        .sub(/\A<!-- hive-suggestion:v1[^\n]* -->\n/, "")
                        .sub(/<!-- \/hive-suggestion:v1 -->\n\z/, "")
        File.write(brainstorm, File.read(brainstorm).sub(region.source, adopted))
        result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
          task_root: folder, path: brainstorm, lease: lease
        )

        assert_equal 1, result.adopted
        assert_equal CANDIDATE, Hive::BrainstormParser.parse(brainstorm).first.answer
        assert_equal :waiting, Hive::Markers.current(brainstorm).name
        refute_includes File.read(brainstorm), "## Requirements"
        refute_includes File.read(brainstorm), "<!-- COMPLETE -->"
        assert_equal "2-brainstorm", File.basename(File.dirname(folder))
        refute File.exist?(File.join(folder, Hive::BrainstormSuggestions::STORE_FILENAME))
      ensure
        scheduler&.shutdown
      end
    end
  end

  def test_tracked_input_change_suppresses_cached_json_and_tui_text_without_authority
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        source = File.join(project, "suggestion_scheduler.rb")
        File.write(source, "class SuggestionScheduler; TASK_LOCAL = true; end\n")
        run!("git", "-C", project, "add", "suggestion_scheduler.rb")
        run!("git", "-C", project, "commit", "-m", "add scheduler evidence", "--quiet")
        folder = task_at_brainstorm(project)
        brainstorm = File.join(folder, "brainstorm.md")
        baseline = authority_snapshot(folder)
        transport = lambda do |_request, _cancellation|
          Hive::BrainstormSuggestions::Runner::Execution.new(
            stdout: JSON.generate("structured_output" => {
              "disposition" => "suggestion",
              "text" => CANDIDATE,
              "rationale" => "The tracked scheduler owns the task-local seam.",
              "provenance" => [ "repository" ]
            }),
            exit_code: 0,
            timed_out: false
          )
        end
        scheduler = scheduler_for(project, transport)
        scheduler.tick(rows: [ waiting_row(project, folder) ], now: fixture_time)

        initial = Hive::Commands::Answer.inventory(
          File.basename(folder), project: File.basename(project)
        ).fetch("slots").first.fetch("suggestion")
        assert_equal "fresh", initial.fetch("state")
        assert_equal CANDIDATE, initial.fetch("text")

        File.write(source, "class SuggestionScheduler; TASK_LOCAL = false; end\n")
        changed = Hive::Commands::Answer.inventory(
          File.basename(folder), project: File.basename(project)
        ).fetch("slots").first.fetch("suggestion")
        lease = Hive::Tui::BrainstormSuggestions.project!(task_root: folder, path: brainstorm)

        assert_equal "stale", changed.fetch("state")
        assert_nil changed.fetch("text")
        assert_nil changed.fetch("rationale")
        assert_empty changed.fetch("provenance")
        assert_empty lease.regions
        refute_includes File.read(brainstorm), "hive-suggestion:v1"
        assert_equal baseline, authority_snapshot(folder)
      ensure
        scheduler&.shutdown
      end
    end
  end

  private

  def task_at_brainstorm(project)
    capture_io do
      Hive::Commands::Init.new(project).call
      Hive::Commands::New.new(File.basename(project), "Add repository-aware answer suggestions").call
    end
    File.write(
      File.join(project, ".hive-state", "config.yml"),
      { "brainstorm" => { "suggestions" => { "enabled" => true } } }.to_yaml
    )
    inbox = Dir[File.join(project, ".hive-state", "stages", "1-inbox", "*")].fetch(0)
    folder = File.join(project, ".hive-state", "stages", "2-brainstorm", File.basename(inbox))
    FileUtils.mv(inbox, folder)
    File.write(
      File.join(folder, "brainstorm.md"),
      <<~MARKDOWN
        ## Round 1

        ### Q1. Which seam should own repository-aware suggestions?
        ### A1.

        <!-- WAITING -->
      MARKDOWN
    )
    folder
  end

  def scheduler_for(project, transport)
    cfg = Hive::Config.load(project)
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:claude),
      model: "claude-sonnet-test",
      transport: transport
    )
    Hive::Daemon::BrainstormSuggestionScheduler.new(
      runner_factory: ->(_config, _project_root) { runner },
      config_loader: ->(_project_root) { cfg },
      worker_launcher: ->(work) { work.call },
      clock: -> { fixture_time },
      max_workers: 1
    )
  end

  def waiting_row(project, folder)
    Hive::Daemon::StatusConsumer::Row.new(
      project: File.basename(project), slug: File.basename(folder), id: 1,
      stage: "2-brainstorm", workflow: "coding", marker: "waiting",
      marker_attrs: {}, folder: folder, state_file: File.join(folder, "brainstorm.md"),
      action: "needs_input"
    )
  end

  def authority_snapshot(folder)
    brainstorm = File.join(folder, "brainstorm.md")
    body = File.read(brainstorm)
    {
      "answers" => Hive::BrainstormParser.parse_text(body).map(&:answer),
      "marker" => Hive::Markers.current(brainstorm).name,
      "requirements" => body.include?("## Requirements"),
      "complete" => body.include?("<!-- COMPLETE -->"),
      "stage" => File.basename(File.dirname(folder)),
      "events" => File.file?(File.join(folder, "events.jsonl")) ?
        File.binread(File.join(folder, "events.jsonl")) : nil
    }
  end

  def fixture_time
    Time.utc(2026, 8, 30, 12, 0, 0)
  end
end
