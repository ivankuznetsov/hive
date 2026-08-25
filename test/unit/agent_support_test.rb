require "test_helper"
require "open3"

class AgentSupportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_support_is_loaded_only_for_the_selected_builtin
    script = <<~RUBY
      require "hive/agent_support"
      puts defined?(Hive::AgentSupport::Pi) || "unloaded"
      require "hive/agent_profiles"
      puts defined?(Hive::AgentSupport::Pi) || "profiles-unloaded"
      puts Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:claude)).inspect
      support = Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:pi))
      puts support.name
      puts support.credential_path(home: "/tmp/home")
      puts support.autoload?(:SetupAdapter) || "setup-loaded"
      puts support::SetupAdapter.name
      puts support.autoload?(:Skills) || "skills-loaded"
      puts support::Skills.verify("/skill:missing", project_root: nil).first
      puts support.autoload?(:Skills) || "skills-loaded"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
    assert_equal [
      "unloaded", "profiles-unloaded", "nil", "Hive::AgentSupport::Pi",
      "/tmp/home/.pi/agent/auth.json",
      "hive/agent_support/pi/setup_adapter", "Hive::AgentSupport::Pi::SetupAdapter",
      "hive/agent_support/pi/skills", "missing", "skills-loaded"
    ], stdout.lines.map(&:strip)
  end

  def test_pi_behavior_has_no_generic_core_residue
    pi_branch = /(?:when\s+(?::pi|["']pi["'])|(?:==|!=)\s*(?::pi|["']pi["'])|def\s+(?:self\.)?pi_|\b(?:compile_pi|pi_(?:evidence|executable|auth|bwrap))|Hive::SkillCheck::Pi|Adapters::Pi)/
    support_root = File.join(ROOT, "lib/hive/agent_support")
    offenders = Dir[File.join(ROOT, "{lib/hive,web/app}/**/*.rb")].filter_map do |path|
      next if path.start_with?(support_root)

      relative = path.delete_prefix("#{ROOT}/")
      relative if File.read(path).match?(pi_branch)
    end

    assert_empty offenders, "Pi behavior escaped its support boundary: #{offenders.join(', ')}"
  end

  def test_support_does_not_depend_on_orchestration_layers
    forbidden = %r{require ["']hive/(?:artifacts|commands|stages|web|workflow_package)}
    offenders = Dir[File.join(ROOT, "lib/hive/agent_support{.rb,/**/*.rb}")].filter_map do |path|
      path.delete_prefix("#{ROOT}/") if File.read(path).match?(forbidden)
    end

    assert_empty offenders, "agent support has an upward dependency: #{offenders.join(', ')}"
  end
end
