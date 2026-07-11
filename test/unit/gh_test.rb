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

  def test_lookup_prs_for_branch_requests_reconciliation_identity_fields
    captured = nil
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    stub = lambda do |*args, **kwargs|
      captured = [ args, kwargs ]
      [ "[]", "", status ]
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, stub) do
      assert_empty Hive::Gh.lookup_prs_for_branch(
        "/repo", "patrol-fix", repository: "acme/demo",
        host: "github.corp.example", cfg: { "x" => true }
      )
    end

    args, kwargs = captured
    fields = args.fetch(args.index("--json") + 1).split(",")
    assert_includes fields, "body"
    assert_includes fields, "baseRefName"
    assert_includes fields, "headRepository"
    assert_equal "github.corp.example/acme/demo", args.fetch(args.index("--repo") + 1)
    assert_equal "/repo", kwargs.fetch(:chdir)
  end

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
    # propagate a stale URL into normal open-PR downstream handling.
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
      ENV["HIVE_FAKE_GH_PR_STATE"] = "CLOSED"
      assert_nil Hive::Gh.lookup_existing_pr(dir, "feat-x-260424-aaaa"),
                 "CLOSED PR must not be returned"

      ENV["HIVE_FAKE_GH_PR_STATE"] = "MERGED"
      assert_nil Hive::Gh.lookup_existing_pr(dir, "feat-x-260424-aaaa"),
                 "MERGED PR must not be returned by normal open lookup"
    ensure
      ENV.delete("HIVE_FAKE_GH_PR_EXISTS")
      ENV.delete("HIVE_FAKE_GH_PR_STATE")
    end
  end

  def test_lookup_merged_pr_returns_merged_pr
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
      ENV["HIVE_FAKE_GH_PR_STATE"] = "MERGED"

      pr = Hive::Gh.lookup_merged_pr(dir, "feat-x-260424-aaaa")
      assert_equal "MERGED", pr.fetch("state")
      assert_equal "https://example.com/pr/1", pr.fetch("url")
    ensure
      ENV.delete("HIVE_FAKE_GH_PR_EXISTS")
      ENV.delete("HIVE_FAKE_GH_PR_STATE")
    end
  end

  def test_lookup_merged_pr_can_filter_by_head_oid
    with_tmp_git_repo do |dir|
      ENV["HIVE_FAKE_GH_LIST_JSON"] = <<~JSON
        [
          {"url":"https://example.com/pr/old","number":1,"state":"MERGED","isDraft":false,"headRefOid":"old"},
          {"url":"https://example.com/pr/current","number":2,"state":"MERGED","isDraft":false,"headRefOid":"current"}
        ]
      JSON

      pr = Hive::Gh.lookup_merged_pr(dir, "feat-x-260424-aaaa", head_oid: "current")
      assert_equal "https://example.com/pr/current", pr.fetch("url")
      assert_nil Hive::Gh.lookup_merged_pr(dir, "feat-x-260424-aaaa", head_oid: "missing")
    ensure
      ENV.delete("HIVE_FAKE_GH_LIST_JSON")
    end
  end

  def test_pr_metadata_returns_pr_fields
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    responses = [
      [ "", "", status ],
      [
        {
          "number" => 197,
          "url" => "https://github.com/o/r/pull/197",
          "baseRefName" => "main",
          "headRefOid" => "abc123",
          "isCrossRepository" => false,
          "state" => "OPEN"
        }.to_json,
        "",
        status
      ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { responses.shift }) do
      metadata = Hive::Gh.pr_metadata(197)

      assert_equal 197, metadata.number
      assert_equal "https://github.com/o/r/pull/197", metadata.url
      assert_equal "main", metadata.base_ref_name
      assert_equal "abc123", metadata.head_ref_oid
      assert_equal false, metadata.is_cross_repository
      assert_equal "OPEN", metadata.state
    end
  end

  def test_pr_metadata_preserves_cross_repository_flag
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    responses = [
      [ "", "", status ],
      [
        {
          "number" => 198,
          "url" => "https://github.com/o/r/pull/198",
          "baseRefName" => "main",
          "headRefOid" => "def456",
          "isCrossRepository" => true,
          "state" => "OPEN"
        }.to_json,
        "",
        status
      ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { responses.shift }) do
      metadata = Hive::Gh.pr_metadata(198)

      assert_equal true, metadata.is_cross_repository
      assert_equal "def456", metadata.head_ref_oid
    end
  end

  def test_pr_metadata_passes_chdir_to_capture3_so_project_scoping_targets_the_right_repo
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = []
    responses = [
      [ "", "", status ],
      [
        {
          "number" => 197, "url" => "https://github.com/o/r/pull/197",
          "baseRefName" => "main", "headRefOid" => "abc",
          "isCrossRepository" => false, "state" => "OPEN"
        }.to_json,
        "",
        status
      ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured << [ cmd, kwargs ]
      responses.shift
    }) do
      Hive::Gh.pr_metadata(197, chdir: "/tmp/some-project")
    end

    view_call = captured.find { |cmd, _kwargs| cmd.include?("view") }
    refute_nil view_call, "expected a `gh pr view` call"
    assert_equal "/tmp/some-project", view_call.last.fetch(:chdir),
                 "pr_metadata must forward chdir: to capture3 so --project queries the right repo"
  end

  def test_pr_metadata_raises_on_gh_pr_view_failure
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    responses = [
      [ "", "", ok ],
      [ "", "not found", failed ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { responses.shift }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_metadata(404) }

      assert_match(/gh pr view 404.*failed/, err.message)
      assert_match(/not found/, err.message)
    end
  end

  def test_pr_metadata_raises_with_login_hint_when_unauthenticated
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "", "not logged in", failed ] }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_metadata(197) }

      assert_match(/gh auth login/, err.message)
      assert_match(/not logged in/, err.message)
    end
  end

  def test_pr_metadata_raises_on_unparseable_json
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    responses = [
      [ "", "", ok ],
      [ "not-json", "", ok ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { responses.shift }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_metadata(197) }

      assert_match(/unparseable JSON/, err.message)
    end
  end

  def test_pr_metadata_raises_when_json_is_not_a_hash
    # Mirror the pr_stats sibling guard: a well-formed but non-object JSON
    # response (e.g. `[]`) must raise rather than be coerced into a PrMetadata.
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    responses = [
      [ "", "", ok ],
      [ "[]", "", ok ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { responses.shift }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_metadata(197) }

      assert_match(/expected Hash/, err.message)
    end
  end

  def test_pr_state_raises_on_gh_pr_view_failure
    status = Hive::Gh::CommandStatus.new(exitstatus: 1)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "", "auth required", status ] }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_state("https://example.com/pr/42") }
      assert_match(/gh pr view https:\/\/example\.com\/pr\/42.*failed/, err.message)
      assert_match(/auth required/, err.message)
    end
  end

  def test_pr_state_raises_on_unparseable_json
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "not-json", "", status ] }) do
      err = assert_raises(Hive::GhError) { Hive::Gh.pr_state("https://example.com/pr/42") }
      assert_match(/unparseable JSON/, err.message)
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

