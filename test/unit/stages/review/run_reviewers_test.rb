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

  class StagedRaisingReviewer < Hive::Reviewers::Base
    def failure_output_path
      "#{output_path}.partial"
    end

    def run!(deadline: nil)
      ensure_reviews_dir!
      File.write(failure_output_path, "incomplete replacement\n")
      raise RuntimeError, "staged boom"
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

  # Shared test helper: stub Hive::Reviewers.dispatch to return adapters
  # keyed by spec["name"] (or, when names collide / are absent, by FIFO
  # order). Indexing-by-name is robust against the orchestrator
  # processing specs in non-input order.
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

  # A mixed roster (two Claude reviewers, one Codex reviewer) runs every
  # reviewer as its own headless spawn through the real Agent adapter: three
  # spawn_agent calls in roster order, and no reviewer shares a session.
  def test_mixed_roster_runs_claude_reviewers_as_independent_headless_spawns
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent",
              "agent" => "claude", "skill" => "ce-code-review",
              "prompt_template" => "reviewer_claude_ce_code_review.md.erb" },
            { "name" => "codex-a", "output_basename" => "codex-a", "kind" => "agent",
              "agent" => "codex", "skill" => "ce-code-review",
              "prompt_template" => "reviewer_codex_ce_code_review.md.erb" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent",
              "agent" => "claude", "skill" => "ce-code-review",
              "prompt_template" => "reviewer_claude_ce_code_review.md.erb" }
          ]
        }
      }
      ctx = make_ctx(dir)
      spawns = []
      spawn = lambda do |_task, **kwargs|
        spawns << kwargs
        File.write(kwargs.fetch(:expected_output), "## Low\n\n- [ ] ok\n")
        { status: :ok }
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))
      end

      assert_equal :ok, result
      assert_equal %i[claude codex claude], spawns.map { |kwargs| kwargs.fetch(:profile).name }
      assert_equal 3, spawns.map { |kwargs| kwargs.fetch(:expected_output) }.uniq.length
      spawns.each { |kwargs| assert_equal :output_file_exists, kwargs.fetch(:status_mode) }
      %w[claude-a codex-a claude-b].each do |name|
        assert File.exist?(File.join(dir, "reviews", "#{name}-01.md")), "#{name} must publish its findings"
      end
    end
  end

  def test_mixed_roster_reviewers_share_the_same_deadline_counter
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "claude-a", "output_basename" => "claude-a", "kind" => "agent", "agent" => "claude" },
            { "name" => "codex-a", "output_basename" => "codex-a", "kind" => "agent", "agent" => "codex" },
            { "name" => "claude-b", "output_basename" => "claude-b", "kind" => "agent", "agent" => "claude" }
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
            max_wall_clock_sec: 120
          )
          assert_equal :ok, result
        end
      end

      # With no wall time elapsed in the fake clock every reviewer sees the
      # full 120s budget; its own timeout_sec is the real per-reviewer cap.
      adapters.each { |adapter| assert_in_delta 120, adapter.deadline_seconds, 0.001 }
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

  # A partial failure records which failed reviewers were NOT provider
  # limits, so the pass can be marked limits_reached only when every failure
  # was a quota wall.
  def test_partial_failure_separates_limit_failures_from_other_failures
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "ok", "output_basename" => "ok" },
            { "name" => "quota", "output_basename" => "quota" },
            { "name" => "quoted", "output_basename" => "quoted" }
          ]
        }
      }
      specs = cfg["review"]["reviewers"]
      adapters = [
        OkReviewer.new(specs[0], make_ctx(dir)),
        LimitErroringReviewer.new(specs[1], make_ctx(dir)),
        QuotedLimitErroringReviewer.new(specs[2], make_ctx(dir))
      ]
      limit_texts = []
      nonlimit_failures = []

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(
          cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")),
          limit_texts: limit_texts, nonlimit_failures: nonlimit_failures
        )
        assert_equal :ok, result
        assert_equal 1, limit_texts.length
        assert_equal [ "quoted" ], nonlimit_failures
        refute Hive::Stages::Review.provider_limited_partial_failure?(limit_texts, nonlimit_failures)
        assert Hive::Stages::Review.provider_limited_partial_failure?(limit_texts, [])
        refute Hive::Stages::Review.provider_limited_partial_failure?(nil, nil)
      end
    end
  end

  class UnsupportedModelErroringReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(
        name: name, output_path: output_path, status: :error,
        error_message: "reviewer exited 1: The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account."
      )
    end
  end

  def test_all_failed_on_unsupported_model_returns_all_failed_model_unsupported
    with_tmp_dir do |dir|
      cfg = { "review" => { "reviewers" => [ { "name" => "a", "output_basename" => "a" } ] } }
      adapters = cfg["review"]["reviewers"].map { |spec| UnsupportedModelErroringReviewer.new(spec, make_ctx(dir)) }
      unsupported = []
      limit_texts = []

      with_stubbed_dispatch(adapters) do
        result = Hive::Stages::Review.run_reviewers(
          cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")),
          limit_texts: limit_texts, unsupported_texts: unsupported
        )
        assert_equal :all_failed_model_unsupported, result
        assert_empty limit_texts, "a refused model is not a provider limit"
        assert_equal 1, unsupported.length
        assert_match(/'gpt-6-sol' model is not supported/, unsupported.first)
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

  def test_bookkeeping_exhaustion_aborts_reviewers_without_attributing_provider_failure
    with_tmp_dir do |dir|
      specs = [ { "name" => "busy", "output_basename" => "busy" }, { "name" => "ok", "output_basename" => "ok" } ]
      cfg = { "review" => { "reviewers" => specs } }
      ctx = make_ctx(dir)
      error = Hive::Attempts::BookkeepingBusy.new(
        operation: "checkpoint", attempt_id: "attempt-1", retry_count: 3, elapsed_sec: 30, budget_sec: 30
      )
      busy = RaisingReviewer.new(specs.first, ctx)
      busy.define_singleton_method(:run!) { |deadline: nil| raise error }
      with_stubbed_dispatch([ busy, OkReviewer.new(specs.last, ctx) ]) do
        assert_same error, assert_raises(Hive::Attempts::BookkeepingBusy) {
          Hive::Stages::Review.run_reviewers(cfg, ctx, Task.new(dir, File.join(dir, "task.md")))
        }
      end
      refute File.exist?(File.join(dir, "reviews", "ok-01.md"))
      refute File.exist?(File.join(dir, "reviews", "errors-01.md"))
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

  def test_raising_staged_reviewer_preserves_prior_successful_output
    with_tmp_dir do |dir|
      spec = { "name" => "staged", "output_basename" => "staged" }
      adapter = StagedRaisingReviewer.new(spec, make_ctx(dir))
      FileUtils.mkdir_p(File.dirname(adapter.output_path))
      prior = "## High\n- [ ] retained finding: prior successful review\n"
      File.write(adapter.output_path, prior)

      with_stubbed_dispatch([ adapter ]) do
        result = Hive::Stages::Review.run_reviewers(
          { "review" => { "reviewers" => [ spec ] } },
          make_ctx(dir),
          Task.new(dir, File.join(dir, "task.md"))
        )
        assert_equal :all_failed, result
      end

      assert_equal prior, File.read(adapter.output_path)
      refute File.exist?(adapter.failure_output_path),
             "orchestrator cleanup must remove only the staged failure output"
      assert_includes File.read(File.join(dir, "reviews", "errors-01.md")), "staged boom"
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

      with_replaced_singleton_method(
        Hive::Stages::Review::GithubPublisher,
        :validated_pr_url,
        ->(_task, _cfg) { "https://example.com/pr/77" }
      ) do
        with_stubbed_dispatch(adapters) do
          Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        end
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

  def test_fix_success_head_reads_binding_and_fails_closed_on_io_error
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      head = "a" * 40
      File.write(
        File.join(reviews, "fix-success-04.md"),
        "<!-- HIVE: fix-success sentinel; head=#{head} -->\n"
      )

      assert_equal head, Hive::Stages::Review.fix_success_head(dir, 4)
      with_replaced_singleton_method(File, :open, ->(*) { raise IOError, "unreadable" }) do
        assert_nil Hive::Stages::Review.fix_success_head(dir, 4)
      end
    end
  end

  def test_fix_success_kind_reads_binding_and_fails_closed_on_io_error
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      sentinel = File.join(reviews, "fix-success-04.md")
      File.write(sentinel, "<!-- HIVE: fix-success sentinel; head=#{'a' * 40} kind=fixed -->\n")

      assert_equal "fixed", Hive::Stages::Review.fix_success_kind(dir, 4)
      with_replaced_singleton_method(File, :open, ->(*) { raise IOError, "unreadable" }) do
        assert_nil Hive::Stages::Review.fix_success_kind(dir, 4)
      end
      File.write(sentinel, "<!-- HIVE: fix-success sentinel; head=#{'a' * 40} -->\n")
      assert_nil Hive::Stages::Review.fix_success_kind(dir, 4), "legacy sentinels carry no kind"
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

  def test_max_review_pass_admits_passes_opened_by_repair_and_approval_receipts
    # max_passes=2: pass 03 is the verify pass. Each repair or approval
    # receipt admits exactly one more pass, so 04 and 05 are legitimate;
    # 06 has no admitting receipt and still fails loudly.
    [ %w[ci_repaired ci_repaired], %w[approved approved], %w[ci_repaired approved] ].each do |kinds|
      with_tmp_dir do |dir|
        reviews = File.join(dir, "reviews")
        FileUtils.mkdir_p(reviews)
        File.write(File.join(reviews, "fix-success-03.md"), "<!-- HIVE: head=#{'a' * 40} kind=#{kinds[0]} -->\n")
        File.write(File.join(reviews, "fix-success-04.md"), "<!-- HIVE: head=#{'b' * 40} kind=#{kinds[1]} -->\n")
        File.write(File.join(reviews, "claude-05.md"), "## High\n")
        cfg = { "review" => { "max_passes" => 2 } }

        assert_equal 5, Hive::Stages::Review.admitted_pass_ceiling(dir, 2)
        assert_equal 5, Hive::Stages::Review.max_review_pass(dir, cfg)

        File.write(File.join(reviews, "claude-06.md"), "## High\n")
        err = assert_raises(Hive::ConfigError) { Hive::Stages::Review.max_review_pass(dir, cfg) }
        assert_match(/claude-06\.md/, err.message)
      end
    end
  end

  def test_max_review_pass_rejects_pass_without_an_admitting_ci_repair
    # A verify pass that completed clean (or a forged out-of-range file)
    # admits nothing further: max_passes + 2 is out of range.
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "fix-success-03.md"), "<!-- HIVE: head=#{'a' * 40} kind=clean -->\n")
      File.write(File.join(reviews, "claude-04.md"), "## High\n")

      err = assert_raises(Hive::ConfigError) do
        Hive::Stages::Review.max_review_pass(dir, { "review" => { "max_passes" => 2 } })
      end
      assert_match(/NN=4 exceeds review\.max_passes=2/, err.message)
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

  def test_retired_lockfile_findings_resume_without_waiving_other_findings
    with_tmp_dir do |dir|
      ctx = make_ctx(dir).with(pass: 4)
      lockfile = "- [ ] dependency_lockfile_change: Gemfile.lock:?: Gemfile.lock\n"
      write_guardrail_file(dir, pass: 4, body: lockfile * 2)
      assert Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 2)
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 3)
      cfg = { "review" => { "fix" => { "guardrail" => { "patterns_override" => {
        "dependency_lockfile_change" => { "regex" => "Gemfile.lock", "targets" => "file_path" }
      } } } } }
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 2, cfg: cfg)
      write_guardrail_file(dir, pass: 4, body: lockfile + "- [ ] dotenv_edit: .env\n")
      refute Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 2)
    end
  end

  def test_exact_guardrail_waiver_emits_a_visible_fingerprint_event
    Dir.mktmpdir("hive-review-waiver-event") do |dir|
      task = Struct.new(:folder, :slug).new(dir, "review-task")
      match = Hive::Stages::Review::FixGuardrail::Match.new(
        pattern_name: "secrets_pattern_match.password_assignment",
        file: "config/example.rb", line: 1, snippet: "[REDACTED]",
        severity: :high, match_sha256: "a" * 64
      )

      Hive::Stages::Review.emit_guardrail_waivers(task, 2, [ match ])

      event = JSON.parse(File.readlines(File.join(dir, "events.jsonl")).last)
      assert_equal "round_complete", event.fetch("event_type")
      assert_equal 2, event.dig("data", "pass")
      assert_equal(
        {
          "pattern" => "secrets_pattern_match.password_assignment",
          "sha256" => "a" * 64
        },
        event.dig("data", "guardrail_waivers", 0)
      )
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

  def test_fix_guardrail_report_escapes_control_bytes_in_decoded_paths
    # Patrol rework follow-up to the C-quoted rename decode: decode_git_path
    # hands write_fix_guardrail_findings paths with LITERAL control bytes,
    # and the report interpolated them unescaped. A rename target like
    # ".github/workflows/de\n- [x] ploy.yml" then split one checkbox line
    # into three, two of them PRE-CHECKED — a forged approval fragment the
    # user never ticked — while the marker recorded one match, so
    # fix_guardrail_approved?(expected_matches: 1) stayed false and the
    # task could never be approved. The report boundary must escape control
    # bytes so one Match renders as exactly one unchecked checkbox line.
    with_tmp_git_repo do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs"))
      File.write(File.join(dir, "docs", "template.yml"), "name: template\n")
      run!("git", "-C", dir, "add", "docs/template.yml")
      run!("git", "-C", dir, "commit", "-m", "add template", "--quiet")
      base = `git -C #{dir} rev-parse HEAD`.strip

      forged = ".github/workflows/de\n- [x] ploy.yml"
      FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
      run!("git", "-C", dir, "mv", "docs/template.yml", forged)
      run!("git", "-C", dir, "commit", "-m", "rename into workflows", "--quiet")
      head = `git -C #{dir} rev-parse HEAD`.strip

      ctx = make_ctx(dir).with(pass: 1)
      guardrail = Hive::Stages::Review::FixGuardrail.run!(
        cfg: { "review" => { "fix" => { "guardrail" => { "enabled" => true } } } },
        ctx: ctx, base_sha: base, head_sha: head
      )
      assert_equal :tripped, guardrail.status
      assert_equal 1, guardrail.matches.size

      Hive::Stages::Review.send(:write_fix_guardrail_findings, ctx, guardrail.matches)
      report = File.join(dir, "reviews", "fix-guardrail-01.md")
      body = File.read(report)

      checkbox_lines = body.each_line.count { |l| l.match?(/^\s*-\s+\[[ xX]\]\s+/) }
      assert_equal 1, checkbox_lines,
                   "one match must render as exactly one checkbox line (got #{checkbox_lines})"
      assert_equal 0, body.each_line.count { |l| l.match?(/^\s*-\s+\[[xX]\]\s+/) },
                    "no checkbox may render pre-checked: the forged fragment must be escaped"
      assert_includes body, 'de\\n- [x] ploy.yml',
                      "the control bytes must be escaped at the report boundary"

      # Full approval round-trip: the user ticks the single intended row,
      # and the count-vs-marker gate accepts it (pre-fix this deadlocked
      # at false because the forged boxes inflated the count).
      File.write(report, body.sub("- [ ] ci_workflow_edit", "- [x] ci_workflow_edit"))
      assert Hive::Stages::Review.fix_guardrail_approved?(ctx, expected_matches: 1),
             "ticking the single escaped row must satisfy the approval round-trip"
    end
  end

  def test_fix_guardrail_report_escapes_control_bytes_in_snippets
    # Same boundary, code-target side: a matched snippet (e.g. a
    # multi-line secret hit) carrying a newline must not split its
    # checkbox line either, or the marker count and the checkbox count
    # drift and approval deadlocks.
    Dir.mktmpdir("hive-guardrail-escape") do |dir|
      ctx = make_ctx(dir).with(pass: 2)
      match = Hive::Stages::Review::FixGuardrail::Match.new(
        pattern_name: "secrets_pattern_match.generic_key",
        file: "config/settings.rb", line: 3,
        snippet: "KEY = \"abc\n- [x] def\"",
        severity: :high, match_sha256: "a" * 64
      )

      Hive::Stages::Review.send(:write_fix_guardrail_findings, ctx, [ match ])
      body = File.read(File.join(dir, "reviews", "fix-guardrail-02.md"))

      assert_equal 1, body.each_line.count { |l| l.match?(/^\s*-\s+\[[ xX]\]\s+/) },
                   "a newline-bearing snippet must still render one checkbox line"
      assert_includes body, 'abc\\n- [x] def',
                      "the snippet's control bytes must be escaped"
      assert_equal 0, body.each_line.count { |l| l.match?(/^\s*-\s+\[[xX]\]\s+/) },
                   "no forged pre-checked box may appear"
    end
  end

  def test_escape_control_bytes_renders_every_control_byte_visibly
    escaped = Hive::Stages::Review.send(
      :escape_control_bytes,
      "\n\t\r\f\v\e\b\a\0\x01"
    )

    assert_equal "\\n\\t\\r\\f\\v\\e\\b\\a\\0\\x01", escaped
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

  class ProviderRouteFailureReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      raise Hive::ProviderRouteFailed, "admitted provider route failed"
    end
  end

  def test_provider_route_failure_terminates_reviewer_phase
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "failed-route", "output_basename" => "failed-route" },
            { "name" => "must-not-run", "output_basename" => "must-not-run" }
          ]
        }
      }
      ctx = make_ctx(dir)
      adapters = [
        ProviderRouteFailureReviewer.new(cfg.dig("review", "reviewers", 0), ctx),
        OkReviewer.new(cfg.dig("review", "reviewers", 1), ctx)
      ]

      with_stubbed_dispatch(adapters) do
        assert_raises(Hive::ProviderRouteFailed) do
          Hive::Stages::Review.run_reviewers(
            cfg, ctx, Task.new(dir, File.join(dir, "task.md"))
          )
        end
      end

      refute File.exist?(File.join(dir, "reviews", "must-not-run-01.md"))
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

      with_replaced_singleton_method(
        Hive::Stages::Review::GithubPublisher,
        :validated_pr_url,
        ->(_task, _cfg) { "https://example.com/pr/77" }
      ) do
        with_stubbed_dispatch(adapters) do
          Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")))
        end
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

  # A cooled retry of a provider-limited pass reuses an output the pass
  # already produced (receipt digest still matches) and dispatches only the
  # reviewer that has no reusable output.
  def test_reuse_skips_dispatch_for_matching_output_and_reruns_the_rest
    with_tmp_dir do |dir|
      cfg = {
        "review" => {
          "reviewers" => [
            { "name" => "kept", "output_basename" => "kept" },
            { "name" => "limited", "output_basename" => "limited" }
          ]
        }
      }
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      kept_path = File.join(dir, "reviews", "kept-01.md")
      File.write(kept_path, "## Low\n\n- [ ] produced before the limit\n")
      reuse = { "kept" => Digest::SHA256.file(kept_path).hexdigest }
      dispatched = []
      limited = LimitErroringReviewer.new(cfg["review"]["reviewers"][1], ctx)
      succeeded = []

      orig = Hive::Reviewers.method(:dispatch)
      Hive::Reviewers.define_singleton_method(:dispatch) do |spec, _ctx, **_kwargs|
        dispatched << spec["name"]
        limited
      end
      begin
        result = nil
        _out, err = capture_io do
          result = Hive::Stages::Review.run_reviewers(
            cfg, ctx, Task.new(dir, File.join(dir, "task.md")),
            reuse: reuse, succeeded: succeeded
          )
        end
        assert_equal :ok, result, "a reused output keeps the phase from reading as all-failed"
        assert_equal [ "limited" ], dispatched, "only the reviewer without a reusable output re-runs"
        assert_equal [ "kept" ], succeeded
        assert_match(/reusing reviewer "kept" pass 01/, err)
        assert_equal "## Low\n\n- [ ] produced before the limit\n", File.read(kept_path)
      ensure
        Hive::Reviewers.define_singleton_method(:dispatch, orig)
      end
    end
  end

  def test_reuse_reruns_a_reviewer_whose_output_changed_since_the_receipt
    with_tmp_dir do |dir|
      cfg = { "review" => { "reviewers" => [ { "name" => "ok", "output_basename" => "ok" } ] } }
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "ok-01.md"), "triage edited this\n")
      succeeded = []

      with_stubbed_dispatch([ OkReviewer.new(cfg["review"]["reviewers"][0], ctx) ]) do
        result = Hive::Stages::Review.run_reviewers(
          cfg, ctx, Task.new(dir, File.join(dir, "task.md")),
          reuse: { "ok" => "0" * 64 }, succeeded: succeeded
        )
        assert_equal :ok, result
      end
      assert_equal [ "ok" ], succeeded
      assert_equal "## Low\n\n- [ ] looks fine\n", File.read(File.join(dir, "reviews", "ok-01.md")),
                   "a digest mismatch must re-run the reviewer, not reuse the edited file"
    end
  end

  def test_ae6_shadowed_review_complete_and_manual_steering_hold_and_strict_internal_pointer
    require "hive/task"
    require "hive/internal_pr_checkout"
    require "hive/stages/base"
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-42")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      state_file = File.join(folder, "task.md")
      # Embedded/shadowed REVIEW_COMPLETE + trailing REVIEW_WAITING + operator prose + frontmatter
      prose = <<~MD
        ---
        source: ad-hoc
        ---

        Operator guidance note: keep checking edge cases.

        <!-- REVIEW_COMPLETE pass=1 -->

        More operator notes.

        <!-- REVIEW_WAITING pass=2 -->
      MD
      File.write(state_file, prose)
      assert_equal :review_waiting, Hive::Markers.current(state_file).name

      removed = Hive::Markers.remove_named_markers(
        state_file, Hive::Markers::REVIEW_MARKER_NAMES, refuse_if_current: [ :manual_steering ]
      )
      assert_equal :removed, removed
      assert_equal :none, Hive::Markers.current(state_file).name,
                   "embedded/shadowed REVIEW_COMPLETE must not resurface as current"
      body_after = File.read(state_file)
      assert_includes body_after, "Operator guidance note: keep checking edge cases."
      assert_includes body_after, "More operator notes."
      refute_includes body_after, "REVIEW_COMPLETE"
      refute_includes body_after, "REVIEW_WAITING"

      # Active MANUAL_STEERING hold: marker removal refuses and Review.run! stops before budget/agents.
      Hive::Markers.set(state_file, :manual_steering)
      steering_bytes = File.binread(state_file)
      assert_equal :refused, Hive::Markers.remove_named_markers(
        state_file, Hive::Markers::REVIEW_MARKER_NAMES, refuse_if_current: [ :manual_steering ]
      )
      assert_equal steering_bytes, File.binread(state_file)

      task = Hive::Task.new(folder)
      with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { flunk "agent must not run under MANUAL_STEERING" }) do
        result = nil
        _out, err = capture_io { result = Hive::Stages::Review.run!(task, { "review" => {} }) }
        assert_equal({ commit: nil, status: :manual_steering }, result)
        assert_match(/MANUAL_STEERING/, err)
      end

      # Strict worktree pointer accepts proven hive/review/pr-42 for internal PR review
      # while normal tasks keep the slug-branch default.
      head_oid = "a" * 40
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 42
        pr_url: https://github.com/acme/app/pull/42
        head_oid: #{head_oid}
        base_ref_name: main
        head_ref_name: feat
        head_repository: acme/app
        is_cross_repository: false
        pr_state: OPEN
        ---
      MD
      store = Hive::InternalPrCheckout::Store.new(folder)
      store.initialize_generation_one!(
        task_id: "0042", task_slug: "adhoc-review-pr-42", project: File.basename(root),
        pr_host: "github.com", pr_repository: "acme/app", pr_number: 42,
        pr_url: "https://github.com/acme/app/pull/42", base_ref_name: "main",
        head_ref_name: "feat", head_repository: "acme/app", is_cross_repository: false,
        pr_state: "OPEN", branch: "hive/review/pr-42", head_oid: head_oid,
        committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
      )
      id = Hive::InternalPrCheckout::Identity.resolve!(task)
      observed_kwargs = nil
      with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(_folder, **kwargs) do
          observed_kwargs = kwargs
          { "path" => id.expected_worktree_path, "branch" => "hive/review/pr-42" }
        end
      ) do
        ptr = Hive::Stages::Base.worktree_pointer_or_exit(task)
        assert_equal "hive/review/pr-42", ptr["branch"]
        assert_equal "hive/review/pr-42", observed_kwargs[:expected_branch]
        assert_equal id.expected_worktree_path, observed_kwargs[:expected_path]
      end

      normal_folder = File.join(root, ".hive-state", "stages", "6-review", "normal-task-260829-abcd")
      FileUtils.mkdir_p(normal_folder)
      File.write(File.join(normal_folder, "task.md"), "# Normal\n")
      normal_task = Hive::Task.new(normal_folder)
      normal_kwargs = nil
      with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(_folder, **kwargs) do
          normal_kwargs = kwargs
          { "path" => File.join(root, "wt"), "branch" => normal_task.slug }
        end
      ) do
        ptr = Hive::Stages::Base.worktree_pointer_or_exit(normal_task)
        assert_equal normal_task.slug, ptr["branch"]
        assert_nil normal_kwargs[:expected_branch]
      end
    end
  end

  def test_ae7_retired_generation_artifacts_do_not_influence_active_pass_while_remaining_auditable
    require "hive/task"
    require "hive/stages/review/pass_archive"
    require "hive/stages/review/triage"
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-42")
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(folder, "task.md"), "---\nsource: ad-hoc\n---\n# PR 42\n")

      # Seed every head-bound artifact from generation 1.
      seeded = {
        "reviews/claude-01.md" => "## High\n- [ ] old finding\n",
        "reviews/codex-02.md" => "## High\n- [ ] old pass 2 finding\n",
        "reviews/escalations-02.md" => "### Q1. Old waiting question?\n",
        "reviews/suppressed.md" => "- old suppression\n",
        "reviews/auto-commit-scope-02.json" => '{"files":["a.rb"]}',
        "reviews/fix-success-02.json" => '{"commit":"' + ("a" * 40) + '"}',
        "reviews/guardrail-02.md" => "old guardrail\n",
        "reviews/ci-blocked.md" => "old ci failure\n",
        "reviews/browser-result-02-01.json" => '{"status":"failed"}',
        "reviews/validation-02.json" => '{"ok":true}',
        "github-publication.json" => '{"pr_url":"https://github.com/acme/app/pull/42"}'
      }
      seeded.each do |rel, content|
        full = File.join(folder, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end

      label = "internal-pr-reopen-bbbbbbbbbbbb-tx0001"
      rel_dest = Hive::Stages::Review::PassArchive.retire!(
        Hive::Task.new(folder),
        label: label,
        expiry_reason: "internal_pr_head_changed",
        receipt: { "transaction_id" => "tx0001", "target_oid" => "b" * 40 },
        exact_label: true
      )
      dest = File.join(folder, rel_dest)
      # Archive remaining non-pass head-bound receipts (mirroring U2 reconciler).
      Dir.children(reviews).each do |name|
        next if name == "archive"
        FileUtils.mv(File.join(reviews, name), File.join(dest, name))
      end
      FileUtils.mv(File.join(folder, "github-publication.json"), File.join(dest, "github-publication.json"))

      # Active pass selection and flat globs see a completely fresh generation 2.
      assert_equal 2, Hive::Stages::Review::PassArchive.generation(folder)
      assert_equal 1, Hive::Stages::Review.next_pass_for(Hive::Task.new(folder), Hive::Markers::State.new(name: :none, attrs: {}, raw: nil))
      ctx = Hive::Reviewers::Context.new(
        worktree_path: root, task_folder: folder, default_branch: "main", pass: 1
      )
      assert_empty Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
      refute File.exist?(File.join(folder, "github-publication.json"))
      refute File.exist?(File.join(reviews, "suppressed.md"))
      refute File.exist?(File.join(reviews, "ci-blocked.md"))

      # Archived generation remains intact and readable for audit.
      assert_equal "## High\n- [ ] old finding\n", File.read(File.join(dest, "claude-01.md"))
      assert_equal "### Q1. Old waiting question?\n", File.read(File.join(dest, "escalations-02.md"))
      assert_equal '{"pr_url":"https://github.com/acme/app/pull/42"}', File.read(File.join(dest, "github-publication.json"))
    end
  end

  def test_reviewer_agent_spawn_custody_blocks_failing_first_attempt_before_retry
    require "hive/internal_pr_checkout"
    require "hive/review_budget"
    require "hive/reviewers/agent"

    %i[new_file edit_sealed symlink].each do |tamper|
      with_tmp_dir do |root|
        folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-56")
        arch = File.join(folder, "reviews", "archive", "gen-01")
        FileUtils.mkdir_p(arch)
        File.write(File.join(folder, "task.md"), "---\nsource: ad-hoc\n---\n# PR 56\n")
        File.write(File.join(folder, "pr.md"), <<~MD)
          ---
          source: ad-hoc
          pr_number: 56
          pr_url: https://github.com/acme/app/pull/56
          head_oid: #{"a" * 40}
          ---
        MD
        sealed = File.join(arch, "claude-01.md")
        File.write(sealed, "sealed gen 1\n")
        store = Hive::InternalPrCheckout::Store.new(folder)
        store.initialize_generation_one!(
          task_id: "0056", task_slug: "adhoc-review-pr-56", project: File.basename(root),
          pr_host: "github.com", pr_repository: "acme/app", pr_number: 56,
          pr_url: "https://github.com/acme/app/pull/56", base_ref_name: "main",
          head_ref_name: "feat", head_repository: "acme/app", is_cross_repository: false,
          pr_state: "OPEN", branch: "hive/review/pr-56", head_oid: "a" * 40,
          committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
        )
        store.seal_retirement!(label: "gen-01")
        store.sync_current_history_root_digest!

        ctx = Hive::Reviewers::Context.new(
          worktree_path: root, task_folder: folder, default_branch: "main", pass: 1
        )
        spec = {
          "name" => "claude-review", "agent" => "claude", "output_basename" => "claude-review",
          "skill" => "ce:code-review",
          "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
          "timeout_sec" => 5, "max_attempts" => 2
        }
        adapter = Hive::Reviewers::Agent.new(spec, ctx)
        spawn_calls = 0

        err = assert_raises(Hive::ReviewBudget::Refused) do
          adapter.send(:run_with_spawn, deadline: nil) do |_profile, _prompt, _cfg_t, _spawn_t, _attempts|
            spawn_calls += 1
            case tamper
            when :new_file then File.write(File.join(arch, "injected.md"), "bad")
            when :edit_sealed then File.write(sealed, "mutated")
            when :symlink then File.symlink("/etc/hosts", File.join(arch, "evil-link.md"))
            end
            { status: :error, error_message: "attempt 1 failed" }
          end
        end
        assert_includes %w[unsafe_state agent_modified_budget], err.reason, tamper.to_s
        assert_equal 1, spawn_calls, "custody must abort failing attempt 1 before attempt 2 (#{tamper})"
      end
    end

    # Clean control succeeds normally.
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-57")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      File.write(File.join(folder, "task.md"), "---\nsource: ad-hoc\n---\n# PR 57\n")
      ctx = Hive::Reviewers::Context.new(
        worktree_path: root, task_folder: folder, default_branch: "main", pass: 1
      )
      spec = {
        "name" => "claude-review", "agent" => "claude", "output_basename" => "claude-review",
        "skill" => "ce:code-review",
        "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
        "timeout_sec" => 5, "max_attempts" => 2
      }
      adapter = Hive::Reviewers::Agent.new(spec, ctx)
      staged = adapter.send(:staged_output_path)
      result = adapter.send(:run_with_spawn, deadline: nil) do |_profile, _prompt, _cfg_t, _spawn_t, _attempts|
        File.write(staged, "## Low\n- [ ] clean\n")
        { status: :ok }
      end
      assert_equal :ok, result.status
      assert File.file?(adapter.output_path)
    end
  end
end
