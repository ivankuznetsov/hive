require "test_helper"
require "hive/gh"

# Unit-level contracts for Hive::Gh. Indirect coverage exists in
# run_open_pr_test, run_finalize_test, and github_publisher_test, but
# this file pins down the lower-level invariants (timeout, frontmatter
# parsing, scan_pr_for_secrets fetch-failure semantics) so a regression
# in those primitives surfaces here rather than as a cascading failure
# in a larger integration test.
class GhUnitTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_path = ENV["PATH"]
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH_FIXTURE, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    @log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = @log_dir
  end

  def teardown
    ENV["PATH"] = @prev_path
    FileUtils.rm_rf(@gh_dir)
    FileUtils.rm_rf(@log_dir)
    %w[
        HIVE_FAKE_GH_LOG_DIR
        HIVE_FAKE_GH_PR_BODY
        HIVE_FAKE_GH_VIEW_EXIT
        HIVE_FAKE_GH_LIST_JSON
      ].each { |k| ENV.delete(k) }
  end

  # --- with_network_timeout --------------------------------------------

  def test_with_network_timeout_raises_typed_error_on_timeout
    err = assert_raises(Hive::GhError) do
      Hive::Gh.with_network_timeout do
        Timeout.timeout(0.01) { sleep 0.5 }
      end
    end
    assert_match(/network operation exceeded/, err.message)
  end

  # --- pr_frontmatter ---------------------------------------------------

  def test_pr_frontmatter_returns_empty_for_missing_file
    assert_equal({}, Hive::Gh.pr_frontmatter("/nonexistent/path/pr.md"))
  end

  def test_pr_frontmatter_returns_empty_for_no_frontmatter
    with_tmp_dir do |dir|
      path = File.join(dir, "pr.md")
      File.write(path, "no frontmatter here\n")
      assert_equal({}, Hive::Gh.pr_frontmatter(path))
    end
  end

  def test_pr_frontmatter_parses_well_formed_yaml
    with_tmp_dir do |dir|
      path = File.join(dir, "pr.md")
      File.write(path, "---\npr_url: https://example.com/pr/1\npr_number: 1\n---\n\nbody\n")
      parsed = Hive::Gh.pr_frontmatter(path)
      assert_equal "https://example.com/pr/1", parsed["pr_url"]
      assert_equal 1, parsed["pr_number"]
    end
  end

  def test_pr_frontmatter_warns_on_malformed_yaml
    with_tmp_dir do |dir|
      path = File.join(dir, "pr.md")
      File.write(path, "---\npr_url: [unclosed\n---\n\nbody\n")
      _out, err = capture_io { assert_equal({}, Hive::Gh.pr_frontmatter(path)) }
      assert_match(/frontmatter unparseable/, err)
    end
  end

  # --- scan_pr_for_secrets ---------------------------------------------

  def test_scan_pr_for_secrets_clean_when_state_file_clean_and_no_url
    with_tmp_dir do |dir|
      state = File.join(dir, "pr.md")
      File.write(state, "no secrets here\n")
      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "")
      assert result.clean?
      refute result.fetch_failed
    end
  end

  def test_scan_pr_for_secrets_detects_secret_in_state_file
    with_tmp_dir do |dir|
      state = File.join(dir, "pr.md")
      File.write(state, "key: sk-ant-#{'a' * 30}\n")
      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "")
      refute result.clean?
      assert_includes result.hits.map { |h| h[:name].to_s }, "anthropic_api_key"
    end
  end

  def test_scan_pr_for_secrets_fetch_failed_when_gh_pr_view_errors
    # H5 regression guard: a remote fetch failure must surface as
    # fetch_failed=true, NOT silently degrade to "no hits found".
    with_tmp_dir do |dir|
      state = File.join(dir, "pr.md")
      File.write(state, "clean local body\n")
      ENV["HIVE_FAKE_GH_VIEW_EXIT"] = "1"

      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "https://example.com/pr/42")
      assert result.fetch_failed, "gh pr view non-zero must set fetch_failed=true"
      refute_empty result.fetch_error.to_s, "fetch_error must preserve the gh failure detail"
      refute result.clean?, "fetch_failed must NOT be reported as clean"
    end
  end

  def test_scan_pr_for_secrets_preserves_local_hits_on_fetch_failure
    with_tmp_dir do |dir|
      state = File.join(dir, "pr.md")
      File.write(state, "key: sk-ant-#{'a' * 30}\n")
      ENV["HIVE_FAKE_GH_VIEW_EXIT"] = "1"

      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "https://example.com/pr/42")
      assert result.fetch_failed
      assert_includes result.hits.map { |h| h[:name].to_s }, "anthropic_api_key"
    end
  end

  def test_scan_pr_for_secrets_includes_remote_body
    with_tmp_dir do |dir|
      state = File.join(dir, "pr.md")
      File.write(state, "clean local body\n")
      ENV["HIVE_FAKE_GH_PR_BODY"] = "remote body containing sk-ant-#{'a' * 30}"

      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "https://example.com/pr/42")
      refute result.fetch_failed
      assert_includes result.hits.map { |h| h[:name].to_s }, "anthropic_api_key",
                      "remote body must be scanned"
    end
  end

  # --- lookup_existing_pr fail-loud on remote unavailable --------------

  def test_lookup_existing_pr_hard_fails_on_gh_pr_list_error
    # Plan R5 regression guard: a network failure during gh pr list
    # must hard-fail (exit 1) so the caller cannot misinterpret a
    # transient error as "no PR exists" and open a second one.
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_LIST_EXIT"] = "1"
      err = assert_raises(Hive::GhError) do
        Hive::Gh.lookup_existing_pr(dir, "feat-x-260424-aaaa")
      end
      assert_match(/gh pr list.*failed/, err.message)
    ensure
      ENV.delete("HIVE_FAKE_GH_LIST_EXIT")
    end
  end

  def test_lookup_existing_pr_rejects_non_array_json
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_LIST_JSON"] = '{"error":"wrapped"}'
      err = assert_raises(Hive::GhError) do
        Hive::Gh.lookup_existing_pr(dir, "feat-x-260424-aaaa")
      end
      assert_match(/expected Array/, err.message)
    ensure
      ENV.delete("HIVE_FAKE_GH_LIST_JSON")
    end
  end

  def test_lookup_existing_pr_skips_closed_and_merged
    # Plan correctness: even when a CLOSED/MERGED PR exists for the
    # branch, lookup_existing_pr returns nil so the caller does not
    # propagate a stale URL into pr.md.
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
      ENV["HIVE_FAKE_GH_PR_STATE"] = "CLOSED"
      assert_nil Hive::Gh.lookup_existing_pr(dir, "feat-x-260424-aaaa"),
                 "CLOSED PR must not be returned"
    ensure
      ENV.delete("HIVE_FAKE_GH_PR_EXISTS")
      ENV.delete("HIVE_FAKE_GH_PR_STATE")
    end
  end

  # --- push_branch returns PushResult, push_branch! hard-fails ---------

  def test_push_branch_returns_push_result_on_failure
    with_tmp_git_repo do |dir|
      # no `origin` remote configured -> push fails -> PushResult.success? == false
      result = Hive::Gh.push_branch(dir, "no-such-branch")
      assert_kind_of Hive::Gh::PushResult, result
      refute result.success?
    end
  end

  def test_push_branch_bang_exits_one_on_failure
    with_tmp_git_repo do |dir|
      err = assert_raises(Hive::GhError) { Hive::Gh.push_branch!(dir, "no-such-branch") }
      assert_match(/git push failed/, err.message)
    end
  end
