require "test_helper"
require "stringio"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "hive/commands/doctor"
require "hive/agent_support/pi"
require "hive/agent_skills/inspector"
require "hive/agent_skills/target_resolver"

class HiveCommandsDoctorTest < Minitest::Test
  include HiveTestHelper

  class ResolutionOnlyInspector
    def initialize(config:, project_root:)
      @config = config
      @project_root = project_root
    end

    def inspect
      Hive::AgentSkills::TargetResolver.new(config: @config, project_root: @project_root).resolve
        .reject { |target| target.capability_id == "hive" }.map do |target|
        if target.kind == "linter" || target.kind == "codex_review"
          health = "healthy"
          message = "kind '#{target.kind}' is not 'agent'; doctor only checks agent-kind reviewers"
          resolution = { "status" => "not_applicable", "path" => nil }
        else
          resolver = case target.agent
          when "claude" then Hive::AgentSupport.for(:claude)::Skills
          when "codex" then Hive::AgentSupport.for(:codex)::Skills
          when "pi" then Hive::AgentSupport::Pi::Skills
          end
          found = resolver.resolve(target.invocation, project_root: @project_root)
          health = found.status == :present ? "healthy" : "missing"
          message = found.message
          resolution = { "status" => found.status.to_s, "path" => found.path }
        end
        Hive::AgentSkills::Inspection.new(
          target: target, expected: {}, native: { "available" => true },
          resolution: resolution, health: health,
          severity: health == "healthy" ? "info" : "error",
          explanation: message, remediation: target.managed ? "hive setup-agents --agent #{target.agent} --skill #{target.capability_id}" : "manual"
        )
      end
    end
  end

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      original_inspector_new = Hive::AgentSkills::Inspector.method(:new)
      ENV["HOME"] = dir
      Hive::AgentSkills::Inspector.define_singleton_method(:new) do |config:, project_root:, **|
        ResolutionOnlyInspector.new(config: config, project_root: project_root)
      end
      yield dir
    ensure
      Hive::AgentSkills::Inspector.define_singleton_method(:new, original_inspector_new) if original_inspector_new
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
    end
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def base_config(overrides = {})
    {
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" }
    }.merge(overrides) { |_k, a, b| a.merge(b) }
  end

  def test_exit_success_when_all_present
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/compound-engineering:ce-brainstorm" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(/✓ present/, out.string)
      refute_match(/✗ missing/, out.string)
    end
  end

  def test_runtime_probe_recommends_current_runtime_setup
    with_tmp_dir do |root|
      File.binwrite(Hive::Paths.runtime_control_plane_path(root), "placeholder")
      previous = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = root
      doctor = Hive::Commands::Doctor.new(
        config: base_config, project_root: root, inspector: ResolutionOnlyInspector.new(
          config: base_config, project_root: root
        )
      )
      status = { "phase" => "absent", "database" => { "status" => "missing" } }

      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::Installation, :status, ->(**) { status }
      ) do
        row = doctor.send(:check_runtime_control_plane).fetch(0)
        assert_equal(
          "run hive runtime status; use hive setup for a new installation",
          row.fetch(:remediation)
        )
        refute_match(/restore|rollback|downgrade/, row.values.compact.join(" "))
      end
    ensure
      previous.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = previous
    end
  end

  def test_runtime_probe_reports_control_plane_errors
    with_tmp_dir do |root|
      File.binwrite(Hive::Paths.runtime_control_plane_path(root), "placeholder")
      previous = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = root
      doctor = Hive::Commands::Doctor.new(
        config: base_config, project_root: root,
        inspector: ResolutionOnlyInspector.new(config: base_config, project_root: root)
      )
      error = Hive::RuntimeControlPlane::IntegrityError.new(
        "broken", code: :broken, action: "run hive setup"
      )

      with_replaced_singleton_method(Hive::RuntimeControlPlane::Installation, :status, ->(**) { raise error }) do
        row = doctor.send(:check_runtime_control_plane).fetch(0)
        assert_equal "missing", row.fetch(:status)
        assert_equal "broken: broken", row.fetch(:message)
      end
    ensure
      previous.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = previous
    end
  end

  def test_exit_missing_skill_when_one_missing
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md")
      # ce-brainstorm intentionally absent
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/compound-engineering:ce-brainstorm" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(/✗ missing/, out.string)
      assert_match(/claude plugin install/, out.string,
        "human-readable output must include the install hint for the missing one")
    end
  end

  def test_pi_stage_uses_profile_skill_format_and_resolves
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.pi/agent/skills/wiki-plan/SKILL.md")
      out = StringIO.new
      cfg = {
          "brainstorm" => { "agent" => "pi" },
        "plan" => { "agent" => "pi" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(%r{brainstorm.*pi.*/skill:ce-brainstorm.*✓ present}, out.string)
      assert_match(%r{plan.*pi.*/skill:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_pi_stage_missing_when_formatted_skill_absent
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
          "brainstorm" => { "agent" => "pi" },
        "plan" => { "agent" => "pi" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{plan.*pi.*/skill:wiki-plan.*✗ missing}, out.string)
    end
  end

  def test_codex_plan_stage_uses_llm_wiki_plugin_skill_by_default
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/mp/llm-wiki/0.1.7/skills/wiki-plan/SKILL.md")
      write_file("#{home}/.codex/plugins/cache/mp/compound-engineering/3.8.1/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
          "brainstorm" => { "agent" => "codex" },
        "plan" => { "agent" => "codex" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call

      assert_equal 0, exit_code
      assert_match(%r{plan.*codex.*/llm-wiki:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_codex_plan_stage_maps_legacy_plan_alias_to_llm_wiki
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/mp/llm-wiki/0.1.7/skills/wiki-plan/SKILL.md")
      write_file("#{home}/.codex/plugins/cache/mp/compound-engineering/3.8.1/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
          "brainstorm" => { "agent" => "codex" },
        "plan" => { "agent" => "codex", "skill" => "/plan" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call

      assert_equal 0, exit_code
      assert_match(%r{plan.*codex.*/llm-wiki:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_json_envelope_shape
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/missing-plug:missing-skill" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        json: true,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code

      env = JSON.parse(out.string)
      assert_equal "hive-doctor.v2", env["schema"]
      assert_equal 3, env["managed_skills"].length
      assert_equal 2, env.dig("summary", "managed", "missing")
      assert_equal 1, env.dig("summary", "managed", "healthy")
      assert(env["managed_skills"].any? { |c| c["stage"] == "plan" && c["health"] == "healthy" })
      assert(env["managed_skills"].any? { |c| c["stage"] == "brainstorm" && c["health"] == "missing" })
      assert(env["managed_skills"].any? do |row|
        row["stage"] == "prerequisite:llm-wiki" && row["health"] == "missing"
      end)
    end
  end

  def test_uses_config_defaults_when_skill_key_unset
    with_fake_home do |home|
      # No `skill:` key in config; doctor falls back to DEFAULTS
      # ("/ce-brainstorm" and Claude's "/plan").
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = {
          "brainstorm" => { "agent" => "claude" },
        "plan" => { "agent" => "claude" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(%r{/ce-brainstorm}, out.string)
      assert_match(%r{/plan}, out.string)
    end
  end

  def test_project_root_affects_claude_plain_invocation_resolution
    with_fake_home do |home|
      # No user-level claude /plan, but project-level present.
      with_tmp_dir do |project|
        write_file("#{home}/.claude/commands/x.md")
        write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
        write_file("#{project}/.claude/commands/plan.md")
        out = StringIO.new
        cfg = base_config(
          "brainstorm" => { "agent" => "claude", "skill" => "/x" }, # parked
          "plan" => { "agent" => "claude", "skill" => "/plan" }
        )
        exit_code = Hive::Commands::Doctor.new(
          config: cfg,
          project_root: project,
          output: out
        ).call
        assert_equal 0, exit_code, "project-level /plan should be detected"
        assert_match(/✓ present/, out.string)
      end
    end
  end

  def test_claude_auth_warns_when_api_key_env_is_exported
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      environment = ENV.to_h.merge("ANTHROPIC_API_KEY" => "test-key").except("CLAUDE_API_KEY")

      Hive::Commands::Doctor.new(
        config: base_config, project_root: nil, json: true, output: out, environment: environment
      ).call

      env = JSON.parse(out.string)
      assert_equal 0, env.fetch("summary").fetch("legacy_failures"),
                   "an exported key is a warning, not a failing check"
      assert_doctor_schema_valid(env)
      warnings = env.fetch("checks").select { |check| check["status"] == "warning" }
      assert_equal 1, warnings.length
      assert_equal 1, env.fetch("summary").fetch("warnings")
      warning = warnings.first
      assert_equal "claude/auth", warning.fetch("label")
      assert_equal "billing-auth", warning.fetch("configured_skill")
      assert_equal "ANTHROPIC_API_KEY", warning.fetch("skill")
      assert_match(/ANTHROPIC_API_KEY is exported.*Hive unsets it before launching Claude.*subscription/,
                   warning.fetch("message"))
      refute(env.fetch("checks").any? { |check| check["label"].to_s.include?("tmux") })
    end
  end

  def test_claude_auth_names_both_exported_keys_in_one_row
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      environment = { "ANTHROPIC_API_KEY" => "a", "CLAUDE_API_KEY" => "b", "HOME" => home }

      Hive::Commands::Doctor.new(
        config: base_config, project_root: nil, output: out, environment: environment
      ).call

      assert_match(%r{claude/auth.*ANTHROPIC_API_KEY and CLAUDE_API_KEY is exported}, out.string)
    end
  end

  def test_claude_auth_is_silent_without_exported_keys
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      environment = ENV.to_h.except("ANTHROPIC_API_KEY").merge("CLAUDE_API_KEY" => "")

      Hive::Commands::Doctor.new(
        config: base_config, project_root: nil, json: true, output: out, environment: environment
      ).call

      env = JSON.parse(out.string)
      assert_doctor_schema_valid(env)
      refute(env.fetch("checks").any? { |check| check["label"] == "claude/auth" })
      assert_equal 0, env.fetch("summary").fetch("warnings")
    end
  end

  def doctor_json_for_project_config(home, yaml)
    install_brainstorm_and_plan_skills(home)
    with_tmp_dir do |project|
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(File.join(project, ".hive-state", "config.yml"), yaml)
      out = StringIO.new
      environment = ENV.to_h.except("ANTHROPIC_API_KEY", "CLAUDE_API_KEY")
      exit_code = Hive::Commands::Doctor.new(
        config: Hive::Config.load(project), project_root: project, json: true, output: out,
        environment: environment
      ).call
      [ exit_code, JSON.parse(out.string) ]
    end
  end

  PARKED_STAGE_YAML = "brainstorm:\n  agent: claude\n  skill: /x\nplan:\n  agent: claude\n  skill: /x\n"

  def test_claude_config_warns_once_about_obsolete_claude_mode_key
    with_fake_home do |home|
      exit_code, env = doctor_json_for_project_config(home, "claude:\n  mode: tmux\n#{PARKED_STAGE_YAML}")

      assert_equal 0, exit_code, "an obsolete key is a warning, not a failing check"
      assert_doctor_schema_valid(env)
      rows = env.fetch("checks").select { |check| check["label"] == "claude/config" }
      assert_equal 1, rows.length
      row = rows.first
      assert_equal "warning", row.fetch("kind")
      assert_equal "warning", row.fetch("status")
      assert_equal "claude.mode", row.fetch("configured_skill")
      assert_match(/claude\.mode is obsolete.*headless.*delete the claude\.mode line/, row.fetch("message"))
      assert_equal 1, env.fetch("summary").fetch("warnings")
      assert_equal 0, env.fetch("summary").fetch("legacy_failures")
    end
  end

  def test_claude_config_is_silent_without_claude_mode_key
    with_fake_home do |home|
      exit_code, env = doctor_json_for_project_config(home, PARKED_STAGE_YAML)

      assert_equal 0, exit_code
      assert_doctor_schema_valid(env)
      refute(env.fetch("checks").any? { |check| check["label"] == "claude/config" })
      assert_equal 0, env.fetch("summary").fetch("warnings")
    end
  end

  def test_claude_config_warning_renders_in_text_table
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      cfg = cfg_with_reviewers([]).merge(Hive::Config::OBSOLETE_CLAUDE_MODE_KEY => true)

      exit_code = Hive::Commands::Doctor.new(
        config: cfg, project_root: nil, output: out,
        environment: { "HOME" => home }
      ).call

      assert_equal 0, exit_code
      assert_match(%r{claude/config}, out.string)
    end
  end

  def assert_doctor_schema_valid(payload)
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-doctor"))))
    errors = schema.validate(payload).map { |error| error.fetch("error") }
    assert_empty errors
  end

  def qmd_executable(path, body = 'printf "qmd 2.1.0\\n"')
    write_file(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def managed_qmd_path(data_home)
    File.join(data_home, "hive", "qmd", "bin", "qmd")
  end

  def find_qmd(environment)
    inspector = Object.new
    inspector.define_singleton_method(:inspect) { [] }
    Hive::Commands::Doctor.new(
      config: base_config, project_root: nil, inspector: inspector,
      environment: environment, mcp_discover: nil
    ).send(:find_qmd)
  end

  # Only this Ruby child inherits the test/coverage runtime. Doctor's QMD probe
  # gets the supplied environment, while host-driven checks see scratch state.
  def doctor_in_child(project_root: nil, environment: {}, host_environment: {}, json: false)
    parent_environment = ENV.to_h
    with_tmp_dir do |home|
      host = {
        "HOME" => home, "HIVE_HOME" => home,
        "HIVE_QMD_BIN" => nil, "PATH" => "", "XDG_DATA_HOME" => nil
      }.merge(host_environment)
      script = <<~'RUBY'
        require "json"
        require "stringio"
        require "hive/commands/doctor"
        input = JSON.parse(STDIN.read)
        inspector = Object.new
        inspector.define_singleton_method(:inspect) { [] }
        output = StringIO.new
        doctor = Hive::Commands::Doctor.new(
          config: input.fetch("config"), project_root: input["project_root"],
          environment: input.fetch("environment"), inspector: inspector,
          mcp_discover: nil, json: input.fetch("json"), output: output
        )
        before = ENV.to_h
        exit_code = doctor.call
        puts JSON.generate(
          exit_code: exit_code, rows: doctor.rows, output: output.string,
          environment_unchanged: before == ENV.to_h
        )
      RUBY
      out, err, status = Open3.capture3(
        host, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script,
        stdin_data: JSON.generate(config: base_config, project_root: project_root,
                                  environment: environment, json: json)
      )
      assert status.success?, "Doctor child failed: #{err}\n#{out}"
      result = JSON.parse(out)
      assert result.fetch("environment_unchanged"), "Doctor changed its process environment"
      assert_equal parent_environment, ENV.to_h
      result
    end
  end

  def assert_qmd_present(result, qmd, version = "qmd 2.1.0")
    assert_equal 0, result.fetch("exit_code"), result.fetch("output")
    row = result.fetch("rows").find { |entry| entry["label"] == "wiki/qmd" }
    assert_equal "dependency", row.fetch("kind")
    assert_equal "present", row.fetch("status")
    assert_equal "#{qmd} #{version}", row.fetch("message")
    assert_match(%r{wiki/qmd.*✓ present}, result.fetch("output"))
  end

  def test_qmd_discovery_precedence_and_override_fallthrough
    with_tmp_dir do |root|
      home = File.join(root, "home")
      data_home = File.join(root, "data")
      prefix = File.join(root, "prefix")
      home_qmd = qmd_executable(managed_qmd_path(File.join(home, ".local/share")))
      data_qmd = qmd_executable(managed_qmd_path(data_home))
      sidecar_qmd = qmd_executable(managed_qmd_path(prefix))
      write_file(File.join(data_home, "hive/install-prefix"), "  #{prefix}  \nignored\n")
      path_qmd = qmd_executable(File.join(root, "bin/qmd"))
      override = qmd_executable(File.join(root, "override"))
      environment = {
        "HIVE_QMD_BIN" => override, "PATH" => File.dirname(path_qmd),
        "HOME" => home, "XDG_DATA_HOME" => data_home
      }

      assert_equal override, find_qmd(environment)
      [ nil, "", File.join(root, "absent") ].each do |value|
        assert_equal path_qmd, find_qmd(environment.merge("HIVE_QMD_BIN" => value))
      end
      File.chmod(0o644, override)
      assert_equal path_qmd, find_qmd(environment)
      environment.delete("HIVE_QMD_BIN")
      assert_equal path_qmd, find_qmd(environment)
      [ nil, "" ].each do |value|
        assert_equal data_qmd, find_qmd(environment.merge("PATH" => value))
      end
      environment.delete("PATH")
      File.unlink(data_qmd)
      assert_equal home_qmd, find_qmd(environment), "HOME fallback precedes the sidecar"
      File.unlink(home_qmd)
      assert_equal sidecar_qmd, find_qmd(environment)
    end
  end

  def test_qmd_discovery_uses_only_nonempty_supplied_roots
    with_tmp_dir do |root|
      home = File.join(root, "home")
      data_home = File.join(root, "data")
      home_qmd = qmd_executable(managed_qmd_path(File.join(home, ".local/share")))
      data_qmd = qmd_executable(managed_qmd_path(data_home))
      [ {}, { "XDG_DATA_HOME" => "" } ].each do |values|
        assert_equal home_qmd, find_qmd(values.merge("HOME" => home))
      end
      [ {}, { "HOME" => "" } ].each do |values|
        environment = values.merge("XDG_DATA_HOME" => data_home)
        assert_equal data_qmd, find_qmd(environment)
      end
      File.unlink(data_qmd)
      prefix = File.join(root, "prefix")
      sidecar_qmd = qmd_executable(managed_qmd_path(prefix))
      write_file(File.join(data_home, "hive/install-prefix"), "#{prefix}\n")
      File.unlink(home_qmd)
      write_file(File.join(home, ".local/share/hive/install-prefix"), "#{prefix}\n")
      [ {}, { "XDG_DATA_HOME" => "" } ].each do |values|
        assert_equal sidecar_qmd, find_qmd(values.merge("HOME" => home))
      end
      [ {}, { "HOME" => "" } ].each do |values|
        assert_equal sidecar_qmd, find_qmd(values.merge("XDG_DATA_HOME" => data_home))
      end
      # A missing root must not accidentally form a relative managed candidate.
      qmd_executable(managed_qmd_path(File.join(root, ".local/share")))
      qmd_executable(managed_qmd_path(root))
      Dir.chdir(root) do
        [ {}, { "HOME" => "" }, { "XDG_DATA_HOME" => "" },
          { "HOME" => "", "XDG_DATA_HOME" => "" } ].each do |environment|
          assert_nil find_qmd(environment)
        end
      end
    end
  end

  def test_qmd_discovery_preserves_sidecar_first_line_and_candidate_eligibility
    with_tmp_dir do |root|
      data_home = File.join(root, "data")
      prefix = File.join(root, "prefix")
      qmd = qmd_executable(managed_qmd_path(prefix))
      sidecar = File.join(data_home, "hive/install-prefix")
      environment = { "XDG_DATA_HOME" => data_home }
      assert_nil find_qmd(environment)
      [ "", "\n#{prefix}\n", "  \n#{prefix}\n" ].each do |contents|
        write_file(sidecar, contents)
        assert_nil find_qmd(environment)
      end
      write_file(sidecar, "  #{prefix} \nignored\n")
      assert_equal qmd, find_qmd(environment)
      File.chmod(0o644, qmd)
      assert_nil find_qmd(environment)
      File.unlink(qmd)
      FileUtils.mkdir_p(qmd)
      assert_nil find_qmd(environment), "sidecar candidates must be regular files"
      data_qmd = qmd_executable(managed_qmd_path(data_home))
      File.chmod(0o644, data_qmd)
      assert_nil find_qmd(environment)
      File.unlink(data_qmd)
      FileUtils.mkdir_p(data_qmd)
      assert_nil find_qmd(environment), "managed candidates must be regular files"
      home = File.join(root, "home")
      home_qmd = qmd_executable(managed_qmd_path(File.join(home, ".local/share")))
      File.chmod(0o644, home_qmd)
      assert_nil find_qmd(environment.merge("HOME" => home))
      File.unlink(home_qmd)
      FileUtils.mkdir_p(home_qmd)
      assert_nil find_qmd(environment.merge("HOME" => home))
    end
  end

  def test_llm_wiki_qmd_uses_hive_managed_binary_when_not_on_path
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      data_home = File.join(root, "data")
      qmd = qmd_executable(managed_qmd_path(data_home))
      result = doctor_in_child(project_root: root, environment: { "XDG_DATA_HOME" => data_home })
      assert_qmd_present(result, qmd)
    end
  end

  def test_llm_wiki_qmd_uses_install_prefix_sidecar_binary
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      data_home = File.join(root, "data")
      prefix = File.join(root, "prefix")
      qmd = qmd_executable(managed_qmd_path(prefix))
      write_file(File.join(data_home, "hive/install-prefix"), "#{prefix}\n")
      result = doctor_in_child(project_root: root, environment: { "XDG_DATA_HOME" => data_home })
      assert_qmd_present(result, qmd)
    end
  end

  def test_llm_wiki_qmd_does_not_discover_host_candidates
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      home = File.join(root, "host-home")
      data_home = File.join(root, "host-data")
      override = qmd_executable(File.join(root, "override"))
      path_qmd = qmd_executable(File.join(root, "bin/qmd"))
      qmd_executable(managed_qmd_path(File.join(home, ".local/share")))
      qmd_executable(managed_qmd_path(data_home))
      prefix = File.join(root, "host-prefix")
      qmd_executable(managed_qmd_path(prefix))
      write_file(File.join(data_home, "hive/install-prefix"), "#{prefix}\n")
      hosts = [
        { "HIVE_QMD_BIN" => override }, { "PATH" => File.dirname(path_qmd) },
        { "HOME" => home }, { "XDG_DATA_HOME" => data_home }
      ]
      hosts.each do |host|
        [ {}, { "HOME" => "", "XDG_DATA_HOME" => "", "PATH" => "", "HIVE_QMD_BIN" => "" } ].each do |environment|
          result = doctor_in_child(project_root: root, environment: environment, host_environment: host)
          assert_equal 0, result.fetch("exit_code"), result.fetch("output")
          row = result.fetch("rows").find { |entry| entry["label"] == "wiki/qmd" }
          assert_equal "warning", row.fetch("status")
          assert_includes row.fetch("message"), "qmd is not installed or not discoverable"
        end
      end
      File.unlink(managed_qmd_path(data_home))
      result = doctor_in_child(project_root: root, environment: { "PATH" => "" },
                               host_environment: { "XDG_DATA_HOME" => data_home })
      assert_includes result.fetch("output"), "qmd is not installed or not discoverable"
    end
  end

  def test_llm_wiki_qmd_directory_override_warns_instead_of_falling_through
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      override = File.join(root, "override")
      FileUtils.mkdir_p(override)
      qmd = qmd_executable(File.join(root, "bin/qmd"))
      environment = { "HIVE_QMD_BIN" => override, "PATH" => File.dirname(qmd) }
      assert_equal override, find_qmd(environment)
      result = doctor_in_child(project_root: root, environment: environment)
      assert_equal 0, result.fetch("exit_code"), result.fetch("output")
      row = result.fetch("rows").find { |entry| entry["label"] == "wiki/qmd" }
      assert_equal "warning", row.fetch("status")
      assert_includes row.fetch("message"), "qmd at #{override} timed out or could not be executed"
    end
  end

  def test_llm_wiki_qmd_is_not_probed_without_wiki_configuration
    with_tmp_dir do |root|
      marker = File.join(root, "probe-ran")
      qmd = qmd_executable(File.join(root, "qmd"), 'printf ran > "' + marker + '"')
      result = doctor_in_child(project_root: root, environment: { "HIVE_QMD_BIN" => qmd })
      assert_equal 0, result.fetch("exit_code"), result.fetch("output")
      refute result.fetch("rows").any? { |row| row["label"] == "wiki/qmd" }
      refute File.exist?(marker)
    end
  end

  def test_llm_wiki_qmd_warning_when_binary_fails_to_start
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      qmd = qmd_executable(File.join(root, "qmd"), 'echo "NODE_MODULE_VERSION mismatch" >&2; exit 1')
      result = doctor_in_child(project_root: root, environment: { "HIVE_QMD_BIN" => qmd })
      assert_equal 0, result.fetch("exit_code"), result.fetch("output")
      assert_match(%r{wiki/qmd.*! warning}, result.fetch("output"))
      assert_includes result.fetch("output"), "NODE_MODULE_VERSION mismatch"
      assert_includes result.fetch("output"), "npm rebuild better-sqlite3"
    end
  end

  def test_llm_wiki_qmd_warning_when_binary_cannot_be_executed
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      qmd = File.join(root, "qmd")
      write_file(qmd, "#!/nonexistent/xyz\n")
      File.chmod(0o755, qmd)
      result = doctor_in_child(project_root: root, environment: { "HIVE_QMD_BIN" => qmd })
      assert_equal 0, result.fetch("exit_code"), result.fetch("output")
      assert_match(%r{wiki/qmd.*! warning}, result.fetch("output"))
      assert_includes result.fetch("output"), "timed out or could not be executed"
    end
  end

  # ---- Review.reviewers extension (U1/U2/U3) ----

  def cfg_with_reviewers(reviewers)
    {
      "brainstorm" => { "agent" => "claude", "skill" => "/x" }, # parked
      "plan" => { "agent" => "claude", "skill" => "/x" },       # parked
      "review" => { "reviewers" => reviewers }
    }
  end

  def install_brainstorm_and_plan_skills(home)
    # Install the parked stage skills so the test focuses on reviewer behaviour.
    write_file("#{home}/.claude/commands/x.md")
  end

  def test_review_reviewers_happy_path_all_present
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      # Reviewers' ce-code-review installed at user level (matches the
      # bare-name → /ce-code-review invocation path).
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      write_file("#{home}/.claude/plugins/cache/mp/pr-review-toolkit/1.0/skills/review-pr/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "pr-review-toolkit", "kind" => "agent",
          "agent" => "claude", "skill" => "pr-review-toolkit:review-pr" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/claude-ce-code-review.*✓ present}, out.string)
      assert_match(%r{6-review/pr-review-toolkit.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_one_missing_exits_65
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      # ce-code-review present, pr-review-toolkit:review-pr absent.
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "pr-review-toolkit", "kind" => "agent",
          "agent" => "claude", "skill" => "pr-review-toolkit:review-pr" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{6-review/pr-review-toolkit.*✗ missing}, out.string)
      assert_match(%r{\[6-review/pr-review-toolkit/claude\]}, out.string,
        "install-hint footer must include the row label")
    end
  end

  def test_review_reviewers_mixed_agents
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      write_file("#{home}/.codex/skills/ce-code-review/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "codex-ce-code-review", "kind" => "agent",
          "agent" => "codex", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/claude-ce-code-review.*claude.*✓ present}, out.string)
      assert_match(%r{6-review/codex-ce-code-review.*codex.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_empty_or_nil_or_absent
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      [
        cfg_with_reviewers([]),
        cfg_with_reviewers(nil),
        { "brainstorm" => { "agent" => "claude", "skill" => "/x" },
          "plan" => { "agent" => "claude", "skill" => "/x" } } # `review:` absent
      ].each do |cfg|
        out = StringIO.new
        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call
        assert_equal 0, exit_code,
          "empty/nil/absent reviewers must not fail (cfg shape: #{cfg.dig('review', 'reviewers').inspect})"
        refute_match(%r{6-review/}, out.string,
          "no reviewer rows should appear when reviewers list is empty/nil/absent")
      end
    end
  end

  def test_review_reviewers_non_agent_kind_is_not_applicable
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "weird-linter", "kind" => "linter",
          "agent" => "claude", "skill" => "doesnt-matter" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code, "non-agent kind must not fail doctor"
      assert_match(%r{6-review/weird-linter.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_pi_agent_resolves_via_real_skill_paths
    # Pi has a real skill model (~/.pi/agent/skills/, ~/.agents/skills/,
    # plus pi packages). With pi's `skill_syntax_format` =
    # `/skill:%{skill}`, the reviewer's bare `skill: ce-code-review`
    # formats to `/skill:ce-code-review` and the verifier probes pi's
    # discovery paths.
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.pi/agent/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "pi-reviewer", "kind" => "agent",
          "agent" => "pi", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/pi-reviewer.*pi.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_pi_agent_missing_when_skill_absent
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "pi-reviewer", "kind" => "agent",
          "agent" => "pi", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{6-review/pi-reviewer.*pi.*✗ missing}, out.string)
      assert_match(/pi install/, out.string)
    end
  end

  def test_row_shape_includes_kind_label_name_for_reviewers
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      doctor = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out)
      doctor.call

      assert_kind_of Array, doctor.rows
      stage_rows = doctor.rows.select { |r| r[:kind] == "managed_skill" && %w[brainstorm plan].include?(r[:stage]) }
      reviewer_rows = doctor.rows.select { |r| r[:kind] == "managed_skill" && r[:stage].start_with?("6-review/") }

      assert_equal 1, stage_rows.length
      assert_equal 1, reviewer_rows.length

      stage_rows.each do |r|
        assert_equal "brainstorm,plan", r[:label], "duplicate agent/capability uses retain both surfaces"
        refute r.key?(:name), "stage rows must NOT have :name"
        assert r[:skill].start_with?("/"), "stage rows store full invocation in :skill"
      end

      reviewer = reviewer_rows.first
      assert_equal "6-review/claude-ce-code-review", reviewer[:stage]
      assert_equal "6-review/claude-ce-code-review", reviewer[:label]
      assert_equal "claude-ce-code-review", reviewer[:name]
      assert_equal "/ce-code-review", reviewer[:skill],
        "reviewer :skill must be the full invocation, not the bare config name"
    end
  end

  def test_json_envelope_includes_kind_and_label_on_all_rows_and_name_on_reviewers
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      Hive::Commands::Doctor.new(config: cfg, project_root: nil, json: true, output: out).call

      env = JSON.parse(out.string)
      assert_equal "hive-doctor.v2", env["schema"]
      assert_equal 2, env["managed_skills"].length

      stage_entries = env["managed_skills"].select { |c| %w[brainstorm plan].include?(c["stage"]) }
      reviewer_entries = env["managed_skills"].select { |c| c["stage"].start_with?("6-review/") }
      assert_equal 1, stage_entries.length
      assert_equal 1, reviewer_entries.length

      stage_entries.each do |c|
        assert c.key?("label"), "every stage entry has :label"
        refute c.key?("name"), "stage entries must NOT have :name"
      end

      reviewer = reviewer_entries.first
      assert_equal "6-review/claude-ce-code-review", reviewer["label"]
      assert_equal "claude-ce-code-review", reviewer["name"]
      assert_equal "/ce-code-review", reviewer["skill"]
    end
  end

  def test_table_column_widths_handle_long_reviewer_labels
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      long_name = "very-long-custom-reviewer-name-that-stretches-the-column"
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => long_name, "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_match(%r{6-review/#{Regexp.escape(long_name)}}, out.string)
      # Header still aligns: separator dashes match the longest label width.
      header_line = out.string.lines[0]
      separator_line = out.string.lines[1]
      assert_equal header_line.length, separator_line.length,
        "header and separator must be the same width even with long reviewer labels"
    end
  end

  def test_json_config_error_returns_config_exit_and_error_payload
    out = StringIO.new
    cfg = base_config("brainstorm" => { "agent" => "bogus", "skill" => "/x" })

    exit_code = Hive::Commands::Doctor.new(
      config: cfg,
      project_root: nil,
      json: true,
      output: out
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_CONFIG_ERROR, exit_code
    payload = JSON.parse(out.string)
    assert_match(/unknown agent profile/, payload.fetch("error"))
  end

  def test_text_config_error_returns_config_exit_and_prefixed_message
    out = StringIO.new
    cfg = base_config("brainstorm" => { "agent" => "bogus", "skill" => "/x" })

    exit_code = Hive::Commands::Doctor.new(
      config: cfg,
      project_root: nil,
      output: out
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_CONFIG_ERROR, exit_code
    assert_match(/hive doctor: unknown agent profile/, out.string)
  end

  def test_row_line_marks_version_too_old_and_unknown_statuses
    doctor = Hive::Commands::Doctor.new(config: base_config, project_root: nil)
    widths = { label: 5, agent: 6, skill: 2, status: 15 }

    old_line = doctor.send(:row_line, {
      label: "plan",
      agent: "claude",
      skill: "/x",
      status: "version_too_old"
    }, widths)
    unknown_line = doctor.send(:row_line, {
      label: "plan",
      agent: "claude",
      skill: "/x",
      status: "mystery"
    }, widths)

    assert_match(/✗ version_too_old/, old_line)
    assert_match(/\? mystery/, unknown_line)
  end
  def test_legacy_runtime_warning_reports_unreadable_config_yml
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        File.write(File.join(project, ".hive-state", "config.yml"), "brainstorm: [broken\n")
        out = StringIO.new
        cfg = base_config(
          "brainstorm" => { "agent" => "claude", "skill" => "/x" },
          "plan" => { "agent" => "claude", "skill" => "/x" }
        )

        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out).call

        assert_equal 0, exit_code
        assert_match(/could not parse \.hive-state\/config\.yml/, out.string)
      end
    end
  end

  def test_private_dependency_and_rendering_boundaries
    with_tmp_dir do |dir|
      executable = File.join(dir, "qmd")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      doctor = Hive::Commands::Doctor.new(
        config: base_config, project_root: dir, output: StringIO.new, environment: { "PATH" => dir }
      )
      assert_equal executable, doctor.send(:which, "qmd")

      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), "brainstorm:\n  agent: claude\n")

      clean = Hive::Commands::Doctor.new(config: base_config, project_root: dir, output: StringIO.new)
      refute clean.send(:config_yml_unreadable?)

      widths = { label: 12, agent: 8, skill: 16, status: 16 }
      %w[stale incompatible unavailable not_applicable].each do |status|
        rendered = doctor.send(
          :row_line,
          { kind: status == "not_applicable" ? "dependency" : "managed_skill",
            label: "row", agent: "agent", skill: "/skill", status: status },
          widths
        )
        assert_includes rendered, status
      end
    end
  end
end
