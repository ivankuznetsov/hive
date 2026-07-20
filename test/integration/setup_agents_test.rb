require "test_helper"
require "json_schemer"
require "hive/commands/setup_agents"

class SetupAgentsIntegrationTest < Minitest::Test
  include HiveTestHelper

  FAKE_AGENT = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"
    require "fileutils"

    agent = File.basename($PROGRAM_NAME).delete_prefix("fake-")
    home = ENV.fetch("HOME")
    File.open(File.join(home, ".fake-agent-calls"), "a") { |file| file.puts "#{agent} #{ARGV.join(' ')}" }
    state_dir = File.join(home, ".fake-agent-state")
    state_path = File.join(state_dir, "#{agent}.json")
    state = File.file?(state_path) ? JSON.parse(File.read(state_path)) : { "marketplaces" => {}, "packages" => {} }
    args = ARGV.dup

    sources = {
      "EveryInc/compound-engineering-plugin" => ["compound-engineering-plugin", "https://github.com/EveryInc/compound-engineering-plugin.git"],
      "https://github.com/EveryInc/compound-engineering-plugin.git" => ["compound-engineering-plugin", "https://github.com/EveryInc/compound-engineering-plugin.git"],
      "anthropics/claude-plugins-official" => ["claude-plugins-official", "anthropics/claude-plugins-official"],
      "ivankuznetsov/agent-plugins" => ["aikuznetsov-marketplace", "https://github.com/ivankuznetsov/agent-plugins.git"],
      "https://github.com/ivankuznetsov/agent-plugins.git" => ["aikuznetsov-marketplace", "https://github.com/ivankuznetsov/agent-plugins.git"]
    }

    def save(path, state)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(state))
    end

    def package_parts(selector)
      case selector
      when /compound-engineering/
        ["compound-engineering", "compound-engineering-plugin", "3.19.0"]
      when /pr-review-toolkit/
        ["pr-review-toolkit", "claude-plugins-official", "unknown"]
      when /llm-wiki/
        ["llm-wiki", "aikuznetsov-marketplace", "0.1.9"]
      else
        raise "unknown package #{selector}"
      end
    end

    def materialize(agent, selector, package, marketplace, version)
      root = case agent
      when "claude"
        File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "plugins", "cache", marketplace, package, version)
      when "codex"
        File.join(ENV.fetch("CODEX_HOME"), "plugins", "cache", marketplace, package, version)
      when "pi"
        uri = selector.sub(%r{\Ahttps://}, "")
        File.join(ENV.fetch("PI_CODING_AGENT_DIR"), "git", uri)
      end
      FileUtils.mkdir_p(root)
      if package == "compound-engineering"
        %w[ce-brainstorm ce-code-review ce-test-browser].each do |skill|
          path = File.join(root, "skills", skill, "SKILL.md")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "---\nname: #{skill}\n---\n")
        end
      elsif package == "llm-wiki"
        relative = agent == "pi" ? File.join("pi", "skills", "wiki-plan", "SKILL.md") : File.join("skills", "wiki-plan", "SKILL.md")
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "---\nname: wiki-plan\n---\n")
        File.write(File.join(root, "package.json"), JSON.generate("version" => version, "pi" => { "skills" => ["./pi/skills"] })) if agent == "pi"
      else
        path = File.join(root, "commands", "review-pr.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "review\n")
      end
      if agent == "pi" && package == "compound-engineering"
        File.write(File.join(root, "package.json"), JSON.generate("version" => version, "pi" => { "skills" => ["./skills"] }))
      end
      root
    end

    def append_section(path, header, values)
      content = File.file?(path) ? File.read(path) : ""
      return if content.include?("[#{header}]")
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") do |file|
        file.write("\n") unless content.empty? || content.end_with?("\n\n")
        file.puts "[#{header}]"
        values.each { |key, value| file.puts "#{key} = #{value.inspect}" }
      end
    end

    mutation = args.include?("add") || args.include?("install") || args.include?("update") || args.include?("upgrade")
    if mutation && File.exist?(File.join(home, ".fake-fail-#{agent}"))
      warn "offline: #{agent} marketplace unavailable"
      exit 1
    end

    if args == ["--version"]
      puts({ "claude" => "2.1.179", "codex" => "codex-cli 0.144.0", "pi" => "0.80.6" }.fetch(agent))
    elsif agent == "claude" && args == ["plugin", "list", "--json"]
      puts JSON.generate(state["packages"].map do |id, row|
        { "id" => id, "version" => row["version"], "enabled" => true, "installPath" => row["root"] }
      end)
    elsif agent == "claude" && args == ["plugin", "marketplace", "list", "--json"]
      puts JSON.generate(state["marketplaces"].map do |name, source|
        { "name" => name, "repo" => source.sub(%r{\Ahttps://github.com/}, "").sub(/\.git\z/, "") }
      end)
    elsif agent == "codex" && args == ["plugin", "list", "--available", "--json"]
      puts JSON.generate("installed" => state["packages"].map do |id, row|
        { "pluginId" => id, "version" => row["version"], "enabled" => true,
          "source" => { "url" => row["source"] } }
      end, "available" => [])
    elsif agent == "codex" && args == ["plugin", "marketplace", "list", "--json"]
      puts JSON.generate("marketplaces" => state["marketplaces"].map do |name, source|
        { "name" => name, "marketplaceSource" => { "sourceType" => "git", "source" => source } }
      end)
    elsif agent == "pi" && args == ["list"]
      puts "User packages:"
      state["packages"].each_value do |row|
        puts "  #{row['source']}"
        puts "    #{row['root']}"
      end
    elsif args[0, 3] == ["plugin", "marketplace", "add"]
      source = args.fetch(3)
      name, canonical = sources.fetch(source)
      state["marketplaces"][name] = canonical
      if agent == "codex"
        append_section(File.join(ENV.fetch("CODEX_HOME"), "config.toml"), "marketplaces.#{name}",
                       "source_type" => "git", "source" => canonical)
      end
      save(state_path, state)
      puts "{}"
    elsif agent == "codex" && args[0, 3] == ["plugin", "marketplace", "upgrade"]
      puts "{}"
    elsif (agent == "claude" && args[0, 2] == ["plugin", "install"]) ||
          (agent == "claude" && args[0, 2] == ["plugin", "update"]) ||
          (agent == "codex" && args[0, 2] == ["plugin", "add"])
      selector = args.fetch(2)
      package, marketplace, version = package_parts(selector)
      root = materialize(agent, selector, package, marketplace, version)
      source = state["marketplaces"][marketplace]
      state["packages"][selector] = { "version" => version, "root" => root, "source" => source }
      if agent == "codex"
        append_section(File.join(ENV.fetch("CODEX_HOME"), "config.toml"), "plugins.\"#{selector}\"", "enabled" => true)
      end
      save(state_path, state)
      puts "{}"
    elsif agent == "pi" && %w[install update].include?(args[0])
      selector = args.fetch(1)
      package, marketplace, version = package_parts(selector)
      root = materialize(agent, selector, package, marketplace, version)
      state["packages"][selector] = { "version" => version, "root" => root, "source" => selector }
      save(state_path, state)
      puts "installed"
    else
      warn "unsupported #{agent} argv: #{args.inspect}"
      exit 64
    end
  RUBY

  def install_fake_clis(dir)
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    %w[claude codex pi].to_h do |agent|
      path = File.join(bin_dir, "fake-#{agent}")
      File.write(path, FAKE_AGENT)
      FileUtils.chmod(0o755, path)
      [ agent, path ]
    end
  end

  def config_for(bins)
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    bins.each { |agent, bin| cfg["agents"][agent]["bin"] = bin }
    cfg["claude"]["mode"] = "headless"
    cfg["brainstorm"] = { "agent" => "claude" }
    cfg["plan"] = { "agent" => "claude" }
    cfg["review"]["reviewers"] = [
      { "name" => "codex-ce", "kind" => "agent", "agent" => "codex", "skill" => "ce-code-review" },
      { "name" => "pi-ce", "kind" => "agent", "agent" => "pi", "skill" => "ce-code-review" },
      { "name" => "pr-review-toolkit", "kind" => "agent", "agent" => "claude", "skill" => "pr-review-toolkit:review-pr" }
    ]
    cfg["review"]["browser_test"]["enabled"] = true
    cfg["review"]["browser_test"]["agent"] = "pi"
    cfg
  end

  def with_agent_environment
    with_tmp_dir do |dir|
      bins = install_fake_clis(dir)
      env = {
        "HOME" => dir,
        "PATH" => [ File.join(dir, "bin"), ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR),
        "CLAUDE_CONFIG_DIR" => File.join(dir, "claude"),
        "CODEX_HOME" => File.join(dir, "codex"),
        "PI_CODING_AGENT_DIR" => File.join(dir, "pi")
      }
      with_env(env) { yield dir, config_for(bins) }
    end
  end

  def run_setup(cfg, dir, yes: true, json: true, input: StringIO.new)
    output = StringIO.new
    error = StringIO.new
    code = Hive::Commands::SetupAgents.new(
      config: cfg, project_root: dir, yes: yes, json: json,
      input: input, output: output, error: error
    ).call
    [ code, output.string, error.string ]
  end

  def inspect(cfg, dir)
    Hive::AgentSkills::Inspector.new(config: cfg, project_root: dir).inspect
  end

  def test_fresh_all_agent_setup_converges_and_second_run_is_a_noop
    with_agent_environment do |dir, cfg|
      assert inspect(cfg, dir).all? { |row| row.health == "missing" }

      code, json, = run_setup(cfg, dir)
      payload = JSON.parse(json)

      assert_equal 0, code, json
      assert_equal "success", payload.fetch("classification")
      assert payload.fetch("final_health").all? { |row| row.fetch("health") == "healthy" }
      assert File.file?(File.join(dir, "claude", "commands", "plan.md"))

      second_code, second_json, = run_setup(cfg, dir)
      second = JSON.parse(second_json)
      assert_equal 0, second_code
      assert_equal "no_op", second.fetch("classification")
      assert_empty second.dig("preview", "operations")
    end
  end

  def test_non_tty_without_yes_changes_nothing
    with_agent_environment do |dir, cfg|
      before = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort

      code, json, = run_setup(cfg, dir, yes: false)

      assert_equal 64, code
      payload = JSON.parse(json)
      assert_equal "refused", payload.fetch("classification")
      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-setup-agents")))
      )
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      assert_equal before, Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort
      refute File.exist?(File.join(dir, ".fake-agent-calls"))
      refute File.exist?(File.join(dir, ".fake-agent-state"))
    end
  end

  def test_offline_claude_does_not_prevent_codex_and_pi_success
    with_agent_environment do |dir, cfg|
      File.write(File.join(dir, ".fake-fail-claude"), "1")

      code, json, = run_setup(cfg, dir)
      payload = JSON.parse(json)
      final = payload.fetch("final_health")

      assert_equal 1, code
      assert_equal "residual_failure", payload.fetch("classification")
      assert final.select { |row| %w[codex pi].include?(row.fetch("agent")) }.all? { |row| row.fetch("health") == "healthy" }, json
      assert final.any? { |row| row.fetch("agent") == "claude" && row.fetch("health") != "healthy" }
      assert payload.fetch("operation_results").any? { |row| row.fetch("status") == "failed" }
    end
  end

  def test_unavailable_pi_is_a_non_blocking_skip
    with_agent_environment do |dir, cfg|
      cfg["agents"]["pi"]["bin"] = File.join(dir, "missing-pi")

      code, json, = run_setup(cfg, dir)
      payload = JSON.parse(json)

      assert_equal 0, code, json
      assert payload.fetch("final_health").any? { |row| row.fetch("agent") == "pi" && row.fetch("health") == "unavailable" }
      assert payload.fetch("skips").any? { |row| row["agent"] == "pi" }
    end
  end

  def test_codex_marketplace_conflict_remains_byte_identical
    with_agent_environment do |dir, cfg|
      codex_home = ENV.fetch("CODEX_HOME")
      FileUtils.mkdir_p(codex_home)
      config_path = File.join(codex_home, "config.toml")
      original = "# mine\n[marketplaces.compound-engineering-plugin]\nsource_type = \"git\"\nsource = \"https://example.test/private.git\"\n"
      File.write(config_path, original)
      state_dir = File.join(dir, ".fake-agent-state")
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, "codex.json"), JSON.generate(
        "marketplaces" => { "compound-engineering-plugin" => "https://example.test/private.git" },
        "packages" => {}
      ))

      code, json, = run_setup(cfg, dir)

      assert_equal 1, code
      assert_equal original, File.read(config_path)
      assert JSON.parse(json).dig("preview", "health").any? { |row| row["agent"] == "codex" && row["health"] == "conflicting" }
    end
  end
end
