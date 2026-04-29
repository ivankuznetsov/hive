require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/markers"

# Integration coverage for `hive markers clear FOLDER --name <NAME>`.
#
# Hits the resolver (path + slug + ambiguity error), the allowlist
# enforcement (terminal-success markers refused, unknown markers
# refused), the marker-vs-state guard (mismatched marker refused with
# WrongStage), the atomic file edit (only the marker line goes,
# surrounding content stays), and the JSON envelope (success +
# allowlist-rejection error envelope).
class MarkersCommandTest < Minitest::Test
  include HiveTestHelper

  def seed_review_task(dir, marker:)
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::New.new(project, "markers probe").call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    review = File.join(dir, ".hive-state", "stages", "5-review", File.basename(inbox))
    FileUtils.mkdir_p(File.dirname(review))
    FileUtils.mv(inbox, review)

    state = File.join(review, "task.md")
    FileUtils.touch(state)
    File.write(state, "# my task\n\n## Implementation\n\nwip\n")
    Hive::Markers.set(state, marker)

    [ project, review, File.basename(review) ]
  end

  # ── Happy path ─────────────────────────────────────────────────────────

  def test_clears_review_stale_and_preserves_surrounding_content
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)
        state = File.join(folder, "task.md")

        before = File.read(state)
        assert_includes before, "REVIEW_STALE", "fixture must include the marker"
        assert_includes before, "wip\n", "fixture body must include surrounding content"

        capture_io do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_STALE").call
        end

        after = File.read(state)
        refute_includes after, "REVIEW_STALE",
                        "REVIEW_STALE marker must be removed from task.md"
        assert_includes after, "wip\n",
                        "surrounding content must be preserved verbatim"
        assert_includes after, "## Implementation",
                        "headings must survive"

        marker = Hive::Markers.current(state)
        assert_equal :none, marker.name,
                     "after clearing the only marker the file is markerless"

        # hive_commit was recorded on the hive/state branch.
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(/markers clear REVIEW_STALE/, log,
                     "hive_commit must record the clear action")
      end
    end
  end

  def test_clears_review_ci_stale_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_ci_stale)
        capture_io do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_CI_STALE").call
        end

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :none, marker.name
      end
    end
  end

  def test_clears_review_error_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_error)
        capture_io do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_ERROR").call
        end

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :none, marker.name
      end
    end
  end

  # ── Allowlist enforcement ──────────────────────────────────────────────

  def test_rejects_unknown_marker_name
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)

        _out, _err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "WHATEVER").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
      end
    end
  end

  def test_rejects_terminal_success_marker_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_complete)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_COMPLETE").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/allowlist|use `hive approve`/, err,
                     "rejection error must point the user at the right tool")
      end
    end
  end

  # Per-rejection coverage for each terminal-success marker the
  # allowlist refuses. Each test seeds the corresponding marker on the
  # state file (so the marker-vs-state guard can't fire first) and
  # asserts the allowlist message points the user at `hive approve`.

  def test_clear_review_complete_is_rejected
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_complete)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_COMPLETE").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/REVIEW_COMPLETE/, err)
        assert_match(/hive approve/, err,
                     "rejection error must redirect the user to `hive approve`")
      end
    end
  end

  def test_clear_execute_complete_is_rejected
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :execute_complete)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "EXECUTE_COMPLETE").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/EXECUTE_COMPLETE/, err)
        assert_match(/hive approve/, err)
      end
    end
  end

  def test_clear_complete_is_rejected
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :complete)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "COMPLETE").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/COMPLETE/, err)
        assert_match(/hive approve/, err)
      end
    end
  end

  def test_clear_unknown_marker_name_is_rejected
    # An unknown name (`FROBNICATE`) must also be rejected; the user
    # gets a helpful error listing the allowed names so they know what
    # to do next.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "FROBNICATE").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/FROBNICATE/, err)
        assert_match(/allowlist|REVIEW_STALE/, err,
                     "error must mention the allowed names so the user knows what to pass")
      end
    end
  end

  # ── Marker-vs-state guard ──────────────────────────────────────────────

  def test_refuses_when_named_marker_does_not_match_actual
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_ERROR").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_match(/REVIEW_ERROR.*REVIEW_STALE|REVIEW_STALE.*REVIEW_ERROR/, err,
                     "error must mention both the requested name and the actual marker")
      end
    end
  end

  # ── Read+match+rewrite atomicity ──────────────────────────────────────

  # Even with --match-attr, the prior implementation read the marker,
  # matched, then re-read and rewrote in remove_marker_line! as a
  # separate operation. A concurrent Markers.set landing between the
  # validation and the rewrite would have its marker erased by the
  # stale-body rewrite. The fix wraps read+match+rewrite under the
  # same `.markers-lock` Markers.set acquires; this test pins that
  # the lock is held by checking that an exclusive flock on the lock
  # path during clear_marker waits for clear to complete.
  def test_markers_clear_holds_markers_lock_around_read_match_rewrite
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)
        state = File.join(folder, "task.md")
        lock_path = "#{state}.markers-lock"

        # Hold the markers-lock from a sibling thread; the main
        # thread's clear_marker must block on flock until the sibling
        # releases. Queue-based signaling avoids the cross-thread
        # mutex ownership problem (Mutex is owned by the locking
        # thread; Queue#pop blocks across threads cleanly).
        sibling_acquired = Queue.new
        sibling_should_release = Queue.new
        sibling_released_at = nil

        sibling = Thread.new do
          File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
            f.flock(File::LOCK_EX)
            sibling_acquired << true
            sibling_should_release.pop
            sibling_released_at = Time.now
          end
        end

        sibling_acquired.pop # wait for sibling to acquire the lock

        clear_finished_at = nil
        clear_thread = Thread.new do
          capture_io do
            Hive::Commands::Markers.new("clear", folder, name: "REVIEW_STALE").call
          end
          clear_finished_at = Time.now
        end

        # Give clear a chance to attempt the flock; it should still be
        # blocked because the sibling holds the lock.
        sleep 0.15
        assert_nil clear_finished_at,
          "clear_marker must block on `.markers-lock`; pre-fix it would complete here"

        # Release sibling's hold; clear should now proceed.
        sibling_should_release << true
        sibling.join(2) || flunk("sibling thread didn't release lock")
        clear_thread.join(2) || flunk("clear_marker didn't complete after lock release")

        refute_nil clear_finished_at
        assert clear_finished_at >= sibling_released_at,
          "clear must observe the lock release before completing"

        marker = Hive::Markers.current(state)
        assert_equal :none, marker.name,
          "after the lock contention resolves, the marker is cleared as usual"
      end
    end
  end

  # ── --match-attr cross-process race guard ─────────────────────────────

  # Seeds an ERROR marker carrying explicit attrs (reason + exit_code).
  # Mirrors the on-disk shape of a kill-class error the TUI auto-healer
  # would observe (`<!-- ERROR reason=exit_code exit_code=143 -->`).
  def seed_error_with_attrs(dir, marker_attrs:)
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::New.new(project, "match-attr probe").call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    review = File.join(dir, ".hive-state", "stages", "5-review", File.basename(inbox))
    FileUtils.mkdir_p(File.dirname(review))
    FileUtils.mv(inbox, review)

    state = File.join(review, "task.md")
    File.write(state, "# my task\n\n## Implementation\n\nwip\n")
    Hive::Markers.set(state, :error, marker_attrs)

    [ project, review, File.basename(review) ]
  end

  def test_match_attr_clears_when_value_matches
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_error_with_attrs(dir, marker_attrs: { reason: "exit_code", exit_code: 143 })
        state = File.join(folder, "task.md")
        assert_includes File.read(state), "exit_code=143"

        capture_io do
          Hive::Commands::Markers.new(
            "clear", folder, name: "ERROR", match_attr: "exit_code=143"
          ).call
        end

        marker = Hive::Markers.current(state)
        assert_equal :none, marker.name,
                     "matching --match-attr value must allow the clear"
      end
    end
  end

  def test_match_attr_refuses_when_value_differs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_error_with_attrs(dir, marker_attrs: { reason: "exit_code", exit_code: 1 })
        state = File.join(folder, "task.md")

        _out, err, status = with_captured_exit do
          Hive::Commands::Markers.new(
            "clear", folder, name: "ERROR", match_attr: "exit_code=143"
          ).call
        end

        assert_equal Hive::ExitCodes::WRONG_STAGE, status,
                     "attr mismatch must surface as WrongStage so callers (auto-heal) " \
                     "evict and retry without erasing a real-failure marker"
        assert_match(/exit_code/, err)
        marker = Hive::Markers.current(state)
        assert_equal :error, marker.name,
                     "marker must remain on disk when --match-attr refuses"
      end
    end
  end

  def test_match_attr_refuses_when_attr_key_absent
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_error_with_attrs(dir, marker_attrs: { reason: "exit_code" })
        state = File.join(folder, "task.md")

        _out, _err, status = with_captured_exit do
          Hive::Commands::Markers.new(
            "clear", folder, name: "ERROR", match_attr: "exit_code=143"
          ).call
        end

        assert_equal Hive::ExitCodes::WRONG_STAGE, status,
                     "missing attr key must refuse with WrongStage"
        marker = Hive::Markers.current(state)
        assert_equal :error, marker.name
      end
    end
  end

  def test_match_attr_invalid_format_raises_invalid_task_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_error_with_attrs(dir, marker_attrs: { reason: "exit_code", exit_code: 143 })

        _out, _err, status = with_captured_exit do
          Hive::Commands::Markers.new(
            "clear", folder, name: "ERROR", match_attr: "no-equals-sign"
          ).call
        end

        assert_equal Hive::ExitCodes::USAGE, status,
                     "malformed --match-attr must surface as USAGE; the auto-heal " \
                     "doesn't generate this shape, but a hand-typed call should fail loudly"
      end
    end
  end

  # ── JSON envelope ──────────────────────────────────────────────────────

  def test_json_success_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, slug = seed_review_task(dir, marker: :review_stale)

        out, _err = capture_io do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_STALE", json: true).call
        end
        payload = JSON.parse(out)

        assert_equal "hive-markers-clear", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal true, payload["ok"]
        assert_equal slug, payload["slug"]
        assert_equal folder, payload["folder"]
        assert_equal "REVIEW_STALE", payload["marker_cleared"]
      end
    end
  end

  def test_json_error_envelope_on_allowlist_rejection
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)

        out, _err, status = with_captured_exit do
          Hive::Commands::Markers.new("clear", folder, name: "REVIEW_COMPLETE", json: true).call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        payload = JSON.parse(out)

        assert_equal "hive-markers-clear", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "wrong_stage", payload["error_kind"]
        assert_equal Hive::ExitCodes::WRONG_STAGE, payload["exit_code"]
        assert_match(/REVIEW_COMPLETE/, payload["message"])
      end
    end
  end

  # ── Subcommand dispatch ─────────────────────────────────────────────────

  def test_unknown_subcommand_raises_invalid_task_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, folder, _slug = seed_review_task(dir, marker: :review_stale)

        _out, _err, status = with_captured_exit do
          Hive::Commands::Markers.new("nuke", folder, name: "REVIEW_STALE").call
        end
        assert_equal Hive::ExitCodes::USAGE, status
      end
    end
  end

  # ── Schema-version registration ─────────────────────────────────────────

  def test_schema_version_registered
    assert Hive::Schemas::SCHEMA_VERSIONS.key?("hive-markers-clear"),
           "hive-markers-clear must be registered in SCHEMA_VERSIONS"
    assert_equal 1, Hive::Schemas::SCHEMA_VERSIONS["hive-markers-clear"]
  end
end
