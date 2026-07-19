require "test_helper"
require "hive/gh"
require "hive/refactor_patrol/github_gateway"

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
    assert_includes fields, "baseRefOid"
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

  def test_verify_pr_identity_binds_created_head_base_host_and_repository
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    record = {
      "url" => "https://github.com/Acme/Demo/pull/9",
      "number" => 9,
      "state" => "OPEN",
      "isDraft" => false,
      "headRefName" => "hive-refactor/fix-abc",
      "headRefOid" => "a" * 40,
      "baseRefName" => "main",
      "baseRefOid" => "b" * 40,
      "headRepository" => { "nameWithOwner" => "Acme/Demo" }
    }
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ JSON.generate(record), "", ok ]
    }) do
      verified = refactor_patrol_github.verify_pr_identity!(
        record.fetch("url"), repository: "acme/demo", host: "github.com",
        branch: "hive-refactor/fix-abc", head_oid: "a" * 40,
        base_branch: "main", base_oid: "b" * 40
      )
      assert_equal record, verified
    end

    assert_equal [ "github.com/acme/demo" ], captured.first.each_cons(2)
                                                         .select { |left, _| left == "--repo" }
                                                         .map(&:last)
    assert_includes captured.first.fetch(captured.first.index("--json") + 1), "baseRefOid"
  end

  def test_verify_pr_identity_rejects_changed_head
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    record = {
      "url" => "https://github.com/acme/demo/pull/9", "number" => 9,
      "state" => "OPEN", "isDraft" => false,
      "headRefName" => "hive-refactor/fix-abc", "headRefOid" => "b" * 40,
      "baseRefName" => "main", "baseRefOid" => "c" * 40,
      "headRepository" => { "nameWithOwner" => "acme/demo" }
    }
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_cmd, **_kwargs|
      [ JSON.generate(record), "", ok ]
    }) do
      assert_raises(Hive::GhError) do
        refactor_patrol_github.verify_pr_identity!(
          record.fetch("url"), repository: "acme/demo", host: "github.com",
          branch: "hive-refactor/fix-abc", head_oid: "a" * 40,
          base_branch: "main", base_oid: "c" * 40
        )
      end
    end
  end

  def test_verify_pr_identity_rejects_remote_base_advance
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    record = {
      "url" => "https://github.com/acme/demo/pull/9", "number" => 9,
      "state" => "OPEN", "isDraft" => false,
      "headRefName" => "hive-refactor/fix-abc", "headRefOid" => "a" * 40,
      "baseRefName" => "main", "baseRefOid" => "c" * 40,
      "headRepository" => { "nameWithOwner" => "acme/demo" }
    }
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_cmd, **_kwargs|
      [ JSON.generate(record), "", ok ]
    }) do
      error = assert_raises(Hive::GhError) do
        refactor_patrol_github.verify_pr_identity!(
          record.fetch("url"), repository: "acme/demo", host: "github.com",
          branch: "hive-refactor/fix-abc", head_oid: "a" * 40,
          base_branch: "main", base_oid: "b" * 40
        )
      end
      assert_includes error.message, "validated patch"
    end
  end

  def test_verify_pr_identity_binds_view_result_to_created_url
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    record = {
      "url" => "https://github.com/acme/demo/pull/10", "number" => 10,
      "state" => "OPEN", "isDraft" => false,
      "headRefName" => "hive-refactor/fix-abc", "headRefOid" => "a" * 40,
      "baseRefName" => "main", "baseRefOid" => "b" * 40,
      "headRepository" => { "nameWithOwner" => "acme/demo" }
    }
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_cmd, **_kwargs|
      [ JSON.generate(record), "", ok ]
    }) do
      assert_raises(Hive::GhError) do
        refactor_patrol_github.verify_pr_identity!(
          "https://github.com/acme/demo/pull/9",
          repository: "acme/demo", host: "github.com",
          branch: "hive-refactor/fix-abc", head_oid: "a" * 40,
          base_branch: "main", base_oid: "b" * 40
        )
      end
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

