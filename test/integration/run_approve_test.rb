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

  # ── Happy paths ─────────────────────────────────────────────────────────

  def test_advances_brainstorm_complete_to_plan
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
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

        capture_io { Hive::Commands::Approve.new(slug, to: "execute").call }

        assert File.directory?(File.join(dir, ".hive-state", "stages", "4-execute", slug))
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

  # ── Resolution / ambiguity ──────────────────────────────────────────────

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

  def test_project_filter_with_zero_matches_includes_project_in_message
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        seed_project_with_inbox_task(dir)
        _, err, status = with_captured_exit do
          Hive::Commands::Approve.new("absent-260424-aaaa", project: "no-such-project").call
        end
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "in project 'no-such-project'"
      end
    end
  end

  def test_ambiguous_slug_across_projects_requires_project_filter
    with_tmp_global_config do
      with_tmp_git_repo do |dir1|
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

          capture_io { Hive::Commands::Approve.new(slug, force: true, project: File.basename(dir1)).call }
          assert File.directory?(File.join(dir1, ".hive-state", "stages", "2-brainstorm", slug))
        end
      end
    end
  end

  def test_same_project_multi_stage_ambiguity_raises
    # The lowest-stage-wins heuristic was wrong for the partial-failure-
    # recovery case (lower=stale, higher=real). Any same-project multi-hit
    # now raises and demands an explicit folder path.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        # Manually plant a stale leftover at a second stage.
        leftover = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(leftover)
        File.write(File.join(leftover, "plan.md"), "stale\n")

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, force: true).call }
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "ambiguous"
        assert_includes err, "multiple stages"

        # Folder-path target disambiguates and works.
        capture_io { Hive::Commands::Approve.new(inbox, force: true).call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "2-brainstorm", slug))
      end
    end
  end

  def test_absolute_path_target_with_mismatched_project_filter_raises
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, _slug = seed_project_with_inbox_task(dir)
        _, err, status = with_captured_exit do
          Hive::Commands::Approve.new(inbox, project: "totally-different", force: true).call
        end
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "but --project says 'totally-different'"
      end
    end
  end

  def test_cwd_collision_does_not_shadow_slug_lookup
    # A bare slug must always go through the cross-project search even if a
    # cwd subdirectory happens to share the name.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        Dir.mktmpdir("decoy") do |decoy|
          # Plant a directory in cwd with the slug name — must NOT be picked.
          FileUtils.mkdir_p(File.join(decoy, slug))
          Dir.chdir(decoy) do
            capture_io { Hive::Commands::Approve.new(slug).call }
          end
        end

        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug)),
               "slug lookup must resolve via the registered project, not the cwd-shadow"
      end
    end
  end

  # ── Marker policy ───────────────────────────────────────────────────────

  def test_destination_collision_aborts
    # Use folder-path target so same-project multi-stage ambiguity (which is
    # raised earlier) doesn't shadow the destination-collision branch.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # A *different* sibling folder pre-occupies the destination — not a
        # same-project leftover at the slug level (that would trigger the
        # ambiguity branch).
        FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "3-plan", slug))

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(brainstorm).call }
        assert_equal Hive::ExitCodes::GENERIC, status
        assert_includes err, "destination already exists"
        assert File.directory?(brainstorm), "source folder must remain on collision"
      end
    end
  end

  def test_error_marker_forward_approve_refused_with_clear_message
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute_dir))
        FileUtils.mv(inbox, execute_dir)
        write_marker(execute_dir, :error, reason: "agent_crashed")

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "marker is :error"
      end
    end
  end

  def test_error_marker_backward_recovery_via_to_works
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute_dir))
        FileUtils.mv(inbox, execute_dir)
        write_marker(execute_dir, :error, reason: "agent_crashed")

        capture_io { Hive::Commands::Approve.new(slug, to: "3-plan").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug))
      end
    end
  end

  def test_advancing_past_6_done_errors_with_wrong_stage
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        done = File.join(dir, ".hive-state", "stages", "6-done", slug)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(inbox, done)
        write_marker(done, :complete)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status,
                     "past-final-stage must use WRONG_STAGE (4), not GENERIC (1)"
        assert_includes err, "already at the final stage"
      end
    end
  end

  # ── --from idempotency ─────────────────────────────────────────────────

  def test_from_assertion_blocks_silent_double_advance
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # First call advances 2-brainstorm -> 3-plan.
        capture_io { Hive::Commands::Approve.new(slug, from: "2-brainstorm").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug))

        # Naive retry that re-passes --from <previous-stage> must fail loudly.
        write_marker(File.join(dir, ".hive-state", "stages", "3-plan", slug), :complete)
        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, from: "2-brainstorm").call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "but --from expected 2-brainstorm"
      end
    end
  end

  def test_from_short_name_resolves_to_full
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        capture_io { Hive::Commands::Approve.new(slug, from: "brainstorm").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug))
      end
    end
  end

  def test_from_unknown_stage_raises_usage
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _inbox, slug = seed_project_with_inbox_task(dir)
        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, from: "8-quux").call }
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "unknown --from stage"
      end
    end
  end

  # ── No-op + same-stage ──────────────────────────────────────────────────

  def test_to_current_stage_is_clean_noop
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        out, _err = capture_io { Hive::Commands::Approve.new(slug, to: "brainstorm").call }
        assert_includes out, "noop"
        assert File.directory?(brainstorm), "noop must not move anything"
      end
    end
  end

  def test_to_current_stage_noop_in_json_emits_noop_field
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        out, _err = capture_io { Hive::Commands::Approve.new(slug, to: "brainstorm", json: true).call }
        payload = JSON.parse(out)
        assert payload["ok"]
        assert payload["noop"]
        assert_equal "same", payload["direction"]
      end
    end
  end

  # ── JSON contract ───────────────────────────────────────────────────────

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

        # Pin the full key set so renames/drops fail at test time.
        expected_keys = %w[
          schema schema_version ok noop slug
          from_stage from_stage_index from_stage_dir
          to_stage to_stage_index to_stage_dir
          direction forced from_folder to_folder from_marker
          commit_action next_action
        ].sort
        assert_equal expected_keys, payload.keys.sort

        assert_equal "hive-approve", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal true, payload["ok"]
        assert_equal false, payload["noop"]
        assert_equal slug, payload["slug"]
        assert_equal "brainstorm", payload["from_stage"]
        assert_equal 2, payload["from_stage_index"]
        assert_equal "2-brainstorm", payload["from_stage_dir"]
        assert_equal "plan", payload["to_stage"]
        assert_equal 3, payload["to_stage_index"]
        assert_equal "3-plan", payload["to_stage_dir"]
        assert_equal "forward", payload["direction"]
        assert_equal false, payload["forced"]
        assert_equal "complete", payload["from_marker"]
        assert_match(%r{/2-brainstorm/#{slug}\z}, payload["from_folder"])
        assert_match(%r{/3-plan/#{slug}\z}, payload["to_folder"])
        assert_includes payload["commit_action"], "approve 2-brainstorm -> 3-plan"

        # next_action: agent reads this to chain the pipeline.
        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::RUN, next_action["kind"]
        assert_includes Hive::Schemas::NextActionKind::ALL, next_action["kind"]
        assert_match(%r{/3-plan/#{slug}\z}, next_action["folder"])
        assert_match(%r{\Ahive run .*/3-plan/#{slug}\z}, next_action["command"])
      end
    end
  end

  def test_json_next_action_at_final_stage_is_no_op_with_reason
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        pr_dir = File.join(dir, ".hive-state", "stages", "5-pr", slug)
        FileUtils.mkdir_p(File.dirname(pr_dir))
        FileUtils.mv(inbox, pr_dir)
        write_marker(pr_dir, :complete)

        out, _err = capture_io { Hive::Commands::Approve.new(slug, json: true).call }
        payload = JSON.parse(out)
        assert_equal "6-done", payload["to_stage_dir"]
        assert_equal Hive::Schemas::NextActionKind::NO_OP, payload["next_action"]["kind"]
        assert_equal "final_stage", payload["next_action"]["reason"]
      end
    end
  end

  def test_json_error_envelope_on_from_mismatch_carries_wrong_stage_kind
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        out, _err, status = with_captured_exit do
          Hive::Commands::Approve.new(slug, from: "1-inbox", json: true).call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status

        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "wrong_stage", payload["error_kind"]
        assert_equal "WrongStage", payload["error_class"]
        assert_equal Hive::ExitCodes::WRONG_STAGE, payload["exit_code"]
        assert_includes payload["message"], "but --from expected 1-inbox"
      end
    end
  end

  def test_json_error_envelope_on_ambiguous_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir1|
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
          slug = "shared-slug-260424-aaaa"
          [ dir1, dir2 ].each do |d|
            FileUtils.mkdir_p(File.join(d, ".hive-state", "stages", "1-inbox", slug))
          end

          out, _err, status = with_captured_exit do
            Hive::Commands::Approve.new(slug, json: true, force: true).call
          end
          assert_equal Hive::ExitCodes::USAGE, status

          payload = JSON.parse(out)
          assert_equal "hive-approve", payload["schema"]
          assert_equal false, payload["ok"]
          assert_equal "AmbiguousSlug", payload["error_class"]
          assert_equal "ambiguous_slug", payload["error_kind"]
          assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
          # Structured candidates rather than prose. Pin the full per-
          # candidate key set so a producer regression that drops `stage`
          # or `folder` fails this test.
          assert_kind_of Array, payload["candidates"]
          assert_equal 2, payload["candidates"].size
          payload["candidates"].each do |candidate|
            assert_equal %w[folder project stage], candidate.keys.sort,
                         "each candidate must have project / stage / folder"
            assert_equal "1-inbox", candidate["stage"]
            assert candidate["folder"].end_with?("/.hive-state/stages/1-inbox/#{slug}"),
                   "candidate folder must point at the actual hit"
          end
          assert_equal [ File.basename(dir1), File.basename(dir2) ].sort,
                       payload["candidates"].map { |c| c["project"] }.sort
        end
      end
    end
  end

  def test_json_error_envelope_on_destination_collision
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)
        FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "3-plan", slug))

        out, _err, status = with_captured_exit { Hive::Commands::Approve.new(brainstorm, json: true).call }
        assert_equal Hive::ExitCodes::GENERIC, status

        payload = JSON.parse(out)
        assert_equal "DestinationCollision", payload["error_class"]
        assert_equal "destination_collision", payload["error_kind"]
        assert_match(%r{/3-plan/#{slug}\z}, payload["path"])
      end
    end
  end

  def test_json_error_envelope_on_final_stage
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        done = File.join(dir, ".hive-state", "stages", "6-done", slug)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(inbox, done)
        write_marker(done, :complete)

        out, _err, status = with_captured_exit { Hive::Commands::Approve.new(slug, json: true).call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status

        payload = JSON.parse(out)
        assert_equal "FinalStageReached", payload["error_class"]
        assert_equal "final_stage", payload["error_kind"]
        assert_equal "6-done", payload["stage"]
      end
    end
  end

  # ── Slug-scoped commit (cross-contamination prevention) ─────────────────

  def test_commit_does_not_sweep_unrelated_sibling_task_changes
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        # Set up the task being approved.
        _, inbox, slug = seed_project_with_inbox_task(dir, text: "primary task")
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # Plant an UNRELATED dirty file under the same source-stage directory.
        # If the commit scopes to slug paths only, this should NOT be in the
        # resulting commit.
        sibling = File.join(dir, ".hive-state", "stages", "2-brainstorm", "sibling-trash-260424-bbbb")
        FileUtils.mkdir_p(sibling)
        File.write(File.join(sibling, "scratch.md"), "I should not be in the approve commit\n")

        capture_io { Hive::Commands::Approve.new(slug).call }

        # Inspect the commit. The sibling's path must NOT appear.
        files_in_commit = `git -C #{File.join(dir, ".hive-state")} show --pretty= --name-only HEAD`.lines.map(&:strip)
        refute_includes files_in_commit, "stages/2-brainstorm/sibling-trash-260424-bbbb/scratch.md",
                        "approve commit must scope to the slug, not sweep stage-level neighbours"
      end
    end
  end

  def test_orphan_task_lock_at_destination_is_not_committed
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        capture_io { Hive::Commands::Approve.new(slug).call }
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        files_in_commit = `git -C #{File.join(dir, ".hive-state")} show --pretty= --name-only HEAD`.lines.map(&:strip)
        refute_includes files_in_commit, "stages/3-plan/#{slug}/.lock",
                        "the per-process .lock file must not be committed"
        refute File.exist?(File.join(plan, ".lock")),
               "orphan .lock from with_task_lock must be cleaned at destination"
      end
    end
  end

  # ── Symlink hardening ───────────────────────────────────────────────────

  def test_symlink_target_outside_hive_state_is_rejected
    # A slug-named symlink at .hive-state/stages/<N>/<slug> pointing outside
    # the hive-state hierarchy must be rejected via realpath. Otherwise an
    # attacker who can write into stages/ could trick approve into mv'ing
    # an arbitrary external directory.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        seed_project_with_inbox_task(dir)
        Dir.mktmpdir("decoy-target") do |external|
          File.write(File.join(external, "decoy.md"), "should never be touched")
          slug = "evil-symlink-260424-abcd"
          symlink_path = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
          FileUtils.mkdir_p(File.dirname(symlink_path))
          File.symlink(external, symlink_path)

          _, err, status = with_captured_exit { Hive::Commands::Approve.new(symlink_path, force: true).call }
          assert_equal Hive::ExitCodes::USAGE, status,
                       "symlink to external path must be refused at the PATH_RE check"
          assert_includes err, "task path must match"
          # External target untouched.
          assert File.exist?(File.join(external, "decoy.md")),
                 "symlink-target's contents must never be moved"
        end
      end
    end
  end

  def test_symlink_in_slug_lookup_is_resolved_via_realpath
    # When a hit returned by find_slug_across_projects is itself a symlink,
    # realpath kicks in and Task.new validates the REAL path, not the link.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        seed_project_with_inbox_task(dir)
        Dir.mktmpdir("external") do |external|
          slug = "evil-link-260424-abcd"
          link_path = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
          FileUtils.mkdir_p(File.dirname(link_path))
          File.symlink(external, link_path)

          _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug, force: true).call }
          assert_equal Hive::ExitCodes::USAGE, status
          assert_includes err, "task path must match"
        end
      end
    end
  end

  # ── TOCTOU concurrent-mkdir ─────────────────────────────────────────────

  def test_concurrent_mkdir_of_non_empty_destination_is_caught_by_rescue
    # Even with the pre-check + commit-lock, a non-hive process could mkdir
    # (and populate) the destination between check and rename. The rescue
    # in move_task! must surface this as DestinationCollision (not as a
    # bare Errno::ENOTEMPTY trace).
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # Stub File.exist? to lie on the pre-check (so we reach the rescue
        # rather than the early-exit), then create a non-empty dir at the
        # destination so File.rename raises ENOTEMPTY.
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(plan)
        File.write(File.join(plan, "stale.md"), "concurrent process left this")

        # Bypass the pre-check by monkey-patching for one assertion. The
        # rescue must catch the rename's ENOTEMPTY and re-raise typed.
        File.singleton_class.alias_method(:__orig_exist?, :exist?)
        first_call_for_dest = true
        File.define_singleton_method(:exist?) do |p|
          if first_call_for_dest && p == plan
            first_call_for_dest = false
            false
          else
            __orig_exist?(p)
          end
        end

        begin
          _, err, status = with_captured_exit { Hive::Commands::Approve.new(brainstorm).call }
          assert_equal Hive::ExitCodes::GENERIC, status,
                       "concurrent-mkdir collision must surface as DestinationCollision"
          assert_includes err, "destination already exists"
        ensure
          File.singleton_class.alias_method(:exist?, :__orig_exist?)
          File.singleton_class.send(:remove_method, :__orig_exist?)
        end
      end
    end
  end

  # ── Rollback on commit failure ──────────────────────────────────────────

  def test_commit_failure_rolls_mv_back_to_source
    # Inject a commit failure via a pre-commit hook that always exits 1.
    # The mv must reverse so the filesystem and git history don't diverge.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        # The hive/state worktree shares its hooks dir with the project's
        # .git/hooks because it's a worktree. A pre-commit hook that exits 1
        # aborts the commit at the kernel level — exactly the production
        # scenario the rollback was designed for.
        hooks_dir = File.join(dir, ".git", "hooks")
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "pre-commit")
        File.write(hook_path, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook_path)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }

        # The typed Hive::GitError surfaces with SOFTWARE (70), preserving
        # the contract code instead of being collapsed to GENERIC (1).
        assert_equal Hive::ExitCodes::SOFTWARE, status,
                     "commit failure must surface the typed GitError exit code, not generic 1"

        # Filesystem rolled back: source restored, destination gone.
        assert File.directory?(brainstorm), "source must be restored on rollback"
        refute File.exist?(File.join(dir, ".hive-state", "stages", "3-plan", slug)),
               "destination must be cleaned up on rollback"

        # Error message names the rollback so a human / agent operator can
        # understand state — the typed Hive::GitError.message describes the
        # commit failure; the rescue path doesn't double-wrap when the
        # underlying error already carried a typed exit code.
        assert_includes err, "commit"
      end
    end
  end

  def test_rollback_failure_surfaces_combined_error_message
    # If the rollback mv ALSO fails (e.g., source path was somehow re-
    # created by a concurrent process between mv and rollback), both errors
    # must surface — original cause AND rollback failure — so the operator
    # has the full picture for manual recovery.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        hooks_dir = File.join(dir, ".git", "hooks")
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "pre-commit")
        File.write(hook_path, "#!/bin/sh\nmkdir -p '#{brainstorm}'\nexit 1\n")
        FileUtils.chmod(0o755, hook_path)

        _, err, status = with_captured_exit { Hive::Commands::Approve.new(slug).call }
        assert_includes [ Hive::ExitCodes::GENERIC, Hive::ExitCodes::SOFTWARE ], status,
                        "rollback-not-possible path produces a typed Hive::Error"
        assert_includes err, "rollback NOT possible"
        assert_includes err, "manual recovery"
      end
    end
  end

  # ── Plain-text output ───────────────────────────────────────────────────

  def test_text_output_includes_next_hint_on_stderr
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, inbox, slug = seed_project_with_inbox_task(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        write_marker(brainstorm, :complete)

        out, err = capture_io { Hive::Commands::Approve.new(slug).call }
        assert_includes out, "hive: approved #{slug}"
        assert_includes out, "from:"
        assert_includes out, "to:"
        # The "next: hive run" hint goes to stderr so a `... | jq`
        # consumer who forgot --json doesn't get prose mixed with data.
        assert_includes err, "next: hive run"
      end
    end
  end
end
