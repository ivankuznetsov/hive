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
    def run!
      raise RuntimeError, "boom"
    end
  end

  # A reviewer whose run! returns :ok. Produces a stub findings file so
  # the test can verify both reviewers actually ran.
  class OkReviewer < Hive::Reviewers::Base
    def run!
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

      # Stub Hive::Reviewers.dispatch to return our two test doubles in
      # order. Patches Hive::Reviewers (not the class) so the orchestrator
      # picks them up unchanged.
      orig = Hive::Reviewers.method(:dispatch)
      idx = 0
      adapters = [
        RaisingReviewer.new(cfg["review"]["reviewers"][0], make_ctx(dir)),
        OkReviewer.new(cfg["review"]["reviewers"][1], make_ctx(dir))
      ]
      Hive::Reviewers.define_singleton_method(:dispatch) do |_spec, _ctx, **_kwargs|
        a = adapters[idx]
        idx += 1
        a
      end

      begin
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
      ensure
        Hive::Reviewers.define_singleton_method(:dispatch, orig)
      end

      # Orchestrator returns :ok because the second reviewer succeeded —
      # not :all_failed. A single rescue does not poison the phase.
      assert_equal :ok, result, "rescue must let surviving reviewers run"

      # The raising reviewer's stub finding file landed (so triage has
      # something to read for it at this pass).
      raising_stub = File.join(dir, "reviews", "raises-01.md")
      assert File.exist?(raising_stub),
             "stub finding file must be written for the raising reviewer"
      assert_includes File.read(raising_stub), "RuntimeError"
      assert_includes File.read(raising_stub), "boom"

      # The OK reviewer's findings landed too.
      ok_findings = File.join(dir, "reviews", "ok-01.md")
      assert File.exist?(ok_findings), "second reviewer must have run"
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
end