def test_command_status_success_predicate
  assert Hive::Gh::CommandStatus.new(exitstatus: 0).success?
  refute Hive::Gh::CommandStatus.new(exitstatus: 1).success?
end

def test_push_branch_returns_failure_when_capture_raises_gh_error
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { raise Hive::GhError, "network down" }) do
    result = Hive::Gh.push_branch("/tmp/worktree", "feature")
    refute result.success?
    assert_equal "network down", result.stderr
  end
end

def test_lookup_existing_pr_rejects_unparseable_json
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "not-json", "", status ] }) do
    err = assert_raises(Hive::GhError) do
      Hive::Gh.lookup_existing_pr("/tmp/worktree", "feat-x-260424-aaaa")
    end
    assert_match(/unparseable JSON/, err.message)
  end
end

def test_scan_pr_for_secrets_reports_fetch_failed_when_capture_raises
  with_tmp_dir do |dir|
    state = File.join(dir, "pr.md")
    File.write(state, "key: sk-ant-#{'a' * 30}\n")

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { raise Hive::GhError, "api unavailable" }) do
      result = Hive::Gh.scan_pr_for_secrets(state_file: state, pr_url: "https://example.com/pr/42")
      assert result.fetch_failed
      assert_equal "api unavailable", result.fetch_error
      assert_includes result.hits.map { |hit| hit[:name].to_s }, "anthropic_api_key"
    end
  end
