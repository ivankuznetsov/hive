require "test_helper"
require "hive/babysitter/gh_ops"

class BabysitterGhOpsTest < Minitest::Test
  include HiveTestHelper

  def test_force_push_uses_bare_force_with_lease_without_expected_oid
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false)
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease origin HEAD:feature], captured.first
    assert_equal "/tmp/wt", captured.last.fetch(:chdir)
  end

  def test_force_push_uses_explicit_lease_when_expected_oid_present
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false, expected_oid: "abc123")
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease=feature:abc123 origin HEAD:feature], captured.first
    assert_equal "/tmp/wt", captured.last.fetch(:chdir)
  end

  def test_force_push_treats_empty_expected_oid_as_bare_lease
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      captured = cmd
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false, expected_oid: "")
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease origin HEAD:feature], captured
  end

  def test_force_push_dry_run_skips_git
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: true, expected_oid: "abc123")
      assert result.success?
    end
    refute called
  end

  def test_add_label_noops_when_label_already_present
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    calls = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      calls << cmd
      [ '{"labels":[{"name":"babysitter/needs-human"}]}', "", status ]
    }) do
      result = Hive::Babysitter::GhOps.add_label("/tmp/wt", 42, "babysitter/needs-human", cfg: {}, dry_run: false)
      assert result.success?
      assert_equal "already labelled", result.stdout
    end
    assert_equal 1, calls.size
  end

  def test_add_give_up_label_provisions_repository_label_when_missing
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    missing = Hive::Gh::CommandStatus.new(exitstatus: 1)
    created = false
    commands = []

    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      case cmd[0, 3]
      when %w[gh label list]
        [ "", "", ok ]
      when %w[gh label create]
        created = true
        [ "created", "", ok ]
      when %w[gh pr view]
        [ '{"labels":[]}', "", ok ]
      when %w[gh pr edit]
        created ? [ "labelled", "", ok ] : [ "", "label not found", missing ]
      else
        flunk "unexpected command: #{cmd.inspect}"
      end
    }) do
      result = Hive::Babysitter::GhOps.add_label(
        "/tmp/wt",
        42,
        Hive::Babysitter::GhOps::GIVE_UP_LABEL,
        cfg: {},
        dry_run: false
      )
      assert result.success?
    end

    assert_includes commands,
                    [
                      "gh", "label", "list", "--search", "babysitter/needs-human",
                      "--limit", "100", "--json", "name"
                    ]
    assert_includes commands,
                    [
                      "gh", "label", "create", "babysitter/needs-human",
                      "--color", "D73A4A",
                      "--description", "Hive babysitter requires human intervention"
                    ]
  end

  def test_add_give_up_label_preserves_existing_repository_label
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      case cmd[0, 3]
      when %w[gh pr view]
        [ '{"labels":[]}', "", ok ]
      when %w[gh label list]
        [ '[{"name":"Babysitter/Needs-Human"}]', "", ok ]
      when %w[gh pr edit]
        [ "labelled", "", ok ]
      else
        flunk "unexpected command: #{cmd.inspect}"
      end
    }) do
      result = Hive::Babysitter::GhOps.add_label(
        "/tmp/wt", 42, Hive::Babysitter::GhOps::GIVE_UP_LABEL, cfg: {}, dry_run: false
      )
      assert result.success?
    end
    refute commands.any? { |cmd| cmd[0, 3] == %w[gh label create] }
  end

  def test_add_give_up_label_stops_when_provisioning_fails
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      case cmd[0, 3]
      when %w[gh pr view]
        [ '{"labels":[]}', "", ok ]
      when %w[gh label list]
        [ "[]", "", ok ]
      else
        [ "", "forbidden", failed ]
      end
    }) do
      result = Hive::Babysitter::GhOps.add_label(
        "/tmp/wt", 42, Hive::Babysitter::GhOps::GIVE_UP_LABEL, cfg: {}, dry_run: false
      )
      refute result.success?
      assert_equal "forbidden", result.stderr
    end
    refute commands.any? { |cmd| cmd[0, 3] == %w[gh pr edit] }
  end

  def test_add_give_up_label_preserves_a_concurrently_created_label
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    list_calls = 0
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      case cmd[0, 3]
      when %w[gh pr view]
        [ '{"labels":[]}', "", ok ]
      when %w[gh label list]
        list_calls += 1
        labels = list_calls == 1 ? "[]" : '[{"name":"babysitter/needs-human"}]'
        [ labels, "", ok ]
      when %w[gh label create]
        [ "", "label already exists", failed ]
      when %w[gh pr edit]
        [ "labelled", "", ok ]
      else
        flunk "unexpected command: #{cmd.inspect}"
      end
    }) do
      result = Hive::Babysitter::GhOps.add_label(
        "/tmp/wt", 42, Hive::Babysitter::GhOps::GIVE_UP_LABEL, cfg: {}, dry_run: false
      )
      assert result.success?
    end
    assert_equal 2, list_calls
    refute commands.flatten.include?("--force")
  end

  def test_add_give_up_label_returns_failure_when_provisioning_raises
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      next [ '{"labels":[]}', "", ok ] if cmd[0, 3] == %w[gh pr view]

      raise Hive::GhError, "network operation timed out"
    }) do
      result = Hive::Babysitter::GhOps.add_label(
        "/tmp/wt", 42, Hive::Babysitter::GhOps::GIVE_UP_LABEL, cfg: {}, dry_run: false
      )
      refute result.success?
      assert_equal "network operation timed out", result.stderr
    end
  end

  def test_ensure_give_up_label_rejects_invalid_catalogue_responses
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    scenarios = [
      [ "", "forbidden", failed, /forbidden/ ],
      [ "{}", "", ok, /unexpected response/ ],
      [ "not json", "", ok, /invalid gh label list response/ ]
    ]

    scenarios.each do |stdout, stderr, status, expected_error|
      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_cmd, **_kwargs|
        [ stdout, stderr, status ]
      }) do
        result = Hive::Babysitter::GhOps.ensure_give_up_label("/tmp/wt", cfg: {})
        refute result.success?
        assert_match expected_error, result.stderr
      end
    end
  end

  def test_post_pr_comment_dry_run_skips_gh
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.post_pr_comment("/tmp/wt", 42, "body", cfg: {}, dry_run: true)
      assert result.success?
    end
    refute called
  end

  PUSH_URL = "https://github.com/o/r.git".freeze

  def test_rebase_onto_base_fetches_push_url_then_rebases_on_success
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    url = PUSH_URL
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      next [ "#{url}\n", "", ok ] if cmd[0, 3] == %w[git remote get-url]

      [ "ok", "", ok ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.success?
      refute result.conflict?
    end

    assert_equal %w[git remote get-url --push origin], commands[0]
    assert_equal [ "git", "fetch", PUSH_URL, "main" ], commands[1], "fetches the resolved push URL, not bare origin"
    assert_equal %w[git rebase FETCH_HEAD], commands[2]
    assert_equal 3, commands.size, "no abort on a clean rebase"
  end

  def test_rebase_onto_base_falls_back_to_origin_when_push_url_unresolved
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    bad = Hive::Gh::CommandStatus.new(exitstatus: 1)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      next [ "", "no such remote", bad ] if cmd[0, 3] == %w[git remote get-url]

      [ "ok", "", ok ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.success?
    end

    assert_equal %w[git fetch origin main], commands[1], "falls back to bare origin"
    assert_equal %w[git rebase FETCH_HEAD], commands[2]
  end

  def test_rebase_onto_base_falls_back_to_origin_when_push_url_empty
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      next [ "  \n", "", ok ] if cmd[0, 3] == %w[git remote get-url]

      [ "ok", "", ok ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.success?
    end

    assert_equal %w[git fetch origin main], commands[1], "empty push URL falls back to bare origin"
  end

  def test_rebase_onto_base_aborts_and_reports_conflict_on_failure
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    bad = Hive::Gh::CommandStatus.new(exitstatus: 1)
    url = PUSH_URL
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      next [ "#{url}\n", "", ok ] if cmd[0, 3] == %w[git remote get-url]

      status = cmd[0, 2] == %w[git rebase] && cmd[2] != "--abort" ? bad : ok
      [ "out", "err", status ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.conflict?
      refute result.success?
    end

    assert_equal %w[git rebase --abort], commands.last
  end

  def test_rebase_onto_base_reports_failure_when_fetch_fails
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    bad = Hive::Gh::CommandStatus.new(exitstatus: 1)
    url = PUSH_URL
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      next [ "#{url}\n", "", ok ] if cmd[0, 3] == %w[git remote get-url]

      [ "out", "fetch boom", bad ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      refute result.success?
      refute result.conflict?
      assert_equal :failure, result.status
    end

    assert_equal [ "git", "fetch", PUSH_URL, "main" ], commands.last
    assert_equal 2, commands.size, "stops after a failed fetch (push-url resolve + fetch)"
  end

  def test_rebase_onto_base_dry_run_skips_git
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: true)
      assert result.success?
    end
    refute called
  end
end
