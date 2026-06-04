require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/task"
require "hive/markers"

# U5 integration: a task paused at a gate, approved through the web UI, moves
# to the next stage and records the same hive/state commit the CLI's Approve
# would — the web approve is the same in-process Approve the TUI uses.
class WebApproveFlowTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  def write_marker(folder, marker_name)
    state = Hive::Task.new(folder).state_file
    FileUtils.touch(state) unless File.exist?(state)
    Hive::Markers.set(state, marker_name)
  end

  def test_approve_advances_gate_and_commits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "approve flow").call }
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        boot_web_app
        login!
        token = csrf_token_from("/tasks/#{project}/#{slug}")

        post "/tasks/#{project}/#{slug}/approve",
             { "from" => "2-brainstorm", "authenticity_token" => token },
             "HTTP_HOST" => "127.0.0.1"

        assert last_response.redirect?, "approve should redirect back to the grid"
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug)),
               "approve must advance the task to 3-plan"
        refute File.directory?(brainstorm), "the old brainstorm folder must be gone"

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{approve 2-brainstorm -> 3-plan\z}, log,
                     "the web approve must record the same hive/state commit as the CLI")
      end
    end
  end
end
