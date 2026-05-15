require "test_helper"
require "hive/stages/review"
require "hive/reviewers"

# Direct unit coverage for Hive::Stages::Review.run_reviewers and the
# pass-derivation helper. Both run inside the Phase 2/3/4 loop and were
# fragile in pre-PR-5 review code:
#   - run_reviewers had no rescue around adapter.run!; one spawn raise
#     aborted the entire reviewers phase.
#   - next_pass_for ignored marker.attrs["pass"] on :review_waiting,
#     letting disk-derived pass drift overwrite user [x] marks.
class RunReviewersTest < Minitest::Test
  include HiveTestHelper

  # Minimal task stand-in. Stages::Review.run_reviewers only reads
  # task.folder via the adapter's output_path; nothing else.
  Task = Struct.new(:folder, :state_file)

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: dir,
      default_branch: "main",
      pass: 1
    )
  end

  # A reviewer whose run! raises mid-phase. The orchestrator must
  # convert this to :error, write the stub finding, and continue with
  # the next reviewer.
  class RaisingReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      raise RuntimeError, "boom"
    end
  end

  # A reviewer whose run! returns :ok. Produces a stub findings file so
  # the test can verify both reviewers actually ran.
  class OkReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      ensure_reviews_dir!
      File.write(output_path, "## Low\n\n- [ ] looks fine\n")
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :ok,
        error_message: nil
      )
    end
  end

  # Shared test helper: stub Hive::Reviewers.dispatch to return a sequence
  # of adapters, run the orchestrator, restore dispatch.
  def with_stubbed_dispatch(adapters)
    orig = Hive::Reviewers.method(:dispatch)
    idx = 0
    Hive::Reviewers.define_singleton_method(:dispatch) do |_spec, _ctx, **_kwargs|
      a = adapters[idx]
      idx += 1
      a
    end
    begin
      yield
    ensure
      Hive::Reviewers.define_singleton_method(:dispatch, orig)
    end
  end

  def test_first_reviewer_raise_does_not_abort_second
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "raises", "output_basename" => "raises" },
            { "name" => "ok",     "output_basename" => "ok" }
          ]
        }
      }

      adapters = [
        RaisingReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir)),
        OkReviewer.new(cfg["review"]["reviewers"][1], make_ctx(dir))
      ]

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :ok, result, "rescue must let surviving reviewers run"
      end

      # The OK reviewer's findings landed.
      ok_findings = File.join(dir, "reviews", "ok-01.md")
      assert File.exist?(ok_findings), "second reviewer must have run"

      # POST-U2: the raising reviewer's failure lands in
      # `reviews/errors-01.md`, NOT in `reviews/raises-01.md`. The
      # reviewer-named file stays absent so triage's
      # discover_reviewer_files sees "this reviewer produced nothing
      # this pass", not "this reviewer produced a finding".
      raising_stub = File.join(dir, "reviews", "raises-01.md")
      refute File.exist?(raising_stub),
             "post-U2: reviewer's own output_basename file must NOT exist for failed adapter (use errors-NN.md instead)"

      errors_path = File.join(dir, "reviews", "errors-01.md")
      assert File.exist?(errors_path),
             "post-U2: failed adapter must record into errors-NN.md"
      contents = File.read(errors_path)
      assert_includes contents, "# Reviewer infra errors for pass 01"
      assert_includes contents, "[raises] reviewer \"raises\" failed"
      assert_includes contents, "RuntimeError"
      assert_includes contents, "boom"
    end
  end

  # --- U2 errors-NN.md sink coverage ----------------------------------

  # A reviewer whose run! returns :error without raising. Tests the
  # non-raise error path (the common case: adapter loop exhausted
  # retries, returns the :error envelope).
  class ErroringReviewer < Hive::Reviewers::Base
    def initialize(spec, ctx, error_message:)
      super(spec, ctx)
      @error_message = error_message
    end

    def run!(deadline: nil)
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :error,
        error_message: @error_message
      )
    end
  end

  def test_multiple_failures_concatenate_into_one_errors_file_with_one_header
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "rev-a", "output_basename" => "rev-a" },
            { "name" => "rev-b", "output_basename" => "rev-b" },
            { "name" => "rev-c", "output_basename" => "rev-c" }
          ]
        }
      }

      adapters = cfg["review"]["reviewers"].each_with_index.map do |spec, i|
        ErroringReviewer.new(spec, make_ctx(dir),
                             error_message: "agent exited with status=:timeout (#{i + 1})")
      end

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :all_failed, result,
                     "all reviewers failing must surface :all_failed"
      end

      errors_path = File.join(dir, "reviews", "errors-01.md")
      assert File.exist?(errors_path)
      contents = File.read(errors_path)
      assert_equal 1, contents.scan(/^# Reviewer infra errors for pass 01$/).size,
                   "exactly one header for the pass — subsequent failures append"
      %w[rev-a rev-b rev-c].each do |basename|
        assert_includes contents, "[#{basename}] reviewer #{basename.inspect} failed",
                        "every failed reviewer must appear in errors-NN.md"
      end
    end
  end

  def test_mixed_success_and_failure_only_failures_land_in_errors_file
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "ok",       "output_basename" => "ok" },
            { "name" => "broken",   "output_basename" => "broken" }
          ]
        }
      }

      adapters = [
        OkReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir)),
        ErroringReviewer.new(cfg["review"]["reviewers"][1], make_ctx(dir),
                             error_message: "timeout after 2 attempt(s)")
      ]

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :ok, result, "mixed result is :ok (at least one reviewer succeeded)"
      end

      assert File.exist?(File.join(dir, "reviews", "ok-01.md")),
             "successful reviewer's per-pass file is written"
      refute File.exist?(File.join(dir, "reviews", "broken-01.md")),
             "failed reviewer's per-pass file is NOT written"

      errors_path = File.join(dir, "reviews", "errors-01.md")
      assert File.exist?(errors_path)
      contents = File.read(errors_path)
      assert_includes contents, "[broken] reviewer \"broken\" failed: timeout after 2 attempt(s)"
      refute_includes contents, "[ok]",
                      "ok reviewer must not appear in errors-NN.md"
    end
  end

  def test_errors_file_is_deleted_when_rerun_has_zero_failures
    # Regression: ce-code-review and correctness reviewer both flagged
    # that the original truncate-on-first-failure design left a stale
    # errors-NN.md when a rerun had zero failures (lazy truncate never
    # fired). After the fix, the file is unconditionally cleared at the
    # start of every run_reviewers invocation.
    with_tmp_dir do |dir|
      reviews_dir = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      stale_path = File.join(reviews_dir, "errors-01.md")
      File.write(stale_path,
                 "# Reviewer infra errors for pass 01\n\n" \
                 "- [rev-a] reviewer \"rev-a\" failed: STALE from previous crashed run\n")

      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "ok", "output_basename" => "ok" }
          ]
        }
      }
      adapters = [ OkReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir)) ]

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :ok, result
      end

      refute File.exist?(stale_path),
             "stale errors-NN.md from a prior crashed run must be removed when the rerun has zero failures"
      assert File.exist?(File.join(dir, "reviews", "ok-01.md")),
             "ok reviewer's per-pass file is still written"
    end
  end

  # pr-review-toolkit round-5 pr-test-analyzer #10 — the round-3 P2 #9
  # fix moved `clear_reviewer_infra_errors` BEFORE the empty-spec
  # early return in `run_reviewers`. A regression that hoists it
  # back below the return would leave stale errors-NN.md when a
  # project removes all reviewers between runs.
  def test_errors_file_is_cleared_even_when_spec_list_is_empty
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      stale_path = File.join(reviews, "errors-01.md")
      File.write(stale_path,
                 "# Reviewer infra errors for pass 01\n\n" \
                 "- [old] reviewer \"old\" failed: leftover from a prior run with reviewers\n")

      cfg = { "review" => { "reviewers" => [] } } # specs intentionally empty

      result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
      assert_equal :ok, result, "empty specs returns :ok"
      refute File.exist?(stale_path),
             "empty-specs invocation must STILL clear stale errors-NN.md (P2 #9)"
    end
  end

  def test_errors_file_is_truncated_on_pass_re_entry_not_appended
    # Defensive: after a marker-clear-and-rerun on the same pass, the
    # second run_reviewers invocation should NOT see double-listed
    # failures (header + failures from prior crashed run + new header +
    # new failures). Truncate-on-first-failure-per-invocation closes
    # this; the test pins the contract.
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "rev-a", "output_basename" => "rev-a" }
          ]
        }
      }

      # Simulate a stale errors-01.md from a prior crashed run.
      reviews_dir = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      stale_path = File.join(reviews_dir, "errors-01.md")
      File.write(stale_path,
                 "# Reviewer infra errors for pass 01\n\n" \
                 "- [rev-a] reviewer \"rev-a\" failed: STALE entry from previous run\n")

      adapters = [
        ErroringReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir),
                             error_message: "fresh failure")
      ]

      with_stubbed_dispatch(adapters) do
        Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
      end

      contents = File.read(stale_path)
      refute_includes contents, "STALE entry",
                      "stale lines from prior run must be truncated, not preserved"
      assert_includes contents, "fresh failure",
                      "fresh failure from current run lands cleanly"
      assert_equal 1, contents.scan(/^# Reviewer infra errors for pass 01$/).size,
                   "exactly one header"
    end
  end

  def test_errors_filename_is_orchestrator_owned_and_skipped_by_reviewer_file_predicate
    refute Hive::Stages::Review.reviewer_file?("errors-01.md"),
           "errors-NN.md must be classified as orchestrator-owned"
    refute Hive::Stages::Review.reviewer_file?("errors-99.md")
    # Sanity: a real reviewer file is still recognized.
    assert Hive::Stages::Review.reviewer_file?("claude-ce-code-review-01.md")
  end

  def test_errors_file_is_not_picked_up_by_triage_discover_reviewer_files
    require "hive/stages/review/triage"
    with_tmp_dir do |dir|
      reviews_dir = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(File.join(reviews_dir, "errors-01.md"),
                 "# Reviewer infra errors for pass 01\n\n- [a] ...\n")
      File.write(File.join(reviews_dir, "claude-ce-code-review-01.md"),
                 "## High\n- [ ] real finding\n")

      ctx = make_ctx(dir)
      files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
      assert_equal 1, files.size, "exactly one reviewer file discovered for pass 1"
      assert files.first.end_with?("claude-ce-code-review-01.md")
      refute(files.any? { |f| f.end_with?("errors-01.md") },
             "errors-NN.md must be excluded from triage's reviewer-file discovery")
    end
  end

  def test_next_pass_for_review_waiting_uses_marker_pass_over_disk_max
    # Drift case: marker says pass=2, but a stale reviews/foo-03.md is
    # on disk. We must trust the marker so re-running on REVIEW_WAITING
    # doesn't bump pass to 3 and overwrite user [x] marks.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "foo-03.md"), "## High\n- [ ] x\n")

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(
        name: :review_waiting,
        attrs: { "pass" => "2" },
        raw: nil
      )

      assert_equal 2, Hive::Stages::Review.next_pass_for(task, marker),
                   "review_waiting must trust marker pass=2 even when disk has -03.md"
    end
  end

  def test_next_pass_for_review_waiting_falls_back_to_disk_when_marker_pass_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "foo-02.md"), "## High\n- [ ] x\n")

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(
        name: :review_waiting,
        attrs: {},
        raw: nil
      )

      assert_equal 2, Hive::Stages::Review.next_pass_for(task, marker),
                   "with no marker pass, fall back to disk-derived max"
    end
  end

  def test_next_pass_for_markerless_retry_keeps_incomplete_triage_pass
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "foo-04.md"), "## High\n- [ ] x\n")

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)

      assert_equal 4, Hive::Stages::Review.next_pass_for(task, marker),
                   "a reviewer artifact without escalations-NN.md means triage did not finish"
    end
  end

  def test_next_pass_for_markerless_advance_after_completed_pass
    # Pass 4 reached completion: reviewers ran, triage wrote
    # escalations, fix succeeded (sentinel present). Markerless rerun
    # advances to pass 5.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "foo-04.md"), "## High\n- [ ] x\n")
      File.write(File.join(dir, "reviews", "escalations-04.md"), "# Escalations\n")
      File.write(File.join(dir, "reviews", "fix-success-04.md"), "ok\n")

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)

      assert_equal 5, Hive::Stages::Review.next_pass_for(task, marker),
                   "fix-success-04.md sentinel proves pass 4 finished cleanly; advance to 5"
    end
  end

  def test_next_pass_for_retries_when_escalations_newer_than_fix_success
    # If an operator edits escalations after the sentinel was written,
    # the prior fix pass no longer covers the accepted set. Retry pass 4
    # instead of treating the stale sentinel as final.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      reviewer = File.join(reviews, "foo-04.md")
      escalations = File.join(reviews, "escalations-04.md")
      sentinel = File.join(reviews, "fix-success-04.md")
      File.write(reviewer, "## High\n- [x] original\n")
      File.write(escalations, "# Escalations\n")
      File.write(sentinel, "ok\n")
      File.utime(Time.utc(2026, 5, 6, 12, 0, 0), Time.utc(2026, 5, 6, 12, 0, 0), sentinel)
      File.utime(Time.utc(2026, 5, 6, 12, 1, 0), Time.utc(2026, 5, 6, 12, 1, 0), escalations)

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)

      assert_equal :fix_incomplete, Hive::Stages::Review.pass_completion_status(dir, 4)
      assert_equal 4, Hive::Stages::Review.next_pass_for(task, marker),
                   "stale fix-success sentinel must not skip edited escalations"
    end
  end

  def test_pass_completion_falls_back_to_next_pass_reviewer_files
    # Back-compat fallback: a legacy repo created BEFORE the
    # fix-success sentinel existed has no `fix-success-NN.md` files.
    # For a non-topmost pass, the existence of `*-{N+1}.md` reviewer
    # files is proof the runner advanced past pass N (it only writes
    # those after a successful fix-N). The topmost pass remains
    # ambiguous on legacy repos — that's an accepted migration cost.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "foo-04.md"), "## H\n- [x] x\n")
      File.write(File.join(reviews, "escalations-04.md"), "# E\n")
      File.write(File.join(reviews, "foo-05.md"), "## H\n- [ ] y\n")
      # No fix-success-04 sentinel and no pass-6 reviewer files.

      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "pass 5 reviewer files prove pass 4's fix succeeded (back-compat)"
    end
  end

  def test_next_pass_for_retries_pass_when_fix_did_not_complete
    # Pass 4 had reviewer files AND triage wrote escalations, but
    # the fix phase failed (REVIEW_ERROR phase=fix) or the runner
    # was interrupted mid-fix. Markerless rerun must RETRY pass 4
    # at Phase 4 with the operator's existing [x] marks instead of
    # advancing to pass 5 and abandoning them — the bug user flagged
    # against PR #56's narrower incomplete_triage_pass? check.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "foo-04.md"), "## High\n- [x] applied\n")
      File.write(File.join(dir, "reviews", "escalations-04.md"), "# Escalations\n")
      # No fix-success-04.md, no pass-05 reviewer files.

      task = Task.new(dir, File.join(dir, "task.md"))
      marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)

      assert_equal 4, Hive::Stages::Review.next_pass_for(task, marker),
                   "without fix-success sentinel or pass-5 reviewer files, " \
                   "pass 4's fix is incomplete; retry pass 4"
    end
  end

  def test_pass_completion_status_classifies_each_phase
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)

      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 1),
                   "empty reviews/ → :complete (nothing to retry)"

      File.write(File.join(reviews, "foo-04.md"), "## High\n- [ ] x\n")
      assert_equal :triage_incomplete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "reviewer files present, no escalations → :triage_incomplete"

      File.write(File.join(reviews, "escalations-04.md"), "# Escalations\n")
      assert_equal :fix_incomplete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "escalations present, no fix-success / no pass-5 → :fix_incomplete"

      File.write(File.join(reviews, "fix-success-04.md"), "ok\n")
      # Touch fix-success to be the most recent file, then sanity-check
      # the :complete classification — the operator-edit detection arm
      # is exercised by the dedicated test below.
      fix_success = File.join(reviews, "fix-success-04.md")
      escalations = File.join(reviews, "escalations-04.md")
      File.utime(Time.now, Time.now, fix_success)
      File.utime(Time.now - 60, Time.now - 60, escalations)
      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "fix-success newer than escalations → :complete"
    end
  end

  def test_pass_completion_status_detects_operator_edit_to_escalations_after_fix
    # Operator-edit detection: when the user edits escalations-NN.md
    # after fix-success-NN.md was written, the next `hive run` should
    # re-enter Phase 4 with the new edits as authoritative input. The
    # mtime comparison drives this — escalations.mtime > fix.mtime
    # flips :complete → :fix_incomplete so next_pass_for stays on
    # pass N instead of advancing to pass N+1 (which would trip the
    # max_passes guard for tasks at the cap).
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-ce-code-review-04.md"), "## High\n- [ ] x\n")
      escalations = File.join(reviews, "escalations-04.md")
      fix_success = File.join(reviews, "fix-success-04.md")
      File.write(escalations, "# Escalations pass 04\n- [ ] open question\n")
      File.write(fix_success, "ok\n")

      # Baseline: fix-success is newer (typical post-fix state) → :complete.
      File.utime(Time.now - 60, Time.now - 60, escalations)
      File.utime(Time.now,      Time.now,      fix_success)
      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "post-fix state (fix-success newer than escalations) → :complete"

      # Operator edits escalations → its mtime is now newer than fix-success.
      File.utime(Time.now + 10, Time.now + 10, escalations)
      assert_equal :fix_incomplete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "operator-edit detection: escalations newer than fix-success → :fix_incomplete"
    end
  end

  def test_pass_completion_status_equal_mtimes_stay_complete
    # Edge case: same-second writes (rare but possible — e.g., a tool
    # that touches both files in one tick). A `>` comparison (not `>=`)
    # avoids spurious retries when escalations.mtime == fix.mtime.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-ce-code-review-04.md"), "## High\n- [ ] x\n")
      escalations = File.join(reviews, "escalations-04.md")
      fix_success = File.join(reviews, "fix-success-04.md")
      File.write(escalations, "# Escalations\n")
      File.write(fix_success, "ok\n")
      t = Time.now
      File.utime(t, t, escalations)
      File.utime(t, t, fix_success)

      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "equal mtimes must not trip the operator-edit detection"
    end
  end

  def test_pass_completion_status_swallows_stat_errors_conservatively
    # If File.mtime raises (transient I/O, stat race), the detection
    # helper must return false so the classifier stays at :complete.
    # Treating an unreadable mtime as "edit detected" would cause
    # surprise fix retries on transient errors.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-ce-code-review-04.md"), "## High\n- [ ] x\n")
      File.write(File.join(reviews, "escalations-04.md"), "# Escalations\n")
      File.write(File.join(reviews, "fix-success-04.md"), "ok\n")

      original_mtime = File.method(:mtime)
      File.singleton_class.define_method(:mtime) { |_path| raise Errno::EIO, "synthetic" }
      begin
        assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                     "stat failure must NOT trigger a retry — conservative on I/O error"
      ensure
        File.singleton_class.define_method(:mtime, original_mtime)
      end
    end
  end

  FakeTaskForNextPass = Struct.new(:folder, :state_file)
  FakeMarkerForNextPass = Struct.new(:name, :attrs)

  def test_next_pass_for_retries_pass_n_when_operator_edited_escalations
    # End-to-end: operator edits escalations-04.md after fix-success-04.md
    # was written → pass_completion_status(4) returns :fix_incomplete →
    # next_pass_for(marker_without_pass_attr) returns 4 (retry current
    # pass), NOT 5 (which would advance past the cap for max_passes=4).
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-ce-code-review-04.md"), "## High\n- [ ] x\n")
      File.write(File.join(reviews, "codex-ce-code-review-04.md"), "## High\n- [ ] y\n")
      escalations = File.join(reviews, "escalations-04.md")
      fix_success = File.join(reviews, "fix-success-04.md")
      File.write(escalations, "# Escalations\n")
      File.write(fix_success, "ok\n")
      File.utime(Time.now - 60, Time.now - 60, fix_success)
      File.utime(Time.now,      Time.now,      escalations)

      task = FakeTaskForNextPass.new(dir, File.join(dir, "task.md"))
      marker = FakeMarkerForNextPass.new(:none, {})
      pass = Hive::Stages::Review.next_pass_for(task, marker)
      assert_equal 4, pass,
                   "operator edit must retry pass 4, not advance to pass 5 " \
                   "(would otherwise hit the max_passes cap)"
    end
  end

  # --- R5: hostile NN cap ----------------------------------------------

  def test_max_review_pass_raises_when_disk_NN_exceeds_max_passes_plus_one
    # A user (or a hostile environment) drops claude-99.md into reviews/.
    # With max_passes=4 and the +1 head-room for "next pass after the
    # max one already on disk", anything > 5 must loudly fail rather
    # than driving the loop into pass 99.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "claude-99.md"), "## High\n- [ ] x\n")

      cfg = { "review" => { "max_passes" => 4 } }
      err = assert_raises(Hive::ConfigError) do
        Hive::Stages::Review.max_review_pass(dir, cfg)
      end
      assert_match(/99/, err.message)
      assert_match(/max_passes/, err.message)
      assert_match(/claude-99\.md/, err.message)
    end
  end

  def test_max_review_pass_does_not_raise_within_cap
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "claude-04.md"), "## High\n")

      cfg = { "review" => { "max_passes" => 4 } }
      assert_equal 4, Hive::Stages::Review.max_review_pass(dir, cfg)
    end
  end

  def test_max_review_pass_without_cfg_skips_the_cap
    # Backward-compatible: existing call sites that pass no cfg get
    # the pre-R5 behaviour.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "claude-99.md"), "## High\n")
      assert_equal 99, Hive::Stages::Review.max_review_pass(dir)
    end
  end

  # --- U5 fix-guardrail approval-on-resume coverage --------------------

  def write_guardrail_file(dir, pass:, body:)
    reviews_dir = File.join(dir, "reviews")
    FileUtils.mkdir_p(reviews_dir)
    File.write(File.join(reviews_dir, "fix-guardrail-#{format('%02d', pass)}.md"), body)
  end

  def test_fix_guardrail_approved_true_when_all_lines_are_x
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: <<~MD)
        # Fix-guardrail findings for pass 04

        - [x] dotenv_edit: .env.example:?: .env.example
        - [x] dotenv_edit: .env.example:?: .env.example
      MD
      ctx = make_ctx(dir).with(pass: 4)
      assert Hive::Stages::Review.fix_guardrail_approved?(ctx),
             "all-[x] file must be reported as approved"
    end
  end

  def test_fix_guardrail_approved_false_when_any_unchecked_remains
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: <<~MD)
        # Fix-guardrail findings for pass 04

        - [x] dotenv_edit: .env.example:?: .env.example
        - [ ] dotenv_edit: .env.production:?: .env.production
      MD
      ctx = make_ctx(dir).with(pass: 4)
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx),
             "any remaining [ ] line means not approved"
    end
  end

  def test_fix_guardrail_approved_false_when_file_absent
    with_tmp_dir do |dir|
      ctx = make_ctx(dir).with(pass: 4)
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx),
             "absent file is not approved (defensive default)"
    end
  end

  def test_fix_guardrail_approved_false_when_header_only
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: "# Fix-guardrail findings for pass 04\n\n")
      ctx = make_ctx(dir).with(pass: 4)
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx),
             "header-only file (no checkbox lines) is empty/corrupt, not approved"
    end
  end

  def test_fix_guardrail_approved_uppercase_X_also_counts_as_approved
    # Editors that auto-capitalize `[ ]` to `[X]` shouldn't cause a
    # spurious approval rejection.
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: <<~MD)
        # Fix-guardrail findings for pass 04

        - [X] dotenv_edit: .env.example:?: .env.example
        - [X] dotenv_edit: .env.example:?: .env.example
      MD
      ctx = make_ctx(dir).with(pass: 4)
      assert Hive::Stages::Review.fix_guardrail_approved?(ctx)
    end
  end

  def test_fix_guardrail_approved_rejects_truncated_file_with_count_mismatch
    # ce-review P1 #2: a user who deletes the findings they didn't
    # want to read and ticks `[x]` only on the survivor could
    # otherwise forge approval. The runner threads marker.attrs["matches"]
    # through as expected_matches: to reject the count mismatch.
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: <<~MD)
        # Fix-guardrail findings for pass 04

        - [x] dotenv_edit: .env.example:?: .env.example
      MD
      ctx = make_ctx(dir).with(pass: 4)
      assert Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 1),
             "count-matching all-[x] file remains approved"
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 2),
             "all-[x] but with deleted findings (count mismatch) must NOT be approved"
    end
  end

  # ce-review round-3 P1 #4 (reviewer_partial_failure pause) is now
  # exercised end-to-end via the integration suite at
  # test/integration/run_review_test.rb after pr-review-toolkit
  # round-4 flagged the previous helper-only test as vacuous. The
  # integration test drives the full Stages::Review.run! call path
  # so a regression in branch ordering or call-site detail is caught.

  def test_fix_guardrail_approved_per_pass_isolation
    # An all-[x] file for pass 4 is approval for pass 4 only — it
    # does not affect pass 5's approval state. R11 single-shot
    # semantic.
    with_tmp_dir do |dir|
      write_guardrail_file(dir, pass: 4, body: <<~MD)
        # Fix-guardrail findings for pass 04

        - [x] dotenv_edit: .env.example:?: .env.example
      MD
      assert Hive::Stages::Review.fix_guardrail_approved?(make_ctx(dir).with(pass: 4))
      refute Hive::Stages::Review.fix_guardrail_approved?(make_ctx(dir).with(pass: 5)),
             "pass 5 has its own fix-guardrail-05.md state (absent here = not approved)"
    end
  end

  # plan U4 AC3 (round-1 finding): the orchestrator MUST call
  # GithubPublisher.publish! once per successful reviewer. A regression
  # that drops the `publish_review_file(...)` call inside
  # `run_reviewers` would otherwise be invisible — every other test
  # either runs with no pr.md (publisher short-circuits :missing_pr) or
  # stubs `run_reviewers` whole. This test wires a real pr.md +
  # fake-gh in PATH and asserts `gh pr comment` is invoked once per
  # reviewer.
  def test_run_reviewers_publishes_each_successful_reviewer_to_github
    prev_path = ENV["PATH"]
    gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH_FIXTURE, File.join(gh_dir, "gh"))
    ENV["PATH"] = "#{gh_dir}:#{prev_path}"
    log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = log_dir

    with_tmp_dir do |dir|
      File.write(File.join(dir, "pr.md"), <<~MD)
        ---
        pr_url: https://example.com/pr/77
        pr_number: 77
        ---

        <!-- COMPLETE pr_url=https://example.com/pr/77 is_draft=true -->
      MD

      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "rev-a", "output_basename" => "rev-a" },
            { "name" => "rev-b", "output_basename" => "rev-b" }
          ],
          "github_publish" => { "enabled" => true, "max_attempts" => 1 }
        }
      }
      adapters = [
        OkReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir)),
        OkReviewer.new(cfg["review"]["reviewers"][1], make_ctx(dir))
      ]

      with_stubbed_dispatch(adapters) do
        Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
      end

      log_path = File.join(log_dir, "fake-gh-argv.log")
      log = File.exist?(log_path) ? File.read(log_path) : ""
      comment_invocations = log.scan(/^cmd=gh\b.*\narg=pr\narg=comment\n/m).size
      # Some fake-gh argv-log formats split per arg per line; fall
      # back to counting `arg=comment` occurrences.
      comment_invocations = log.scan(/^arg=comment$/).size if comment_invocations.zero?
      assert_equal 2, comment_invocations,
                   "publisher must be invoked once per successful reviewer (got log=#{log.inspect})"
    end
  ensure
    ENV["PATH"] = prev_path
    FileUtils.rm_rf(gh_dir) if gh_dir
    FileUtils.rm_rf(log_dir) if log_dir
    ENV.delete("HIVE_FAKE_GH_LOG_DIR")
  end
end