def test_push_branch_uses_absence_lease_and_exact_validated_remote_url
  captured = nil
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  remote = "git@github.com:acme/demo.git"
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    captured = cmd
    [ "", "", ok ]
  }) do
    Hive::Gh.push_branch(
      "/tmp/wt", "feature", expected_remote_absent: true, remote: remote
    )
  end

  assert_includes captured, "--force-with-lease=refs/heads/feature:"
  assert_equal [ remote, "feature" ], captured.last(2)
end

def test_remote_branch_oid_uses_exact_validated_remote_url
  captured = nil
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  remote = "git@github.com:acme/demo.git"
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
    captured = cmd
    [ "#{'a' * 40}\trefs/heads/feature\n", "", ok ]
  }) do
    assert_equal "a" * 40, Hive::Gh.remote_branch_oid(
      "/tmp/wt", "feature", remote: remote
    )
  end

  assert_equal remote, captured.fetch(captured.index("--heads") + 1)
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
  times = [ 0.0, 2.0 ]
  terminated = []

  with_replaced_singleton_method(Hive::Gh, :monotonic_now, -> { times.shift || 2.0 }) do
    with_replaced_singleton_method(Process, :waitpid2, ->(_pid, _flags) { nil }) do
      with_replaced_singleton_method(Hive::Gh, :terminate_process_group, ->(pid) { terminated << pid }) do
        err = assert_raises(Hive::GhError) do
          Hive::Gh.wait_with_deadline(1234, 1, [ "gh", "pr", "view" ])
        end
        assert_match(/network operation exceeded 1s/, err.message)
      end
    end
  end

  assert_equal [ 1234 ], terminated
end

def test_capture3_deadline_kills_a_stdout_inheriting_process_group
  with_tmp_dir do |dir|
    script = File.join(dir, "forking-helper.rb")
    pid_path = File.join(dir, "child.pid")
    File.write(script, <<~RUBY)
      reader, writer = IO.pipe
      child = fork do
        reader.close
        trap("TERM", "IGNORE")
        writer.write("ready")
        writer.close
        sleep 30
      end
      writer.close
      reader.read(5)
      File.write(ARGV.fetch(0), child.to_s)
      exit! 0
    RUBY
    child_pid = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Hive::GhError) do
      Hive::Gh.capture3(RbConfig.ruby, script, pid_path, timeout_sec: 0.5)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_match(/network operation exceeded/, error.message)
    assert_operator elapsed, :<, 3.0
    child_pid = Integer(File.read(pid_path))
    deadline = Time.now + 1
    while gh_test_pid_alive?(child_pid) && Time.now < deadline
      sleep 0.01
    end
    refute gh_test_pid_alive?(child_pid), "stdout-inheriting helper survived the capture deadline"
  ensure
    Process.kill("KILL", child_pid) if child_pid && gh_test_pid_alive?(child_pid)
  end
end

def gh_test_pid_alive?(pid)
  stat_path = "/proc/#{pid}/stat"
  return false if File.file?(stat_path) && File.read(stat_path).split[2] == "Z"

  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

def test_process_group_liveness_is_fail_closed_on_permissions_and_false_when_missing
  with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
    assert Hive::Gh.process_group_alive?(1234)
  end
  with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
    refute Hive::Gh.process_group_alive?(1234)
  end
  with_replaced_singleton_method(Process, :waitpid2, ->(*) { raise Errno::ECHILD }) do
    assert_nil Hive::Gh.reap_process(1234, nonblock: true)
  end
end

def test_process_group_termination_ignores_an_already_missing_group
  with_replaced_singleton_method(Hive::Gh, :signal_process_group, lambda { |*|
    raise Errno::ESRCH, "missing"
  }) do
    assert_nil Hive::Gh.terminate_process_group(1234)
  end
end