end

def test_capture3_wraps_spawn_errors_and_ignores_close_errors
  io_pairs = [ [ FakeCloseIO.new, FakeCloseIO.new ], [ FakeCloseIO.new, FakeCloseIO.new ] ]

  with_replaced_singleton_method(IO, :pipe, -> { io_pairs.shift }) do
    with_replaced_singleton_method(Process, :spawn, ->(*_args, **_kwargs) { raise Errno::ENOENT, "missing gh" }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.capture3("gh", "missing") }
      assert_match(/failed to run gh missing/, err.message)
    end
  end
end

def test_wait_with_deadline_terminates_and_raises_on_timeout
  base = Time.utc(2026, 5, 22, 12, 0, 0)
  times = [ base, base + 2 ]
  terminated = []

  with_replaced_singleton_method(Time, :now, -> { times.shift || base + 2 }) do
    with_replaced_singleton_method(Process, :waitpid2, ->(_pid, _flags) { nil }) do
      with_replaced_singleton_method(Hive::Gh, :terminate_process, ->(pid) { terminated << pid }) do
        err = assert_raises(Hive::GhError) do
          Hive::Gh.wait_with_deadline(1234, 1, [ "gh", "pr", "view" ])
        end
        assert_match(/network operation exceeded 1s/, err.message)
      end
    end
  end

  assert_equal [ 1234 ], terminated
end

def test_terminate_process_returns_when_child_exits_during_grace
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  wait_results = [ nil, [ 1234, status ] ]
  signals = []
  base = Time.utc(2026, 5, 22, 12, 0, 0)
  times = [ base, base ]

  with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
    with_replaced_singleton_method(Time, :now, -> { times.shift || base }) do
      with_replaced_singleton_method(Process, :waitpid2, ->(_pid, _flags = nil) { wait_results.shift }) do
        assert_equal status, Hive::Gh.terminate_process(1234)
      end
    end
  end

  assert_equal [ [ "TERM", 1234 ] ], signals
end

def test_terminate_process_escalates_to_kill_after_grace
  signals = []
  waits = []
  base = Time.utc(2026, 5, 22, 12, 0, 0)
  times = [ base, base + 2 ]

  with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
    with_replaced_singleton_method(Time, :now, -> { times.shift || base + 2 }) do
      with_replaced_singleton_method(Process, :waitpid2, lambda { |pid, flags = nil|
        waits << [ pid, flags ]
        nil
      }) do
        assert_nil Hive::Gh.terminate_process(1234)
      end
    end
  end

  assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signals
  assert_equal [ [ 1234, Process::WNOHANG ], [ 1234, nil ] ], waits
end

def test_terminate_process_ignores_missing_child
  with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
    assert_nil Hive::Gh.terminate_process(1234)
  end
end

private

class FakeCloseIO
  def closed?
    false
  end

  def close
    raise IOError, "already closed"
  end
end
end