def test_push_branch_force_passes_force_with_lease
  captured = nil
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    captured = cmd
    [ "", "", ok ]
  }) do
    Hive::Gh.push_branch("/tmp/wt", "feature", force: true)
    assert_includes captured, "--force-with-lease",
                    "force: true must pass --force-with-lease to git push"

    captured = nil
    Hive::Gh.push_branch("/tmp/wt", "feature")
    refute_includes captured, "--force-with-lease",
                    "a default push must not force"
  end
end

def test_push_branch_uses_exact_expected_oid_lease
  captured = nil
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    captured = cmd
    [ "", "", ok ]
  }) do
    Hive::Gh.push_branch(
      "/tmp/wt", "feature", expected_remote_oid: "a" * 40
    )
  end

  assert_includes captured, "--force-with-lease=refs/heads/feature:#{'a' * 40}"
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

def test_list_open_prs_parses_gh_json_array
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  json = '[{"number":42,"headRefName":"feat","labels":[],"updatedAt":"2026-05-26T10:00:00Z"}]'
  captured = nil
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
    captured = [ cmd, kwargs ]
    [ json, "", status ]
  }) do
    prs = Hive::Gh.list_open_prs("/tmp/repo")
    assert_equal 42, prs.first.fetch("number")
  end
  assert_includes captured.first, "list"
  assert_match(/(^|,)mergeStateStatus(,|$)/, captured.first.fetch(captured.first.index("--json") + 1))
  assert_equal "/tmp/repo", captured.last.fetch(:chdir)
end

def test_list_open_prs_raises_on_gh_error
  status = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "boom", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.list_open_prs("/tmp/repo") }
    assert_match(/gh pr list.*failed/, err.message)
  end
end

def test_repo_name_with_owner_parses_repo_view
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  captured = nil
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
    captured = [ cmd, kwargs ]
    [ '{"nameWithOwner":"owner/repo"}', "", status ]
  }) do
    assert_equal "owner/repo", Hive::Gh.repo_name_with_owner("/tmp/repo", cfg: { "cfg" => true })
  end

  assert_equal [ "gh", "repo", "view", "--json", "nameWithOwner" ], captured.first
  assert_equal "/tmp/repo", captured.last.fetch(:chdir)
  assert_equal({ "cfg" => true }, captured.last.fetch(:cfg))
end

