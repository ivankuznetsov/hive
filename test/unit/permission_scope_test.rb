require "test_helper"
require "hive/permission_scope"
require "hive/agent_profiles"

class PermissionScopeTest < Minitest::Test
  include HiveTestHelper

  def claude_profile
    Hive::AgentProfiles.lookup(:claude)
  end

  def codex_profile
    Hive::AgentProfiles.lookup(:codex)
  end

  def pi_profile
    Hive::AgentProfiles.lookup(:pi)
  end

  def test_scalar_and_map_read_only_resolve_identically
    with_tmp_dir do |dir|
      scalar = Hive::PermissionScope.resolve(
        "read-only",
        task_folder: dir,
        profile: claude_profile,
        stage: "plan"
      )
      mapped = Hive::PermissionScope.resolve(
        { "preset" => "read-only" },
        task_folder: dir,
        profile: claude_profile,
        stage: "plan"
      )

      assert_equal mapped.to_h, scalar.to_h
      assert_equal "default", scalar.permission_mode
      assert_equal %w[Read LS Grep Glob], scalar.allowed_tools
      assert_equal %w[Write Edit MultiEdit NotebookEdit Bash], scalar.disallowed_tools
      refute_includes scalar.allowed_tools, "Bash"
      refute_includes scalar.allowed_tools, "WebFetch"
      assert_empty scalar.add_dirs_extra
    end
  end

  def test_nil_and_yolo_are_noop_scope
    with_tmp_dir do |dir|
      nil_scope = Hive::PermissionScope.resolve(nil, task_folder: dir, profile: codex_profile, stage: "execute")
      yolo_scope = Hive::PermissionScope.resolve("yolo", task_folder: dir, profile: codex_profile, stage: "execute")

      [ nil_scope, yolo_scope ].each do |scope|
        assert scope.yolo?
        assert_equal "bypassPermissions", scope.permission_mode
        assert_nil scope.allowed_tools
        assert_nil scope.disallowed_tools
        assert_empty scope.add_dirs_extra
      end
    end
  end

  def test_scoped_with_tools_and_dirs_resolves_paths
    with_tmp_dir do |dir|
      absolute = File.join(dir, "absolute-extra")
      scope = Hive::PermissionScope.resolve(
        {
          "preset" => "scoped",
          "tools" => %w[Read Write Edit],
          "dirs" => [ "./drafts", absolute ]
        },
        task_folder: dir,
        profile: claude_profile,
        stage: "execute"
      )

      assert_equal "scoped", scope.preset
      assert_equal "default", scope.permission_mode
      assert_equal %w[Read Write Edit], scope.allowed_tools
      # The granted tools (Write, Edit) are subtracted from the read-only
      # deny list — otherwise Claude's deny rules would override the grant
      # and the scope could never actually use Write/Edit.
      assert_equal %w[MultiEdit NotebookEdit Bash], scope.disallowed_tools
      refute_includes scope.disallowed_tools, "Write"
      refute_includes scope.disallowed_tools, "Edit"
      assert_empty scope.allowed_tools & scope.disallowed_tools,
                   "scoped allow and deny lists must never overlap"
      assert_equal [ File.join(dir, "drafts"), absolute ], scope.add_dirs_extra
    end
  end

  def test_scoped_never_denies_a_tool_it_grants
    with_tmp_dir do |dir|
      # Every combination of granted tools must leave the deny list
      # disjoint from the allow list, so a granted tool is always usable.
      [
        %w[Read Write Edit],
        %w[Read Write Edit MultiEdit NotebookEdit Bash],
        %w[Bash],
        %w[Read]
      ].each do |tools|
        scope = Hive::PermissionScope.resolve(
          { "preset" => "scoped", "tools" => tools },
          task_folder: dir,
          profile: claude_profile,
          stage: "execute"
        )

        assert_equal tools, scope.allowed_tools
        assert_empty scope.allowed_tools & scope.disallowed_tools,
                     "granted tools #{tools.inspect} must not appear in the deny list"
        tools.each do |granted|
          refute_includes scope.disallowed_tools, granted,
                          "granted tool #{granted.inspect} must not be denied"
        end
      end
    end
  end

  def test_bash_sugar_toggles_bash_on_read_only_base
    with_tmp_dir do |dir|
      bash_on = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "bash" => true },
        task_folder: dir,
        profile: claude_profile,
        stage: "execute"
      )
      bash_off = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "bash" => false },
        task_folder: dir,
        profile: claude_profile,
        stage: "execute"
      )

      assert_equal %w[Read LS Grep Glob Bash], bash_on.allowed_tools
      assert_equal %w[Read LS Grep Glob], bash_off.allowed_tools

      # `bash: true` grants Bash, so Bash must be subtracted from the deny
      # list; `bash: false` keeps the read-only deny list (Bash denied).
      assert_equal %w[Write Edit MultiEdit NotebookEdit], bash_on.disallowed_tools
      refute_includes bash_on.disallowed_tools, "Bash"
      assert_empty bash_on.allowed_tools & bash_on.disallowed_tools
      assert_equal %w[Write Edit MultiEdit NotebookEdit Bash], bash_off.disallowed_tools
      assert_includes bash_off.disallowed_tools, "Bash"
    end
  end

  def test_bash_with_tools_is_rejected
    error = assert_raises(Hive::ConfigError) do
      Hive::PermissionScope.validate!(
        { "preset" => "scoped", "tools" => %w[Read Bash], "bash" => true },
        stage: "execute"
      )
    end

    assert_match(/stage execute permissions/, error.message)
    assert_match(/express Bash via tools/, error.message)
  end

  def test_malformed_specs_fail_closed_with_offending_value
    cases = [
      [ "reckless", /unknown preset "reckless"/ ],
      [ { "tools" => %w[Read] }, /map must include preset/ ],
      [ { "preset" => "read-only", "dirs" => [ "tmp" ] }, /unknown key/ ],
      [ 42, /must be a preset string or a map/ ],
      [ { "preset" => "scoped" }, /scoped requires tools: or bash:/ ],
      [ { "preset" => "scoped", "tools" => [] }, /tools: must be a non-empty Array/ ],
      [ { "preset" => "scoped", "dirs" => "tmp", "bash" => false }, /dirs: must be an Array/ ],
      [ { "preset" => "scoped", "bash" => "yes" }, /bash: must be true or false/ ]
    ]

    cases.each do |spec, pattern|
      error = assert_raises(Hive::ConfigError) do
        Hive::PermissionScope.validate!(spec, stage: "plan")
      end
      assert_match(/stage plan permissions/, error.message)
      assert_includes error.message, spec.inspect
      assert_match(pattern, error.message)
    end
  end

  def test_non_yolo_requires_claude_profile
    with_tmp_dir do |dir|
      [ codex_profile, pi_profile ].each do |profile|
        error = assert_raises(Hive::ConfigError) do
          Hive::PermissionScope.resolve("read-only", task_folder: dir, profile: profile, stage: "execute")
        end
        assert_match(/stage execute requests permissions/, error.message)
        assert_match(/runner #{profile.name.inspect}/, error.message)
        assert_match(/claude only/, error.message)
      end
    end
  end

  def test_yolo_is_allowed_for_non_claude_profiles
    with_tmp_dir do |dir|
      scope = Hive::PermissionScope.resolve("yolo", task_folder: dir, profile: codex_profile, stage: "execute")

      assert scope.yolo?
    end
  end

  def test_tool_csv_omits_blank_values
    assert_equal "Read,Write", Hive::PermissionScope.tool_csv([ "Read", "", nil, :Write ])
    assert_nil Hive::PermissionScope.tool_csv([])
  end

  def test_tool_csv_dedups_preserving_first_occurrence_order
    assert_equal "Read,Write,Edit",
                 Hive::PermissionScope.tool_csv([ "Read", "Write", "Read", :Edit, "Write" ])
    assert_nil Hive::PermissionScope.tool_csv([ "", nil ])
  end
end