def test_capture_timeout_must_be_finite_positive_and_numeric
  [ 0, -1, Float::NAN ].each do |value|
    assert_raises(Hive::GhError) { Hive::Gh.normalized_timeout(value) }
  end
  [ "bad", Object.new ].each do |value|
    assert_raises(Hive::GhError) { Hive::Gh.normalized_timeout(value) }
  end
end

def test_terminate_process_returns_when_child_exits_during_grace
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  wait_results = [ nil, [ 1234, status ] ]
  signals = []
  times = [ 0.0, 0.0 ]

  with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
    with_replaced_singleton_method(Hive::Gh, :monotonic_now, -> { times.shift || 0.0 }) do
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
  times = [ 0.0, 2.0 ]

  with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
    with_replaced_singleton_method(Hive::Gh, :monotonic_now, -> { times.shift || 2.0 }) do
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

def test_repo_name_with_owner_uses_the_actual_origin_push_url
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  captured = nil
  with_env("GH_REPO" => "attacker/spoofed") do
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ "git@github.com:owner/repo.git\n", "", status ]
    }) do
      assert_equal "owner/repo", Hive::Gh.repo_name_with_owner("/tmp/repo", cfg: { "cfg" => true })
    end
  end

  assert_equal(
    [ "git", "-C", "/tmp/repo", "remote", "get-url", "--push", "--all", "origin" ],
    captured.first
  )
  refute captured.last.key?(:chdir)
  assert_equal({ "cfg" => true }, captured.last.fetch(:cfg))
end

def test_repo_name_with_owner_raises_when_origin_lookup_fails
  status = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "no remote", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.repo_name_with_owner("/tmp/repo") }
    assert_match(/git remote get-url.*failed/, err.message)
    assert_match(/no remote/, err.message)
  end
end

def test_repo_name_with_owner_raises_on_unsupported_origin
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "/tmp/local.git\n", "", status ] }) do
    err = assert_raises(Hive::GhError) { Hive::Gh.repo_name_with_owner("/tmp/repo") }
    assert_match(/not a supported GitHub remote/, err.message)
  end
end

def test_repository_identity_binds_slug_and_https_host
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  captured = nil
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
    captured = [ cmd, kwargs ]
    [ "https://github.corp.example/Owner/Repo.git\n", "", status ]
  }) do
    assert_equal(
      { "repository" => "Owner/Repo", "host" => "github.corp.example" },
      Hive::Gh.repository_identity(
        "/tmp/repo", cfg: { "cfg" => true }, timeout_sec: 3.5
      )
    )
  end
  assert_equal(
    [ "git", "-C", "/tmp/repo", "remote", "get-url", "--push", "--all", "origin" ],
    captured.first
  )
  assert_equal 3.5, captured.last.fetch(:timeout_sec)
end

def test_repository_identity_rejects_multiple_origin_push_urls
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_cmd, **_kwargs|
    [ "git@github.com:acme/one.git\ngit@github.com:acme/two.git\n", "", status ]
  }) do
    error = assert_raises(Hive::GhError) do
      Hive::Gh.repository_identity("/tmp/repo")
    end
    assert_match(/returned 2 records/, error.message)
  end
end

def test_repository_identity_rejects_credential_bearing_https_origin
  error = assert_raises(Hive::GhError) do
    Hive::Gh.repository_identity_from_remote(
      "https://user:secret@github.com/acme/demo.git"
    )
  end

  assert_match(/unsupported credentials/, error.message)
  assert_raises(Hive::GhError) do
    Hive::Gh.repository_identity_from_remote(
      "https://github.com/acme/demo.git?redirect=other"
    )
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
    with_replaced_singleton_method(Hive::Gh, :repository_identity, lambda { |*|
      { "repository" => "acme/demo", "host" => "github.com" }
    }) do
      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
        calls << [ cmd, kwargs ]
        body = cmd[1] == "pr" ? JSON.generate(metadata) : JSON.generate(pages)
        [ body, "", status ]
      }) do
        details = refactor_patrol_github.merged_pr_details(
          "7", worktree_path: "/tmp/demo", cfg: { "x" => true }
        )
        assert_equal 2, details.fetch("files").size
        assert_equal "lib/old.rb", details.fetch("files").last.fetch("previous_path")
      end
    end
  end

  api = calls.find { |cmd, _| cmd[1] == "api" }
  assert_includes api.first, "--paginate"
  assert_includes api.first, "--slurp"
  assert_includes api.first, "--hostname"
  assert_equal "/tmp/demo", calls.first.last.fetch(:chdir)