def test_repo_name_with_owner_raises_on_gh_error
  status = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "no remote", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.repo_name_with_owner("/tmp/repo") }
    assert_match(/gh repo view.*failed/, err.message)
    assert_match(/no remote/, err.message)
  end
end

def test_repo_name_with_owner_raises_on_unparseable_json
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "not json", "", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.repo_name_with_owner("/tmp/repo") }
    assert_match(/unparseable JSON/, err.message)
  end
end

def test_merged_pr_details_fetches_complete_paginated_file_metadata
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  calls = []
  metadata = {
    "number" => 7, "url" => "https://github.com/acme/demo/pull/7", "state" => "MERGED",
    "baseRefName" => "main", "baseRefOid" => "a" * 40,
    "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-07-10T10:00:00Z",
    "changedFiles" => 2
  }
  pages = [
    [ { "filename" => "lib/a.rb", "status" => "modified" } ],
    [ { "filename" => "lib/b.rb", "status" => "renamed", "previous_filename" => "lib/old.rb" } ]
  ]

  with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(*) { }) do
    with_replaced_singleton_method(Hive::Gh, :repo_name_with_owner, ->(*) { "acme/demo" }) do
      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
        calls << [ cmd, kwargs ]
        body = cmd[1] == "pr" ? JSON.generate(metadata) : JSON.generate(pages)
        [ body, "", status ]
      }) do
        details = Hive::Gh.merged_pr_details("7", worktree_path: "/tmp/demo", cfg: { "x" => true })
        assert_equal 2, details.fetch("files").size
        assert_equal "lib/old.rb", details.fetch("files").last.fetch("previous_path")
      end
    end
  end

  api = calls.find { |cmd, _| cmd[1] == "api" }
  assert_includes api.first, "--paginate"
  assert_includes api.first, "--slurp"
  assert_equal "/tmp/demo", calls.first.last.fetch(:chdir)
end

def test_merged_pr_details_rejects_url_from_another_repository_before_file_fetch
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  metadata = {
    "number" => 7, "url" => "https://github.com/other/repo/pull/7", "state" => "MERGED",
    "baseRefName" => "main", "baseRefOid" => "a" * 40,
    "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-07-10T10:00:00Z",
    "changedFiles" => 1
  }
  calls = []

  with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(*) { }) do
    with_replaced_singleton_method(Hive::Gh, :repo_name_with_owner, ->(*) { "acme/demo" }) do
      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
        calls << cmd
        [ JSON.generate(metadata), "", status ]
      }) do
        assert_raises(Hive::GhError) do
          Hive::Gh.merged_pr_details("https://github.com/other/repo/pull/7", worktree_path: "/tmp/demo")
        end
      end
    end
  end

  assert_equal 1, calls.size, "repository mismatch must fail before fetching local-repository file pages"
end

def test_merged_prs_page_exposes_graphql_cursor_and_complete_merge_identity
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  captured = nil
  response = {
    "data" => {
      "search" => {
        "issueCount" => 1,
        "nodes" => [
          {
            "number" => 7,
            "url" => "https://github.com/acme/demo/pull/7",
            "mergedAt" => "2026-07-10T10:00:00Z",
            "baseRefName" => "main",
            "mergeCommit" => { "oid" => "b" * 40 },
            "repository" => { "nameWithOwner" => "acme/demo" }
          }
        ],
        "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-2" }
      }
    }
  }

  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
    captured = [ cmd, kwargs ]
    [ JSON.generate(response), "", status ]
  }) do
    page = Hive::Gh.merged_prs_page(
      repository: "acme/demo",
      default_branch: "main",
      cursor: "cursor-1",
      merged_since: Time.utc(2026, 7, 10, 9),
      per_page: 25,
      worktree_path: "/tmp/demo",
      cfg: { "x" => true }
    )

    assert_equal true, page.fetch("complete")
    assert_equal "cursor-2", page.fetch("next_cursor")
    assert_equal "b" * 40, page.dig("items", 0, "merge_sha")
    assert_equal "acme/demo", page.dig("items", 0, "repository")
  end

  assert_equal [ "gh", "api", "graphql" ], captured.first.first(3)
  assert_includes captured.first, "cursor=cursor-1"
  assert captured.first.any? { |arg| arg.include?("base:main") }
  assert_equal "/tmp/demo", captured.last.fetch(:chdir)
end

def test_merged_prs_page_rejects_graphql_errors_or_missing_page_info
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  responses = [
    { "errors" => [ { "message" => "rate limited" } ] },
    { "data" => { "search" => { "nodes" => [] } } }
  ]

  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_, **|
    [ JSON.generate(responses.shift), "", status ]
  }) do
    2.times do
      assert_raises(Hive::GhError) do
        Hive::Gh.merged_prs_page(
          repository: "acme/demo", default_branch: "main", cursor: nil,
          merged_since: nil, per_page: 100, worktree_path: "/tmp/demo"
        )
      end
    end
  end
