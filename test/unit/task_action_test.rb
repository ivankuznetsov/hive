require "test_helper"
require "fileutils"
require "hive/task"
require "hive/task_action"
require "hive/markers"

# Pin Hive::TaskAction's classification matrix and command-emission rules.
# This module is the central decision point for `hive status` action
# grouping and `next_action.command` strings emitted by every other
# command, so a typo in ACTIONS would silently misroute agents.
class TaskActionTest < Minitest::Test
  Marker = Hive::Markers::State
  FakeTask = Struct.new(
    :stage_name, :stage_index, :slug, :project_root, :project_name, :folder, :state_file,
    keyword_init: true
  )

  def fake_task(stage_name:, stage_index:, slug: "demo-260426-aaaa", project_root: "/x")
    folder = File.join(project_root, ".hive-state", "stages", "#{stage_index}-#{stage_name}", slug)
    FakeTask.new(stage_name: stage_name, stage_index: stage_index, slug: slug,
                 project_root: project_root, project_name: File.basename(project_root),
                 folder: folder, state_file: File.join(folder, "task.md"))
  end

  def marker(name, attrs = {})
    Marker.new(name: name, attrs: attrs, raw: nil)
  end

  # ── classification matrix ─────────────────────────────────────────────

  def test_inbox_marker_waiting_is_ready_to_brainstorm
    task = fake_task(stage_name: "inbox", stage_index: 1)
    action = Hive::TaskAction.for(task, marker(:waiting))
    assert_equal "ready_to_brainstorm", action.key
    assert_equal "Ready to brainstorm", action.label
  end

  def test_brainstorm_complete_is_ready_to_plan
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "ready_to_plan", action.key
    assert_equal "Ready to plan", action.label
  end

  def test_brainstorm_waiting_is_needs_input
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    assert_equal "needs_input", Hive::TaskAction.for(task, marker(:waiting)).key
  end

  def test_plan_complete_is_ready_to_develop
    task = fake_task(stage_name: "plan", stage_index: 3)
    assert_equal "ready_to_develop", Hive::TaskAction.for(task, marker(:complete)).key
  end

  def test_plan_missing_or_empty_output_is_error_not_needs_input
    Dir.mktmpdir("task-action-plan") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "3-plan", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      missing = Hive::TaskAction.for(task, marker(:none))
      assert_equal "needs_input", missing.key,
                   "freshly approved plan-stage folders start without plan.md and must remain runnable"
      assert_equal "hive plan demo-260426-aaaa --from 3-plan", missing.command

      FileUtils.mkdir_p(File.join(dir, ".hive-state", "logs", task.slug))
      File.write(File.join(dir, ".hive-state", "logs", task.slug, "plan-20260519T221007Z.log"), "spawned\n")
      interrupted = Hive::TaskAction.for(task, marker(:none))
      assert_equal "error", interrupted.key
      assert_nil interrupted.command
      assert_match(/Plan is incomplete because .*plan\.md is missing or empty/,
                   interrupted.diagnostic["detail"])

      FileUtils.rm_rf(File.join(dir, ".hive-state", "logs", task.slug))
      File.write(task.state_file, "")
      empty = Hive::TaskAction.for(task, marker(:none))
      assert_equal "error", empty.key
      assert_nil empty.command
      assert_match(/PLAN_MISSING_OUTPUT/, empty.diagnostic["summary"])
      assert_match(/Rerun the plan stage to regenerate plan\.md/, empty.diagnostic["detail"])
      assert_equal "marker", empty.diagnostic["source"]
      assert_equal "retry", empty.diagnostic.fetch("suggested_next_action").fetch("kind")
      assert_equal "hive plan demo-260426-aaaa --from 3-plan",
                   empty.diagnostic.fetch("suggested_next_action").fetch("command")
    end
  end

  def test_execute_complete_is_ready_to_open_pr
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_complete))
    assert_equal "ready_to_open_pr", action.key
    assert_equal "hive open-pr demo-260426-aaaa --from 4-execute", action.command
  end

  def test_open_pr_complete_is_ready_for_review
    task = fake_task(stage_name: "open-pr", stage_index: 5)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "ready_for_review", action.key
    assert_equal "hive review demo-260426-aaaa --from 5-open-pr", action.command
  end

  def test_review_complete_is_ready_to_artifacts
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_complete))
    assert_equal "ready_to_artifacts", action.key
    assert_equal "hive artifacts demo-260426-aaaa --from 6-review", action.command
  end

  def test_markerless_artifacts_is_ready_to_collect_artifacts
    task = fake_task(stage_name: "artifacts", stage_index: 7)
    action = Hive::TaskAction.for(task, marker(:none))
    assert_equal "ready_to_artifacts", action.key
    assert_equal "Ready to collect artifacts", action.label
    assert_equal "hive artifacts demo-260426-aaaa --from 7-artifacts", action.command
  end

  def test_complete_artifacts_is_ready_to_finalize
    task = fake_task(stage_name: "artifacts", stage_index: 7)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "ready_to_finalize", action.key
    assert_equal "hive finalize demo-260426-aaaa --from 7-artifacts", action.command
  end

  def test_review_without_marker_is_ready_for_review
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:none))
    assert_equal "ready_for_review", action.key
    assert_equal "Ready for review", action.label
    assert_match(/\Ahive review demo-260426-aaaa --from 6-review\z/, action.command)
  end

  def test_review_waiting_is_needs_input
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_waiting, "pass" => "2"))
    assert_equal "needs_input", action.key
    assert_equal "Needs your input", action.label
  end

  # REVIEW_WORKING is the review stage's in-flight marker. Pre-fix, it
  # fell through to :review_waiting and emitted a runnable
  # `hive review … --from 6-review` command while review was active —
  # running it would acquire-then-fail the per-task lock with
  # ConcurrentRunError. Treat as in-flight (agent_running) so the TUI's
  # verb-refusal flash + log-tail-on-Enter path covers review-stage rows.
  def test_review_working_is_agent_running_with_no_command
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_working, "phase" => "reviewers"))
    assert_equal "agent_running", action.key,
      "REVIEW_WORKING must surface as agent_running so dispatch refuses while review is active"
    assert_nil action.command,
      "no command for an in-flight stage — pressing the verb key flashes refusal"
  end

  def test_execute_waiting_is_needs_input
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_waiting))
    assert_equal "needs_input", action.key
  end

  def test_legacy_execute_waiting_with_findings_surfaces_recovery_findings_cli
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 3))

    assert_equal "recover_execute", action.key
    assert_equal "Needs recovery", action.label
    assert_equal "hive findings demo-260426-aaaa", action.command
    assert_nil action.next_action,
               "legacy findings rows should not fall through to ExecuteWaitingAction edit guidance"
  end

  def test_execute_waiting_no_changes_exposes_structured_next_action
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(
      task,
      marker(:execute_waiting, "reason" => "no_worktree_changes")
    )

    next_action = action.next_action
    assert_equal Hive::Schemas::NextActionKind::EDIT, next_action["kind"]
    assert_equal File.join(task.folder, "plan.md"), next_action["target"]
    assert_equal "hive develop demo-260426-aaaa --from 4-execute", next_action["rerun_with"]
  end

  def test_finalize_complete_is_ready_to_archive
    Dir.mktmpdir("task-action-finalize") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "8-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        stage_name: "finalize",
        stage_index: 8,
        slug: "demo-260426-aaaa",
        project_root: dir,
        project_name: File.basename(dir),
        folder: folder,
        state_file: File.join(folder, "pr.md")
      )
      File.write(task.state_file, <<~MD)
        ---
        pr_url: https://example.com/pr/9
        ---

        <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
      MD

      assert_equal "ready_to_archive",
                   Hive::TaskAction.for(
                     task,
                     marker(:complete, "pr_url" => "https://example.com/pr/9", "is_draft" => "false")
                   ).key
    end
  end

  def test_finalize_complete_requires_final_pr_metadata_before_archive
    Dir.mktmpdir("task-action-finalize") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "8-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        stage_name: "finalize",
        stage_index: 8,
        slug: "demo-260426-aaaa",
        project_root: dir,
        project_name: File.basename(dir),
        folder: folder,
        state_file: File.join(folder, "pr.md")
      )

      File.write(task.state_file, "<!-- COMPLETE is_draft=false -->\n")
      missing_url = Hive::TaskAction.for(task, marker(:complete, "is_draft" => "false"))
      assert_equal "error", missing_url.key
      assert_match(/FINALIZE_MISSING_PR_URL/, missing_url.diagnostic["summary"])

      File.write(task.state_file, <<~MD)
        ---
        pr_url: https://example.com/pr/9
        ---

        <!-- COMPLETE pr_url=https://example.com/pr/other is_draft=false -->
      MD
      mismatch = Hive::TaskAction.for(
        task,
        marker(:complete, "pr_url" => "https://example.com/pr/other", "is_draft" => "false")
      )
      assert_equal "error", mismatch.key
      assert_match(/FINALIZE_PR_URL_MISMATCH/, mismatch.diagnostic["summary"])

      open_pr_marker = Hive::TaskAction.for(
        task,
        marker(:complete, "pr_url" => "https://example.com/pr/9", "is_draft" => "true")
      )
      assert_equal "ready_to_finalize", open_pr_marker.key,
                   "open-pr's is_draft=true COMPLETE marker must not look archive-ready"
      assert_equal "hive finalize demo-260426-aaaa --from 8-finalize", open_pr_marker.command
    end
  end

  def test_finalize_complete_with_invalid_pr_frontmatter_reports_missing_url
    Dir.mktmpdir("task-action-finalize-frontmatter") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        stage_name: "finalize",
        stage_index: 7,
        slug: "demo-260426-aaaa",
        project_root: dir,
        project_name: File.basename(dir),
        folder: folder,
        state_file: File.join(folder, "pr.md")
      )
      File.write(task.state_file, "---\n: bad\n---\n")

      action = Hive::TaskAction.for(
        task,
        marker(:complete, "pr_url" => "https://example.com/pr/9", "is_draft" => "false")
      )

      assert_equal "error", action.key
      assert_match(/FINALIZE_MISSING_PR_URL/, action.diagnostic.fetch("summary"))
      assert_equal "manual_fix", action.diagnostic.fetch("suggested_next_action").fetch("kind")
    end
  end

  def test_finalize_missing_pr_md_is_error_not_needs_input
    Dir.mktmpdir("task-action-finalize") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "8-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        stage_name: "finalize",
        stage_index: 8,
        slug: "demo-260426-aaaa",
        project_root: dir,
        project_name: File.basename(dir),
        folder: folder,
        state_file: File.join(folder, "pr.md")
      )

      action = Hive::TaskAction.for(task, marker(:none))

      assert_equal "error", action.key
      assert_equal "Error", action.label
      assert_nil action.command
      assert_match(/Finalize cannot run because .*pr\.md is missing/, action.diagnostic["detail"])
    end
  end

  def test_finalize_missing_metadata_error_is_manual_fix_not_retry
    Dir.mktmpdir("task-action-finalize") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "8-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        stage_name: "finalize",
        stage_index: 8,
        slug: "demo-260426-aaaa",
        project_root: dir,
        project_name: File.basename(dir),
        folder: folder,
        state_file: File.join(folder, "pr.md")
      )

      %w[missing_pr_md missing_pr_url].each do |reason|
        diagnostic = Hive::TaskAction.for(task, marker(:error, "reason" => reason)).diagnostic
        suggested = diagnostic.fetch("suggested_next_action")

        assert_equal "manual_fix", suggested.fetch("kind"), "reason=#{reason}"
        assert_nil suggested["command"], "reason=#{reason}"
      end
    end
  end

  def test_done_is_archived_with_no_command
    task = fake_task(stage_name: "done", stage_index: 9)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "archived", action.key
    assert_nil action.command, "archived state has no runnable command"
  end

  # ── carve-outs ─────────────────────────────────────────────────────────

  def test_agent_working_marker_overrides_every_stage
    # Surfacing a workflow command for an in-flight agent would send
    # retry loops into ConcurrentRunError. Always agent_running, no command.
    %w[brainstorm plan execute open-pr review finalize].each do |stage|
      task = fake_task(stage_name: stage, stage_index: Hive::Stages::NAMES.index(stage) + 1)
      action = Hive::TaskAction.for(task, marker(:agent_working, "pid" => "12345"),
                                    pid_alive: true)
      assert_equal "agent_running", action.key, "stage=#{stage} must short-circuit to agent_running"
      assert_equal "Agent running", action.label
      assert_nil action.command, "agent_running must emit no command"
    end
  end

  def test_manual_steering_marker_is_non_actionable_in_execute_stage
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:manual_steering, "agent" => "claude"))

    assert_equal "manual_steering", action.key
    assert_equal "Manually steered", action.label
    assert_nil action.command, "manual steering rows must not expose a workflow command"
  end

  def test_manual_steering_marker_overrides_early_stage_classification
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:manual_steering, "agent" => "codex"))

    assert_equal "manual_steering", action.key
    assert_equal "Manually steered", action.label
    assert_nil action.command
  end

  def test_agent_working_with_dead_pid_classifies_as_error
    # Liveness signal: marker has pid attr AND caller passes
    # pid_alive: false → the agent died without rewriting its own
    # marker. Classifying as :agent_running would lie to every
    # consumer (TUI, bot, daemon) about there being live work.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(
      task, marker(:agent_working, "pid" => "12345"), pid_alive: false
    )
    assert_equal "error", action.key,
                 "dead-pid AGENT_WORKING must classify as error so the row stops claiming the agent is running"
    assert_nil action.command
    diag = action.diagnostic
    refute_nil diag, "stale agent_working must emit a synthetic diagnostic so the red-status surface has something to render"
    assert_includes diag["summary"], "12345",
                    "diagnostic summary should surface the recorded pid for operator triage"
  end

  def test_agent_working_with_no_pid_and_old_mtime_classifies_as_error
    # The placeholder case: executor stage stamps AGENT_WORKING with no
    # pid attribute on stage entry. If the dispatcher never attaches an
    # agent, the marker just lingers — this was the original bug. Once
    # the placeholder is older than the grace window, classify as
    # :error reason=agent_orphaned.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(
      task, marker(:agent_working),
      pid_alive: nil,
      state_file_mtime: Time.now - 600,
      agent_marker_grace_sec: 300
    )
    assert_equal "error", action.key
    assert_match(/never attached/, action.diagnostic["summary"])
  end

  def test_synthetic_stale_agent_diagnostic_suggests_a_command_in_markers_clear_allowlist
    # The synthetic diagnostic's `detail` text instructs the operator
    # to run `hive markers clear <slug> --name ERROR`. If a future
    # rename in lib/hive/commands/markers.rb#ALLOWED_NAMES ships a
    # different terminal-recovery marker, this test catches the drift
    # at unit-test time rather than at customer-frustration time
    # (exit 4 from a copy-paste).
    require "hive/commands/markers"
    task = fake_task(stage_name: "execute", stage_index: 4)
    pattern = /clear[^\n]*--name ([A-Z_]+)/

    # agent_died branch: marker has pid attr, claude_pid_alive=false.
    died_action = Hive::TaskAction.for(
      task, marker(:agent_working, "pid" => "12345"),
      pid_alive: false, agent_marker_grace_sec: 300
    )
    died_detail = died_action.diagnostic["detail"]
    died_match = died_detail.match(pattern)
    assert died_match, "agent_died synthetic detail must include a `markers clear --name X` command; got: #{died_detail.inspect}"
    assert_includes Hive::Commands::Markers::ALLOWED_NAMES, died_match[1],
                    "agent_died synthetic detail suggests `--name #{died_match[1]}` which is not in ALLOWED_NAMES"

    # agent_orphaned branch: marker has NO pid attr, mtime past grace.
    orphan_action = Hive::TaskAction.for(
      task, marker(:agent_working),
      pid_alive: nil, state_file_mtime: Time.now - 600, agent_marker_grace_sec: 300
    )
    orphan_detail = orphan_action.diagnostic["detail"]
    orphan_match = orphan_detail.match(pattern)
    assert orphan_match, "agent_orphaned synthetic detail must include a `markers clear --name X` command; got: #{orphan_detail.inspect}"
    assert_includes Hive::Commands::Markers::ALLOWED_NAMES, orphan_match[1],
                    "agent_orphaned synthetic detail suggests `--name #{orphan_match[1]}` which is not in ALLOWED_NAMES"
  end

  def test_agent_working_with_no_pid_within_grace_stays_agent_running
    # Within the grace window the daemon is presumed to be mid-spawn.
    # Classifying as :error here would race the dispatcher.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(
      task, marker(:agent_working),
      pid_alive: nil,
      state_file_mtime: Time.now - 60,
      agent_marker_grace_sec: 300
    )
    assert_equal "agent_running", action.key
  end

  def test_agent_working_without_liveness_signal_falls_back_to_agent_running
    # Backward compat: callers that haven't been updated to pass
    # pid_alive/state_file_mtime should see the original behavior.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:agent_working))
    assert_equal "agent_running", action.key
  end

  def test_error_marker_overrides_every_stage
    %w[brainstorm plan execute open-pr review finalize].each do |stage|
      task = fake_task(stage_name: stage, stage_index: 2)
      action = Hive::TaskAction.for(task, marker(:error, "reason" => "agent_crashed"))
      assert_equal "error", action.key
      assert_nil action.command, "error state has no runnable command"
    end
  end

  def test_execute_stale_routes_to_findings_not_develop
    # Running `hive develop slug` against a stale execute task would
    # refuse on the non-terminal marker; pointing at findings opens
    # the recovery loop instead of a verb-rejection loop.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_stale, "max_passes" => 4))
    assert_equal "recover_execute", action.key
    assert_equal "Needs recovery", action.label
    assert_match(/\Ahive findings demo-260426-aaaa/, action.command,
                 "execute_stale must point at findings (recovery), not develop (would loop)")
  end

  # Generic verbs (`findings` and friends) only carry `--stage` when slug
  # collision actually exists, so the common single-task command stays
  # clean. Both EXECUTE_STALE and legacy EXECUTE_WAITING findings rows
  # emit the findings verb through the recover_execute action surface.
  def test_findings_command_uses_stage_only_on_collision
    task = fake_task(stage_name: "execute", stage_index: 4)
    no_collision = Hive::TaskAction.for(task, marker(:execute_stale, "max_passes" => 4))
    assert_equal "hive findings demo-260426-aaaa", no_collision.command,
                 "findings command must NOT carry --stage absent collision"

    with_collision = Hive::TaskAction.for(task, marker(:execute_stale, "max_passes" => 4),
                                          stage_collision: true)
    assert_equal "hive findings demo-260426-aaaa --stage 4-execute", with_collision.command,
                 "findings command must carry --stage when status.rb flags a slug collision"

    legacy_no_collision = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 2))
    assert_equal "hive findings demo-260426-aaaa", legacy_no_collision.command

    legacy_with_collision = Hive::TaskAction.for(
      task,
      marker(:execute_waiting, "findings_count" => 2),
      stage_collision: true
    )
    assert_equal "hive findings demo-260426-aaaa --stage 4-execute", legacy_with_collision.command
  end

  # Canary for the post-PR #122 invariant: no producer in Hive::TaskAction
  # should ever emit the removed `review_findings` action key. A future
  # revert or parallel branch reintroducing a `findings_count`-bearing
  # EXECUTE_WAITING writer must route through `recover_execute`, not the
  # deleted enum value or a generic `needs_input` edit path. This canary
  # fails fast at unit-test time.
  def test_no_producer_emits_review_findings
    stage_markers = [
      [ "brainstorm",  2, [ :waiting, :complete, :agent_working, :error ] ],
      [ "plan",        3, [ :waiting, :complete, :agent_working, :error ] ],
      [ "execute",     4, [ :execute_waiting, :execute_complete, :execute_stale, :agent_working, :error ] ],
      [ "open-pr",     5, [ :waiting, :complete, :agent_working, :error ] ],
      [ "review",      6, [ :review_working, :review_waiting, :review_complete, :review_stale, :review_error, :review_ci_stale, :agent_working, :error ] ],
      [ "finalize",    7, [ :waiting, :complete, :agent_working, :error ] ]
    ]

    stage_markers.each do |stage_name, stage_index, marker_names|
      marker_names.each do |marker_name|
        # Cover both "no attrs" and "findings_count carried as legacy
        # attr" — the latter is the case that pre-PR #122 routed to
        # `review_findings` and must now route through recover_execute.
        [ {}, { "findings_count" => 3 } ].each do |attrs|
          task = fake_task(stage_name: stage_name, stage_index: stage_index)
          action = Hive::TaskAction.for(task, marker(marker_name, **attrs))
          refute_equal "review_findings", action.key,
                       "no producer may emit `review_findings` " \
                       "(stage=#{stage_name} marker=#{marker_name} attrs=#{attrs.inspect}); " \
                       "see ADR-028 in wiki/decisions.md"
          if stage_name == "execute" && marker_name == :execute_waiting && attrs["findings_count"]
            assert_equal "recover_execute", action.key,
                         "legacy findings_count waits must stay a human recovery gate"
          end
        end
      end
    end
  end

  # ── command emission ──────────────────────────────────────────────────

  def test_workflow_verbs_always_include_from_for_idempotency
    # Single-project, no slug collision — workflow verb commands STILL
    # carry --from <stage> so a retry after a successful advance hits
    # WRONG_STAGE (4) instead of silently advancing twice.
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "hive plan demo-260426-aaaa --from 2-brainstorm", action.command
  end

  def test_workflow_verb_command_includes_project_when_multi_project
    task = fake_task(stage_name: "plan", stage_index: 3, project_root: "/proj-a")
    action = Hive::TaskAction.for(task, marker(:complete), project_name: "proj-a", project_count: 3)
    assert_equal "hive develop demo-260426-aaaa --project proj-a --from 3-plan", action.command
  end

  def test_command_shellescapes_slug_with_special_characters
    task = fake_task(stage_name: "brainstorm", stage_index: 2, slug: "weird slug")
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_includes action.command, "weird\\ slug",
                    "shelljoin must escape whitespace"
  end

  # ── payload shape ──────────────────────────────────────────────────────

  def test_payload_has_expected_keys
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    payload = Hive::TaskAction.for(task, marker(:complete)).payload
    assert_equal %w[command key label next_action].sort, payload.keys.sort
    assert_equal "ready_to_plan", payload["key"]
  end

  def test_non_recovery_rows_do_not_emit_diagnostic
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:complete))

    assert_nil action.diagnostic
  end

  def test_review_error_diagnostic_points_at_relevant_artifact_and_redacts_secrets
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      artifact = File.join(reviews, "fix-guardrail-04.md")
      token = "ghp_#{'a' * 40}"
      File.write(artifact, "Fix guardrail failed with #{token}\n")

      action = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "reason" => "fix_guardrail", "pass" => "4")
      )
      diagnostic = action.diagnostic

      assert_equal "artifact", diagnostic["source"]
      assert_equal artifact, diagnostic["source_path"]
      assert_includes diagnostic["artifact_paths"], artifact
      assert_includes diagnostic["summary"], "REVIEW_ERROR"
      assert_includes diagnostic["summary"], "reason=fix_guardrail"
      assert_includes diagnostic["detail"], "[REDACTED:github_token]"
      refute_includes diagnostic["detail"], token
      assert_equal "local", diagnostic["generated_by"]
    end
  end

  def test_diagnostic_rejects_artifact_symlink_escape
    Dir.mktmpdir("hive-task-action-symlink") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      outside = File.join(root, "..", "outside-secret.md")
      File.write(outside, "outside diagnostic secret\n")
      symlink = File.join(reviews, "errors-04.md")
      File.symlink(outside, symlink)

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "reason" => "timeout", "pass" => "4")
      ).diagnostic

      refute_equal symlink, diagnostic["source_path"]
      refute_includes diagnostic["artifact_paths"], symlink
      refute_includes diagnostic["detail"], "outside diagnostic secret"
      assert_equal "marker", diagnostic["source"]
    end
  end

  def test_review_ci_stale_diagnostic_points_at_ci_blocked_artifact
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      ci_blocked = File.join(reviews, "ci-blocked.md")
      File.write(ci_blocked, "CI failed on bundle exec rake test\n")

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_ci_stale, "attempts" => "3")
      ).diagnostic

      assert_equal "artifact", diagnostic["source"]
      assert_equal ci_blocked, diagnostic["source_path"]
      assert_includes diagnostic["summary"], "REVIEW_CI_STALE"
      assert_includes diagnostic["detail"], "bundle exec rake test"
    end
  end

  def test_legacy_execute_waiting_with_findings_emits_recovery_diagnostic
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "execute", stage_index: 4, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "ce-review-01.md"), "legacy finding remains\n")

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:execute_waiting, "findings_count" => "1")
      ).diagnostic

      refute_nil diagnostic
      assert_includes diagnostic["summary"], "EXECUTE_WAITING"
      assert_includes diagnostic["detail"], "legacy finding remains"
      assert_equal "manual_fix", diagnostic.fetch("suggested_next_action").fetch("kind")
      assert_nil diagnostic.fetch("suggested_next_action")["command"]
    end
  end

  def test_execute_stale_recovery_emits_diagnostic_for_external_consumers
    # ADR-027 and wiki/commands/status.md commit to emitting bounded
    # diagnostics for ALL three red action_keys (recover_review, error,
    # recover_execute). Bot / daemon / external-agent consumers reading
    # `hive status --json` need the diagnostic to explain why an
    # EXECUTE_STALE task is stuck — even though the TUI red_status_detail
    # view doesn't yet render this case. Without the diagnostic, the
    # whole class of execute-stalled tasks becomes invisible to those
    # consumers.
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "execute", stage_index: 4, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "ce-review-02.md"), "P1 finding remains unresolved\n")

      diagnostic = Hive::TaskAction.for(task, marker(:execute_stale, "pass" => "2")).diagnostic

      refute_nil diagnostic, "EXECUTE_STALE must emit a diagnostic for non-TUI consumers"
      assert_includes diagnostic["summary"], "EXECUTE_STALE"
      assert_includes diagnostic["detail"], "P1 finding remains unresolved"
    end
  end

  def test_diagnostic_artifact_resolves_through_symlinked_hive_state
    # Deployment pattern: .hive-state symlinked to a separate volume
    # (state on a fast-SSD partition, project on a slower share). The
    # task.folder.realpath then lands OUTSIDE project_root.realpath
    # but the artifact is still legitimate. Pre-fix, the project_root
    # containment guard in diagnostic_roots dropped every artifact in
    # this layout and the operator silently saw "no diagnostic
    # available" for paid-for agent verdicts. See PR #84 review C4.
    Dir.mktmpdir("hive-task-action") do |root|
      state_volume = File.join(root, "state-volume")
      FileUtils.mkdir_p(state_volume)
      symlinked_state = File.join(root, "project", ".hive-state")
      FileUtils.mkdir_p(File.dirname(symlinked_state))
      File.symlink(state_volume, symlinked_state)

      slug = "red-260519-symlink"
      folder = File.join(symlinked_state, "stages", "6-review", slug)
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      File.write(File.join(folder, "task.md"), "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      File.write(File.join(folder, "reviews", "errors-01.md"), "fix failed\n")

      task = Hive::Task.new(folder)
      diagnostic = Hive::TaskAction.for(task, marker(:review_error, "phase" => "fix", "pass" => "1")).diagnostic

      refute_nil diagnostic
      assert_equal "artifact", diagnostic["source"]
      assert_includes diagnostic["detail"], "fix failed",
                      "symlinked .hive-state must not invisible legitimate diagnostic artifacts"
    end
  end

  def test_execute_stale_emits_manual_fix_suggested_next_action
    # EXECUTE_STALE has no auto-retry recipe — the operator must edit
    # findings or lower the pass counter. Emit manual_fix with
    # command: null so agent consumers see an explicit "do not auto-
    # retry" signal rather than absence of data. See PR #84 review
    # finding #9.
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "execute", stage_index: 4, project_root: root)
      FileUtils.mkdir_p(task.folder)

      diagnostic = Hive::TaskAction.for(task, marker(:execute_stale, "pass" => "2")).diagnostic

      refute_nil diagnostic
      suggested = diagnostic["suggested_next_action"]
      refute_nil suggested,
                 "EXECUTE_STALE must emit a suggested_next_action so agents see an explicit do-not-retry signal"
      assert_equal "manual_fix", suggested["kind"]
      assert_nil suggested["command"], "manual_fix carries no shell recipe"
    end
  end

  def test_diagnostic_redacts_before_truncating_so_boundary_secrets_dont_leak
    # PR #84 review row 1: a secret straddling the truncation boundary
    # (summary 120 / detail 4000 chars) used to escape redaction because
    # truncate ran first, splitting the credential and hiding only the
    # trailing half. Re-ordered to redact-then-truncate; pin the invariant
    # so a future contributor cannot flip the call order silently.
    Dir.mktmpdir("hive-task-action-redact") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)

      # Use a github_token-shaped credential (no \b prefix requirement)
      # so the marker-built string actually matches a redaction pattern
      # when interpolated next to other word characters. Place the token
      # so that the truncation boundary (DIAGNOSTIC_SUMMARY_MAX) lands in
      # the middle of the credential — pre-redaction truncation would
      # leave the leading half intact in the emitted summary.
      gh_token = "ghp_#{'A' * 40}"
      summary_max = Hive::TaskAction::DIAGNOSTIC_SUMMARY_MAX
      # The marker_summary is "REVIEW_ERROR phase=fix pass=4 reason=<padding><token>".
      # We need the cut point to fall inside the token bytes — choose a
      # padding that leaves the token spanning the cut.
      prefix = "REVIEW_ERROR phase=fix pass=4 reason="
      padding_len = summary_max - prefix.length - 10  # cut ~10 chars into the token
      padding = " x" * (padding_len / 2)              # spaces give SecretPatterns a clean boundary
      reason = "#{padding}#{gh_token}"
      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "pass" => "4", "reason" => reason)
      ).diagnostic

      # Negative invariants: the original token bytes (and any leading
      # half thereof) MUST NOT appear in the emitted summary or detail.
      # Pre-fix code would emit `ghp_AAAAAAA…` (leading half + ellipsis)
      # because truncate fired before redact and split the token.
      refute_includes diagnostic["summary"], gh_token,
                      "summary must not contain the raw GitHub token (redact-then-truncate)"
      refute_match(/ghp_A{4,}/, diagnostic["summary"],
                   "summary must not leak ANY leading half of the token — " \
                   "truncate-after-redact ordering is load-bearing for boundary secrets")
      refute_includes diagnostic["detail"], gh_token,
                      "detail must not contain the raw GitHub token"
      refute_match(/ghp_A{4,}/, diagnostic["detail"],
                   "detail must not leak ANY leading half of the token")
    end
  end

  # Two-gate trust check: fresh_diagnosis_artifact rejects on EITHER
  # marker_signature mismatch OR unknown generated_by. Pinning both
  # rejection paths so a future refactor cannot drop one gate silently
  # (the artifact would then describe stale state OR be authored by an
  # untrusted profile).
  def test_fresh_diagnosis_artifact_rejected_when_marker_signature_stale
    Dir.mktmpdir("hive-task-action-stale") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      diagnostics = File.join(task.folder, "diagnostics")
      FileUtils.mkdir_p(diagnostics)
      # Plant an artifact whose frontmatter pins a DIFFERENT marker
      # signature than the current marker. Trust gate must reject.
      stale_signature = Digest::SHA256.hexdigest("review_error\npass=999\nphase=stale")
      File.write(File.join(diagnostics, "red-status.md"), <<~MD)
        ---
        generated_by: claude
        marker_signature: #{stale_signature}
        diagnosed_at: 2026-05-16T00:00:00Z
        ---
        # Red Status Diagnosis

        stale verdict body
      MD

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "pass" => "1")
      ).diagnostic

      refute_nil diagnostic
      refute_equal "artifact", diagnostic["source"],
                   "stale-signature artifact must NOT be surfaced as the diagnostic source"
      refute_includes diagnostic["detail"], "stale verdict body",
                      "stale artifact body must not leak into the diagnostic detail"
      assert_equal "local", diagnostic["generated_by"],
                   "rejected artifact falls back to local extraction (generated_by: 'local')"
    end
  end

  def test_fresh_diagnosis_artifact_rejected_when_generator_unknown
    Dir.mktmpdir("hive-task-action-evil") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      diagnostics = File.join(task.folder, "diagnostics")
      FileUtils.mkdir_p(diagnostics)
      # Plant an artifact whose generated_by is NOT in the registered
      # AgentProfiles registry. Even with a matching marker_signature,
      # the trust gate must reject — a malicious actor with write access
      # to diagnostics/ should not be able to inject arbitrary
      # diagnostic text under a profile they invented.
      current_signature = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
      File.write(File.join(diagnostics, "red-status.md"), <<~MD)
        ---
        generated_by: evil-profile
        marker_signature: #{current_signature}
        diagnosed_at: 2026-05-16T00:00:00Z
        ---
        # Red Status Diagnosis

        evil verdict body
      MD

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "pass" => "1")
      ).diagnostic

      refute_nil diagnostic
      refute_equal "evil-profile", diagnostic["generated_by"],
                   "untrusted generator must not surface as generated_by"
      refute_includes diagnostic["detail"], "evil verdict body",
                      "untrusted artifact body must not leak into the diagnostic detail"
    end
  end

  # marker_signature is SHA-256(marker_name + sorted_attr_pairs) so a
  # red → green → same-shape red rotation cycle produces an IDENTICAL
  # signature across episodes. The signature check alone cannot tell
  # them apart. fresh_diagnosis_artifact rejects when the artifact mtime
  # predates the state_file mtime (every marker rotation touches the
  # state_file). See issue #89.
  def test_fresh_diagnosis_artifact_rejected_when_predates_state_file
    Dir.mktmpdir("hive-task-action-rotation") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      FileUtils.mkdir_p(task.folder)
      # Write the state_file FIRST and capture its mtime; the artifact
      # we plant will have an earlier mtime, simulating a stale
      # diagnosis from a previous red-episode in the same rotation
      # cycle.
      File.write(task.state_file, "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      diagnostics = File.join(task.folder, "diagnostics")
      FileUtils.mkdir_p(diagnostics)
      current_signature = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
      artifact = File.join(diagnostics, "red-status.md")
      File.write(artifact, <<~MD)
        ---
        generated_by: claude
        marker_signature: #{current_signature}
        diagnosed_at: 2026-05-16T00:00:00Z
        ---
        # Red Status Diagnosis

        verdict from a previous red episode (cycle collision)
      MD
      # Roll the artifact mtime back so it visibly predates the
      # state_file. 60s is well above any filesystem mtime granularity.
      File.utime(Time.now - 120, Time.now - 120, artifact)

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "pass" => "1")
      ).diagnostic

      refute_nil diagnostic
      refute_equal "artifact", diagnostic["source"],
                   "artifact older than state_file must NOT be surfaced (rotation-cycle collision)"
      refute_includes diagnostic["detail"], "previous red episode",
                      "stale-rotation artifact body must not leak into diagnostic detail"
      assert_equal "local", diagnostic["generated_by"],
                   "rejected stale-rotation artifact falls back to local extraction"
    end
  end

  def test_fresh_diagnosis_artifact_accepted_when_artifact_newer_than_state_file
    # Inverse of the rotation-cycle case: a fresh artifact written
    # AFTER the most recent marker rotation must still be trusted.
    # Regression guard so the mtime check doesn't accidentally reject
    # legitimate freshly-written diagnoses.
    Dir.mktmpdir("hive-task-action-fresh-mtime") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      FileUtils.mkdir_p(task.folder)
      File.write(task.state_file, "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      File.utime(Time.now - 120, Time.now - 120, task.state_file)
      diagnostics = File.join(task.folder, "diagnostics")
      FileUtils.mkdir_p(diagnostics)
      current_signature = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
      artifact = File.join(diagnostics, "red-status.md")
      File.write(artifact, <<~MD)
        ---
        generated_by: claude
        marker_signature: #{current_signature}
        diagnosed_at: 2026-05-16T00:00:00Z
        ---
        # Red Status Diagnosis

        fresh-after-rotation verdict
      MD
      # artifact mtime defaults to now (newer than state_file's -120s).

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "fix", "pass" => "1")
      ).diagnostic

      refute_nil diagnostic
      assert_equal "artifact", diagnostic["source"],
                   "fresh artifact (mtime newer than state_file) must be accepted"
      assert_equal "claude", diagnostic["generated_by"]
    end
  end

  def test_recovery_diagnostic_falls_back_to_marker_when_artifacts_are_missing
    Dir.mktmpdir("hive-task-action") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      FileUtils.mkdir_p(task.folder)
      File.write(task.state_file, "<!-- REVIEW_ERROR phase=triage pass=7 -->\n")

      diagnostic = Hive::TaskAction.for(
        task,
        marker(:review_error, "phase" => "triage", "pass" => "7")
      ).diagnostic

      assert_equal "marker", diagnostic["source"]
      assert_nil diagnostic["source_path"]
      assert_empty diagnostic["artifact_paths"]
      assert_includes diagnostic["detail"], "No diagnostic artifact"
    end
  end

  # ── closed enum membership ─────────────────────────────────────────────

  def test_every_action_key_is_in_closed_enum
    Hive::TaskAction::ACTIONS.each_value do |entry|
      assert_includes Hive::Schemas::TaskActionKind::ALL, entry[:key],
                      "TaskAction emits key #{entry[:key].inspect} not in TaskActionKind::ALL"
    end
  end

  # ── cross-layer contracts (the dogfood-found bug) ──────────────────────
  #
  # These tests pin contracts between TaskAction (what gets surfaced to
  # the user as "Ready for X") and the CLI layer (what `hive X` actually
  # accepts). A drift here is the bug pattern that surfaced when the
  # `hive tui` "Ready for PR" rows kept dispatching `hive pr` and
  # raising WrongStage on every press because the CLI's terminal-marker
  # whitelist had a stale gap.

  ADVANCE_VERBS_TO_TERMINAL_MARKERS = {
    # verb → marker that review/etc. writes when the stage is done
    # and the next workflow verb should accept the task. Each pair
    # comes directly from a TaskAction ACTIONS row that maps a marker
    # name to a `command:`. Adding a new advance pair anywhere must
    # come with a new entry here AND the marker must be in
    # `Hive::Markers::TERMINAL_MARKER_NAMES`.
    "plan" => :complete,           # 2-brainstorm finishes with :complete
    "develop" => :complete,        # 3-plan finishes with :complete
    "open-pr" => :execute_complete, # 4-execute finishes with :execute_complete
    "review" => :complete,          # 5-open-pr finishes with :complete
    "artifacts" => :review_complete, # 6-review finishes with :review_complete
    "finalize" => :complete,        # 7-artifacts finishes with :complete
    "archive" => :complete          # 8-finalize finishes with :complete
  }.freeze

  # Pin the constant <-> map relationship: every marker that a
  # workflow verb advances FROM must be in TERMINAL_MARKER_NAMES.
  # If someone adds a new advance pair to the map without updating
  # the constant, this test fails loudly.
  def test_advance_verb_markers_are_in_terminal_marker_names_constant
    require "hive/markers"
    ADVANCE_VERBS_TO_TERMINAL_MARKERS.each_value do |marker_name|
      assert_includes Hive::Markers::TERMINAL_MARKER_NAMES, marker_name,
        "marker :#{marker_name} is referenced as an advance source but isn't " \
        "in `Hive::Markers::TERMINAL_MARKER_NAMES`. Add it to the constant " \
        "in lib/hive/markers.rb so every layer (StageAction#terminal_marker?, " \
        "Run#json_next_action, the TUI) picks it up."
    end
  end

  # Pin: every workflow advance verb's `terminal_marker?` whitelist
  # accepts the corresponding stage-terminal marker. This is the test
  # that would have caught the U11 dogfood bug — `:review_complete`
  # was missing from `terminal_marker?`, so `hive artifacts --from 6-review`
  # rejected its only valid pre-advance marker.
  def test_stage_action_terminal_marker_accepts_every_advance_marker
    require "hive/commands/stage_action"

    ADVANCE_VERBS_TO_TERMINAL_MARKERS.each do |verb, marker_name|
      m = marker(marker_name)
      probe = Hive::Commands::StageAction.allocate
      assert probe.send(:terminal_marker?, m),
             "TaskAction routes #{marker_name.inspect} → 'hive #{verb}' but " \
             "StageAction#terminal_marker? rejects :#{marker_name}; the TUI's " \
             "advance row for this state would WrongStage on every dispatch. " \
             "Add :#{marker_name} to the whitelist in " \
             "lib/hive/commands/stage_action.rb#terminal_marker?."
    end
  end

  # Pin: every workflow advance row in TaskAction emits a verb that
  # exists in `Hive::Workflows::VERBS`. Drift here would mean the
  # TUI's "Ready to X" row dispatches `hive ship` (typo) and the
  # CLI returns "command not found" via Thor.
  def test_every_advance_action_command_is_a_workflow_verb
    require "hive/workflows"

    Hive::TaskAction::ACTIONS.each do |state, entry|
      command = entry[:command]
      next if command.nil?
      # Skip non-workflow-verb commands ("findings" routes to the
      # accept/reject toggler, not StageAction).
      next unless Hive::Workflows.workflow_verb?(command)

      assert_includes Hive::Workflows::VERBS.keys, command,
                      "TaskAction state :#{state} advertises command 'hive #{command}' " \
                      "but it isn't in Hive::Workflows::VERBS"
    end
  end

  # Pin: TaskAction's stage names match `Hive::Stages::DIRS`. The
  # classifier branches on `task.stage_name` ("inbox" / "brainstorm" /
  # "execute" / etc.); if Stages renames a stage, every TaskAction
  # branch for it silently falls into the `error` fallback.
  def test_task_action_stage_names_match_stages_dirs
    require "hive/stages"

    expected_stage_names = Hive::Stages::DIRS.map { |d| d.split("-", 2).last }
    classifier_stage_names = %w[inbox brainstorm plan execute open-pr review artifacts finalize done]
    missing = classifier_stage_names - expected_stage_names
    extra = expected_stage_names - classifier_stage_names
    assert_empty missing,
                 "TaskAction branches on stage names #{missing.inspect} that aren't in Stages::DIRS"
    assert_empty extra,
                 "Stages::DIRS has stage names #{extra.inspect} that TaskAction doesn't classify; " \
                 "tasks at those stages will fall through to ACTIONS[:error]"
  end

  # ── additional helper edge coverage ───────────────────────────────────

  def test_unknown_stage_classifies_as_error
    task = fake_task(stage_name: "mystery", stage_index: 9)
    action = Hive::TaskAction.for(task, marker(:waiting))

    assert_equal "error", action.key
    assert_nil action.command
  end

  def test_open_pr_waiting_is_ready_to_open_pr
    task = fake_task(stage_name: "open-pr", stage_index: 5)
    action = Hive::TaskAction.for(task, marker(:waiting))

    assert_equal "ready_to_open_pr", action.key
    assert_equal "hive open-pr demo-260426-aaaa --from 5-open-pr", action.command
  end

  def test_finalize_waiting_when_pr_md_exists
    Dir.mktmpdir("task-action-finalize-waiting") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-finalize", "demo-260426-aaaa")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "pr.md")
      File.write(state_file, "---\npr_url: https://example.com/pr/9\n---\n")
      task = FakeTask.new(stage_name: "finalize", stage_index: 7, slug: "demo-260426-aaaa",
                          project_root: dir, project_name: File.basename(dir), folder: folder,
                          state_file: state_file)

      action = Hive::TaskAction.for(task, marker(:none))

      assert_equal "needs_input", action.key
      assert_equal "hive finalize demo-260426-aaaa --from 7-finalize", action.command
    end
  end

  def test_dead_agent_without_recorded_pid_uses_generic_summary
    task = fake_task(stage_name: "execute", stage_index: 4)
    diagnostic = Hive::TaskAction.for(task, marker(:agent_working), pid_alive: false).diagnostic

    assert_equal "agent process not alive", diagnostic.fetch("summary")
  end

  def test_review_stale_diagnostic_uses_pass_artifacts_and_latest_logs
    Dir.mktmpdir("task-action-review-stale") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      logs = File.join(task.folder, "logs")
      FileUtils.mkdir_p([ reviews, logs ])
      escalation = File.join(reviews, "escalations-02.md")
      review_note = File.join(reviews, "ce-review-02.md")
      log = File.join(logs, "review-pass-20260522.log")
      File.write(escalation, "needs user decision\n")
      File.write(review_note, "review note\n")
      File.write(log, "latest log\n")

      diagnostic = Hive::TaskAction.for(task, marker(:review_stale, "pass" => "2")).diagnostic

      assert_equal escalation, diagnostic.fetch("source_path")
      assert_includes diagnostic.fetch("artifact_paths"), review_note
      assert_includes diagnostic.fetch("artifact_paths"), log
    end
  end

  def test_review_phase_logs_cover_browser_reviewers_and_unknown_phases
    Dir.mktmpdir("task-action-review-logs") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      logs = File.join(task.folder, "logs")
      FileUtils.mkdir_p(logs)
      browser = File.join(logs, "review-browser-pass03.log")
      reviewer = File.join(logs, "review-claude-pass03.log")
      File.write(browser, "browser log\n")
      File.write(reviewer, "reviewer log\n")
      action = Hive::TaskAction.for(task, marker(:review_error, "pass" => "3"))

      assert_equal [ browser ], action.send(:review_phase_logs, "browser", "03")
      assert_equal [ browser, reviewer ].sort, action.send(:review_phase_logs, "reviewers", "03").sort
      assert_empty action.send(:review_phase_logs, "unknown", "03")
    end
  end

  def test_paths_from_marker_files_filters_unsafe_entries
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(
      task,
      marker(:review_error, "files" => "reviews/a.md ../escape /tmp/rooted logs/b.log")
    )

    assert_equal [ File.join(task.folder, "reviews/a.md"), File.join(task.folder, "logs/b.log") ],
                 action.send(:paths_from_marker_files)
  end

  def test_artifact_detail_reports_read_errors
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_error))
    detail = action.send(:artifact_detail, File.join(task.folder, "missing.md"))

    assert_includes detail, "Errno::ENOENT"
  end

  def test_diagnostic_generated_by_falls_back_when_frontmatter_has_no_generator
    Dir.mktmpdir("task-action-generator") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      path = File.join(task.folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "---\nmarker_signature: abc\n---\nbody\n")
      action = Hive::TaskAction.for(task, marker(:review_error))

      assert_equal "local", action.send(:diagnostic_generated_by, path)
    end
  end

  def test_diagnostic_frontmatter_returns_empty_on_parse_or_read_errors
    Dir.mktmpdir("task-action-frontmatter") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      path = File.join(task.folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "---\n: bad\n---\nbody\n")
      action = Hive::TaskAction.for(task, marker(:review_error))

      assert_equal({}, action.send(:diagnostic_frontmatter, path))
      assert_equal({}, action.send(:diagnostic_frontmatter, File.join(task.folder, "missing.md")))
    end
  end

  def test_review_stale_with_escalations_suggests_manual_fix
    Dir.mktmpdir("task-action-review-stale-manual") do |root|
      task = fake_task(stage_name: "review", stage_index: 6, project_root: root)
      reviews = File.join(task.folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "escalations-04.md"), "decide\n")

      suggested = Hive::TaskAction.for(task, marker(:review_stale, "pass" => "4")).diagnostic.fetch("suggested_next_action")

      assert_equal "manual_fix", suggested.fetch("kind")
      assert_nil suggested["command"]
    end
  end

  def test_review_stale_and_error_retry_commands_include_priority_match_attrs
    review_task = fake_task(stage_name: "review", stage_index: 6)
    review_suggested = Hive::TaskAction.for(
      review_task,
      marker(:review_stale, "pass" => "2", "reason" => "wall_clock")
    ).diagnostic.fetch("suggested_next_action")

    assert_equal "retry", review_suggested.fetch("kind")
    review_parts = Shellwords.split(review_suggested.fetch("command"))
    assert_includes review_parts, "--name"
    assert_includes review_parts, "REVIEW_STALE"
    assert_includes review_parts, "--match-attr"
    assert_includes review_parts, "pass=2"

    error_task = fake_task(stage_name: "execute", stage_index: 4)
    error_suggested = Hive::TaskAction.for(
      error_task,
      marker(:error, "exit_code" => "70", "reason" => "agent_failed")
    ).diagnostic.fetch("suggested_next_action")

    assert_equal "retry", error_suggested.fetch("kind")
    error_parts = Shellwords.split(error_suggested.fetch("command"))
    assert_includes error_parts, "--name"
    assert_includes error_parts, "ERROR"
    assert_includes error_parts, "--match-attr"
    assert_includes error_parts, "exit_code=70"
  end

  def test_incomplete_plan_retry_command_includes_project_when_needed
    Dir.mktmpdir("task-action-plan-project") do |root|
      folder = File.join(root, ".hive-state", "stages", "3-plan", "demo-260426-aaaa")
      state_file = File.join(folder, "plan.md")
      FileUtils.mkdir_p(folder)
      File.write(state_file, "")
      task = FakeTask.new(
        stage_name: "plan",
        stage_index: 3,
        slug: "demo-260426-aaaa",
        project_root: root,
        project_name: File.basename(root),
        folder: folder,
        state_file: state_file
      )

      suggested = Hive::TaskAction.for(
        task,
        marker(:none),
        project_name: "demo-project",
        project_count: 2
      ).diagnostic.fetch("suggested_next_action")

      assert_includes suggested.fetch("command"), "--project demo-project"
      assert_includes suggested.fetch("command"), "--from 3-plan"
    end
  end

  def test_private_path_helpers_cover_missing_and_empty_inputs
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_error))

    assert_nil action.send(:realpath_or_expand, nil)
    assert_equal File.expand_path(File.join(task.folder, "missing")),
                 action.send(:realpath_or_expand, File.join(task.folder, "missing"))
  end

  def test_safe_diagnostic_artifact_handles_realpath_failures
    task = fake_task(stage_name: "review", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:review_error))
    original_file = File.method(:file?)
    original_realpath = File.method(:realpath)

    with_replaced_singleton_method(File, :file?, ->(_path) { true }) do
      with_replaced_singleton_method(File, :realpath, ->(_path) { raise Errno::ENOENT }) do
        refute action.send(:safe_diagnostic_artifact?, File.join(task.folder, "gone.md"))
      end

      with_replaced_singleton_method(File, :realpath, ->(_path) { raise Errno::EACCES }) do
        _out, err = capture_io do
          refute action.send(:safe_diagnostic_artifact?, File.join(task.folder, "blocked.md"))
        end
        assert_includes err, "cannot realpath"
      end
    end
  ensure
    File.define_singleton_method(:file?, original_file) if original_file
    File.define_singleton_method(:realpath, original_realpath) if original_realpath
  end

  def with_replaced_singleton_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original) if original
  end
end
