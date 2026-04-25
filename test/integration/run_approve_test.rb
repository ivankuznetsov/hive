require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/approve"

class RunApproveTest < Minitest::Test
  include HiveTestHelper

  def seed_project_with_inbox_task(dir, text: "approve probe")
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::New.new(project, text).call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    [ project, inbox, File.basename(inbox) ]
  end

  def write_marker(folder, marker_name, attrs = {})
    state = Hive::Task.new(folder).state_file
    FileUtils.touch(state) unless File.exist?(state)
    Hive::Markers.set(state, marker_name, attrs)
  end

  # Forward auto-advance with terminal marker is the load-bearing happy path.
  def test_advances_brainstorm_complete_to_plan
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        # Move to 2-brainstorm and put a COMPLETE marker on brainstorm.md.
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        capture_io { Hive::Commands::Approve.new(slug).call }

        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug)),
               "task must have moved into 3-plan"
        refute File.exist?(brainstorm), "old folder must be gone"

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 2-brainstorm/.* approve 2-brainstorm -> 3-plan\z}, log,
                     "hive_commit must record the approval")
      end
    end
  end

  # Inbox -> brainstorm has no terminal marker requirement (idea.md just says
  # WAITING by template). The forward move from 1-inbox should still work
  # because the destination stage index is *not greater* than the source... wait,
  # 2 > 1, so it IS forward. The marker check kicks in. That means inbox tasks
  # need --force OR the user must hand-edit a terminal marker — undesirable UX.
  # Document the inbox case: idea.md's WAITING is the user's "this is ready to
  # think about" signal; require --force for inbox→brainstorm.
  def test_forward_from_inbox_requires_force_due_to_waiting_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _inbox, slug = seed_project_with_inbox_task(dir)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "forward approve requires a terminal marker"

        capture_io { Hive::Commands::Approve.new(slug, force: true).call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "2-brainstorm", slug))
      end
    end
  end

  def test_explicit_to_allows_backward_move_for_recovery
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        # Park in 4-execute with a non-terminal marker — exactly what a user
        # would have when they realise the plan was wrong.
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute_dir))
        FileUtils.mv(inbox, execute_dir)
        write_marker(execute_dir, :execute_waiting, findings_count: 3, pass: 1)

        capture_io { Hive::Commands::Approve.new(slug, to: "3-plan").call }

        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug))
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{approve 4-execute -> 3-plan}, log)
      end
    end
  end

  def test_to_accepts_short_stage_name
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        write_marker(plan_dir, :complete)

        # `--to execute` should resolve to `4-execute`.
        capture_io { Hive::Commands::Approve.new(slug, to: "execute").call }

        assert File.directory?(File.join(dir, ".hive-state", "stages", "4-execute", slug))
      end
    end
  end

  def test_unknown_stage_in_to_raises_invalid_task_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _inbox, slug = seed_project_with_inbox_task(dir)
        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, to: "7-bogus").call }
        assert_equal Hive::ExitCodes::USAGE, status,
                     "bad --to value must map to USAGE (64), not generic"
        assert_includes err, "unknown stage"
      end
    end
  end

  def test_slug_not_found_raises_invalid_task_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        seed_project_with_inbox_task(dir)
        _, err, status = with_captured_exit { Hive::Commands::Approve.new("does-not-exist-260424-aaaa").call }
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "no task folder for slug"
      end
    end
  end

  def test_ambiguous_slug_across_projects_requires_project_filter
    with_tmp_global_config do
      with_tmp_git_repo do |dir1|
        # Project 2 lives in a sibling tmpdir with the same slug.
        Dir.mktmpdir("hive-test-other") do |dir2|
          run!("git", "-C", dir2, "init", "-b", "master", "--quiet")
          run!("git", "-C", dir2, "config", "user.email", "t@t")
          run!("git", "-C", dir2, "config", "user.name", "t")
          run!("git", "-C", dir2, "config", "commit.gpgsign", "false")
          File.write(File.join(dir2, "README.md"), "x")
          run!("git", "-C", dir2, "add", ".")
          run!("git", "-C", dir2, "commit", "-m", "i", "--quiet")

          capture_io { Hive::Commands::Init.new(dir1).call }
          capture_io { Hive::Commands::Init.new(dir2).call }
          # Force the same slug into both projects by injecting folders directly.
          slug = "shared-slug-260424-aaaa"
          [ dir1, dir2 ].each do |d|
            FileUtils.mkdir_p(File.join(d, ".hive-state", "stages", "1-inbox", slug))
            File.write(File.join(d, ".hive-state", "stages", "1-inbox", slug, "idea.md"),
                       "# x\n<!-- WAITING -->\n")
          end

          _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, force: true).call }
          assert_equal Hive::ExitCodes::USAGE, status
          assert_includes err, "ambiguous"
          assert_includes err, "--project"

          # With --project, disambiguation works.
          capture_io { Hive::Commands::Approve.new(slug, force: true, project: File.basename(dir1)).call }
          assert File.directory?(File.join(dir1, ".hive-state", "stages", "2-brainstorm", slug))
        end
      end
    end
  end

  def test_destination_collision_aborts
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # Pre-create the destination folder under 3-plan to simulate a stale leftover.
        dest = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(dest)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_equal Hive::ExitCodes::GENERIC, status
        assert_includes err, "destination already exists"
        assert File.directory?(brainstorm), "source folder must remain on collision"
      end
    end
  end

  def test_folder_path_target_works_directly
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        capture_io { Hive::Commands::Approve.new(brainstorm).call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug))
      end
    end
  end

  def test_json_output_emits_stable_schema
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        out, _err = capture_io { Hive::Commands::Approve.new(slug, json: true).call }
        assert_equal 1, out.lines.count, "JSON output must be a single line"
        payload = JSON.parse(out)
        assert_equal "hive-approve", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal slug, payload["slug"]
        assert_equal "2-brainstorm", payload["from_stage"]
        assert_equal "3-plan", payload["to_stage"]
        assert_match(%r{/3-plan/#{slug}\z}, payload["to_folder"])
        assert_includes payload["commit_action"], "approve 2-brainstorm -> 3-plan"
      end
    end
  end

  def test_advancing_past_6_done_errors
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        done = File.join(dir, ".hive-state", "stages", "6-done", slug)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(inbox, done)
        write_marker(done, :complete)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_equal Hive::ExitCodes::GENERIC, status
        assert_includes err, "already at the final stage"
      end
    end
  end
end