end

def test_merged_prs_page_fails_closed_above_graphql_search_traversal_cap
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  response = {
    "data" => {
      "search" => {
        "issueCount" => 1001,
        "nodes" => [],
        "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-2" }
      }
    }
  }
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_, **) { [ JSON.generate(response), "", status ] }) do
    error = assert_raises(Hive::GhError) do
      Hive::Gh.merged_prs_page(
        repository: "acme/demo", default_branch: "main", cursor: nil,
        merged_since: nil, per_page: 100, worktree_path: "/tmp/demo"
      )
    end
    assert_match(/1,000-result traversal cap/, error.message)
  end
end

def test_list_merged_prs_uses_repo_search_window
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  captured = nil
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
    captured = [ cmd, kwargs ]
    [ '[{"number":1,"mergedAt":"2026-06-13T12:00:00Z"}]', "", status ]
  }) do
    prs = Hive::Gh.list_merged_prs("owner/repo", since: "2026-06-12", until_date: "2026-06-14")
    assert_equal 1, prs.first.fetch("number")
  end

  assert_includes captured.first, "--repo"
  assert_includes captured.first, "owner/repo"
  assert_includes captured.first, "merged:2026-06-12..2026-06-14"
  assert_match(/mergedAt/, captured.first.fetch(captured.first.index("--json") + 1))
end

def test_list_merged_prs_raises_on_gh_error
  status = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "api unavailable", status ] }) do
    err = assert_raises(Hive::GhError) do
      Hive::Gh.list_merged_prs("owner/repo", since: "2026-06-12", until_date: "2026-06-14")
    end
    assert_match(/gh pr list.*failed for owner\/repo/, err.message)
    assert_match(/api unavailable/, err.message)
  end
end

def test_list_merged_prs_raises_on_unparseable_json
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "not json", "", status ] }) do
    err = assert_raises(Hive::GhError) do
      Hive::Gh.list_merged_prs("owner/repo", since: "2026-06-12", until_date: "2026-06-14")
    end
    assert_match(/unparseable JSON/, err.message)
  end
end

def test_pr_stats_returns_line_and_commit_counts_keyed_off_the_url
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  json = '{"additions":2111,"deletions":1102,"commits":[{"oid":"a"},{"oid":"b"}]}'
  captured = nil
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    captured = cmd
    [ json, "", status ]
  }) do
    stats = Hive::Gh.pr_stats("https://github.com/o/r/pull/7")
    assert_equal 2111, stats[:additions]
    assert_equal 1102, stats[:deletions]
    assert_equal 2, stats[:commits], "commits must be the commit count, not the raw array"
  end
  assert_includes captured, "https://github.com/o/r/pull/7"
  assert_match(/(^|,)commits(,|$)/, captured[captured.index("--json") + 1])
end

def test_pr_stats_raises_on_failed_lookup
  status = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "no pull requests found", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.pr_stats("https://github.com/o/r/pull/7") }
    assert_match(/gh pr view.*failed/, err.message)
  end
end

# These two raise-paths are exactly what Digest::Stats relies on to DROP a PR
# gracefully (rescue Hive::Error); if a refactor turned either into a silent
# nil/crash, "one bad PR never fails the digest" would break unnoticed.
def test_pr_stats_raises_on_unparseable_json
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "not json", "", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.pr_stats("https://github.com/o/r/pull/7") }
    assert_match(/unparseable JSON/, err.message)
  end
end

def test_pr_stats_raises_when_json_is_not_a_hash
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "[]", "", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.pr_stats("https://github.com/o/r/pull/7") }
    assert_match(/expected Hash/, err.message)
  end
end

def test_pr_failing_job_logs_tail_clips_each_job
  calls = []
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  rollup = {
    "statusCheckRollup" => [
      { "name" => "unit", "databaseId" => 11, "conclusion" => "FAILURE" },
      { "name" => "lint", "databaseId" => 12, "conclusion" => "SUCCESS" }
    ]
  }
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    calls << cmd
    if cmd.include?("pr")
      [ JSON.generate(rollup), "", status ]
    else
      [ "x" * 100, "", status ]
    end
  }) do
    logs = Hive::Gh.pr_failing_job_logs("/tmp/repo", 42, byte_cap: 20)
    assert_equal 1, logs.size
    assert_equal "unit", logs.first.fetch("name")
    assert_operator logs.first.fetch("log").bytesize, :>, 20
    assert_includes logs.first.fetch("log"), "truncated"
  end
  assert calls.any? { |cmd| cmd.include?("--job") && cmd.include?("11") }
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
