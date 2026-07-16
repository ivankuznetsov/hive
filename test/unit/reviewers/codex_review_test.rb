require "test_helper"
require "hive/reviewers"
require "hive/agent_profiles"

class ReviewersCodexReviewTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-codex", __dir__)

  FakeDecision = Struct.new(
    :profile, :provider, :model, :lease, :rejections,
    :explanation, :reason, :wait_reason, :waiting,
    keyword_init: true
  ) do
    def wait? = waiting == true
  end

  class FakeRouter
    attr_accessor :check
    attr_reader :cancelled, :outcomes, :lease_store

    def initialize
      @check = Struct.new(:valid, :reason).new(true, "closed")
      @cancelled = []
      @outcomes = []
      @lease_store = Object.new
      @lease_store.define_singleton_method(:with_heartbeat) { |_lease, &block| block.call }
    end

    def dispatch_valid?(_decision) = check
    def cancel(decision) = cancelled << decision
    def record_outcome(**kwargs) = outcomes << kwargs
  end

  def setup
    @prev_bin = ENV["HIVE_CODEX_BIN"]
    ENV["HIVE_CODEX_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CODEX_BIN"] = @prev_bin
    %w[HIVE_FAKE_CODEX_STDOUT HIVE_FAKE_CODEX_EXIT HIVE_FAKE_CODEX_ARGV_LOG
       HIVE_FAKE_CODEX_HANG HIVE_FAKE_CODEX_VERSION HIVE_FAKE_CODEX_BIG_MIB].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "6-review", "test"),
      default_branch: "main",
      pass: 1
    )
  end

  def make_spec(overrides = {})
    {
      "name" => "codex-native-review",
      "kind" => "codex_review",
      "agent" => "codex",
      "output_basename" => "codex-native-review",
      "prompt_template" => "reviewer_codex_native_review.md.erb",
      "timeout_sec" => 5
    }.merge(overrides)
  end

  def build_reviewer(dir, overrides = {})
    ctx = make_ctx(dir)
    FileUtils.mkdir_p(ctx.task_folder)
    Hive::Reviewers::CodexReview.new(make_spec(overrides), ctx)
  end

  # --- argv construction -------------------------------------------------

  def test_builds_codex_review_argv_with_title_and_prompt
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      raw = File.read(log)
      # Leading positional args are logged one-per-line; the trailing
      # prompt arg is multi-line, so assert against the raw log.
      args = raw.lines.grep(/^arg=/).map { |l| l.sub(/^arg=/, "").chomp }
      assert_equal "review", args[0], "first codex arg must be the review subcommand"
      title_idx = args.index("--title")
      refute_nil title_idx, "argv must carry --title"
      assert_includes args[title_idx + 1], "pass 1", "title carries the pass number"
      # codex rejects --base alongside a custom prompt, so we never pass --base.
      refute_includes args, "--base", "must NOT pass --base (mutually exclusive with custom prompt)"
      assert_includes raw, "git diff main...HEAD",
                      "prompt must scope the review to the base-branch diff"
      assert_includes raw, "## High", "prompt must coerce the GFM findings format"
    end
  end

  def test_runs_codex_in_worktree_cwd
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir)

      reviewer.run!

      cwd_line = File.readlines(log).grep(/^cwd=/).first.to_s.chomp.sub(/^cwd=/, "")
      assert_equal File.realpath(dir), File.realpath(cwd_line),
                   "codex review must run with cwd = the worktree path"
    end
  end

  # --- stdout -> findings file ------------------------------------------

  def test_captures_stdout_into_findings_file
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?
      assert_equal reviewer.output_path, result.output_path
      assert File.exist?(reviewer.output_path), "findings file must be written"
      body = File.read(reviewer.output_path)
      assert body.start_with?("## High"), "banner noise must be trimmed to the first severity header"
      assert_includes body, "uses subtraction instead of addition"
      assert_includes body, "## Nit"
      refute_includes body, "OpenAI Codex", "codex banner must not leak into the findings file"
    end
  end

  def test_accepts_output_with_only_some_severity_headers
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "## Medium\n- [ ] thing: reason\n"
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "a single severity header is enough to count as valid findings"
      assert_equal "## Medium\n- [ ] thing: reason\n", File.read(reviewer.output_path)
    end
  end

  def test_trims_banner_and_trailing_blanks_to_exact_findings_body
    with_tmp_dir do |dir|
      # Banner before the first header, plus trailing blank lines after the
      # findings. review_body must drop the banner, rstrip the trailing
      # blanks, and append exactly one newline.
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "OpenAI Codex v0.139.0\nsome banner\n## High\n- [ ] x: y\n\n\n"
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      assert_equal "## High\n- [ ] x: y\n", File.read(reviewer.output_path),
                   "banner trimmed to first header and exactly one trailing newline"
    end
  end

  # `codex review` streams its whole session: the findings block, then a long
  # exec/tool transcript, then its final message. The transcript must be
  # dropped so triage isn't handed hundreds of KB (which has timed it out);
  # the leading block and codex's final verdict are kept.
  def test_drops_session_transcript_keeping_head_and_final_message
    with_tmp_dir do |dir|
      flood = (1..400).map { |i| "  cat'd SKILL.md / git diff line #{i}" }.join("\n")
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        OpenAI Codex v0.139.0
        ## High
        - [ ] uses subtraction instead of addition: breaks add()

        ## Medium
        No findings.

        ## Nit
        No findings.
        exec
        /usr/bin/bash -lc "cat SKILL.md && git diff origin/main...HEAD" in /worktree
         succeeded in 12ms:
        #{flood}
        exec
        /usr/bin/bash -lc "bundle exec ruby -Itest test/foo_test.rb" in /worktree
         succeeded in 3458ms:
        13 runs, 46 assertions, 0 failures, 0 errors, 0 skips
        codex
        The diff is clean. No correctness, security, or data-loss regressions were identified.
      OUT
      raw_bytes = ENV["HIVE_FAKE_CODEX_STDOUT"].bytesize
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      body = File.read(reviewer.output_path)
      assert_includes body, "## High", "the severity-header block must survive (valid_findings? + format)"
      assert_includes body, "The diff is clean. No correctness", "codex's final verdict must be surfaced"
      refute_includes body, "succeeded in", "the exec/tool transcript must be dropped"
      refute_includes body, "bundle exec ruby", "transcript commands must be dropped"
      refute_includes body, "git diff line 200", "the hundreds of transcript lines must be dropped"
      assert_operator body.bytesize, :<, raw_bytes / 4,
                      "published findings must be a fraction of the raw transcript"
    end
  end

  def test_drops_transcript_with_no_trailing_codex_reply_keeps_head
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] real bug: explain it
        ## Medium
        No findings.
        ## Nit
        No findings.
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        some transcript diff output here
        more transcript lines
      OUT
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      body = File.read(reviewer.output_path)
      assert_includes body, "- [ ] real bug: explain it", "the head findings block must survive"
      refute_includes body, "succeeded in", "transcript dropped even with no trailing codex reply"
      refute_includes body, "some transcript diff output", "transcript dropped"
    end
  end

  # --- FIX 1: full pipe drain (no write() deadlock past the retain cap) ---

  def test_oversized_output_drains_without_deadlock_and_yields_valid_findings
    with_tmp_dir do |dir|
      # Emit valid headers up front, then ~6 MiB of filler — past the 4 MiB
      # MAX_OUTPUT_BYTES retain cap. If the reader stopped at the cap the
      # child would block on write() forever and the run would only end via
      # the wall-clock timeout. A generous-but-finite timeout proves the run
      # completes promptly because the pipe is fully drained.
      ENV["HIVE_FAKE_CODEX_BIG_MIB"] = "6"
      reviewer = build_reviewer(dir, "timeout_sec" => 60, "max_attempts" => 1)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = reviewer.run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert result.ok?,
             "oversized output must still produce valid findings, got #{result.status} (#{result.error_message})"
      assert elapsed < 30,
             "run must finish promptly (drained pipe), not hang to timeout; took #{elapsed.round(1)}s"
      body = File.read(reviewer.output_path)
      assert body.start_with?("## High"), "retained findings must start at the first severity header"
      assert_includes body, "big: overflow case"
      assert_operator File.size(reviewer.output_path), :<=, Hive::Reviewers::CodexReview::MAX_OUTPUT_BYTES,
                      "retained output must not exceed the cap"
    end
  end

  # --- malformed / empty stdout -> error, no findings file --------------

  def test_malformed_stdout_yields_error_and_no_findings_file
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "OpenAI Codex v0.139.0\nReview was interrupted.\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?, "missing High/Medium/Nit headers must fail the reviewer"
      assert_match(/missing High\/Medium\/Nit/, result.error_message)
      refute File.exist?(reviewer.output_path),
             "a malformed findings file must not be left behind for triage"
    end
  end

  def test_empty_stdout_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = ""
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      refute File.exist?(reviewer.output_path)
    end
  end

  def test_nonzero_exit_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_EXIT"] = "1"
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "ERROR: You've hit your usage limit.\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/exited with status=1/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  # Observability: a failed codex run must carry its captured stdout/stderr tail
  # into the error message (→ reviews/errors-NN.md) so an `all_failed` is
  # diagnosable instead of an opaque "exited status=1".
  def test_failure_message_captures_codex_output_tail
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_EXIT"] = "1"
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "panic: codex internal assertion failed at frobnicate.rs:42\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/exited with status=1/, result.error_message)
      assert_includes result.error_message, "codex output (last",
                      "the captured codex transcript tail must be surfaced"
      assert_includes result.error_message, "frobnicate.rs:42",
                      "the actual codex error text must reach errors-NN.md"
    end
  end

  # Because the failed output now reaches the error message, a codex usage-limit
  # that exits non-zero becomes detectable by AgentLimit — which lets the review
  # phase route it to the cooldown (limits_reached) path instead of all_failed.
  def test_usage_limit_in_failed_output_is_detectable
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_EXIT"] = "1"
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "stream error: You've hit your usage limit. Try again later.\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert Hive::AgentLimit.limit_reached?(result.error_message),
             "a codex usage-limit failure must be limit-detectable via the captured tail"
    end
  end

  # codex sometimes echoes the prompt's own example block (with the literal
  # `<finding>: <one-line justification>` placeholders) instead of reviewing.
  # It has the severity headers but is hollow — reject it as a failure so it
  # retries, rather than recording a fake clean pass.
  def test_template_echo_is_rejected_as_failure
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~ECHO
        ## High
        - [ ] <finding>: <one-line justification>

        ## Medium
        - [ ] <finding>: <one-line justification>

        ## Nit
        - [ ] <finding>: <one-line justification>
      ECHO
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?, "an echoed prompt template must not count as a clean review"
      assert_match(/echoed the prompt template/, result.error_message)
      refute File.exist?(reviewer.output_path),
             "a hollow template echo must not be left as a findings file"
    end
  end

  # The flip side: a genuine clean review (`No findings.` under each header)
  # must still pass — the echo guard must not over-reject real output.
  def test_legitimate_no_findings_review_is_accepted
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "## High\nNo findings.\n## Medium\nNo findings.\n## Nit\nNo findings.\n"
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "a real 'No findings.' review must be accepted, got: #{result.error_message}"
      assert File.exist?(reviewer.output_path)
    end
  end

  # The real all_failed regression: codex echoes the prompt (carrying the
  # template's ## headers AND the <finding> placeholder) at the top of its
  # session, runs a real review, then gives a PROSE "no regressions" verdict
  # in its final message. The echoed placeholder must NOT fail the pass — the
  # decision must read codex's real answer, not the prompt-echoed transcript.
  def test_clean_prose_verdict_after_prompt_echo_is_accepted_as_clean
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        OpenAI Codex v0.139.0
        ## High
        - [ ] <finding>: <one-line justification>

        ## Medium
        - [ ] <finding>: <one-line justification>

        ## Nit
        - [ ] <finding>: <one-line justification>
        thinking
        Let me inspect the branch diff.
        exec
        /usr/bin/bash -lc "git diff main...HEAD" in /worktree
         succeeded in 12ms:
        some diff output
        codex
        No plan was found. I did not find a correctness, security, or maintainability regression in the diff.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?,
             "a real clean review whose transcript echoes the prompt must pass, got: #{result.error_message}"
      body = File.read(reviewer.output_path)
      assert_includes body, "## High", "a clean pass must publish the canonical headers"
      assert_includes body, "No findings.", "a clean pass must record No findings."
      refute_includes body, "<finding>",
                       "the echoed prompt placeholder must never reach the findings file"
      refute_includes body, "succeeded in", "the tool transcript must be dropped"
    end
  end

  # codex echoes the prompt placeholder, then its FINAL message carries REAL
  # findings. The published file must keep the real findings and drop both the
  # echoed placeholder and the transcript.
  def test_real_findings_in_final_message_survive_a_prompt_echo
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        diff output
        codex
        ## High
        - [ ] off-by-one in paginate(): drops the last row
        ## Medium
        No findings.
        ## Nit
        No findings.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?,
             "real findings in codex's final message must be accepted, got: #{result.error_message}"
      body = File.read(reviewer.output_path)
      assert_includes body, "off-by-one in paginate()", "codex's real finding must be published"
      refute_includes body, "<finding>", "the echoed placeholder must not reach the file"
      refute_includes body, "succeeded in", "the transcript must be dropped"
    end
  end

  # The real patrol all_failed regression: codex-cli ignores the prompt's GFM
  # coercion and emits its NATIVE `codex review` format — a "No plan was found"
  # preamble and `[P1]/[P2]` priority bullets instead of `## High/Medium/Nit`
  # checkboxes. That real finding must be normalized and published, not rejected
  # as "missing headers" (which deterministically fails every retry).
  def test_native_priority_findings_are_normalized_to_gfm
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        OpenAI Codex v0.141.0
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        exec
        /usr/bin/bash -lc "git diff main...HEAD" in /worktree
         succeeded in 12ms:
        some diff output
        codex
        No plan was found; the diff still leaves a config-driven signature-verification path.

        Review comment:

        - [P1] Block config-driven signature checks — bin/hive-babysitter-stub-git:169-169
          When local git config enables signature verification the passthrough honors repo-local gpg.program.
        - [P2] Tighten the read-only allowlist — bin/hive-babysitter-stub-git:200
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?,
             "codex's native [Pn] findings must be normalized, not failed, got: #{result.error_message}"
      body = File.read(reviewer.output_path)
      assert body.start_with?("## High"), "normalized output must lead with the High header"
      assert_includes body, "- [ ] Block config-driven signature checks — bin/hive-babysitter-stub-git:169-169",
                      "the P1 finding must become a High checkbox"
      assert_includes body, "honors repo-local gpg.program",
                      "the finding's indented justification must fold onto its line"
      assert_includes body, "## Medium\n- [ ] Tighten the read-only allowlist",
                      "the P2 finding must become a Medium checkbox"
      assert_includes body, "## Nit\nNo findings.", "an empty severity still prints its header"
      refute_includes body, "[P1]", "the native priority tag must be stripped"
      refute_includes body, "No plan was found", "the codex preamble must not leak into findings"
      refute_includes body, "<finding>", "the echoed prompt placeholder must not reach the file"
      refute_includes body, "succeeded in", "the tool transcript must be dropped"
    end
  end

  # codex sometimes echoes the same native finding twice; the normalized output
  # must carry it once so triage doesn't see a phantom duplicate.
  def test_native_findings_are_deduplicated
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        codex
        - [P1] Duplicate finding — a.rb:1
        - [P1] Duplicate finding — a.rb:1
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      body = File.read(reviewer.output_path)
      assert_equal 1, body.scan("- [ ] Duplicate finding").size,
                   "a repeated native finding must be published once"
    end
  end

  # A finding codex describes in PROSE (no checkbox) must NOT be laundered into a
  # clean pass — the :clean branch requires an affirmative no-findings verdict.
  def test_prose_finding_without_checkbox_is_not_a_clean_pass
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        diff output
        codex
        I found an off-by-one bug in paginate() that drops the last row; this should be fixed before merge.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?,
             "a finding codex described in prose (no checkbox) must NOT be recorded as a clean pass"
      refute File.exist?(reviewer.output_path),
             "no clean findings file may be written when codex flagged a problem in prose"
    end
  end

  # An exit-0 soft-error / abort verdict ("couldn't complete the review") must
  # not be laundered into a clean pass either.
  def test_soft_error_final_message_is_not_a_clean_pass
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        diff output
        codex
        Stream error: connection reset. I was unable to complete the review.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?,
             "an exit-0 soft-error verdict must not be recorded as a clean pass"
      refute File.exist?(reviewer.output_path)
    end
  end

  # codex concluded in pure prose (no severity headers anywhere): an affirmative
  # no-findings verdict must still pass as a clean review.
  def test_header_less_clean_prose_verdict_is_accepted_as_clean
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        OpenAI Codex v0.139.0
        thinking
        Reviewing the diff.
        exec
        /usr/bin/bash -lc "git diff main...HEAD" in /worktree
         succeeded in 8ms:
        diff output
        codex
        I reviewed the branch diff and found no correctness, security, or maintainability regressions.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?,
             "an affirmative no-findings prose verdict must pass, got: #{result.error_message}"
      assert_includes File.read(reviewer.output_path), "No findings."
    end
  end

  # codex emits several `codex`-marked turns; only the FINAL verdict drives the
  # result (an intermediate planning note must be discarded).
  def test_multiple_codex_markers_use_only_the_final_verdict
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        ## High
        - [ ] <finding>: <one-line justification>
        ## Medium
        - [ ] <finding>: <one-line justification>
        ## Nit
        - [ ] <finding>: <one-line justification>
        thinking
        Planning the review.
        codex
        Let me start by checking the tests.
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        diff output
        codex
        I did not find any regressions in the diff.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?, "the final codex verdict must drive the result, got: #{result.error_message}"
      body = File.read(reviewer.output_path)
      assert_includes body, "No findings."
      refute_includes body, "Let me start by checking",
                       "an intermediate codex note must not be treated as the verdict"
    end
  end

  # A clean pass preserves codex's verdict as an inert one-line HTML comment,
  # with angle brackets stripped so it can't break the comment or re-introduce a
  # `<finding>` placeholder.
  def test_clean_pass_preserves_codex_verdict_as_an_inert_comment
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = <<~OUT
        thinking
        Reviewing.
        exec
        /usr/bin/bash -lc "git diff" in /worktree
         succeeded in 5ms:
        diff output
        codex
        No findings; the <diff> looks clean and I found no regressions.
      OUT
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.ok?
      body = File.read(reviewer.output_path)
      assert_includes body, "<!-- codex review summary:",
                       "codex's verdict must be preserved as an audit comment"
      refute_includes body, "<diff>",
                       "angle brackets must be stripped so the verdict can't break the comment"
    end
  end

  def test_missing_binary_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_CODEX_BIN"] = File.join(dir, "does-not-exist-codex")
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/preflight failed|not runnable/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  # --- retry / multi-attempt message ------------------------------------

  def test_retries_then_succeeds_and_appends_no_attempt_suffix_on_success
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      # Patch backoff to avoid real sleeps.
      def reviewer.backoff(_seconds) = nil

      result = reviewer.run!

      assert result.ok?
    end
  end

  def test_error_message_includes_attempt_count_when_retry_enabled
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers here\n"
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      # Real backoff path, but zero-duration so sleep(0) returns instantly.
      def reviewer.backoff_seconds_for(_attempt) = 0

      result = reviewer.run!

      assert result.error?
      assert_match(/after 2 attempt\(s\)/, result.error_message)
    end
  end

  def test_retry_with_future_deadline_clamps_backoff_then_retries
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers here\n"
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      def reviewer.backoff_seconds_for(_attempt) = 0

      # A far-future deadline leaves ample budget, so the loop takes the
      # clamp branch (`[backoff, remaining].min`) and still retries.
      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.error?
      assert_match(/after 2 attempt\(s\)/, result.error_message)
    end
  end

  def test_invalid_max_attempts_falls_back_to_default_with_warning
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir, "max_attempts" => "two")
      def reviewer.backoff(_seconds) = nil

      out, err = capture_subprocess_io do
        @result = reviewer.run!
      end
      _ = out

      assert @result.ok?
      assert_match(/invalid max_attempts/, err)
    end
  end

  # --- deadline handling -------------------------------------------------

  def test_deadline_already_passed_yields_error_without_spawning
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      result = reviewer.run!(deadline: past)

      assert result.error?
      assert_match(/deadline reached/, result.error_message)
      refute File.exist?(log), "no codex spawn when the deadline is already in the past"
    end
  end

  def test_future_deadline_allows_spawn
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)

      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.ok?
    end
  end

  def test_deadline_exhausted_between_failed_attempts_stops_retry
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers\n"
      reviewer = build_reviewer(dir, "max_attempts" => 3)
      # deadline_remaining is consulted twice per attempt: once by
      # effective_timeout (needs a positive budget so the spawn proceeds),
      # then once in the retry backoff check. Feed a large value first, then
      # a non-positive one so the loop breaks on `remaining <= 0` rather than
      # exhausting all 3 attempts.
      slack = [ 9999.0, 0.0 ]
      reviewer.define_singleton_method(:deadline_remaining) do |_deadline|
        slack.shift || -1
      end
      def reviewer.backoff(_seconds) = nil

      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.error?
      # Broke after the first failed attempt (not all 3).
      assert_match(/after 1 attempt\(s\)/, result.error_message)
    end
  end

  # --- timeout -----------------------------------------------------------

  def test_timeout_kills_the_subprocess_and_errors
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_HANG"] = "30"
      reviewer = build_reviewer(dir, "timeout_sec" => 1, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/timed out after 1s/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  def test_terminate_escalates_to_kill_when_term_is_ignored
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Child traps (ignores) TERM and sleeps. TERM alone won't reap it, so
      # terminate must escalate to KILL after the grace and then reap it.
      pid = Process.spawn("trap '' TERM; sleep 30", pgroup: true)
      # Let the shell install the trap before we signal.
      sleep 0.2

      # terminate must not raise even though TERM is ignored.
      reviewer.send(:terminate, pid)
      # The process group must be gone after KILL escalation + reap.
      refute reviewer.send(:process_group_alive?, Process.getpgid(pid)),
             "process group must be torn down by the KILL escalation"
    rescue Errno::ESRCH
      # getpgid after reap can race to ESRCH — that itself proves the group
      # is gone, which is the assertion's intent.
      assert true
    end
  end

  def test_process_group_alive_true_for_running_group
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      pid = Process.spawn("sleep 30", pgroup: true)
      begin
        assert reviewer.send(:process_group_alive?, Process.getpgid(pid)),
               "a running group must report alive"
      ensure
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
    end
  end

  def test_process_group_alive_false_for_dead_group
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Spawn a child in its own group, capture its pgid, then reap it. The
      # group no longer exists, so the liveness probe (Process.kill(0, ...))
      # raises ESRCH and the probe reports false.
      pid = Process.spawn("true", pgroup: true)
      pgid = Process.getpgid(pid)
      Process.wait(pid)

      refute reviewer.send(:process_group_alive?, pgid),
             "a reaped group must report not-alive"
    end
  end

  def test_process_group_alive_treats_eperm_as_alive
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # A group we can see but not signal (EPERM) must be treated as alive so
      # the guarded KILL attempt still fires. Temporarily make Process.kill
      # raise EPERM to simulate the unsignalable-but-present case.
      original = Process.method(:kill)
      Process.singleton_class.send(:define_method, :kill) { |*| raise Errno::EPERM }
      begin
        assert reviewer.send(:process_group_alive?, 12_345),
               "EPERM (exists but unsignalable) must be treated as alive"
      ensure
        Process.singleton_class.send(:define_method, :kill, original)
      end
    end
  end

  def test_terminate_is_quiet_when_process_already_gone
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Spawn a trivial child, reap it, then ask terminate to act on the
      # now-dead pid. Both the kill (ESRCH) and the reap (ECHILD) must be
      # swallowed without raising.
      pid = Process.spawn("true", pgroup: true)
      Process.wait(pid)

      assert_nil reviewer.send(:terminate, pid),
                 "terminate must be a no-op for an already-reaped pid"
      assert_nil reviewer.send(:reap, pid),
                 "reap must swallow ECHILD for an already-reaped pid"
    end
  end

  # --- version gate ------------------------------------------------------

  def test_below_min_version_yields_preflight_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_VERSION"] = "0.1.0"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/preflight failed/, result.error_message)
    end
  end

  # --- prompt rendering --------------------------------------------------

  def test_prompt_template_renders_base_branch_and_format_contract
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      File.write(
        File.join(reviewer.ctx.task_folder, "plan.md"),
        "# Plan\n\n## Goals\n- G1. Keep add() additive.\n"
      )
      prompt = reviewer.send(:render_prompt)

      assert_includes prompt, "git diff main...HEAD"
      assert_includes prompt, "## High"
      assert_includes prompt, "## Medium"
      assert_includes prompt, "## Nit"
      assert_includes prompt, "No findings."
      assert_match(/Plan context \(authoritative on scope\)/, prompt,
                   "native-review template must embed the plan-context section")
      assert_includes prompt, "G1. Keep add() additive.",
                      "plan.md content must be inlined into the prompt"
    end
  end

  def test_prompt_template_falls_back_to_absent_note_when_plan_missing
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      prompt = reviewer.send(:render_prompt)

      assert_match(/no plan\.md found/, prompt)
    end
  end

  def test_delete_output_reraises_on_non_enoent_system_call_error
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Point output_path at a directory; File.delete raises EISDIR/EPERM
      # (a non-ENOENT SystemCallError) which must surface as a named
      # Hive::Error rather than being swallowed like a missing file.
      a_dir = File.join(dir, "a-directory")
      FileUtils.mkdir_p(a_dir)
      reviewer.define_singleton_method(:output_path) { a_dir }

      err = assert_raises(Hive::Error) { reviewer.send(:delete_output!) }
      assert_match(/failed to clear partial output_path/, err.message)
    end
  end

  # --- dispatch ----------------------------------------------------------

  def test_dispatch_selects_codex_review_for_codex_review_kind
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      adapter = Hive::Reviewers.dispatch(make_spec, ctx)
      assert_instance_of Hive::Reviewers::CodexReview, adapter
    end
  end

  def test_dispatch_defaults_to_agent_when_kind_absent
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      spec = make_spec.tap { |s| s.delete("kind") }.merge("skill" => "ce-code-review")
      adapter = Hive::Reviewers.dispatch(spec, ctx)
      assert_instance_of Hive::Reviewers::Agent, adapter
    end
  end

  def test_dispatch_rejects_unknown_kind
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      err = assert_raises(Hive::Reviewers::UnknownKindError) do
        Hive::Reviewers.dispatch(make_spec("kind" => "bogus"), ctx)
      end
      assert_match(/codex_review/, err.message)
    end
  end

  # --- A8 permission-scope gate -----------------------------------------

  # A8 verified VIA codex_review.rb (the plan requires it via both adapters):
  # a non-yolo `permissions:` on a codex_review reviewer can never be honored
  # (`codex review` is read-only and takes no tool-list args), so run! must
  # raise Hive::ConfigError BEFORE any spawn — not silently run codex review
  # with the scope discarded. The standard `agent: codex` entry trips
  # PermissionScope's runner gate (codex can't enforce scoping).
  def test_non_yolo_permissions_raises_before_spawn_for_codex_agent
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir, "permissions" => "read-only")

      assert_raises(Hive::ConfigError) { reviewer.run! }

      refute File.exist?(log), "the A8 gate must raise before any codex spawn"
      refute File.exist?(reviewer.output_path), "no findings file may be written when the gate raises"
    end
  end

  # A8 bypass guard: a `kind: codex_review, agent: claude` entry resolves
  # cleanly through the claude profile (claude CAN scope), so the runner gate
  # alone would NOT fire and the declared scope would be silently discarded.
  # The adapter must still fail closed — `codex review` ignores the profile
  # class and never enforces scoping — so any non-yolo effective scope raises
  # regardless of the configured agent.
  def test_non_yolo_permissions_raises_even_with_claude_agent
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir, "agent" => "claude", "permissions" => "read-only")

      error = assert_raises(Hive::ConfigError) { reviewer.run! }
      assert_match(/codex review/, error.message)
      assert_match(/cannot enforce tool scoping/, error.message)

      refute File.exist?(log), "no codex spawn may occur when the scope is non-yolo"
      refute File.exist?(reviewer.output_path)
    end
  end

  # Control: an explicit `permissions: yolo` passes the gate and runs normally
  # — the gate rejects ONLY non-yolo scopes, so the happy path is unaffected.
  def test_explicit_yolo_permissions_passes_the_gate
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir, "permissions" => "yolo")

      result = reviewer.run!

      assert result.ok?, "explicit yolo must pass the A8 gate and run normally"
    end
  end

  def test_provider_failure_reselects_native_review_on_fallback_account
    with_tmp_dir do |dir|
      accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "codex-main" => { "adapter" => "codex" },
          "codex-backup" => { "adapter" => "codex" }
        },
        source: "codex reviewer test"
      )
      routing = {
        "pool" => [
          { "provider" => "codex-main", "agent" => "codex" },
          { "provider" => "codex-backup", "agent" => "codex" }
        ]
      }
      cfg = Hive::Config.merge_defaults({})
      cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = accounts
      counter = File.join(dir, "codex-review-count")
      codex_bin = File.join(dir, "routed-codex")
      File.write(codex_bin, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.139.0\n'; exit 0; fi
        if [ ! -f #{counter} ]; then
          : > #{counter}
          printf '%s\n' "You've hit your usage limit. Try again later."
          exit 1
        fi
        printf '## High\nNo findings.\n'
      SH
      File.chmod(0o755, codex_bin)
      cfg.fetch("agents").fetch("codex")["bin"] = codex_bin
      circuits = Hive::ProviderRouting::Store.new(path: File.join(dir, "circuits.json"))
      router = Hive::ProviderRouting::Router.new(
        circuit_store: circuits,
        lease_store: Hive::AttemptLeaseStore.new(path: File.join(dir, "leases.json"))
      )
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      build = lambda do
        Hive::Reviewers::CodexReview.new(
          make_spec("routing" => routing, "max_attempts" => 1),
          ctx,
          cfg: cfg
        )
      end

      with_env("HIVE_CODEX_BIN" => codex_bin) do
        with_replaced_singleton_method(Hive::Stages::Base, :provider_router, -> { router }) do
          first = build.call.run!

          assert first.error?
          assert_equal "codex-main", first.provider
          assert first.provider_signal.circuit_worthy?
          assert_equal "open", circuits.state("codex-main").fetch("state")

          second = build.call.run!

          assert second.ok?
          assert_equal "codex-backup", second.provider
        end
      end
    end
  end

  def test_routing_wait_and_non_codex_fallback_return_errors_without_native_spawn
    with_tmp_dir do |dir|
      router = FakeRouter.new
      codex = Hive::AgentProfiles.lookup(:codex)
      waiting = FakeDecision.new(
        profile: codex, provider: "codex", rejections: [],
        explanation: "provider open", reason: "circuit_open",
        wait_reason: "limits_reached", waiting: true
      )
      reviewer = build_reviewer(dir)
      result = run_with_routing(reviewer, router, waiting)
      assert result.error?
      assert_includes result.error_message, "provider open"

      claude = Hive::AgentProfiles.lookup(:claude)
      fallback = FakeDecision.new(
        profile: claude, provider: "claude", rejections: [], waiting: false
      )
      result = run_with_routing(build_reviewer(dir), router, fallback)
      assert result.error?
      assert_includes result.error_message, "cannot run the native `codex review`"
      assert_includes router.cancelled, fallback
    end
  end

  def test_invalid_final_route_and_native_spawn_exception_are_recorded
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      decision = FakeDecision.new(
        profile: profile, provider: "codex", model: nil,
        lease: Object.new, rejections: [], waiting: false
      )
      router = FakeRouter.new
      router.check = Struct.new(:valid, :reason).new(false, "probe lost")
      result = run_with_routing(build_reviewer(dir), router, decision)
      assert result.error?
      assert_includes result.error_message, "probe lost"
      assert_includes router.cancelled, decision

      router = FakeRouter.new
      reviewer = build_reviewer(dir)
      reviewer.define_singleton_method(:run_codex_review) do |*_args|
        raise "native spawn failed"
      end
      error = assert_raises(RuntimeError) do
        run_with_routing(reviewer, router, decision)
      end
      assert_includes error.message, "native spawn failed"
      assert_equal false, router.outcomes.last.fetch(:success)
    end
  end

  def test_unexpected_preflight_failure_cancels_the_route
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      profile = Hive::AgentProfiles.lookup(:codex)
      reviewer.define_singleton_method(:enforce_permission_scope_gate!) do |_profile|
        raise "preflight exploded"
      end
      decision = FakeDecision.new(
        profile: profile, provider: "codex", lease: Object.new,
        rejections: [], waiting: false
      )
      router = FakeRouter.new

      assert_raises(RuntimeError) do
        reviewer.send(:codex_preflight, profile, decision, router)
      end
      assert_includes router.cancelled, decision
    end
  end

  private

  def run_with_routing(reviewer, router, decision)
    with_replaced_singleton_method(Hive::Stages::Base, :provider_router, -> { router }) do
      with_replaced_singleton_method(
        Hive::Stages::Base, :route_attempt, ->(*_args, **_kwargs) { decision }
      ) do
        return reviewer.run!
      end
    end
  end
end
