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

  def with_fake_clocks(wall_start: Time.utc(2026, 5, 26, 12, 0, 0), monotonic_start: 1_000.0)
    wall_now = wall_start
    monotonic_now = monotonic_start
    advance = lambda do |seconds|
      wall_now += seconds
      monotonic_now += seconds
    end

    with_replaced_singleton_method(Time, :now, -> { wall_now }) do
      with_replaced_singleton_method(Process, :clock_gettime, ->(_clock, *_args) { monotonic_now }) do
        yield advance
      end
    end
  end

  # Refs are full `refs/remotes/origin/<branch>` paths so the test matches
  # how `reviewer_compare_ref` probes existence in production (the short
  # form `origin/<branch>` is ambiguous with a like-named tag).
  class FakeOps
    def initialize(origin_default_branch: nil, refs: [])
      @origin_default_branch = origin_default_branch
      @refs = refs
    end

    attr_reader :origin_default_branch

    def ref_exists?(ref)
      @refs.include?(ref)
    end
  end

  def test_reviewer_compare_ref_prefers_origin_default_branch_when_available
    ops = FakeOps.new(origin_default_branch: "main",
                      refs: [ "refs/remotes/origin/main" ])

    assert_equal "origin/main", Hive::Stages::Review.reviewer_compare_ref({}, ops)
  end

  def test_reviewer_compare_ref_falls_back_to_local_default_when_origin_ref_missing
    # origin_default_branch is set (operator's project HAS a default branch
    # from origin/HEAD or a probe match) but the remote-tracking ref is
    # absent locally (shallow clone, offline worktree). Warn and fall back.
    ops = FakeOps.new(origin_default_branch: "main", refs: [])

    result = nil
    _out, err = capture_io do
      result = Hive::Stages::Review.reviewer_compare_ref({}, ops)
    end

    assert_equal "main", result
    assert_match(/origin\/main not found/, err)
    assert_match(/diffs may be stale/, err)
  end

  def test_reviewer_compare_ref_refuses_preflight_when_no_trusted_source
    # No config, no origin/HEAD, no origin/main, no origin/master:
    # falling back to the worktree's current branch would make reviewers
    # diff the task branch against itself. Refuse instead with a clear
    # message naming the two remediation paths.
    ops = FakeOps.new(origin_default_branch: nil, refs: [])

    _out, err = capture_io do
      assert_raises(SystemExit) do
        Hive::Stages::Review.reviewer_compare_ref({}, ops)
      end
    end

    assert_match(/reviewer compare ref unavailable/, err)
    assert_match(/default_branch/, err)
    assert_match(/remote set-head/, err)
  end

  def test_reviewer_compare_ref_honors_configured_default_branch
    ops = FakeOps.new(origin_default_branch: "main",
                      refs: [ "refs/remotes/origin/trunk" ])
    cfg = { "default_branch" => "trunk" }

    assert_equal "origin/trunk", Hive::Stages::Review.reviewer_compare_ref(cfg, ops)
  end

  def test_reviewer_compare_ref_preserves_explicit_remote_ref
    ops = FakeOps.new(origin_default_branch: "main",
                      refs: [ "refs/remotes/origin/main" ])
    cfg = { "default_branch" => "origin/main" }

    assert_equal "origin/main", Hive::Stages::Review.reviewer_compare_ref(cfg, ops)
  end

  def test_reviewer_compare_ref_strips_whitespace_in_configured_branch
    ops = FakeOps.new(origin_default_branch: "main",
                      refs: [ "refs/remotes/origin/trunk" ])
    cfg = { "default_branch" => "  trunk  " }

    assert_equal "origin/trunk", Hive::Stages::Review.reviewer_compare_ref(cfg, ops)
  end

  # Minimal ops for reviewer_compare_base_sha, which only reads
  # project_root to shell `git -C <root> rev-parse`.
  BaseOps = Struct.new(:project_root)

  def test_reviewer_compare_base_sha_resolves_a_real_ref
    with_tmp_git_repo do |dir|
      head = run!("git", "-C", dir, "rev-parse", "--verify", "HEAD").strip

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.reviewer_compare_base_sha(BaseOps.new(dir), "master")
      end

      assert_equal head, result.sha
      refute result.degraded, "a ref that resolves is not the degraded fallback"
      assert_empty err
    end
  end

  def test_reviewer_compare_base_sha_falls_back_to_head_when_ref_unresolvable
    with_tmp_git_repo do |dir|
      head = run!("git", "-C", dir, "rev-parse", "--verify", "HEAD").strip

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.reviewer_compare_base_sha(BaseOps.new(dir), "no-such-ref")
      end

      assert_equal head, result.sha, "an unresolvable ref must fall back to the worktree HEAD"
      assert result.degraded, "the HEAD fallback is the degraded mode that resets suppression each pass"
      assert_match(/did not resolve/, err)
      assert_match(/falling back to worktree HEAD/, err)
    end
  end

  def test_reviewer_compare_base_sha_uses_unresolved_token_when_head_missing
    # A brand-new repo with no commits: neither the compare ref nor HEAD
    # resolves, so the base degrades to a deterministic unresolved-ref token.
    with_tmp_dir do |dir|
      run!("git", "-C", dir, "init", "-b", "master", "--quiet")

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.reviewer_compare_base_sha(BaseOps.new(dir), "no-such-ref")
      end

      assert_match(/\Aunresolved-[0-9a-f]{16}\z/, result.sha)
      assert result.degraded
      assert_match(/unresolved-ref token/, err)
    end
  end

  def test_reviewer_specs_for_normal_task_uses_standard_reviewers
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ]
      },
      "patrol" => {
        "review" => {
          "reviewers" => [ { "name" => "patrol-reviewer" } ]
        }
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: telegram\n---\n\n# Task\n")
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(cfg, task)
      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  def test_reviewer_specs_for_patrol_task_uses_patrol_reviewers
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ]
      },
      "patrol" => {
        "review" => {
          "reviewers" => [ { "name" => "patrol-reviewer" } ]
        }
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: patrol\n---\n\n# Patrol: Demo\n")
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(cfg, task)
      assert_equal [ "patrol-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  def test_reviewer_specs_for_adhoc_task_uses_adhoc_reviewers
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ],
        "adhoc" => {
          "reviewers" => [ { "name" => "adhoc-reviewer" } ]
        }
      },
      "patrol" => {
        "review" => {
          "reviewers" => [ { "name" => "patrol-reviewer" } ]
        }
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc PR\n")
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(cfg, task)
      assert_equal [ "adhoc-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  def test_reviewer_specs_for_adhoc_task_passes_through_a_malformed_entry
    # A malformed ENTRY (a non-Hash) inside review.adhoc.reviewers is distinct
    # from a malformed array SHAPE: the ad-hoc branch is still taken (an
    # explicit non-nil adhoc.reviewers does NOT fall back to the normal set),
    # and the entry is threaded through unchanged for the reviewer dispatcher
    # to reject — it is not silently dropped or swapped for the normal set.
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ],
        "adhoc" => { "reviewers" => [ "not-a-hash-entry" ] }
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc PR\n")
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(cfg, task)
      assert_equal [ "not-a-hash-entry" ], specs,
                   "an explicit ad-hoc reviewers list is used as-is, not replaced by the normal set"
    end
  end

  def test_reviewer_specs_for_adhoc_task_falls_back_to_standard_reviewers
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ],
        "adhoc" => { "reviewers" => nil }
      },
      "patrol" => {
        "review" => {
          "reviewers" => [ { "name" => "patrol-reviewer" } ]
        }
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: AD-HOC\n---\n\n# Ad-hoc PR\n")
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(cfg, task)
      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  # cfg with distinct normal vs patrol reviewer sets, reused by the
  # task_frontmatter / patrol_task? edge-case tests below.
  def scoped_reviewer_cfg
    {
      "review" => { "reviewers" => [ { "name" => "normal-reviewer" } ] },
      "patrol" => { "review" => { "reviewers" => [ { "name" => "patrol-reviewer" } ] } }
    }
  end

  def assert_routes_to_normal(task_md_contents)
    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, task_md_contents)
      task = Task.new(dir, task_file)

      specs = Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  def test_reviewer_specs_for_routes_to_normal_when_state_file_missing
    # task_frontmatter: File.exist? false → {} → not patrol → normal set.
    with_tmp_dir do |dir|
      task = Task.new(dir, File.join(dir, "task.md")) # never created
      specs = Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
    end
  end

  def test_reviewer_specs_for_routes_to_normal_without_frontmatter_marker
    # task_frontmatter: content not starting with "---\n" → {} → normal.
    assert_routes_to_normal("# Just a heading\n\nsource: patrol\n")
  end

  def test_reviewer_specs_for_routes_to_normal_on_empty_frontmatter_block
    # task_frontmatter: empty YAML between the fences → {} → normal.
    assert_routes_to_normal("---\n---\n\n# Body\n")
  end

  def test_reviewer_specs_for_routes_to_normal_on_non_hash_frontmatter
    # task_frontmatter: top-level YAML is a list, not a Hash → {} → normal.
    assert_routes_to_normal("---\n- patrol\n---\n\n# Body\n")
  end

  def test_reviewer_specs_for_routes_to_normal_on_malformed_yaml
    # task_frontmatter: Psych::Exception is rescued → {} → normal.
    assert_routes_to_normal("---\nsource: : : broken\n  bad: [unclosed\n---\n\n# Body\n")
  end

  def test_reviewer_specs_for_normalizes_patrol_source_casing_and_whitespace
    # patrol_task? uses strip + casecmp?, so producer/consumer drift in
    # casing or surrounding whitespace still routes to the patrol set.
    [ "Patrol", "PATROL", "\"patrol\"", "  patrol  " ].each do |value|
      with_tmp_dir do |dir|
        task_file = File.join(dir, "task.md")
        File.write(task_file, "---\nsource: #{value}\n---\n\n# Body\n")
        task = Task.new(dir, task_file)

        specs = Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
        assert_equal [ "patrol-reviewer" ], specs.map { |spec| spec.fetch("name") },
                     "source #{value.inspect} must normalize to a patrol task"
      end
    end
  end

  # A task whose state_file accessor raises, used to exercise patrol_task?'s
  # rescue boundary.
  RaisingStateFileTask = Struct.new(:folder, :error) do
    def state_file
      raise error
    end
  end

  def test_patrol_task_io_error_falls_back_to_normal_with_warn
    # An I/O failure reading state_file must NOT misroute silently: the
    # narrowed SystemCallError rescue logs and falls back to the normal set.
    # Point state_file at a directory so File.read raises Errno::EISDIR —
    # the realistic shape (the path resolves, but the read fails).
    with_tmp_dir do |dir|
      task = Task.new(dir, dir) # state_file is a directory → File.read raises

      specs = nil
      _out, err = capture_io do
        specs = Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
      end

      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
      assert_match(/patrol_task\? could not read/, err)
      assert_match(/routing as a normal/, err)
    end
  end

  def test_patrol_task_does_not_swallow_programmer_errors
    # The rescue is intentionally narrowed to SystemCallError so genuine
    # programmer errors surface instead of being masked as "not patrol".
    task = RaisingStateFileTask.new("/nonexistent", RuntimeError.new("boom"))

    assert_raises(RuntimeError) do
      Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
    end
  end

  def test_adhoc_task_io_error_falls_back_to_normal_with_warn
    with_tmp_dir do |dir|
      task = Task.new(dir, dir)

      specs = nil
      _out, err = capture_io do
        specs = Hive::Stages::Review.reviewer_specs_for(scoped_reviewer_cfg, task)
      end

      assert_equal [ "normal-reviewer" ], specs.map { |spec| spec.fetch("name") }
      assert_match(/adhoc_task\? could not read/, err)
      assert_match(/routing as a normal/, err)
    end
  end

  def test_adhoc_fix_enabled_predicate
    cfg = { "review" => { "adhoc" => { "fix" => false } } }
    enabled_cfg = { "review" => { "adhoc" => { "fix" => true } } }

    with_tmp_dir do |dir|
      adhoc_file = File.join(dir, "adhoc.md")
      normal_file = File.join(dir, "normal.md")
      File.write(adhoc_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc\n")
      File.write(normal_file, "---\nsource: telegram\n---\n\n# Normal\n")
      adhoc_task = Task.new(dir, adhoc_file)
      normal_task = Task.new(dir, normal_file)

      refute Hive::Stages::Review.adhoc_fix_enabled?(cfg, adhoc_task)
      assert Hive::Stages::Review.adhoc_fix_enabled?(enabled_cfg, adhoc_task)
      assert Hive::Stages::Review.adhoc_fix_enabled?(cfg, normal_task)
    end
  end

  def test_adhoc_fix_gate_fails_closed_on_state_file_read_error
    # The fix gate is a SAFETY check: when the source can't be read it must
    # fail CLOSED (treat as ad-hoc → auto-fix disabled by default), the
    # opposite of reviewer selection's fail-open. Point state_file at a
    # directory so File.read raises Errno::EISDIR.
    cfg = { "review" => { "adhoc" => { "fix" => false } } }

    with_tmp_dir do |dir|
      task = Task.new(dir, dir) # state_file is a directory → File.read raises

      enabled = nil
      _out, err = capture_io do
        enabled = Hive::Stages::Review.adhoc_fix_enabled?(cfg, task)
      end

      refute enabled, "unreadable source must disable auto-fix (fail closed)"
      assert_match(/adhoc fix-gate could not read/, err)
      assert_match(/failing closed \(auto-fix disabled, source unconfirmable\)/, err)
    end
  end

  def test_adhoc_fix_gate_classifies_the_three_source_states
    # The gate must report WHY auto-fix is disabled so a Phase 4 park reason
    # can tell a review-only ad-hoc task apart from a normal task whose source
    # couldn't be read (otherwise a normal task halts as adhoc_fix_disabled).
    fix_off = { "review" => { "adhoc" => { "fix" => false } } }
    fix_on = { "review" => { "adhoc" => { "fix" => true } } }

    with_tmp_dir do |dir|
      adhoc_file = File.join(dir, "adhoc.md")
      File.write(adhoc_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc\n")
      normal_file = File.join(dir, "normal.md")
      File.write(normal_file, "---\nsource: telegram\n---\n\n# Normal\n")

      assert_equal :disabled_adhoc,
                   Hive::Stages::Review.adhoc_fix_gate(fix_off, Task.new(dir, adhoc_file))
      assert_equal :enabled,
                   Hive::Stages::Review.adhoc_fix_gate(fix_on, Task.new(dir, adhoc_file))
      assert_equal :enabled,
                   Hive::Stages::Review.adhoc_fix_gate(fix_off, Task.new(dir, normal_file))

      capture_io do
        assert_equal :disabled_source_unknown,
                     Hive::Stages::Review.adhoc_fix_gate(fix_off, Task.new(dir, dir)),
                     "an unreadable source must classify as source-unknown, not adhoc"
      end
    end
  end

  def test_empty_patrol_reviewers_warns_so_patrol_pr_is_not_silently_unreviewed
    cfg = {
      "review" => { "reviewers" => [ { "name" => "normal-reviewer" } ] },
      "patrol" => { "review" => { "reviewers" => [] } } # explicit opt-out
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: patrol\n---\n\n# Patrol PR\n")
      task = Task.new(dir, task_file)

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), task)
      end

      assert_equal :ok, result, "empty patrol reviewers still returns :ok (intentional opt-out)"
      assert_match(/zero patrol\.review\.reviewers/, err,
                   "a patrol task with no reviewers must warn rather than pass silently")
    end
  end

  def test_empty_adhoc_reviewers_warns_so_adhoc_pr_is_not_silently_unreviewed
    cfg = {
      "review" => {
        "reviewers" => [ { "name" => "normal-reviewer" } ],
        "adhoc" => { "reviewers" => [] } # explicit [] runs zero reviewers
      }
    }

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc PR\n")
      task = Task.new(dir, task_file)

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), task)
      end

      assert_equal :ok, result, "empty ad-hoc reviewers still returns :ok (explicit opt-out)"
      assert_match(/zero reviewers \(review\.adhoc\.reviewers is empty\)/, err,
                   "an explicit empty review.adhoc.reviewers must name that knob")
    end
  end

  def test_empty_inherited_reviewers_warns_and_names_review_reviewers
    # nil review.adhoc.reviewers inherits review.reviewers; when that is ALSO
    # empty (the DEFAULT) the ad-hoc task DOES reach the zero-reviewer branch,
    # and the warning must name review.reviewers (the actually-empty knob),
    # not review.adhoc.reviewers.
    cfg = { "review" => { "reviewers" => [] } } # adhoc.reviewers omitted → inherits

    with_tmp_dir do |dir|
      task_file = File.join(dir, "task.md")
      File.write(task_file, "---\nsource: ad-hoc\n---\n\n# Ad-hoc PR\n")
      task = Task.new(dir, task_file)

      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), task)
      end

      assert_equal :ok, result
      assert_match(/zero reviewers \(review\.reviewers is empty\)/, err,
                   "the inherit case must name review.reviewers, not review.adhoc.reviewers")
    end
  end

  def test_reviewer_compare_ref_configured_branch_falls_back_to_local_with_warn
    # Configured branch is the explicit operator opt-in, so we use it
    # even when the remote ref is missing — but still warn so the
    # operator sees the degraded mode.
    ops = FakeOps.new(origin_default_branch: nil, refs: [])
    cfg = { "default_branch" => "develop" }

    result = nil
    _out, err = capture_io do
      result = Hive::Stages::Review.reviewer_compare_ref(cfg, ops)
    end

    assert_equal "develop", result
    assert_match(/origin\/develop not found/, err)
  end

  def test_reviewer_compare_ref_ignores_tag_named_origin_main
    # rev-parse --verify on the SHORT form `origin/main` resolves a tag
    # of that name; the helper probes the full path
    # `refs/remotes/origin/main` to reject this collision. Pin the
    # contract: a FakeOps that returns true for the SHORT form but false
    # for the FULL form must NOT yield an origin/-form return.
    ops = Class.new do
      def origin_default_branch = "main"
      # Tag-shaped match: only the short form would resolve.
      def ref_exists?(ref) = ref == "origin/main"
    end.new

    result = nil
    _out, err = capture_io do
      result = Hive::Stages::Review.reviewer_compare_ref({}, ops)
    end

    assert_equal "main", result,
                 "tag-shaped short-form match must not satisfy the remote-tracking ref check"
    assert_match(/origin\/main not found/, err)
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

  # A legacy/custom reviewer adapter that does not accept deadline:.
  class NoDeadlineReviewer < Hive::Reviewers::Base
    def run!
      ensure_reviews_dir!
      File.write(output_path, "## Low\n\n- [ ] no deadline kwarg\n")
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :ok,
        error_message: nil
      )
    end
  end

  class DeadlineCaptureReviewer < Hive::Reviewers::Base
    attr_reader :deadline_seconds

    def run!(deadline: nil)
      @deadline_seconds = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
      ensure_reviews_dir!
      File.write(output_path, "## Low\n\n- [ ] captured deadline\n")
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :ok,
        error_message: nil
      )
    end
  end

  class AdvancingDeadlineCaptureReviewer < DeadlineCaptureReviewer
    def initialize(spec, ctx, advance:)
      super(spec, ctx)
      @advance = advance
    end

    def run!(deadline: nil)
      result = super
      @advance.call
      result
    end
  end

  class SharedSessionReviewer < Hive::Reviewers::Base
    attr_reader :headless_runs, :session_runs

    def initialize(spec, ctx)
      super
      @headless_runs = 0
      @session_runs = 0
    end

    def run!(deadline: nil)
      @headless_runs += 1
      write_success
    end

    def run_in_session!(handle:, deadline: nil)
      @session_runs += 1
      handle.events << name
      write_success
    end

    def write_success
      ensure_reviews_dir!
      File.write(output_path, "## #{name}\n\n- [ ] ok\n")
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :ok,
        error_message: nil
      )
    end
  end

  class DeadlineCaptureSharedReviewer < SharedSessionReviewer
    attr_reader :session_deadline_seconds

    def run_in_session!(handle:, deadline: nil)
      @session_deadline_seconds = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
      super
    end
  end

  SharedSessionHandle = Struct.new(:events)

  # Shared test helper: stub Hive::Reviewers.dispatch to return adapters
  # keyed by spec["name"] (or, when names collide / are absent, by FIFO
  # order). Indexing-by-name is robust against the orchestrator
  # processing specs in non-input order (e.g., the claude / non-claude
  # partition introduced when the shared tmux session covers only the
  # claude group).
  def with_stubbed_dispatch(adapters)
    orig = Hive::Reviewers.method(:dispatch)
    by_name = {}
    fifo = adapters.dup
    adapters.each do |a|
      name = a.respond_to?(:name) ? a.name : nil
      by_name[name] ||= [] if name
      by_name[name] << a if name
    end
    Hive::Reviewers.define_singleton_method(:dispatch) do |spec, _ctx, **_kwargs|
      key = spec.is_a?(Hash) ? spec["name"] : nil
      if key && by_name[key] && !by_name[key].empty?
        by_name[key].shift
      else
        fifo.shift
      end
    end
    begin
      yield
    ensure
      Hive::Reviewers.define_singleton_method(:dispatch, orig)
    end
  end

  def with_stubbed_claude_session
    orig = Hive::ClaudeLauncher.method(:with_shared_session)
    sessions = []
    Hive::ClaudeLauncher.define_singleton_method(:with_shared_session) do |**kwargs, &block|
      handle = SharedSessionHandle.new([])
      sessions << { kwargs: kwargs, handle: handle }
      block.call(handle)
    end
    begin
      yield sessions
    ensure
      Hive::ClaudeLauncher.define_singleton_method(:with_shared_session, orig)
    end
  end

  def test_claude_reviewers_share_one_tmux_session_when_claude_mode_tmux
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| SharedSessionReviewer.new(spec, ctx) }

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))

          assert_equal :ok, result
          assert_equal 1, sessions.length
          assert_equal "hive-6-review-pass1-#{File.basename(dir)}", sessions[0][:kwargs][:session_name]
          assert_equal [ "claude-a", "claude-b" ], sessions[0][:handle].events
          assert_equal [ 0, 0 ], adapters.map(&:headless_runs)
          assert_equal [ 1, 1 ], adapters.map(&:session_runs)
        end
      end
    end
  end

  def test_shared_claude_sessions_receive_their_group_route
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "models" => {
          "review_reviewers" => { "effort" => "high" }
        },
        "review" => {
          "reviewers" => [
            {
              "name" => "opus", "output_basename" => "opus",
              "kind" => "agent", "agent" => "claude", "model" => "opus"
            },
            {
              "name" => "sonnet", "output_basename" => "sonnet",
              "kind" => "agent", "agent" => "claude", "model" => "sonnet"
            }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| SharedSessionReviewer.new(spec, ctx) }

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(
            cfg, ctx, Task.new(dir, File.join(dir, "task.md"))
          )

          assert_equal :ok, result
          assert_equal 2, sessions.length
          assert_equal [
            [ "--model", "opus", "--effort", "high" ],
            [ "--model", "sonnet", "--effort", "high" ]
          ], sessions.map { |session| session[:kwargs].fetch(:cli_flags) }
        end
      end
    end
  end

  def test_shared_session_reviewers_each_get_full_remaining_budget
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| DeadlineCaptureSharedReviewer.new(spec, ctx) }

      with_fake_clocks do
        with_stubbed_dispatch(adapters) do
          with_stubbed_claude_session do
            result = Hive::Stages::Review.run_reviewers(
              cfg,
              ctx,
              Task.new(dir, File.join(dir, "task.md")),
              started_at: Time.now,
              max_wall_clock_sec: 60
            )
            assert_equal :ok, result
          end
        end
      end

      assert_in_delta 60, adapters[0].session_deadline_seconds, 0.001,
                      "each shared-session reviewer gets the FULL remaining 60s budget — its own " \
                      "timeout_sec is the real per-reviewer cap, not a 1/N split"
      assert_in_delta 60, adapters[1].session_deadline_seconds, 0.001,
                      "with no wall time elapsed, the last reviewer also sees the full budget"
    end
  end

  def test_mixed_tmux_and_headless_reviewers_share_the_same_deadline_counter
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" },
            { "name" => "codex-a", "output_basename" => "codex-a", "kind" => "agent", "agent" => "codex" },
            { "name" => "codex-b", "output_basename" => "codex-b", "kind" => "agent", "agent" => "codex" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map do |spec|
        spec["agent"] == "claude" ? DeadlineCaptureSharedReviewer.new(spec, ctx) : DeadlineCaptureReviewer.new(spec, ctx)
      end

      with_fake_clocks do
        with_stubbed_dispatch(adapters) do
          with_stubbed_claude_session do
            result = Hive::Stages::Review.run_reviewers(
              cfg,
              ctx,
              Task.new(dir, File.join(dir, "task.md")),
              started_at: Time.now,
              max_wall_clock_sec: 120
            )
            assert_equal :ok, result
          end
        end
      end

      # Same deadline counter across the mixed pass; with no wall time
      # elapsed in the fake clock every reviewer sees the full 120s budget.
      assert_in_delta 120, adapters[1].deadline_seconds, 0.001
      assert_in_delta 120, adapters[2].deadline_seconds, 0.001
      assert_in_delta 120, adapters[0].session_deadline_seconds, 0.001
      assert_in_delta 120, adapters[3].session_deadline_seconds, 0.001
    end
  end

  def test_tmux_mode_keeps_non_claude_reviewers_headless_inside_shared_pass
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" },
            { "name" => "codex-a", "output_basename" => "codex-a", "kind" => "agent", "agent" => "codex" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| SharedSessionReviewer.new(spec, ctx) }

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))

          assert_equal :ok, result
          assert_equal 1, sessions.length
          assert_equal [ "claude-a", "claude-b" ], sessions[0][:handle].events
          assert_equal [ 0, 1, 0 ], adapters.map(&:headless_runs)
          assert_equal [ 1, 0, 1 ], adapters.map(&:session_runs)
        end
      end
    end
  end

  def test_claude_reviewers_stay_headless_when_claude_mode_headless
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "headless" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| SharedSessionReviewer.new(spec, ctx) }

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))

          assert_equal :ok, result
          assert_empty sessions
          assert_equal [ 1 ], adapters.map(&:headless_runs)
          assert_equal [ 0 ], adapters.map(&:session_runs)
        end
      end
    end
  end

  def test_tmux_session_is_not_opened_when_wall_clock_already_exceeded
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| SharedSessionReviewer.new(spec, ctx) }

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(
            cfg,
            ctx,
            Task.new(dir, File.join(dir, "task.md")),
            started_at: Time.now - 10,
            max_wall_clock_sec: 1
          )

          assert_equal :wall_clock_exceeded, result
          assert_empty sessions
          assert_equal [ 0 ], adapters.map(&:headless_runs)
          assert_equal [ 0 ], adapters.map(&:session_runs)
        end
      end
    end
  end

  # G1: shared-session mid-pass failure — one claude reviewer raises
  # inside the shared tmux session, the next one in the group must
  # still run. A regression that tears down the session on a single
  # raise would only affect the SHARED branch (the unshared branch is
  # already covered by `test_first_reviewer_raise_does_not_abort_second`).
  class SharedSessionRaisingReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      raise RuntimeError, "headless boom"
    end

    def run_in_session!(handle:, deadline: nil)
      raise RuntimeError, "shared boom"
    end
  end

  def test_shared_session_first_reviewer_raise_does_not_abort_second
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "raises", "output_basename" => "raises", "kind" => "agent", "agent" => "claude" },
            { "name" => "ok",     "output_basename" => "ok",     "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = [
        SharedSessionRaisingReviewer.new(cfg["review"]["reviewers"][0], ctx),
        SharedSessionReviewer.new(cfg["review"]["reviewers"][1], ctx)
      ]

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do |sessions|
          result = Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))
          assert_equal :ok, result, "shared-session raise must NOT abort surviving reviewer"
          assert_equal 1, sessions.length
        end
      end

      assert File.exist?(File.join(dir, "reviews", "ok-01.md")),
             "second reviewer in shared session must run after first raises"
      assert File.exist?(File.join(dir, "reviews", "errors-01.md")),
             "first reviewer's raise must land in errors-NN.md"
    end
  end

  # G7: shared-session :all_failed — when every claude reviewer in
  # the shared session returns :error, the orchestrator must still
  # return :all_failed (and the errors-NN.md sink must reflect every
  # failure, not be silently dropped by the with_shared_session block).
  class SharedSessionErroringReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(
        name: name, output_path: output_path, status: :error,
        error_message: "headless failure"
      )
    end

    def run_in_session!(handle:, deadline: nil)
      Hive::Reviewers::Result.new(
        name: name, output_path: output_path, status: :error,
        error_message: "shared failure"
      )
    end
  end

  def test_shared_session_all_failed
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "review" => {
          "reviewers" => [
            { "name" => "a", "output_basename" => "a", "kind" => "agent", "agent" => "claude" },
            { "name" => "b", "output_basename" => "b", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map do |spec|
        SharedSessionErroringReviewer.new(spec, ctx)
      end

      with_stubbed_dispatch(adapters) do
        with_stubbed_claude_session do
          result = Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))
          assert_equal :all_failed, result,
                       "every shared-session reviewer failing must surface :all_failed"
        end
      end

      errors_path = File.join(dir, "reviews", "errors-01.md")
      assert File.exist?(errors_path), "errors-NN.md must record both failures"
      contents = File.read(errors_path)
      assert_includes contents, "[a] reviewer \"a\" failed"
      assert_includes contents, "[b] reviewer \"b\" failed"
    end
  end

  # Every reviewer failing specifically because of a usage/credit limit must
  # be classified as :all_failed_limit (so the marker becomes
  # reason=limits_reached) rather than a generic :all_failed.
  class LimitErroringReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(
        name: name, output_path: output_path, status: :error,
        error_message: "limits reached for codex: You've hit your usage limit.",
        limit_text: "You've hit your usage limit. Try again at Jul 18th, 2026 7:50 AM."
      )
    end
  end

  class QuotedLimitErroringReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(
        name: name, output_path: output_path, status: :error,
        error_message: "reviewer analyzed code that quoted limits reached for codex: not an agent wall"
      )
    end
  end

  def test_all_failed_due_to_usage_limit_returns_all_failed_limit
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "a", "output_basename" => "a" },
            { "name" => "b", "output_basename" => "b" }
          ]
        }
      }
      adapters = cfg["review"]["reviewers"].map { |spec| LimitErroringReviewer.new(spec, make_ctx(dir)) }
      limit_texts = []

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(
          cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")), limit_texts: limit_texts
        )
        assert_equal :all_failed_limit, result,
                     "all reviewers failing with a usage-limit error must surface :all_failed_limit"
        assert_equal [ "You've hit your usage limit. Try again at Jul 18th, 2026 7:50 AM." ] * 2,
                     limit_texts
      end
    end
  end

  def test_all_failed_with_quoted_limit_text_returns_all_failed
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "a", "output_basename" => "a" },
            { "name" => "b", "output_basename" => "b" }
          ]
        }
      }
      adapters = cfg["review"]["reviewers"].map { |spec| QuotedLimitErroringReviewer.new(spec, make_ctx(dir)) }

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :all_failed, result,
                     "quoted limit prose must not promote all reviewers to limits_reached"
      end
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

  def test_reviewer_without_deadline_kwarg_still_runs
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [ { "name" => "legacy", "output_basename" => "legacy" } ]
        }
      }
      adapters = [ NoDeadlineReviewer.new(cfg["review"]["reviewers"].first, make_ctx(dir)) ]

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        assert_equal :ok, result
      end

      assert File.exist?(File.join(dir, "reviews", "legacy-01.md"))
    end
  end

  def test_run_reviewers_gives_each_reviewer_the_full_remaining_budget
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
      ctx = make_ctx(dir)
      adapters = cfg["review"]["reviewers"].map { |spec| DeadlineCaptureReviewer.new(spec, ctx) }

      with_fake_clocks do
        with_stubbed_dispatch(adapters) do
          result = Hive::Stages::Review.run_reviewers(
            cfg,
            ctx,
            Task.new(dir, File.join(dir, "task.md")),
            started_at: Time.now,
            max_wall_clock_sec: 90
          )
          assert_equal :ok, result
        end
      end

      assert_in_delta 90, adapters[0].deadline_seconds, 0.001,
                      "each reviewer receives the FULL remaining 90s budget, not a 1/N split"
      assert_in_delta 90, adapters[1].deadline_seconds, 0.001,
                      "no wall time elapsed → still the full budget"
      assert_in_delta 90, adapters[2].deadline_seconds, 0.001,
                      "last reviewer may use the remaining budget"
    end
  end

  def test_run_reviewers_reduces_later_deadline_by_elapsed_wall_clock
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "rev-a", "output_basename" => "rev-a" },
            { "name" => "rev-b", "output_basename" => "rev-b" }
          ]
        }
      }
      ctx = make_ctx(dir)

      with_fake_clocks do |advance|
        adapters = [
          AdvancingDeadlineCaptureReviewer.new(cfg["review"]["reviewers"][0], ctx, advance: -> { advance.call(30) }),
          DeadlineCaptureReviewer.new(cfg["review"]["reviewers"][1], ctx)
        ]

        with_stubbed_dispatch(adapters) do
          result = Hive::Stages::Review.run_reviewers(
            cfg,
            ctx,
            Task.new(dir, File.join(dir, "task.md")),
            started_at: Time.now,
            max_wall_clock_sec: 90
          )
          assert_equal :ok, result
        end

        assert_in_delta 90, adapters[0].deadline_seconds, 0.001,
                        "first reviewer gets the full 90s budget"
        assert_in_delta 60, adapters[1].deadline_seconds, 0.001,
                        "second reviewer deadline reflects the 30s the first consumed (full remaining)"
      end
    end
  end

  def test_run_reviewers_returns_wall_clock_exceeded_before_dispatch_when_budget_spent
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [ { "name" => "late", "output_basename" => "late" } ]
        }
      }
      original_dispatch = Hive::Reviewers.method(:dispatch)
      Hive::Reviewers.define_singleton_method(:dispatch) do |_spec, _ctx, **_kwargs|
        flunk "dispatch must not run after wall-clock budget is spent"
      end

      result = Hive::Stages::Review.run_reviewers(
        cfg,
        make_ctx(dir),
        Task.new(dir, File.join(dir, "task.md")),
        started_at: Time.now - 2,
        max_wall_clock_sec: 1
      )
      assert_equal :wall_clock_exceeded, result
    ensure
      Hive::Reviewers.define_singleton_method(:dispatch, original_dispatch) if original_dispatch
    end
  end

  # --- U2 errors-NN.md sink coverage ----------------------------------

  # A reviewer whose run! returns :error without raising. Tests the
  # non-raise error path (the common case: adapter loop exhausted
  # retries, returns the :error envelope).
  class ErroringReviewer < Hive::Reviewers::Base
    def initialize(spec, ctx, error_message:, advance: nil)
      super(spec, ctx)
      @error_message = error_message
      @advance = advance
    end

    def run!(deadline: nil)
      @advance.call if @advance
      Hive::Reviewers::Result.new(
        name: name,
        output_path: output_path,
        status: :error,
        error_message: @error_message
      )
    end
  end

  def test_all_failed_returns_wall_clock_exceeded_when_errors_consume_budget
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "rev-a", "output_basename" => "rev-a" },
            { "name" => "rev-b", "output_basename" => "rev-b" }
          ]
        }
      }
      ctx = make_ctx(dir)

      with_fake_clocks do |advance|
        adapters = cfg["review"]["reviewers"].map do |spec|
          ErroringReviewer.new(spec, ctx, error_message: "timed out", advance: -> { advance.call(1) })
        end

        with_stubbed_dispatch(adapters) do
          result = Hive::Stages::Review.run_reviewers(
            cfg,
            ctx,
            Task.new(dir, File.join(dir, "task.md")),
            started_at: Time.now,
            max_wall_clock_sec: 2
          )
          assert_equal :wall_clock_exceeded, result,
                       "wall-clock exhaustion must win over the all_failed fallback"
        end
      end
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
    refute Hive::Stages::Review.reviewer_file?("suppressed.md"),
           "suppressed.md must be classified as orchestrator-owned"
    # The `suppressed.` prefix is dot-terminated, so a reviewer file that
    # merely begins with `suppressed` is NOT swept into orchestrator-owned.
    assert Hive::Stages::Review.reviewer_file?("suppressed-checks-01.md"),
           "suppressed-checks-01.md is a reviewer file, not the suppression doc"
    assert Hive::Stages::Review.reviewer_file?("suppression-audit-01.md"),
           "suppression-* must stay an ordinary reviewer file"
    # Sanity: a real reviewer file is still recognized.
    assert Hive::Stages::Review.reviewer_file?("claude-ce-code-review-01.md")
  end

  def test_clear_reviewer_infra_errors_raises_named_error_on_delete_failure
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      original_delete = File.method(:delete)
      File.define_singleton_method(:delete) do |target|
        if target.end_with?("errors-01.md")
          raise Errno::EACCES, target
        end

        original_delete.call(target)
      end

      error = assert_raises(Hive::Error) do
        Hive::Stages::Review.clear_reviewer_infra_errors(ctx)
      end
      assert_match(/failed to clear stale .*errors-01\.md/, error.message)
    ensure
      File.define_singleton_method(:delete, original_delete) if original_delete
    end
  end

  def test_record_reviewer_infra_error_raises_named_error_on_write_failure
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      spec = { "name" => "broken", "output_basename" => "broken" }
      result = Hive::Reviewers::Result.new(
        name: "broken",
        output_path: nil,
        status: :error,
        error_message: "boom"
      )
      original_open = File.method(:open)
      File.define_singleton_method(:open) do |target, *args, **kwargs, &block|
        if target.end_with?("errors-01.md") && args.first == "a"
          raise Errno::ENOSPC, target
        end

        original_open.call(target, *args, **kwargs, &block)
      end

      error = assert_raises(Hive::Error) do
        Hive::Stages::Review.record_reviewer_infra_error(ctx, spec, result)
      end
      assert_match(/failed to write reviews\/errors-01\.md/, error.message)
      assert_match(/reviewer "broken"/, error.message)
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end

  def test_incomplete_triage_pass_shim_reports_only_triage_incomplete
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "reviewer-04.md"), "## High\n- [ ] finding\n")

      assert Hive::Stages::Review.incomplete_triage_pass?(dir, 4)

      File.write(File.join(reviews, "escalations-04.md"), "# Escalations\n")
      refute Hive::Stages::Review.incomplete_triage_pass?(dir, 4)
    end
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

  def test_pass_completion_status_errors_retry_only_before_fix_completes
    # A pass can carry a partial reviewer failure (errors-NN.md) AND
    # surviving reviewers whose accepted findings get triaged + fixed.
    # errors-NN.md must force a reviewer rerun ONLY while the fix is still
    # incomplete; once a fresh fix-success-NN.md exists, re-running would
    # clobber the operator's [x] marks and redo the fix.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-ce-code-review-04.md"), "## High\n- [x] x\n")
      escalations = File.join(reviews, "escalations-04.md")
      errors = File.join(reviews, "errors-04.md")
      File.write(escalations, "# Escalations pass 04\n- [x] done\n")
      File.write(errors, "claude-ce-code-review: adapter failed\n")

      assert_equal :triage_incomplete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "errors-NN.md with no completed fix → :triage_incomplete (rerun reviewers)"

      fix_success = File.join(reviews, "fix-success-04.md")
      File.write(fix_success, "ok\n")
      File.utime(Time.now - 60, Time.now - 60, escalations)
      File.utime(Time.now,      Time.now,      fix_success)
      assert_equal :complete, Hive::Stages::Review.pass_completion_status(dir, 4),
                   "fresh fix-success beats lingering errors-NN.md → :complete (no reviewer rerun)"
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

  # G2: pin the direct rescue in `Stages::Review.run!` that maps
  # tmux-unavailable AgentErrors to the dedicated REVIEW_ERROR marker.
  # The existing claude_launcher_test.rb only covers the launcher-level
  # envelope produced by `Stages::Base.spawn_claude_with_tmux_marker!`,
  # which is a different marker family (`:error` vs `:review_error`).
  class TmuxUnavailableReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      raise Hive::AgentError, "tmux binary not runnable: tmux"
    end
  end

  def test_review_run_reviewers_tmux_unavailable_propagates
    # Drive the non-shared headless branch so the test stays in
    # run_reviewer_spec's rescue without touching the real tmux
    # runner. `claude.mode: headless` skips with_shared_session;
    # an agent reviewer's adapter then raises the tmux AgentError
    # exactly as a real claude reviewer would in the same situation.
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "headless" },
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapter = TmuxUnavailableReviewer.new(cfg["review"]["reviewers"][0], ctx)

      err = nil
      with_stubbed_dispatch([ adapter ]) do
        err = assert_raises(Hive::AgentError) do
          Hive::Stages::Review.run_reviewers(
            cfg, ctx, Task.new(dir, File.join(dir, "task.md"))
          )
        end
      end

      assert Hive::ClaudeLauncher.tmux_unavailable_error?(err),
             "tmux unavailable AgentError must propagate out of run_reviewers " \
             "so Stages::Review.run!'s outer rescue can land :review_error"
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

  # A8 fail-closed: a reviewer carrying a non-yolo permission scope on a
  # runner that cannot enforce tool scoping (codex / pi) makes
  # stage_permission_scope raise Hive::ConfigError. The real Agent#run!
  # raises it before spawning; model that here.
  class UnenforceableScopeReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      raise Hive::ConfigError,
            "stage review.reviewers requests permissions \"read-only\" but runner :codex " \
            "cannot enforce tool scoping (claude only)"
    end
  end

  # A8 contract: an unenforceable reviewer permission scope must HARD-ERROR
  # the whole review. The Hive::ConfigError must propagate out of
  # run_reviewers so Stages::Review.run!'s ConfigError rescue lands
  # :review_error — it must NOT be silently caught by run_reviewer_spec's
  # per-reviewer rescue and dropped, which would let a mixed pass continue
  # after dropping the unenforceable reviewer (a silent security downgrade).
  def test_unenforceable_reviewer_scope_hard_errors_the_run
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "headless" },
        "review" => {
          "reviewers" => [
            { "name" => "scoped-codex", "output_basename" => "scoped-codex",
              "kind" => "agent", "agent" => "codex",
              "permissions" => "read-only" },
            { "name" => "ok", "output_basename" => "ok" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = [
        UnenforceableScopeReviewer.new(cfg["review"]["reviewers"][0], ctx),
        OkReviewer.new(cfg["review"]["reviewers"][1], ctx)
      ]

      err = nil
      with_stubbed_dispatch(adapters) do
        err = assert_raises(Hive::ConfigError) do
          Hive::Stages::Review.run_reviewers(
            cfg, ctx, Task.new(dir, File.join(dir, "task.md"))
          )
        end
      end

      assert_match(/cannot enforce tool scoping/, err.message,
                   "the unenforceable-scope ConfigError must propagate, not be swallowed")

      # The pass must NOT continue past the unenforceable reviewer: the
      # surviving OK reviewer never publishes a finding, because the run
      # hard-errored instead of silently dropping the bad reviewer.
      refute File.exist?(File.join(dir, "reviews", "ok-01.md")),
             "review must hard-error, not silently drop the reviewer and continue"
    end
  end

  # --- shared-session reviewer grouping (multi-scope) -------------------

  # Reviewers that resolve to the SAME effective permission scope share one
  # group (one tmux session); a reviewer with a DIFFERING scope splits into
  # its own group. An explicit `permissions: yolo` and a reviewer inheriting
  # the project default yolo are the same effective scope → one group; a
  # read-only reviewer is a different scope → a second group.
  def test_shared_reviewer_groups_dedups_equal_scopes_and_splits_differing_ones
    cfg = { "permissions" => "yolo" }
    specs = [
      { "name" => "inherits-default" },
      { "name" => "explicit-yolo", "permissions" => "yolo" },
      { "name" => "read-only", "permissions" => "read-only" }
    ]

    groups = Hive::Stages::Review.shared_reviewer_groups(cfg, specs)

    assert_equal 2, groups.length,
                 "equal-scope reviewers share one group; the read-only reviewer splits off"
    yolo_group = groups.find { |g| g.map { |s| s["name"] }.sort == %w[explicit-yolo inherits-default] }
    refute_nil yolo_group,
               "explicit yolo and inherited-default yolo must land in the SAME group"
    read_only_group = groups.find { |g| g.map { |s| s["name"] } == %w[read-only] }
    refute_nil read_only_group, "the read-only reviewer must be its own group"
  end

  def test_shared_reviewer_groups_split_different_effective_routes
    cfg = {
      "permissions" => "yolo",
      "models" => {
        "review_reviewers" => { "effort" => "high" }
      }
    }
    specs = [
      { "name" => "opus-a", "model" => "opus" },
      { "name" => "opus-b", "model" => "opus" },
      { "name" => "sonnet", "model" => "sonnet" }
    ]

    groups = Hive::Stages::Review.shared_reviewer_groups(cfg, specs)

    assert_equal 2, groups.length
    assert groups.any? { |group| group.map { |spec| spec["name"] }.sort == %w[opus-a opus-b] }
    assert groups.any? { |group| group.map { |spec| spec["name"] } == %w[sonnet] }
  end

  # Only the first group reuses the base session name; each subsequent
  # differing-scope group gets a distinct "-scopeN" suffix so two scopes
  # never collide on one tmux session.
  def test_shared_reviewer_session_name_suffixes_only_secondary_scope_groups
    with_tmp_dir do |dir|
      task = Task.new(dir, File.join(dir, "task.md"))

      base = Hive::Stages::Review.shared_reviewer_session_name(task, 2, 0)
      second = Hive::Stages::Review.shared_reviewer_session_name(task, 2, 1)

      refute_includes base, "-scope", "the first group keeps the base session name"
      assert_includes second, "-scope2", "the second scope group gets a -scope2 suffix"
      refute_equal base, second, "differing-scope groups must not share a session name"
    end
  end

  # The reviewer path builds each group's scope from group.first via
  # stage_permission_scope("review.reviewers", base_add_dirs: [ctx.task_folder]).
  # A `scoped` reviewer's `dirs:` must EXTEND that base list (relative resolved
  # from the task folder, absolute honored) rather than replacing it.
  def test_shared_reviewer_permission_scope_extends_task_folder_with_scoped_dirs
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Task.new(dir, File.join(dir, "task.md"))
      absolute = File.join(dir, "abs-extra")
      spec = {
        "name" => "scoped-reviewer",
        "permissions" => {
          "preset" => "scoped",
          "tools" => %w[Read Grep],
          "dirs" => [ "./notes", absolute ]
        }
      }

      scope = Hive::Stages::Review.shared_reviewer_permission_scope(
        { "claude" => { "mode" => "tmux" } }, ctx, task, spec
      )

      assert_equal [ ctx.task_folder, File.join(ctx.task_folder, "notes"), absolute ],
                   scope.fetch(:add_dirs),
                   "scoped dirs must EXTEND [ctx.task_folder], not replace it"
      assert_equal %w[Read Grep], scope.fetch(:allowed_tools)
      assert_equal "dontAsk", scope.fetch(:permission_mode)
    end
  end
end
