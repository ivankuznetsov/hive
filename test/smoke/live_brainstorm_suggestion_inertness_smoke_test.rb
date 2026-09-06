# frozen_string_literal: true

require "test_helper"
require "open3"
require "timeout"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions/envelope"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

# Real-provider proof for the first-pass advisory grammar. The provider is
# configurable so a temporarily exhausted account does not force a fixture to
# masquerade as model evidence:
#
#   HIVE_TEST_ALLOW_REAL_USER_ENV=1 \
#     HIVE_LIVE_BRAINSTORM_AGENT=codex \
#     bin/test test/smoke/live_brainstorm_suggestion_inertness_smoke_test.rb
class LiveBrainstormSuggestionInertnessSmokeTest < Minitest::Test
  include HiveTestHelper

  TIMEOUT_SEC = 300
  AGENTS = %w[claude codex].freeze

  def setup
    @agent = ENV.fetch("HIVE_LIVE_BRAINSTORM_AGENT", "codex")
    skip "live brainstorm agent must be one of #{AGENTS.join(', ')}" unless AGENTS.include?(@agent)

    @override_key = "HIVE_#{@agent.upcase}_BIN"
    @previous_bin = ENV[@override_key]
    configured = ENV["HIVE_LIVE_#{@agent.upcase}_BIN"].to_s
    resolved, status = Open3.capture2("mise", "which", @agent) if configured.empty?
    executable = configured.empty? && status&.success? ? resolved.to_s.strip : configured
    skip "real #{@agent} binary is unavailable" unless File.file?(executable) && File.executable?(executable)

    ENV[@override_key] = executable
    Hive::AgentProfile.reset_version_cache!
  rescue Errno::ENOENT
    skip "mise could not resolve the real #{@agent} binary"
  end

  def teardown
    if @previous_bin
      ENV[@override_key] = @previous_bin
    elsif @override_key
      ENV.delete(@override_key)
    end
    Hive::AgentProfile.reset_version_cache!
  end

  def test_untouched_suggestion_envelope_is_inert_to_real_brainstorm_producer
    with_tmp_global_config(home: ENV.fetch("HOME")) do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        configure_project(project_root)
        project = File.basename(project_root)
        capture_io do
          Hive::Commands::New.new(project, "choose a repository adapter").call
        end

        slug = File.basename(
          Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")].fetch(0)
        )
        brainstorm_dir = File.join(
          project_root, ".hive-state", "stages", "2-brainstorm", slug
        )
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(
          File.join(project_root, ".hive-state", "stages", "1-inbox", slug),
          brainstorm_dir
        )
        envelope = Hive::BrainstormSuggestions::Envelope.render(
          binding: "d" * 64, text: "Use the repository adapter."
        )
        brainstorm_md = File.join(brainstorm_dir, "brainstorm.md")
        File.write(
          brainstorm_md,
          "## Round 1\n### Q1. Which adapter?\n### A1.\n#{envelope}\n<!-- WAITING -->\n"
        )

        Timeout.timeout(TIMEOUT_SEC) { Hive::Commands::Run.new(brainstorm_dir).call }

        body = File.read(brainstorm_md)
        assert_equal :waiting, Hive::Markers.current(brainstorm_md).name
        assert_nil Hive::BrainstormParser.parse(brainstorm_md).first.answer
        assert_includes body, envelope
        refute_includes body, "## Requirements"
        refute_includes body, "<!-- COMPLETE -->"
        assert_equal "2-brainstorm", File.basename(File.dirname(brainstorm_dir))
      end
    end
  end

  private

  def configure_project(project_root)
    path = File.join(project_root, ".hive-state", "config.yml")
    config = YAML.safe_load_file(path)
    config.dig("brainstorm", "suggestions")["enabled"] = true
    config["brainstorm"]["agent"] = @agent
    config["claude"]["mode"] = "headless" if @agent == "claude"
    File.write(path, config.to_yaml)
  end
end
