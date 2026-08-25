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
      "unloaded", "profiles-unloaded", "Hive::AgentSupport::Claude", "Hive::AgentSupport::Pi",
      "/tmp/home/.pi/agent/auth.json",
      "hive/agent_support/pi/setup_adapter", "Hive::AgentSupport::Pi::SetupAdapter",
      "hive/agent_support/pi/skills", "missing", "skills-loaded"
    ], stdout.lines.map(&:strip)
  end

  def test_opencode_loads_only_after_selection_and_keeps_heavy_facets_lazy
    script = <<~RUBY
      require "hive/agent_profiles"
      puts defined?(Hive::AgentSupport::OpenCode) || "unloaded"
      support = Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:opencode))
      puts support.name
      puts support.autoload?(:Configuration) || "configuration-loaded"
      puts support.autoload?(:Execution) || "execution-loaded"
      puts support.autoload?(:Skills) || "skills-loaded"
      puts support.autoload?(:SetupAdapter) || "setup-loaded"
      puts support.const_defined?(:PORTABLE_MANAGED_RUNTIME, false)
      puts support.configuration.class.name
      puts support.autoload?(:Execution) || "execution-loaded"
      puts support.autoload?(:Skills) || "skills-loaded"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
    assert_equal [
      "unloaded", "Hive::AgentSupport::OpenCode", "configuration-loaded",
      "hive/agent_support/opencode/execution", "hive/agent_support/opencode/skills",
      "hive/agent_support/opencode/setup_adapter",
      "true",
      "Hive::AgentSupport::OpenCode::Configuration",
      "hive/agent_support/opencode/execution", "hive/agent_support/opencode/skills"
    ], stdout.lines.map(&:strip)
  end

  def test_codex_loads_only_after_selection_and_keeps_facets_lazy
    script = <<~RUBY
      require "hive/agent_profiles"
      puts defined?(Hive::AgentSupport::Codex) || "unloaded"
      support = Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:codex))
      puts support.name
      puts support.autoload?(:Runtime) || "runtime-loaded"
      puts support.autoload?(:ArtifactPolicy) || "artifact-loaded"
      puts support.autoload?(:Reviewer) || "reviewer-loaded"
      puts support.autoload?(:Skills) || "skills-loaded"
      puts support.autoload?(:SetupAdapter) || "setup-loaded"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
    assert_equal [
      "unloaded", "Hive::AgentSupport::Codex",
      "hive/agent_support/codex/runtime",
      "hive/agent_support/codex/artifact_policy",
      "hive/agent_support/codex/reviewer",
      "hive/agent_support/codex/skills",
      "hive/agent_support/codex/setup_adapter"
    ], stdout.lines.map(&:strip)
  end

  def test_grok_loads_only_after_selection_and_keeps_facets_lazy
    script = <<~RUBY
      require "hive/agent_profiles"
      puts defined?(Hive::AgentSupport::Grok) || "unloaded"
      support = Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:grok))
      puts support.name
      puts support.autoload?(:Runtime) || "runtime-loaded"
      puts support.autoload?(:Skills) || "skills-loaded"
      puts support.autoload?(:SetupAdapter) || "setup-loaded"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
    assert_equal [
      "unloaded", "Hive::AgentSupport::Grok",
      "hive/agent_support/grok/runtime",
      "hive/agent_support/grok/skills",
      "hive/agent_support/grok/setup_adapter"
    ], stdout.lines.map(&:strip)
  end

  def test_claude_loads_only_after_selection_and_keeps_facets_lazy
    script = <<~RUBY
      require "hive/agent_profiles"
      puts defined?(Hive::AgentSupport::Claude) || "unloaded"
      support = Hive::AgentSupport.for(Hive::AgentProfiles.lookup(:claude))
      puts support.name
      puts support.autoload?(:Interactive) || "interactive-loaded"
      puts support.autoload?(:Runtime) || "runtime-loaded"
      puts support.autoload?(:Skills) || "skills-loaded"
      puts support.autoload?(:SetupAdapter) || "setup-loaded"
      puts Hive::AgentSupport.autoload?(:StreamMeter) || "stream-meter-loaded"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
    assert_equal [
      "unloaded", "Hive::AgentSupport::Claude",
      "hive/agent_support/claude/interactive",
      "hive/agent_support/claude/runtime",
      "hive/agent_support/claude/skills",
      "hive/agent_support/claude/setup_adapter",
      "hive/agent_support/stream_meter"
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

  def test_opencode_behavior_has_no_generic_core_residue
    branch = /(?:when\s+(?::opencode|["']opencode["'])|(?:==|!=)\s*(?::opencode|["']opencode["'])|def\s+(?:self\.)?opencode_|\bopencode_(?:configuration|permission|edit|bash|invocation|observation|route)|Hive::SkillCheck::OpenCode|Adapters::OpenCode)/
    allowed = File.join(ROOT, "lib/hive/agent_profiles/opencode.rb")
    support_root = File.join(ROOT, "lib/hive/agent_support")
    offenders = Dir[File.join(ROOT, "{lib/hive,web/app}/**/*.rb")].filter_map do |path|
      next if path.start_with?(support_root) || path == allowed

      relative = path.delete_prefix("#{ROOT}/")
      relative if File.read(path).match?(branch)
    end

    assert_empty offenders,
                 "OpenCode behavior escaped its support boundary: #{offenders.join(', ')}"
  end

  def test_codex_behavior_has_no_generic_core_residue
    branch = /(?:when\s+(?::codex|["']codex["'])|(?:==|!=)\s*(?::codex|["']codex["'])|def\s+(?:self\.)?(?:codex_|\w+_codex\b)|\b(?:compile_codex|portable_codex|codex_(?:runtime|executable|doctor|permission|inventory|install_path))|\.codex-plugin|Hive::SkillCheck::Codex|Adapters::Codex)/
    allowed = File.join(ROOT, "lib/hive/agent_profiles/codex.rb")
    support_root = File.join(ROOT, "lib/hive/agent_support")
    offenders = Dir[File.join(ROOT, "{lib/hive,web/app}/**/*.rb")].filter_map do |path|
      next if path.start_with?(support_root) || path == allowed

      relative = path.delete_prefix("#{ROOT}/")
      relative if File.read(path).match?(branch)
    end

    assert_empty offenders,
                 "Codex behavior escaped its support boundary: #{offenders.join(', ')}"
  end

  def test_grok_behavior_has_no_generic_core_residue
    branch = /(?:when\s+(?::grok|["']grok["'])|(?:==|!=)\s*(?::grok|["']grok["'])|def\s+(?:self\.)?(?:grok_|\w+_grok\b)|\b(?:compile_grok|grok_(?:runtime|inventory|auth|bwrap))|:grok_end|Hive::SkillCheck::Grok|Adapters::Grok)/
    allowed = File.join(ROOT, "lib/hive/agent_profiles/grok.rb")
    support_root = File.join(ROOT, "lib/hive/agent_support")
    offenders = Dir[File.join(ROOT, "{lib/hive,web/app}/**/*.rb")].filter_map do |path|
      next if path.start_with?(support_root) || path == allowed

      relative = path.delete_prefix("#{ROOT}/")
      relative if File.read(path).match?(branch)
    end

    assert_empty offenders,
                 "Grok behavior escaped its support boundary: #{offenders.join(', ')}"
  end

  def test_claude_dispatch_has_no_generic_core_name_branch
    branch = /(?:when\s+(?::claude|["']claude["'])|(?:==|!=)\s*(?::claude|["']claude["'])|Hive::SkillCheck::Claude|Adapters::Claude)/
    support_root = File.join(ROOT, "lib/hive/agent_support")
    offenders = Dir[File.join(ROOT, "{lib/hive,web/app}/**/*.rb")].filter_map do |path|
      next if path.start_with?(support_root)

      path.delete_prefix("#{ROOT}/") if File.read(path).match?(branch)
    end

    assert_empty offenders,
                 "Claude dispatch escaped its support boundary: #{offenders.join(', ')}"
  end

  def test_support_does_not_depend_on_orchestration_layers
    forbidden = %r{require ["']hive/(?:artifacts|commands|stages|web|workflow_package)}
    offenders = Dir[File.join(ROOT, "lib/hive/agent_support{.rb,/**/*.rb}")].filter_map do |path|
      path.delete_prefix("#{ROOT}/") if File.read(path).match?(forbidden)
    end

    assert_empty offenders, "agent support has an upward dependency: #{offenders.join(', ')}"
  end

  def test_codex_reviewer_delegates_process_and_artifact_authority_to_core
    source = File.read(File.join(ROOT, "lib/hive/agent_support/codex/reviewer.rb"))
    forbidden = /\bProcess\.(?:spawn|kill|wait2?)|\bFile\.(?:write|delete)/

    refute_match forbidden, source
  end
end