end

def test_refactor_patrol_gateway_shares_one_monotonic_deadline_across_metadata_calls
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  metadata = {
    "number" => 7, "url" => "https://github.com/acme/demo/pull/7", "state" => "MERGED",
    "baseRefName" => "main", "baseRefOid" => "a" * 40,
    "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-07-10T10:00:00Z",
    "changedFiles" => 1
  }
  transport = Object.new
  timeouts = []
  transport.define_singleton_method(:repository_identity) do |*, timeout_sec:, **|
    timeouts << timeout_sec
    { "repository" => "acme/demo", "host" => "github.com" }
  end
  transport.define_singleton_method(:ensure_authenticated!) do |*, timeout_sec:, **|
    timeouts << timeout_sec
  end
  transport.define_singleton_method(:capture3) do |*cmd, timeout_sec:, **|
    timeouts << timeout_sec
    body = cmd[1] == "pr" ? JSON.generate(metadata) : JSON.generate([
      [ { "filename" => "lib/a.rb", "status" => "modified" } ]
    ])
    [ body, "", status ]
  end
  monotonic = [ 0.0, 0.0, 0.25, 0.75, 1.25 ]
  gateway = Hive::RefactorPatrol::GithubGateway.new(
    transport: transport,
    monotonic_clock: -> { monotonic.shift || 1.25 }
  )

  gateway.merged_pr_details("7", worktree_path: "/tmp/demo", timeout_sec: 2.0)

  assert_equal 4, timeouts.length
  assert_in_delta 2.0, timeouts.fetch(0), 0.001
  assert_in_delta 1.75, timeouts.fetch(1), 0.001
  assert_in_delta 1.25, timeouts.fetch(2), 0.001
  assert_in_delta 0.75, timeouts.fetch(3), 0.001
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
    with_replaced_singleton_method(Hive::Gh, :repository_identity, lambda { |*|
      { "repository" => "acme/demo", "host" => "github.com" }
    }) do
      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
        calls << cmd
        [ JSON.generate(metadata), "", status ]
      }) do
        assert_raises(Hive::GhError) do
          refactor_patrol_github.merged_pr_details(
            "https://github.com/other/repo/pull/7", worktree_path: "/tmp/demo"
          )
        end
      end
    end
  end

  assert_equal 1, calls.size, "repository mismatch must fail before fetching local-repository file pages"
end

