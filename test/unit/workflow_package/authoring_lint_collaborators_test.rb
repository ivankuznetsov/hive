require "test_helper"
require "hive/workflow_package/authoring_lint"

class WorkflowPackageAuthoringLintCollaboratorsTest < Minitest::Test
  include HiveTestHelper

  Lint = Hive::WorkflowPackage::AuthoringLint
  Policy = Hive::WorkflowPackage::LintPolicy

  def test_package_reader_returns_ordered_immutable_files_and_typed_rejections
    with_tmp_dir do |root|
      File.write(File.join(root, "z.md"), "z\n")
      File.write(File.join(root, "a.md"), "a\n")
      File.symlink("a.md", File.join(root, "linked.md"))

      snapshot = package_reader.new(
        root, limits: Policy.load.limits
      ).read

      assert_equal %w[a.md z.md], snapshot.files.map(&:path)
      assert_equal [ "policy.invalid-file" ], snapshot.events.map(&:rule_id)
      assert snapshot.frozen?
      assert snapshot.files.frozen?
      assert snapshot.events.frozen?
      assert snapshot.files.all?(&:frozen?)
      assert snapshot.files.all? { |entry| entry.path.frozen? }
      assert snapshot.files.all? { |entry| entry.bytes.frozen? }
      assert snapshot.files.all? { |entry| entry.text.frozen? }
    end
  end

  def test_command_extractors_preserve_format_behavior_order_and_global_limit
    with_tmp_dir do |root|
      payloads = {
        "README.md" => "# Demo\n",
        "workflow.yml" => "command: curl https://yaml.example\n",
        "instructions/work.md" => "cat /tmp/input\n",
        "prompts/broken.json" => "curl https://json.example\n{\n",
        "tools/check.rb" => "system(\"echo ruby\")\n",
        "tools/run.sh" => "echo shell\n",
        "tools/runner" => "curl https://extensionless.example\n"
      }
      payloads.reverse_each do |relative, bytes|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, bytes)
      end
      manifest = lint_manifest({
        "x-hive" => {
          "tools" => [
            { "path" => "tools/check.rb" },
            { "path" => "tools/run.sh" },
            { "path" => "tools/runner" }
          ],
          "prompt_assets" => [ { "path" => "prompts/broken.json" } ]
        }
      })
      policy = Policy.load
      snapshot = package_reader.new(root, limits: policy.limits).read

      batch = command_extractor.new(
        manifest: manifest, limits: policy.limits
      ).extract(snapshot.files)

      assert_equal(
        %w[
          instructions/work.md prompts/broken.json tools/check.rb tools/run.sh
          tools/runner workflow.yml
        ],
        batch.commands.map(&:path)
      )
      assert_empty batch.events
      assert batch.frozen?
      assert batch.commands.frozen?
      assert batch.commands.all?(&:frozen?)
      assert batch.commands.all? { |command| command.raw.frozen? }

      limited = command_extractor.new(
        manifest: manifest,
        limits: policy.limits.merge("max_commands" => 1).freeze
      ).extract(snapshot.files)
      assert_equal 1, limited.commands.length
      assert limited.events.all? do |event|
        event.rule_id == "policy.command-limit"
      end
      refute_empty limited.events
    end
  end

  def test_observation_extractor_preserves_dynamic_hosts_limits_and_immutability
    with_tmp_dir do |root|
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "workflow.yml"), "id: demo\nstages: []\n")
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(
        File.join(root, "instructions", "work.md"),
        "curl https://one.example\ncurl \"$API_URL\"\n"
      )
      policy = Policy.load
      manifest = lint_manifest
      snapshot = package_reader.new(root, limits: policy.limits).read
      commands = command_extractor.new(
        manifest: manifest, limits: policy.limits
      ).extract(snapshot.files)

      batch = observation_extractor.new(
        limits: policy.limits
      ).extract(commands.commands)

      assert_equal [ "one.example", "<dynamic>" ],
                   batch.observations.map(&:host)
      assert_equal [ false, true ], batch.observations.map(&:dynamic)
      assert batch.frozen?
      assert batch.observations.frozen?
      assert batch.observations.all?(&:frozen?)
      assert batch.observations.all? { |observation| observation.raw.frozen? }

      limited = observation_extractor.new(
        limits: policy.limits.merge("max_observations" => 1).freeze
      ).extract(commands.commands)
      assert_equal 1, limited.observations.length
      assert_includes limited.events.map(&:rule_id), "policy.observation-limit"
    end
  end

  def test_finding_buffer_pops_newest_once_and_manifest_snapshot_keeps_hash_order
    policy = Policy.load
    limited = policy.with(
      limits: policy.limits.merge("max_findings" => 2).freeze
    )
    buffer = finding_buffer.new(limited)
    buffer.add("pii.email", :warning, "a", 1, 1, "first")
    buffer.add("pii.phone", :warning, "b", 1, 1, "newest")
    buffer.add("pii.government-id", :error, "c", 1, 1, "overflow")
    buffer.add("pii.phone", :warning, "d", 1, 1, "ignored")

    assert_equal %w[pii.email policy.finding-limit],
                 buffer.finish.map(&:rule_id).sort

    with_tmp_dir do |root|
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "workflow.yml"), "id: demo\nstages: []\n")

      first_permissions = {
        "risk" => "low", "filesystem_read" => [ "*" ],
        "capabilities" => [], "network_hosts" => [],
        "filesystem_write" => [], "secrets" => []
      }
      second_permissions = {
        "filesystem_read" => [ "*" ], "risk" => "low",
        "capabilities" => [], "network_hosts" => [],
        "filesystem_write" => [], "secrets" => []
      }
      first = Lint.verify(
        root, manifest: lint_manifest(permissions: first_permissions),
        policy: policy
      )
      second = Lint.verify(
        root, manifest: lint_manifest(permissions: second_permissions),
        policy: policy
      )
      first_fingerprint = first.findings
                               .find { |item| item.rule_id == "permission.broad-declaration" }
                               .fingerprint
      second_fingerprint = second.findings
                                .find { |item| item.rule_id == "permission.broad-declaration" }
                                .fingerprint

      refute_equal first_fingerprint, second_fingerprint
    end
  end

  private

  def package_reader = Lint.const_get(:PackageReader, false)
  def command_extractor = Lint.const_get(:CommandExtractor, false)
  def observation_extractor = Lint.const_get(:ObservationExtractor, false)

  def finding_buffer
    evaluator = Lint.const_get(:FindingEvaluator, false)
    evaluator.const_get(:FindingBuffer, false)
  end

  def lint_manifest(data = {}, permissions: default_permissions)
    Struct.new(:data, :permissions).new(
      { "permissions" => permissions }.merge(data), permissions
    )
  end

  def default_permissions
    {
      "risk" => "low", "capabilities" => [ "filesystem-read" ],
      "network_hosts" => [], "filesystem_read" => %w[repository task],
      "filesystem_write" => [], "secrets" => []
    }
  end
end
