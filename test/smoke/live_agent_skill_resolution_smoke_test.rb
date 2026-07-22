require "test_helper"
require "hive/commands/doctor"
require "hive/commands/setup_agents"
require "hive/agent_skills/provisioner"

# Opt-in authenticated proof that provisioning is followed by native skill
# activation. Every run uses disposable provider homes; only credential files
# are copied from the operator's normal home. Enable explicitly with:
#
#   HIVE_LIVE_AGENT_SKILLS=1 rake smoke
#   HIVE_LIVE_AGENT_SKILLS=1 HIVE_LIVE_AGENT=codex rake smoke
class LiveAgentSkillResolutionSmokeTest < Minitest::Test
  include HiveTestHelper

  CAPABILITY = "ce-brainstorm"
  CREDENTIALS = {
    "claude" => [ ".claude/.credentials.json", ".credentials.json" ],
    "codex" => [ ".codex/auth.json", "auth.json" ],
    "pi" => [ ".pi/agent/auth.json", "auth.json" ]
  }.freeze
  CONFIG_ENV = {
    "claude" => "CLAUDE_CONFIG_DIR",
    "codex" => "CODEX_HOME",
    "pi" => "PI_CODING_AGENT_DIR"
  }.freeze

  %w[claude codex pi].each do |agent|
    define_method("test_#{agent}_loads_provisioned_skill") do
      run_live_activation(agent)
    end
  end

  private

  def run_live_activation(agent)
    skip "set HIVE_LIVE_AGENT_SKILLS=1 to run authenticated skill resolution" unless ENV["HIVE_LIVE_AGENT_SKILLS"] == "1"
    selected = ENV["HIVE_LIVE_AGENT"].to_s
    skip "HIVE_LIVE_AGENT selects #{selected}" unless selected.empty? || selected == agent
    bin = find_executable(agent)
    skip "#{agent} binary not on PATH" unless bin

    source_relative, destination_relative = CREDENTIALS.fetch(agent)
    credential = File.join(Dir.home, source_relative)
    skip "#{credential} is absent; authenticate #{agent} before this opt-in smoke" unless File.file?(credential)

    with_tmp_dir do |dir|
      config_home = File.join(dir, agent)
      destination = File.join(config_home, destination_relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(credential, destination, preserve: true)
      environment = ENV.to_h.merge(
        "HOME" => dir,
        CONFIG_ENV.fetch(agent) => config_home
      )
      cfg = live_config(agent, bin)
      provisioner = Hive::AgentSkills::Provisioner.new(
        config: cfg, project_root: dir, environment: environment
      )
      setup_output = StringIO.new
      setup_code = Hive::Commands::SetupAgents.new(
        config: cfg, project_root: dir, yes: true, json: true,
        agents: [ agent ], skills: [ CAPABILITY ], provisioner: provisioner,
        output: setup_output, error: StringIO.new
      ).call
      assert_equal 0, setup_code, setup_output.string

      doctor_output = StringIO.new
      inspector = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, environment: environment
      )
      Hive::Commands::Doctor.new(
        config: cfg, project_root: dir, json: true,
        output: doctor_output, inspector: inspector, environment: environment
      ).call
      managed = JSON.parse(doctor_output.string).fetch("managed_skills")
      row = managed.find { |entry| entry["agent"] == agent && entry["capability"] == CAPABILITY }
      assert_equal "healthy", row&.fetch("health"), doctor_output.string

      profile = Hive::AgentProfiles.lookup(agent, cfg: cfg)
      prompt = "Load #{row.fetch('expected').fetch('invocation')} and begin its native workflow. Do not claim success unless the CLI activated the skill."
      argv = [ bin, profile.headless_flag, *profile.output_format_flags, prompt ]
      stdout, stderr, status = Open3.capture3(environment, *argv, chdir: dir)
      assert status.success?, "#{agent} workflow failed: #{stderr}\n#{stdout}"

      events = parse_native_events(stdout)
      assert events.any? { |event| activation_metadata?(event, CAPABILITY) },
             "#{agent} emitted no structured skill/plugin activation metadata for #{CAPABILITY}:\n#{stdout.lines.first(20).join}"
    end
  end

  def live_config(agent, bin)
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["agents"][agent]["bin"] = bin
    cfg["claude"]["mode"] = "headless"
    cfg["brainstorm"] = { "agent" => agent, "skill" => CAPABILITY }
    cfg["plan"] = { "agent" => agent, "skill" => CAPABILITY }
    cfg["review"]["reviewers"] = []
    cfg["review"]["adhoc"]["reviewers"] = [] if cfg.dig("review", "adhoc")
    cfg["review"]["browser_test"]["enabled"] = false
    cfg["patrol"]["enabled"] = false if cfg["patrol"].is_a?(Hash)
    cfg
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      path = File.join(directory, name)
      return path if File.file?(path) && File.executable?(path)
    end
    nil
  end

  def parse_native_events(output)
    lines = output.lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    return lines unless lines.empty?

    parsed = JSON.parse(output)
    parsed.is_a?(Array) ? parsed : [ parsed ]
  rescue JSON::ParserError
    []
  end

  def activation_metadata?(value, capability)
    case value
    when Hash
      value.any? do |key, nested|
        metadata = key.to_s.match?(/skill|plugin/i) && JSON.generate(nested).include?(capability)
        metadata || activation_metadata?(nested, capability)
      end
    when Array
      value.any? { |nested| activation_metadata?(nested, capability) }
    else
      false
    end
  end
end
