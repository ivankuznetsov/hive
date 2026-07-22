require "test_helper"
require "shellwords"
require "hive/agent_skills/adapters/registry"

class AgentSkillAdaptersIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_pi_adapter_executes_an_argv_array_without_a_shell
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      bin = File.join(dir, "fake-pi")
      File.write(bin, <<~SH)
        #!/bin/sh
        : > #{Shellwords.escape(log)}
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> #{Shellwords.escape(log)}
        done
      SH
      FileUtils.chmod(0o755, bin)

      manifest = Hive::AgentSkills::Manifest.load
      target = Hive::AgentSkills::Target.new(
        surfaces: [ "brainstorm" ], kind: "stage", agent: "pi",
        configured_skill: "ce-brainstorm", invocation: "/skill:ce-brainstorm",
        capability_id: "ce-brainstorm", package_id: "compound-engineering", managed: true
      )
      row = Hive::AgentSkills::Inspection.new(
        target: target,
        expected: {},
        native: { "available" => true, "bin" => bin, "package" => nil, "marketplace" => nil },
        resolution: { "path" => nil },
        health: "missing", severity: "error", explanation: "missing", remediation: "repair"
      )
      adapter = Hive::AgentSkills::Adapters::Pi.new(
        config: Hive::Config::DEFAULTS,
        project_root: dir,
        manifest: manifest,
        environment: { "HOME" => dir, "PATH" => ENV.fetch("PATH", "") }
      )

      operation = adapter.plan([ row ]).operations.fetch(0)
      outcome = adapter.execute(operation)

      assert_equal "succeeded", outcome.status
      assert_equal [ "install", "https://github.com/EveryInc/compound-engineering-plugin" ], File.readlines(log, chomp: true)
    end
  end
end
