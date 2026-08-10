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

  def test_yolo_is_a_noop_scope
    with_tmp_dir do |dir|
      scope = Hive::PermissionScope.resolve("yolo", task_folder: dir, profile: codex_profile, stage: "execute")

      assert scope.yolo?
      assert_equal "bypassPermissions", scope.permission_mode
      assert_nil scope.allowed_tools
      assert_nil scope.disallowed_tools
      assert_empty scope.add_dirs_extra
    end
  end

  def test_managed_resolution_returns_the_scope_without_the_legacy_claude_gate
    with_tmp_dir do |dir|
      scope = Hive::PermissionScope.resolve_managed(
        {
          "preset" => "scoped",
          "tools" => [ "Read", "Edit(./article.md)" ]
        },
        task_folder: dir,
        stage: "managed-workflow"
      )

      assert_equal "scoped", scope.preset
      assert_equal [
        "Read",
        "Edit(//#{File.expand_path("article.md", dir).delete_prefix("/")})"
      ], scope.allowed_tools
    end
  end

  # Fail-closed: a present-but-blank `permissions:` (YAML key with no value →
  # nil) must be a hard error, NOT silently mapped to yolo. A fully-absent key
  # resolves to yolo via Config.permission_spec and never reaches resolve as
  # nil, so a nil here can only be an operator who typed `permissions:`
  # intending to scope — granting full access would be the exact footgun this
  # feature guards against.
  def test_blank_nil_permissions_fails_closed
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ConfigError) do
        Hive::PermissionScope.resolve(nil, task_folder: dir, profile: claude_profile, stage: "execute")
      end

      assert_match(/stage execute permissions/, error.message)
      assert_match(/present but blank/, error.message)
      assert_match(/yolo/, error.message)
    end
  end

  def test_blank_nil_permissions_fails_closed_via_validate
    error = assert_raises(Hive::ConfigError) do
      Hive::PermissionScope.validate!(nil, stage: "review.reviewers[0]")
    end

    assert_match(/present but blank/, error.message)
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
      assert_equal "dontAsk", scope.permission_mode
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

  def test_bare_file_tool_allow_only_removes_that_exact_deny
    with_tmp_dir do |dir|
      scope = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "tools" => [ "Write" ] },
        task_folder: dir,
        profile: claude_profile,
        stage: "execute"
      )

      assert_equal %w[Edit MultiEdit NotebookEdit Bash], scope.disallowed_tools
    end
  end

  def test_scoped_accepts_path_qualified_file_rules_and_keeps_them_bounded
    with_tmp_dir do |dir|
      tools = [
        "Read",
        "Edit(./inspect.md)",
        "Edit(../../../../docs/**)"
      ]
      scope = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "tools" => tools, "dirs" => [ "../../../.." ] },
        task_folder: dir,
        profile: claude_profile,
        stage: "inspect"
      )

      assert_equal "dontAsk", scope.permission_mode
      assert_equal [
        "Read",
        "Edit(//#{File.expand_path("inspect.md", dir).delete_prefix("/")})",
        "Edit(//#{File.expand_path("../../../../docs/**", dir).delete_prefix("/")})"
      ], scope.allowed_tools
      assert_equal %w[Bash], scope.disallowed_tools
      refute_includes scope.disallowed_tools, "Write"
      refute_includes scope.disallowed_tools, "Edit"
      refute_includes scope.disallowed_tools, "MultiEdit"
      refute_includes scope.disallowed_tools, "NotebookEdit"
      assert_equal [ File.expand_path("../../../..", dir) ], scope.add_dirs_extra
    end
  end

  def test_scoped_preserves_mcp_wildcard_and_hyphenated_tool_rules
    with_tmp_dir do |dir|
      tools = [ "mcp__browser-tools__*", "Agent(review-agent)" ]
      scope = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "tools" => tools },
        task_folder: dir,
        profile: claude_profile,
        stage: "review"
      )

      assert_equal tools, scope.allowed_tools
    end
  end

  def test_claude_absolute_permission_path_normalizes_windows_drive_paths
    assert_equal "//c/Users/alice/project/docs/**",
                 Hive::PermissionScope.claude_absolute_permission_path("C:\\Users\\alice\\project\\docs\\**")
    assert_equal "//tmp/project/docs/**",
                 Hive::PermissionScope.claude_absolute_permission_path("/tmp/project/docs/**")
  end

  # resolve_dirs runs File.expand_path, which raises ArgumentError on an
  # un-expandable `~user` (validate_dirs! guards blanks/null-bytes but cannot
  # know at load whether a `~user` resolves). That must surface as a typed
  # Hive::ConfigError (fail-closed, U10-4) so stage_permission_scope_or_mark! /
  # Review.run! stamp an attributed :error marker instead of letting a bare
  # crash strand the stage's in-progress marker (a hang).
  def test_scoped_dirs_with_unexpandable_tilde_user_raises_config_error
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ConfigError) do
        Hive::PermissionScope.resolve(
          { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "~hive_no_such_user_42/x" ] },
          task_folder: dir,
          profile: claude_profile,
          stage: "execute"
        )
      end

      assert_match(/could not be resolved/, error.message)
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

  # validate! pushes the parse-time check TOWARD resolve: an unknown `~user`
  # in `dirs:` can never resolve (resolve_dirs raises ArgumentError), so it must
  # be rejected at LOAD time — when the descriptor parser calls validate! —
  # rather than deferred to a run-time attributed :error marker. A `~user` does
  # not depend on the task folder, so the placeholder root validate! uses
  # surfaces it.
  def test_validate_rejects_unresolvable_tilde_user_dir_at_parse_time
    error = assert_raises(Hive::ConfigError) do
      Hive::PermissionScope.validate!(
        { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "~hive_no_such_user_42/x" ] },
        stage: "execute"
      )
    end

    assert_match(/could not be resolved/, error.message)
  end

  def test_validate_rejects_unresolvable_tilde_user_tool_path_at_parse_time
    error = assert_raises(Hive::ConfigError) do
      Hive::PermissionScope.validate!(
        {
          "preset" => "scoped",
          "tools" => [ "Read", "Edit(~hive_no_such_user_42/docs/**)" ]
        },
        stage: "execute"
      )
    end

    assert_match(/tool path could not be resolved/, error.message)
  end

  # A relative or absolute dir resolves fine at validate! time (no task folder
  # needed to know it CAN resolve), so a normal scoped block still validates.
  def test_validate_accepts_resolvable_relative_and_absolute_dirs
    assert Hive::PermissionScope.validate!(
      { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "./drafts", "/tmp/extra" ] },
      stage: "execute"
    )
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
      # Non-String/Symbol map key and non-String/Symbol preset value are
      # rejected during key stringification, before any preset lookup.
      [ { 42 => "x", "preset" => "yolo" }, /contains non-string key 42/ ],
      [ { "preset" => 42 }, /preset must be a string/ ],
      [ { "preset" => "scoped" }, /scoped requires tools: or bash:/ ],
      [ { "preset" => "scoped", "tools" => [] }, /tools: must be a non-empty Array/ ],
      # Per-entry tools validation: a blank String or a non-String entry is
      # rejected with its index so the operator can find the bad item.
      [ { "preset" => "scoped", "tools" => [ "" ] }, /tools\[0\] must be a non-empty String/ ],
      [ { "preset" => "scoped", "tools" => [ 42 ] }, /tools\[0\] must be a non-empty String/ ],
      # A comma-bearing entry (one CSV element Claude would split), an
      # internal-whitespace entry, and a null-byte entry are all rejected as
      # mis-scoped tool names — they would silently re-deny the intended grant
      # (and a NUL would crash Process.spawn).
      [ { "preset" => "scoped", "tools" => [ "Read,Write" ] },
        /tools\[0\] .* must be a single tool name without commas, whitespace, or null bytes/ ],
      [ { "preset" => "scoped", "tools" => [ "Read Write" ] },
        /tools\[0\] .* must be a single tool name without commas, whitespace, or null bytes/ ],
      [ { "preset" => "scoped", "tools" => [ "a\0b" ] },
        /tools\[0\] .* must be a single tool name without commas, whitespace, or null bytes/ ],
      [ { "preset" => "scoped", "tools" => [ "Edit()" ] },
        /tools\[0\] .* malformed permission rule/ ],
      [ { "preset" => "scoped", "tools" => [ "Edit(./docs/**" ] },
        /tools\[0\] .* malformed permission rule/ ],
      [ { "preset" => "scoped", "tools" => [ "Edit((./docs/**)" ] },
        /tools\[0\] .* malformed permission rule/ ],
      [ { "preset" => "scoped", "tools" => [ "Write(./docs/**)" ] },
        /tools\[0\] .* does not enforce Write\(path\), use Edit\(path\)/ ],
      [ { "preset" => "scoped", "tools" => [ "NotebookEdit(./docs/**)" ] },
        /tools\[0\] .* does not enforce NotebookEdit\(path\), use Edit\(path\)/ ],
      [ { "preset" => "scoped", "tools" => [ "Glob(./docs/**)" ] },
        /tools\[0\] .* does not enforce Glob\(path\), use Read\(path\)/ ],
      [ { "preset" => "scoped", "dirs" => "tmp", "bash" => false }, /dirs: must be an Array/ ],
      # Per-entry dirs validation: a blank entry and a null-byte-bearing entry
      # are both rejected (a null byte would corrupt the add-dir argv).
      [ { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "" ] },
        /dirs\[0\] must be a non-empty String without null bytes/ ],
      [ { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "a\0b" ] },
        /dirs\[0\] must be a non-empty String without null bytes/ ],
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

  # Pin the documented String-passthrough half of tool_csv's param contract:
  # a pre-joined CSV String (the *_ALLOWED_TOOLS constants) is treated as ONE
  # opaque element and returned verbatim, and nil maps to nil. The Array path
  # is covered above; this guards the String/nil path directly.
  def test_tool_csv_passes_a_csv_string_through_verbatim_and_maps_nil
    assert_equal "Read,LS", Hive::PermissionScope.tool_csv("Read,LS")
    assert_nil Hive::PermissionScope.tool_csv(nil)
  end

  # Scope.build is the single validated construction site (see its comment):
  # it guards the core invariants directly so a future construction site
  # cannot reintroduce a non-Array add_dirs_extra, a yolo scope carrying tool
  # lists, or an allow/deny overlap. resolve never produces these — they are a
  # second line of defense — so they are exercised through the factory.
  def test_scope_build_rejects_non_array_add_dirs_extra
    error = assert_raises(ArgumentError) do
      Hive::PermissionScope::Scope.build(
        preset: "read-only",
        permission_mode: "default",
        allowed_tools: %w[Read],
        disallowed_tools: %w[Bash],
        add_dirs_extra: nil
      )
    end

    assert_match(/add_dirs_extra must be an Array/, error.message)
  end

  def test_scope_build_rejects_yolo_carrying_tool_scoping
    error = assert_raises(ArgumentError) do
      Hive::PermissionScope::Scope.build(
        preset: "yolo",
        permission_mode: "default",
        allowed_tools: nil,
        disallowed_tools: nil,
        add_dirs_extra: []
      )
    end

    assert_match(/yolo scope must carry bypassPermissions and nil tool lists/, error.message)
  end

  def test_scope_build_rejects_allow_deny_overlap
    error = assert_raises(ArgumentError) do
      Hive::PermissionScope::Scope.build(
        preset: "scoped",
        permission_mode: "default",
        allowed_tools: %w[Read Bash],
        disallowed_tools: %w[Bash],
        add_dirs_extra: []
      )
    end

    assert_match(/would both grant and deny \["Bash"\]/, error.message)
    assert_match(/deny rules win/, error.message)
  end

  def test_scope_build_rejects_path_rule_with_bare_deny_for_same_tool
    error = assert_raises(ArgumentError) do
      Hive::PermissionScope::Scope.build(
        preset: "scoped",
        permission_mode: "dontAsk",
        allowed_tools: [ "Read", "Edit(./docs/**)" ],
        disallowed_tools: %w[Write Bash],
        add_dirs_extra: []
      )
    end

    assert_match(/would grant and deny tools \["Write"\]/, error.message)
    assert_match(/deny rules win/, error.message)
  end

  # Defense-in-depth: a non-yolo scope with an empty allowed_tools list would
  # emit no --allowedTools and silently grant nothing. validate_tools! already
  # requires a non-empty `tools:` upstream, so resolve never produces this —
  # the invariant is exercised through the factory.
  def test_scope_build_rejects_empty_allowed_tools_for_non_yolo
    error = assert_raises(ArgumentError) do
      Hive::PermissionScope::Scope.build(
        preset: "scoped",
        permission_mode: "default",
        allowed_tools: [],
        disallowed_tools: %w[Bash],
        add_dirs_extra: []
      )
    end

    assert_match(/requires a non-empty allowed_tools list/, error.message)
  end

  # Scope.build is the SINGLE construction site: Struct.new's public `new` is
  # made private so the invariants above cannot be bypassed by constructing a
  # Scope directly.
  def test_scope_new_is_private_so_build_is_the_only_construction_site
    error = assert_raises(NoMethodError) do
      Hive::PermissionScope::Scope.new(
        preset: "yolo",
        permission_mode: "bypassPermissions",
        allowed_tools: nil,
        disallowed_tools: nil,
        add_dirs_extra: []
      )
    end

    assert_match(/private method .new./, error.message)
  end

  # A built scope's tool/dir member arrays are deep-frozen, so the validated
  # disjoint allow/deny lists can't be mutated in place to reintroduce an
  # overlap after construction.
  def test_built_scope_deep_freezes_member_arrays
    with_tmp_dir do |dir|
      scope = Hive::PermissionScope.resolve(
        { "preset" => "scoped", "tools" => %w[Read Write], "dirs" => [ "./drafts" ] },
        task_folder: dir,
        profile: claude_profile,
        stage: "execute"
      )

      assert scope.frozen?, "scope struct must be frozen"
      assert scope.allowed_tools.frozen?, "allowed_tools array must be frozen"
      assert scope.disallowed_tools.frozen?, "disallowed_tools array must be frozen"
      assert scope.add_dirs_extra.frozen?, "add_dirs_extra array must be frozen"
      assert_raises(FrozenError) { scope.disallowed_tools << "Bash" }
    end
  end
end