def test_merged_pr_details_rejects_non_object_file_rows
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  responses = [
    [ JSON.generate(
      "number" => 7, "url" => "https://github.com/acme/demo/pull/7",
      "state" => "MERGED", "baseRefName" => "main", "baseRefOid" => "a" * 40,
      "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-07-10T10:00:00Z",
      "changedFiles" => 1
    ), "", status ],
    [ JSON.generate([ [ nil ] ]), "", status ]
  ]
  transport = Object.new
  transport.define_singleton_method(:repository_identity) do |*|
    { "repository" => "acme/demo", "host" => "github.com" }
  end
  transport.define_singleton_method(:ensure_authenticated!) { |*_, **| true }
  transport.define_singleton_method(:capture3) { |*_, **| responses.shift }
  gateway = Hive::RefactorPatrol::GithubGateway.new(transport: transport)

  error = assert_raises(Hive::GhError) do
    gateway.merged_pr_details("7", worktree_path: "/tmp/demo")
  end
  assert_match(/non-object file/, error.message)
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
    page = refactor_patrol_github.merged_prs_page(
      repository: "acme/demo",
      host: "github.com",
      default_branch: "main",
      cursor: "cursor-1",
      merged_since: Time.utc(2026, 7, 10, 9),
      merged_until: Time.utc(2026, 7, 10, 11),
      per_page: 25,
      worktree_path: "/tmp/demo",
      cfg: { "x" => true },
      timeout_sec: 2.0
    )

    assert_equal true, page.fetch("complete")
    assert_equal "cursor-2", page.fetch("next_cursor")
    assert_equal "b" * 40, page.dig("items", 0, "merge_sha")
    assert_equal "acme/demo", page.dig("items", 0, "repository")
    assert_equal 1, page.fetch("total_count")
  end

  assert_equal [ "gh", "api", "graphql", "--hostname", "github.com" ], captured.first.first(5)
  assert_includes captured.first, "cursor=cursor-1"
  assert captured.first.any? { |arg| arg.include?("base:main") }
  search_arg = captured.first.find { |arg| arg.start_with?("searchQuery=") }
  assert_includes search_arg, "sort:created-asc"
  assert_includes search_arg, "merged:2026-07-10T09:00:00Z..2026-07-10T11:00:00Z"
  refute_includes search_arg, "merged:>="
  refute_includes search_arg, "merged:<="
  assert_equal 1, search_arg.scan("merged:").length
  assert_equal "/tmp/demo", captured.last.fetch(:chdir)
  assert_operator captured.last.fetch(:timeout_sec), :>, 0
  assert_operator captured.last.fetch(:timeout_sec), :<=, 2.0
end

