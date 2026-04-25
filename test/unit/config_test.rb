require "test_helper"
require "hive/config"

class ConfigTest < Minitest::Test
  include HiveTestHelper

  def test_load_returns_defaults_when_no_config_file
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 4, cfg["max_review_passes"]
      assert_equal 10, cfg["budget_usd"]["brainstorm"]
      assert_equal 100, cfg["budget_usd"]["execute_implementation"]
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
      assert_equal 20, cfg["budget_usd"]["brainstorm"]
      assert_equal 20, cfg["budget_usd"]["plan"], "plan budget should fall back to default"
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
      assert_equal 4,            cfg.dig("review", "max_passes")
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
            - name: dup-reviewer
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: b
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
            - name: b
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: collision
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate output_basename "collision"/, err.message)
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

  # --- New defaults present ----------------------------------------------

  def test_new_review_defaults_are_present
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 3,         cfg.dig("review", "ci", "max_attempts")
      assert_equal "claude",  cfg.dig("review", "ci", "agent")
      assert_equal "courageous", cfg.dig("review", "triage", "bias")
      assert_equal false,     cfg.dig("review", "browser_test", "enabled")
      assert_equal 4,         cfg.dig("review", "max_passes")
      assert_equal 5400,      cfg.dig("review", "max_wall_clock_sec")
      assert_equal "claude",  cfg.dig("agents", "claude", "bin")
      assert_equal "codex",   cfg.dig("agents", "codex", "bin")
      assert_equal "pi",      cfg.dig("agents", "pi", "bin")
    end
  end
end
