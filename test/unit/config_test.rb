require "test_helper"
require "hive/config"

class ConfigTest < Minitest::Test
  include HiveTestHelper

  def test_load_returns_defaults_when_no_config_file
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 2, cfg["max_review_passes"]
      # Generous defaults bumped ~5x in plan 2026-05-04-001 / ADR-023.
      assert_equal 50, cfg["budget_usd"]["brainstorm"]
      assert_equal 500, cfg["budget_usd"]["execute_implementation"]
      assert_nil cfg["budget_usd"]["execute_review"],
                 "deprecated execute_review key must be absent from DEFAULTS"
      assert_equal dir, cfg["project_root"]
    end
  end

  def test_load_merges_per_project_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        default_branch: main
        max_review_passes: 6
        budget_usd:
          brainstorm: 20
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "main", cfg["default_branch"]
      assert_equal 6, cfg["max_review_passes"]
      assert_equal 20, cfg["budget_usd"]["brainstorm"], "explicit override must win"
      assert_equal 100, cfg["budget_usd"]["plan"], "plan budget should fall back to bumped default"
    end
  end

  # Legacy projects that still carry execute_review explicitly must keep it
  # via deep-merge — DEFAULTS no longer ships the key but user-supplied
  # values survive untouched.
  def test_load_preserves_user_supplied_execute_review_when_legacy
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        budget_usd:
          execute_review: 50
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 50, cfg["budget_usd"]["execute_review"],
                   "legacy explicit execute_review must survive deep-merge"
    end
  end

  # ADR-023: stage-level agent keys for brainstorm / plan / execute.
  # Defaults are "claude" so legacy configs without these keys keep
  # the same runtime behavior as before this plan landed.
  def test_load_returns_default_stage_agents_when_keys_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal "claude", cfg.dig("brainstorm", "agent"), "brainstorm agent must default to claude"
      assert_equal "claude", cfg.dig("plan", "agent"), "plan agent must default to claude"
      assert_equal "claude", cfg.dig("execute", "agent"), "execute agent must default to claude"
    end
  end

  def test_load_honors_per_project_stage_agent_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm:
          agent: codex
        plan:
          agent: pi
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "codex", cfg.dig("brainstorm", "agent")
      assert_equal "pi",    cfg.dig("plan", "agent")
      assert_equal "claude", cfg.dig("execute", "agent"),
                   "execute agent must fall back to default when not overridden"
    end
  end

  def test_load_raises_when_stage_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          agent: nonexistent_profile
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/execute\.agent "nonexistent_profile"/, err.message)
      assert_match(/registered:/, err.message, "error must list registered profiles")
    end
  end

  # ADR-023 shape-validation gap (ce-code-review F1): non-Hash overrides on
  # the new top-level keys would otherwise survive deep_merge (because
  # deep_merge returns the override unchanged when it is not a Hash) and
  # crash later as TypeError/NoMethodError in stage code. validate! now
  # rejects them at load time with a typed ConfigError.
  def test_load_raises_when_stage_block_is_a_scalar_instead_of_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm: claude
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/brainstorm.*must be a Hash/, err.message)
      assert_match(/got "claude"/, err.message)
    end
  end

  def test_load_raises_when_budget_usd_is_nil
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        budget_usd: ~
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/budget_usd.*must be a Hash/, err.message)
    end
  end

  def test_load_raises_when_timeout_sec_is_a_scalar
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        timeout_sec: 600
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/timeout_sec.*must be a Hash/, err.message)
    end
  end

  # AgentProfiles.registered?(name) calls name.to_sym; non-String values
  # (Integer, Hash, Array, Boolean) crash with NoMethodError. validate_agent_name!
  # type-checks first so a typo like `execute.agent: 42` surfaces as
  # ConfigError, not NoMethodError. Closes ce-code-review F2 (P2).
  def test_load_raises_when_stage_agent_is_an_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          agent: 42
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/execute\.agent.*must be a String/, err.message)
      assert_match(/got 42 \(Integer\)/, err.message)
    end
  end

  def test_load_raises_when_stage_agent_is_a_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        plan:
          agent:
            name: claude
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/plan\.agent.*must be a String/, err.message)
    end
  end

  # Symbol agents (e.g. from a Ruby-injected config) should still pass —
  # AgentProfiles.registered? handles both symbols and strings.
  def test_load_accepts_symbol_stage_agent
    with_tmp_dir do |dir|
      cfg = Hive::Config.send(:merge_defaults, { "execute" => { "agent" => :claude } })
      cfg["project_root"] = dir
      Hive::Config.send(:validate!, cfg, "synthetic")
      assert_equal :claude, cfg.dig("execute", "agent")
    end
  end

  # Table-driven coverage so every key in HASH_SHAPED_KEYS — not just the
  # 3 we sampled in the original tests — is defended against scalar
  # overrides. A future refactor that subsetted the constant (e.g.
  # conditionalised the check per-key) would otherwise pass tests while
  # silently letting `agents: claude` or `review: foo` bypass validation.
  def test_load_rejects_scalar_override_on_every_hash_shaped_key
    Hive::Config::HASH_SHAPED_KEYS.each do |key|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "#{key}: scalar-value\n")
        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_match(/#{key}.*must be a Hash/, err.message,
                     "HASH_SHAPED_KEYS member #{key.inspect} must reject scalar overrides")
      end
    end
  end

  # Table-driven coverage for the type-check in validate_agent_name!.
  # Every path in ROLE_AGENT_PATHS — including all four review.* paths —
  # must reject non-String/non-Symbol values with ConfigError, not crash
  # with NoMethodError on `name.to_sym`.
  def test_load_rejects_non_string_agent_value_on_every_role_agent_path
    Hive::Config::ROLE_AGENT_PATHS.each do |path|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        # Build a nested YAML hash matching the path with the leaf as
        # an Integer (the canonical NoMethodError trigger for to_sym).
        yaml = path.reverse.reduce(42) { |acc, key| { key => acc } }.to_yaml
        File.write(File.join(dir, ".hive-state", "config.yml"), yaml)
        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        label = path.join(".")
        assert_match(/#{Regexp.escape(label)}.*must be a String/, err.message,
                     "#{label} must reject Integer agent values with ConfigError, not crash on to_sym")
      end
    end
  end

  # Boolean is the documented crash class in validate_agent_name!'s
  # comment but isn't exercised anywhere else. Pin it explicitly.
  def test_load_rejects_boolean_agent_value
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            agent: true
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.agent.*must be a String/, err.message)
    end
  end

  def test_register_and_lookup_project
    with_tmp_global_config do |home|
      Hive::Config.register_project(name: "foo", path: "/tmp/foo")
      Hive::Config.register_project(name: "bar", path: "/tmp/bar")
      projects = Hive::Config.registered_projects
      assert_equal 2, projects.size, "two projects should be registered"
      assert_equal "/tmp/foo", projects.first["path"]
      assert Hive::Config.find_project("bar"), "find_project should locate registered project by name"
      refute Hive::Config.find_project("missing"), "find_project should return nil for unknown project"
      assert File.exist?(File.join(home, "config.yml"))
    end
  end

  def test_register_project_replaces_existing_by_name
    with_tmp_global_config do
      Hive::Config.register_project(name: "foo", path: "/tmp/old")
      Hive::Config.register_project(name: "foo", path: "/tmp/new")
      projects = Hive::Config.registered_projects
      assert_equal 1, projects.size
      assert_equal "/tmp/new", projects.first["path"]
    end
  end

  def test_load_raises_on_non_hash_yaml
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "- a\n- b\n")
      assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
    end
  end

  # --- Deep-merge semantics (closes doc-review F3) -----------------------

  def test_deep_merge_keeps_siblings_at_three_levels_nested
    # Pre-U2 bug: a partial override at review.ci.command would wipe every
    # other key under review.ci. The recursive deep-merge keeps siblings.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            command: bin/ci
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "bin/ci", cfg.dig("review", "ci", "command")
      assert_equal 3,        cfg.dig("review", "ci", "max_attempts"), "max_attempts must fall back to default"
      assert_equal "claude", cfg.dig("review", "ci", "agent"),        "agent must fall back to default"
      assert_equal "ci_fix_prompt.md.erb", cfg.dig("review", "ci", "prompt_template")
      # Other sibling blocks at review.* must also stay intact.
      assert_equal "courageous", cfg.dig("review", "triage", "bias")
      assert_equal 2,            cfg.dig("review", "max_passes")
    end
  end

  def test_deep_merge_partial_triage_override_keeps_other_triage_defaults
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            bias: safetyist
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "safetyist", cfg.dig("review", "triage", "bias")
      assert_equal "claude",    cfg.dig("review", "triage", "agent"),   "agent default must persist"
      assert_equal true,        cfg.dig("review", "triage", "enabled"), "enabled default must persist"
    end
  end

  def test_deep_merge_partial_agents_override_keeps_other_profiles
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        agents:
          codex:
            min_version: "0.5.0"
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "0.5.0", cfg.dig("agents", "codex", "min_version")
      assert_equal "codex", cfg.dig("agents", "codex", "bin"),          "codex.bin default must persist"
      assert_equal "claude", cfg.dig("agents", "claude", "bin"),        "claude profile must stay intact"
      assert_equal "pi", cfg.dig("agents", "pi", "bin"),                "pi profile must stay intact"
    end
  end

  def test_review_reviewers_replaces_wholesale_not_per_element
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: only-one
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: only-one
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      cfg = Hive::Config.load(dir)
      reviewers = cfg.dig("review", "reviewers")
      assert_equal 1, reviewers.size
      assert_equal "only-one", reviewers.first["name"]
    end
  end

  # --- Validation --------------------------------------------------------

  def test_load_raises_when_reviewers_is_not_an_array
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            this: is_a_hash_not_an_array
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers/, err.message)
      assert_match(/must be an Array/, err.message)
    end
  end

  def test_load_raises_on_duplicate_reviewer_name
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: dup-reviewer
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: a
              prompt_template: reviewer_claude_ce_code_review.md.erb
            - name: dup-reviewer
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: b
              prompt_template: reviewer_codex_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate name "dup-reviewer"/, err.message)
    end
  end

  def test_load_raises_on_duplicate_output_basename
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: a
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: collision
              prompt_template: reviewer_claude_ce_code_review.md.erb
            - name: b
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: collision
              prompt_template: reviewer_codex_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate output_basename "collision"/, err.message)
    end
  end

  # ce-review P2 #6 — output_basename starting with a reserved
  # orchestrator prefix would silently have its per-pass file (e.g.
  # `errors-01.md`) classified as orchestrator-owned by
  # `Hive::Stages::Review.reviewer_file?`, hidden from triage's
  # `discover_reviewer_files`, and (for `output_basename: "errors"`
  # specifically) overwritten by the U2 errors sink.
  def test_load_raises_when_output_basename_collides_with_reserved_prefix
    %w[errors escalations fix-guardrail fix-success browser ci-blocked].each do |reserved|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          review:
            reviewers:
              - name: bad
                kind: agent
                agent: claude
                skill: ce-code-review
                output_basename: #{reserved}
                prompt_template: reviewer_claude_ce_code_review.md.erb
        YAML
        err = assert_raises(Hive::ConfigError, "output_basename #{reserved.inspect} must be rejected") do
          Hive::Config.load(dir)
        end
        assert_match(/output_basename .* reserved orchestrator-owned prefix/, err.message,
                     "error message must explain why #{reserved.inspect} was rejected")
      end
    end
  end

  # ce-review P3 #8 — max_attempts is parsed by the adapter at spawn
  # time but should also fail loudly at config-load when malformed,
  # so operators don't discover a typo deep in a 5-review pass.
  def test_load_raises_when_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  def test_load_raises_when_max_attempts_is_negative
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  def test_load_raises_when_max_attempts_is_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: "two"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  # ce-review round-3 P1 #2 — output_basename containing path
  # separators or `.`/`..` flows into `reviews/<basename>-NN.md` and
  # the retry-loop cleanup `File.delete(output_path)` could then
  # delete files outside the reviews/ dir.
  def test_load_raises_when_output_basename_contains_path_separator
    %w[../escape foo/bar foo\\bar . .. \0nul].each do |bad|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          review:
            reviewers:
              - name: bad
                kind: agent
                agent: claude
                skill: ce-code-review
                output_basename: #{bad.inspect}
                prompt_template: reviewer_claude_ce_code_review.md.erb
        YAML
        err = assert_raises(Hive::ConfigError, "output_basename #{bad.inspect} must be rejected") do
          Hive::Config.load(dir)
        end
        assert_match(/single filename component|path separators|'\.\.'|'\.'/, err.message,
                     "error message must explain why #{bad.inspect} was rejected")
      end
    end
  end

  def test_load_accepts_max_attempts_one_and_three
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: a
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: a
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: 1
            - name: b
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: b
              prompt_template: reviewer_codex_ce_code_review.md.erb
              max_attempts: 3
      YAML
      assert Hive::Config.load(dir),
             "positive Integer max_attempts (1, 3) must load cleanly"
    end
  end

  def test_load_raises_when_role_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            agent: nonexistent_profile
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.triage\.agent "nonexistent_profile"/, err.message)
      assert_match(/not a registered AgentProfile/, err.message)
    end
  end

  # ── Required fields on each reviewer entry (closes AC-6) ───────────────
  # validate_reviewers! must reject missing name / skill / prompt_template
  # at config-load time; otherwise a misconfigured reviewer NoMethodError-s
  # mid-spawn instead of raising Hive::ConfigError at `hive run` startup.

  def test_load_raises_when_reviewer_name_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: bad
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.name/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_skill_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: needs-skill
              kind: agent
              agent: claude
              output_basename: needs-skill
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.skill/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_prompt_template_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: needs-template
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: needs-template
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.prompt_template/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_skill_is_blank_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: blank-skill
              kind: agent
              agent: claude
              skill: "   "
              output_basename: blank-skill
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.skill/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad-reviewer
              kind: agent
              agent: nonexistent_profile
              skill: ce-code-review
              output_basename: bad-reviewer
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.agent "nonexistent_profile"/, err.message)
    end
  end

  def test_load_raises_when_reviewers_key_is_nil
    # User typed `reviewers:` with no value — YAML parses to nil. Without
    # this guard the early-return swallowed the typo and downstream code
    # NoMethodError'd on .each. Closes ce-code-review #12.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers/, err.message)
      assert_match(/is nil/, err.message)
    end
  end

  def test_load_raises_on_empty_output_basename
    # output_basename: "" would yield reviews/-NN.md filenames. Closes
    # ce-code-review #11.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: empty-basename
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ""
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/output_basename/, err.message)
      assert_match(/must not be empty/, err.message)
    end
  end

  def test_load_raises_on_whitespace_only_output_basename
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: ws-basename
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: "   "
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/output_basename/, err.message)
      assert_match(/must not be empty/, err.message)
    end
  end

  def test_validation_error_message_notes_when_no_config_file_present
    # When there is no config.yml on disk, validation errors mentioning
    # the source path should call that out so the user isn't sent to a
    # phantom file. Closes ce-code-review #13.
    #
    # Reproducing the no-file-present validation failure requires the
    # defaults to themselves fail validation, which they don't by design
    # (only user input fails validation). So we exercise the
    # `describe_source` helper indirectly by registering a tampered
    # claude profile name and writing a config that picks an unknown
    # agent — but the source_path describe applies regardless.
    #
    # Direct unit test of the helper:
    msg = Hive::Config.send(:describe_source, "/no/such/file.yml")
    assert_match %r{/no/such/file\.yml \(defaults; no file present\)}, msg
    # When the file does exist, no annotation:
    Tempfile.create([ "config", ".yml" ]) do |f|
      f.write("---\n")
      f.flush
      assert_equal f.path, Hive::Config.send(:describe_source, f.path)
    end
  end

  # --- Positive-integer review knobs --------------------------------------
  # 0 / negative / non-integer values yield degenerate runner behavior:
  #   review.ci.max_attempts: 0           → CiFix runs once and bails
  #   review.browser_test.max_attempts: 0 → BrowserTest writes blocked.md without spawn
  #   review.max_passes: 0                → pass loop exits before Phase 2
  #   review.max_wall_clock_sec: 0        → wall_clock_exceeded? trips immediately
  # Validation catches each at config-load time so misconfig fails at
  # `hive run` startup, not silently mid-loop.

  def test_load_raises_when_review_ci_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
      assert_match(/positive integer/, err.message)
    end
  end

  def test_load_raises_when_review_ci_max_attempts_is_negative
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_ci_max_attempts_is_non_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 1.5
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_browser_test_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          browser_test:
            max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.browser_test\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_max_passes_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          max_passes: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.max_passes/, err.message)
    end
  end

  def test_load_raises_when_review_max_wall_clock_sec_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          max_wall_clock_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.max_wall_clock_sec/, err.message)
    end
  end

  def test_load_accepts_review_knobs_at_default_positive_values
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 5
          browser_test:
            max_attempts: 3
          max_passes: 6
          max_wall_clock_sec: 7200
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 5, cfg.dig("review", "ci", "max_attempts")
      assert_equal 3, cfg.dig("review", "browser_test", "max_attempts")
      assert_equal 6, cfg.dig("review", "max_passes")
      assert_equal 7200, cfg.dig("review", "max_wall_clock_sec")
    end
  end

  # --- New defaults present ----------------------------------------------

  def test_new_review_defaults_are_present
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 3,         cfg.dig("review", "ci", "max_attempts")
      assert_equal "claude",  cfg.dig("review", "ci", "agent")
      assert_equal "courageous", cfg.dig("review", "triage", "bias")
      assert_equal false,     cfg.dig("review", "browser_test", "enabled")
      assert_equal 2,         cfg.dig("review", "max_passes")
      assert_equal 5400,      cfg.dig("review", "max_wall_clock_sec")
      assert_equal "claude",  cfg.dig("agents", "claude", "bin")
      assert_equal "codex",   cfg.dig("agents", "codex", "bin")
      assert_equal "pi",      cfg.dig("agents", "pi", "bin")
    end
  end

  # --- HIVE_HOME explicit-but-nonexistent validation --------------------
  # Silent `[]` on a typo'd HIVE_HOME hid the misconfiguration and made
  # `hive status --json | jq .ok` falsely report `true`. The validation
  # fires only when ENV["HIVE_HOME"] is explicitly set AND the directory
  # doesn't exist — the default path (env unset) and the legitimate
  # first-install state (dir exists, no config.yml yet) must continue to
  # work without raising.

  def test_registered_projects_raises_when_hive_home_explicitly_nonexistent
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-test-definitely-does-not-exist-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
    assert_match(/HIVE_HOME is set to a path that does not exist/, err.message)
    assert_includes err.message, ENV["HIVE_HOME"]
  ensure
    ENV["HIVE_HOME"] = prev
  end

  def test_registered_projects_returns_empty_when_hive_home_unset
    prev = ENV["HIVE_HOME"]
    ENV.delete("HIVE_HOME")
    # Default ~/Dev/hive may or may not have a config.yml; what matters is
    # that the validation doesn't fire and the call returns an Array. Stub
    # global_config_path to a guaranteed-missing file so we exercise the
    # "no config.yml" branch deterministically.
    Hive::Config.singleton_class.alias_method(:__orig_global_config_path, :global_config_path)
    Hive::Config.define_singleton_method(:global_config_path) { "/nonexistent-#{rand(1_000_000)}/config.yml" }
    begin
      assert_equal [], Hive::Config.registered_projects
    ensure
      Hive::Config.singleton_class.alias_method(:global_config_path, :__orig_global_config_path)
      Hive::Config.singleton_class.send(:remove_method, :__orig_global_config_path)
      ENV["HIVE_HOME"] = prev
    end
  end

  def test_registered_projects_returns_empty_when_hive_home_dir_exists_but_no_config
    Dir.mktmpdir("hive-empty-home") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        assert_equal [], Hive::Config.registered_projects,
                     "directory exists but no config.yml is the legitimate fresh-install state"
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_register_project_still_works_on_first_call_with_fresh_hive_home
    # `register_project` must continue to lazy-create config.yml on first
    # use even though `registered_projects` now validates HIVE_HOME. The
    # validation guards READ paths only; register_project does its own
    # mkdir_p and reads the YAML file directly without going through
    # registered_projects.
    Dir.mktmpdir("hive-fresh-home") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        entry = Hive::Config.register_project(name: "first", path: "/tmp/first")
        assert_equal "first", entry["name"]
        assert File.exist?(File.join(dir, "config.yml")),
               "register_project must lazy-create config.yml on first use"
        # registered_projects after registration still works (directory now
        # exists AND config.yml is now there).
        projects = Hive::Config.registered_projects
        assert_equal 1, projects.size
        assert_equal "first", projects.first["name"]
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_unregister_project_removes_named_entry_and_returns_it
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      removed = Hive::Config.unregister_project(name: "drop")
      assert_equal "drop", removed["name"]
      assert_equal "/tmp/drop", removed["path"]

      remaining = Hive::Config.registered_projects.map { |p| p["name"] }
      assert_equal [ "keep" ], remaining
    end
  end

  def test_unregister_project_returns_nil_for_unknown_name
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      assert_nil Hive::Config.unregister_project(name: "ghost"),
                 "unregister_project must return nil for an unknown name (idempotent inverse of register)"
      assert_equal 1, Hive::Config.registered_projects.size,
                   "config must be untouched when no entry matched"
    end
  end

  def test_unregister_project_returns_nil_when_no_global_config_file
    Dir.mktmpdir("hive-no-config") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        assert_nil Hive::Config.unregister_project(name: "anything")
        refute File.exist?(File.join(dir, "config.yml")),
               "unregister must not lazy-create config.yml when there's nothing to remove"
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_prune_missing_projects_drops_entries_whose_path_is_gone
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")
        Hive::Config.register_project(name: "dead2", path: "/tmp/hive-prune-#{rand(1_000_000)}-also-gone")

        result = Hive::Config.prune_missing_projects!
        names = result.fetch(:removed).map { |e| e["name"] }.sort
        assert_equal [ "dead", "dead2" ], names
        assert_equal 1, result.fetch(:kept_count),
                     "kept_count must reflect rows surviving the prune"

        kept = Hive::Config.registered_projects.map { |p| p["name"] }
        assert_equal [ "live" ], kept
      end
    end
  end

  def test_prune_missing_projects_dry_run_returns_targets_without_writing
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")

        before = File.read(File.join(home, "config.yml"))
        result = Hive::Config.prune_missing_projects!(dry_run: true)
        after = File.read(File.join(home, "config.yml"))

        assert_equal [ "dead" ], result.fetch(:removed).map { |e| e["name"] }
        assert_equal 1, result.fetch(:kept_count)
        assert_equal before, after, "dry-run must not rewrite config.yml"
        assert_equal 2, Hive::Config.registered_projects.size,
                     "registry must still contain both entries after a dry-run"
      end
    end
  end

  def test_prune_missing_projects_returns_empty_removed_when_all_paths_exist
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-1") do |a|
        Dir.mktmpdir("hive-live-2") do |b|
          Hive::Config.register_project(name: "a", path: a)
          Hive::Config.register_project(name: "b", path: b)
          result = Hive::Config.prune_missing_projects!
          assert_empty result.fetch(:removed),
                       "no rows should be dropped when every path exists"
          assert_equal 2, result.fetch(:kept_count)
          assert_equal 2, Hive::Config.registered_projects.size
        end
      end
    end
  end

  # Regression for the P0 Array#- subtraction bug: two registry rows
  # with identical content (same name + same path) used to be both
  # deleted by `entries - [removed]` because Array# uses Hash#==
  # equality. Index-based delete removes exactly the row at the matched
  # index. We can't reach this state via register_project (which dedups
  # by name) but a hand-edited config.yml or a write race can produce
  # it, and the loader's tolerance for malformed rows means it survives
  # to runtime.
  def test_unregister_project_with_identical_duplicate_entries_removes_only_one
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "dup", "path" => "/tmp/hive-dup", "hive_state_path" => "/tmp/hive-dup/.hive-state" },
            { "name" => "dup", "path" => "/tmp/hive-dup", "hive_state_path" => "/tmp/hive-dup/.hive-state" }
          ]
        }.to_yaml
      )

      removed = Hive::Config.unregister_project(name: "dup")
      refute_nil removed
      assert_equal "dup", removed["name"]

      remaining = YAML.safe_load(File.read(File.join(home, "config.yml")))["registered_projects"]
      assert_equal 1, remaining.size,
                   "Array#- subtraction would have cleared both identical rows; index-based delete must keep one"
      assert_equal "dup", remaining.first["name"]
    end
  end

  # Loader tolerance: a hand-edited row (non-Hash, missing path, nil
  # path) used to crash `registered_projects` and brick every command.
  # Now the loader skips invalid rows so the rest of the surface stays
  # usable; `hive prune` operates below the loader and drops them.
  def test_registered_projects_skips_malformed_rows_instead_of_raising
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "good", "path" => "/tmp/hive-good" },
            "not-a-hash",
            { "name" => "missing-path" },
            { "name" => nil, "path" => "/tmp/hive-anon" },
            { "name" => "nil-path", "path" => nil }
          ]
        }.to_yaml
      )

      assert_equal [ "good" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_prune_drops_malformed_rows_and_reports_them
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live") do |live_dir|
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              { "name" => "live", "path" => live_dir, "hive_state_path" => File.join(live_dir, ".hive-state") },
              "not-a-hash",
              { "name" => "missing-path" }
            ]
          }.to_yaml
        )

        result = Hive::Config.prune_missing_projects!
        assert_equal 2, result.fetch(:removed).size,
                     "the non-Hash row and the missing-path row must both be dropped"
        assert_equal 1, result.fetch(:kept_count)
      end
    end
  end

  # Psych::SyntaxError on malformed YAML used to leak as InternalError
  # (exit 70) — schemas promise exit 78 (CONFIG) for "bad config".
  def test_registered_projects_rewraps_psych_syntax_error_as_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects: [\nthis: is: not: yaml")

      err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
      assert_match(/not valid YAML/, err.message)
    end
  end

  # NEW-1: unregister_project must validate $HIVE_HOME first so a typoed
  # env var surfaces as ConfigError (exit 78), not as a missing-name
  # USAGE error (exit 64) that masks the real problem.
  def test_unregister_project_validates_hive_home_when_explicitly_missing
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-does-not-exist-#{Process.pid}-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.unregister_project(name: "anything") }
    assert_match(/HIVE_HOME/, err.message)
  ensure
    ENV["HIVE_HOME"] = prev
  end

  def test_prune_missing_projects_validates_hive_home_when_explicitly_missing
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-does-not-exist-#{Process.pid}-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.prune_missing_projects! }
    assert_match(/HIVE_HOME/, err.message)
  ensure
    ENV["HIVE_HOME"] = prev
  end

  # P3 #21: a hand-edited row with `name: 42` (Integer) used to be
  # invisible to `hive forget 42` because String != Integer, but the
  # TUI X-key (which compared name-strings end-to-end) could drop it.
  # Stringify both sides so the two surfaces stay in sync.
  def test_unregister_project_matches_integer_named_entry_via_string_coercion
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => 42, "path" => "/tmp/hive-int", "hive_state_path" => "/tmp/hive-int/.hive-state" }
          ]
        }.to_yaml
      )

      removed = Hive::Config.unregister_project(name: "42")
      refute_nil removed, "Integer name must be reachable via the String passed by the CLI"
      assert_equal 42, removed["name"]
    end
  end

  # P3 #22: EACCES on the config file used to surface as
  # `internal error: Errno::EACCES: ...` at exit 70. Now: ConfigError
  # (exit 78) — the root cause is a configuration-access problem, not
  # a Hive bug.
  def test_load_global_config_rewraps_eacces_as_config_error
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      File.chmod(0o000, path)

      err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
      assert_match(/not readable/, err.message)
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  # P3 #22 (write half): ENOSPC / EACCES on the config write surface
  # as ConfigError, not InternalError. This mirrors the read-side
  # classification so an agent's error envelope is consistent across
  # the two failure paths.
  def test_write_global_config_rewraps_eacces_as_config_error
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      File.chmod(0o400, path) # read-only

      err = assert_raises(Hive::ConfigError) do
        Hive::Config.send(:write_global_config!, { "registered_projects" => [ { "name" => "x", "path" => "/tmp/x" } ] })
      end
      assert_match(/could not be written/, err.message)
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  # ── ADR-024: daemon settings ──────────────────────────────────────────

  # Per-project default `daemon.enabled` is `false` so legacy projects
  # whose YAML predates the `daemon:` block don't silently flip on. Same
  # pattern ADR-023 used for stage agents.
  def test_load_returns_default_daemon_disabled_when_key_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal false, cfg.dig("daemon", "enabled"),
                   "legacy projects without daemon: key must default to disabled"
    end
  end

  def test_load_returns_documented_daemon_numeric_defaults
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 30,    cfg.dig("daemon", "poll_interval_sec")
      assert_equal 30,    cfg.dig("daemon", "edit_debounce_sec")
      assert_equal 300,   cfg.dig("daemon", "pr_merge_poll_interval_sec")
      assert_equal 5,     cfg.dig("daemon", "max_concurrent_runs")
      assert_equal 5,     cfg.dig("daemon", "max_concurrent_per_project")
      assert_equal 50,    cfg.dig("daemon", "max_runs_per_day_per_project")
      assert_equal 60,    cfg.dig("daemon", "transient_retry_backoff_sec")
      assert_equal 600,   cfg.dig("daemon", "shutdown_grace_sec")
    end
  end

  def test_load_honors_per_project_daemon_enabled_true
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: true
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("daemon", "enabled")
      # Other daemon defaults should still come from DEFAULTS via deep-merge.
      assert_equal 30, cfg.dig("daemon", "poll_interval_sec")
    end
  end

  def test_load_honors_per_project_daemon_partial_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: true
          poll_interval_sec: 15
          max_concurrent_runs: 8
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("daemon", "enabled")
      assert_equal 15,   cfg.dig("daemon", "poll_interval_sec")
      assert_equal 8,    cfg.dig("daemon", "max_concurrent_runs")
      # Unspecified keys still fall back to defaults via deep-merge.
      assert_equal 50,   cfg.dig("daemon", "max_runs_per_day_per_project")
    end
  end

  def test_load_rejects_non_boolean_daemon_enabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: "yes"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.enabled.*must be a boolean/, err.message)
    end
  end

  def test_load_rejects_too_small_daemon_poll_interval
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          poll_interval_sec: 2
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.poll_interval_sec.*>= 5/, err.message)
    end
  end

  def test_load_rejects_too_small_pr_merge_poll_interval
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          pr_merge_poll_interval_sec: 30
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.pr_merge_poll_interval_sec.*>= 60/, err.message)
    end
  end

  def test_load_rejects_zero_max_concurrent_runs
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          max_concurrent_runs: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.max_concurrent_runs.*>= 1/, err.message)
    end
  end

  def test_load_rejects_negative_edit_debounce
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          edit_debounce_sec: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.edit_debounce_sec.*>= 0/, err.message)
    end
  end

  def test_load_accepts_zero_edit_debounce
    # 0 is a valid choice (operator wants instant dispatch on first
    # mtime move, no debounce window).
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          edit_debounce_sec: 0
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 0, cfg.dig("daemon", "edit_debounce_sec")
    end
  end

  def test_load_rejects_non_hash_daemon_section
    # daemon: enabled    (scalar; user forgot the nested mapping)
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.*must be a Hash/, err.message)
    end
  end

  # PR-40 review P1 #2: load_global_daemon merges the operator's
  # ~/Dev/hive/config.yml `daemon:` overrides over Config::DEFAULTS,
  # so `hive daemon start` actually honours configured caps.

  def test_load_global_daemon_returns_defaults_when_no_global_config
    with_tmp_global_config do |home|
      # Default with_tmp_global_config writes an empty registered_projects.
      # With no `daemon:` block in the global yaml, defaults flow through.
      File.write(File.join(home, "config.yml"), { "registered_projects" => [] }.to_yaml)
      cfg = Hive::Config.load_global_daemon
      assert_equal 30, cfg["poll_interval_sec"]
      assert_equal 5, cfg["max_concurrent_runs"]
      assert_equal 5, cfg["max_concurrent_per_project"]
      assert_equal 50, cfg["max_runs_per_day_per_project"]
    end
  end

  def test_load_global_daemon_honors_global_config_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon:
          poll_interval_sec: 60
          max_concurrent_runs: 8
          log_max_bytes: 524288
      YAML
      cfg = Hive::Config.load_global_daemon
      assert_equal 60,     cfg["poll_interval_sec"]
      assert_equal 8,      cfg["max_concurrent_runs"]
      assert_equal 524_288, cfg["log_max_bytes"]
      # Unspecified keys still pull from defaults
      assert_equal 50, cfg["max_runs_per_day_per_project"]
      assert_equal 5,  cfg["max_concurrent_per_project"]
    end
  end

  def test_load_global_daemon_validates_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon:
          poll_interval_sec: 1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
      assert_match(/daemon.poll_interval_sec.*>= 5/, err.message)
    end
  end

  def test_load_global_daemon_rejects_non_hash_daemon_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
      assert_match(/daemon.*must be a Hash/, err.message)
    end
  end

  def test_load_global_daemon_falls_back_to_defaults_when_no_file
    # No ~/Dev/hive/config.yml at all (first-run before any project
    # was registered): return bare DEFAULTS["daemon"] without raising.
    Dir.mktmpdir do |dir|
      old = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      cfg = Hive::Config.load_global_daemon
      assert_equal 30, cfg["poll_interval_sec"]
    ensure
      ENV["HIVE_HOME"] = old
    end
  end

  # ---- Auto-rebase `rebase:` block (plan
  # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md U5) ----

  def test_rebase_defaults_when_block_absent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "")
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("rebase", "enabled")
      assert_equal 2700, cfg.dig("rebase", "conflict_resolution_timeout_sec")
    end
  end

  def test_rebase_enabled_false_override_is_respected
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          enabled: false
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal false, cfg.dig("rebase", "enabled")
      assert_equal 2700, cfg.dig("rebase", "conflict_resolution_timeout_sec"),
                   "other keys keep their defaults when only `enabled` is overridden"
    end
  end

  def test_rebase_timeout_override_is_respected
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: 600
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 600, cfg.dig("rebase", "conflict_resolution_timeout_sec")
    end
  end

  def test_rebase_enabled_must_be_boolean
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          enabled: "yes"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/rebase\.enabled.*must be a boolean/, err.message)
    end
  end

  def test_rebase_timeout_must_be_positive_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/conflict_resolution_timeout_sec.*must be an integer >= 60/, err.message)
    end
  end

  def test_rebase_timeout_must_be_integer_not_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: "five"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/conflict_resolution_timeout_sec.*must be an integer/, err.message)
    end
  end

  def test_rebase_block_must_be_hash_shaped
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase: true
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/rebase.*must be a Hash/, err.message)
    end
  end
end