def test_merged_prs_page_preserves_one_sided_merge_bounds
  status = Hive::Gh::CommandStatus.new(exitstatus: 0)
  response = {
    "data" => {
      "search" => {
        "issueCount" => 0,
        "nodes" => [],
        "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
      }
    }
  }
  searches = []

  with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **|
    searches << cmd.find { |arg| arg.start_with?("searchQuery=") }
    [ JSON.generate(response), "", status ]
  }) do
    refactor_patrol_github.merged_prs_page(
      repository: "acme/demo", host: "github.com", default_branch: "main",
      cursor: nil, merged_since: Time.utc(2026, 7, 10, 9), per_page: 25,
      worktree_path: "/tmp/demo"
    )
    refactor_patrol_github.merged_prs_page(
      repository: "acme/demo", host: "github.com", default_branch: "main",
      cursor: nil, merged_since: nil, merged_until: Time.utc(2026, 7, 10, 11),
      per_page: 25, worktree_path: "/tmp/demo"
    )
  end

  assert_includes searches.fetch(0), "merged:>=2026-07-10T09:00:00Z"
  assert_includes searches.fetch(1), "merged:<=2026-07-10T11:00:00Z"
  searches.each { |search| assert_equal 1, search.scan("merged:").length }
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
        refactor_patrol_github.merged_prs_page(
          repository: "acme/demo", host: "github.com",
          default_branch: "main", cursor: nil,
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
      refactor_patrol_github.merged_prs_page(
        repository: "acme/demo", host: "github.com",
        default_branch: "main", cursor: nil,
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

def test_push_branch_rejects_conflicting_or_invalid_exact_leases
  conflicting = Hive::Gh.push_branch(
    "/tmp/worktree", "feature",
    expected_remote_oid: "a" * 40, expected_remote_absent: true
  )
  malformed = Hive::Gh.push_branch(
    "/tmp/worktree", "feature", expected_remote_oid: "not-an-oid"
  )
  unsafe_branch = Hive::Gh.push_branch("/tmp/worktree", "--exec=helper")
  unsafe_remote = Hive::Gh.push_branch("/tmp/worktree", "feature", remote: "--upload-pack=helper")

  refute conflicting.success?
  assert_includes conflicting.stderr, "both an OID and absence"
  refute malformed.success?
  assert_includes malformed.stderr, "OID is invalid"
  refute unsafe_branch.success?
  assert_includes unsafe_branch.stderr, "branch name is invalid"
  refute unsafe_remote.success?
  assert_includes unsafe_remote.stderr, "remote target is invalid"
end

def test_remote_branch_oid_rejects_unsafe_names_and_malformed_remote_records
  [ "bad..branch", "ends/", ".hidden" ].each do |branch|
    assert_raises(Hive::GhError, branch) do
      Hive::Gh.remote_branch_oid("/tmp/worktree", branch)
    end
  end
  assert_raises(Hive::GhError) do
    Hive::Gh.remote_branch_oid("/tmp/worktree", "feature", remote: "--upload-pack=helper")
  end

  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
  responses = [
    [ "transport failed", "", failed ],
    [ "#{'a' * 40}\trefs/heads/feature\n#{'b' * 40}\trefs/heads/feature\n", "", ok ],
    [ "not-an-oid\trefs/heads/feature\n", "", ok ]
  ]
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
    3.times do
      assert_raises(Hive::GhError) do
        Hive::Gh.remote_branch_oid("/tmp/worktree", "feature")
      end
    end
  end
end

def test_pull_request_lookup_requires_repository_and_host_together
  assert_raises(Hive::GhError) do
    Hive::Gh.lookup_prs_for_branch("/tmp/worktree", "feature", repository: "acme/demo")
  end
  assert_raises(Hive::GhError) do
    Hive::Gh.lookup_prs_for_branch("/tmp/worktree", "feature", host: "github.com")
  end
end

def test_verify_pr_identity_wraps_transport_shape_and_parse_failures
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
  responses = [
    [ "transport failed", "", failed ],
    [ "[]", "", ok ],
    [ "{", "", ok ]
  ]
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
    3.times do
      assert_raises(Hive::GhError) do
        refactor_patrol_github.verify_pr_identity!(
          "https://github.com/acme/demo/pull/9",
          repository: "acme/demo", host: "github.com", branch: "feature",
          head_oid: "a" * 40, base_branch: "main", base_oid: "b" * 40
        )
      end
    end
  end

  assert_raises(Hive::GhError) do
    refactor_patrol_github.send(
      :validate_pr_repository_identity!,
      "http://[", "acme/demo", 9, host: "github.com"
    )
  end
end

def test_merged_pr_details_wraps_view_file_transport_shape_and_parse_failures
  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
  metadata = {
    "number" => 7, "url" => "https://github.com/acme/demo/pull/7",
    "state" => "MERGED", "baseRefName" => "main", "baseRefOid" => "a" * 40,
    "mergeCommit" => { "oid" => "b" * 40 }, "mergedAt" => "2026-07-10T10:00:00Z",
    "changedFiles" => 1
  }
  response_sets = [
    [ [ "view unavailable", "", failed ] ],
    [ [ JSON.generate(metadata), "", ok ], [ "api unavailable", "", failed ] ],
    [ [ JSON.generate(metadata), "", ok ], [ "{}", "", ok ] ],
    [ [ "{", "", ok ] ]
  ]

  with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(*) { }) do
    with_replaced_singleton_method(Hive::Gh, :repository_identity, ->(*) {
      { "repository" => "acme/demo", "host" => "github.com" }
    }) do
      response_sets.each do |responses|
        with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
          assert_raises(Hive::GhError) do
            refactor_patrol_github.merged_pr_details("7", worktree_path: "/tmp/demo")
          end
        end
      end
    end
  end
end

def test_merged_pr_page_rejects_invalid_inputs_transport_cursor_repository_and_json
  base = {
    "data" => {
      "search" => {
        "issueCount" => 1,
        "nodes" => [
          {
            "number" => 7, "url" => "https://github.com/acme/demo/pull/7",
            "mergedAt" => "2026-07-10T10:00:00Z", "baseRefName" => "main",
            "mergeCommit" => { "oid" => "b" * 40 },
            "repository" => { "nameWithOwner" => "acme/demo" }
          }
        ],
        "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
      }
    }
  }
  defaults = {
    repository: "acme/demo", host: "github.com", default_branch: "main",
    cursor: nil, merged_since: nil, per_page: 100, worktree_path: "/tmp/demo"
  }

  assert_raises(Hive::GhError) do
    refactor_patrol_github.merged_prs_page(**defaults.merge(default_branch: ""))
  end
  assert_raises(Hive::GhError) do
    refactor_patrol_github.merged_prs_page(**defaults.merge(cursor: 123))
  end
  assert_raises(Hive::GhError) do
    refactor_patrol_github.merged_prs_page(**defaults.merge(merged_since: "not-a-time"))
  end
  [ 0, 101 ].each do |per_page|
    assert_raises(Hive::GhError) do
      refactor_patrol_github.merged_prs_page(**defaults.merge(per_page: per_page))
    end
  end
  assert_raises(Hive::GhError) do
    refactor_patrol_github.merged_prs_page(
      **defaults.merge(
        merged_since: Time.utc(2026, 7, 10, 11),
        merged_until: Time.utc(2026, 7, 10, 10)
      )
    )
  end

  ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
  failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
  missing_cursor = Marshal.load(Marshal.dump(base))
  missing_cursor.dig("data", "search", "pageInfo")["hasNextPage"] = true
  other_repository = Marshal.load(Marshal.dump(base))
  other_repository.dig("data", "search", "nodes", 0, "repository")["nameWithOwner"] = "other/demo"
  invalid_merge_sha = Marshal.load(Marshal.dump(base))
  invalid_merge_sha.dig("data", "search", "nodes", 0, "mergeCommit")["oid"] = 123
  responses = [
    [ "graphql unavailable", "", failed ],
    [ JSON.generate(missing_cursor), "", ok ],
    [ JSON.generate(other_repository), "", ok ],
    [ JSON.generate(invalid_merge_sha), "", ok ],
    [ "{", "", ok ]
  ]
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
    5.times do
      assert_raises(Hive::GhError) { refactor_patrol_github.merged_prs_page(**defaults) }
    end
  end
end

def test_refactor_patrol_gateway_timeout_and_url_helpers_fail_closed
  [ 0, -1, Float::NAN, "bad", Object.new ].each do |value|
    assert_raises(Hive::GhError) do
      refactor_patrol_github.send(:operation_deadline, value)
    end
  end
  expired = Hive::RefactorPatrol::GithubGateway.new(
    transport: Hive::Gh, monotonic_clock: -> { 2.0 }
  )
  assert_raises(Hive::GhError) { expired.send(:remaining_timeout, 1.0) }
  assert_raises(Hive::GhError) do
    Hive::Gh::RepositoryIdentity.validated_github_host("[")
  end
  refute refactor_patrol_github.send(
    :pull_request_url_matches_repository?, "http://[", "acme/demo",
    host: "github.com", number: 7
  )
end

def test_repository_url_helpers_reject_invalid_uris_and_ssh_passwords
  assert_raises(Hive::GhError) do
    Hive::Gh::RepositoryIdentity.validated_github_host("[")
  end
  refute refactor_patrol_github.send(
    :issue_url_matches_repository?, "http://[", "acme/demo", host: "github.com", number: 7
  )
  assert_raises(Hive::GhError) do
    Hive::Gh.repository_identity_from_remote("ssh://user:secret@github.com/acme/demo.git")
  end
  assert_raises(Hive::GhError) do
    Hive::Gh.repository_identity_from_remote("http://[")
  end
end

def test_origin_push_url_transport_failure_uses_stdout_when_stderr_is_blank
  failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
  with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { [ "no remote", "", failed ] }) do
    error = assert_raises(Hive::GhError) { Hive::Gh.origin_push_url("/tmp/demo") }
    assert_includes error.message, "no remote"
  end
end

private

def refactor_patrol_github
  @refactor_patrol_github ||= Hive::RefactorPatrol::GithubGateway.new
end

class FakeCloseIO
  def closed?
    false
  end

  def close
    raise IOError, "already closed"
  end
end
end
