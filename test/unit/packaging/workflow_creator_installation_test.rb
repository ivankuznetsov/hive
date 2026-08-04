require "test_helper"
require "digest"
require_relative "../../../packaging/live_agent_skills/workflow_creator_installation"

class WorkflowCreatorInstallationTest < Minitest::Test
  include HiveTestHelper

  Installation = HiveLiveAgentProof::WorkflowCreatorInstallation
  Creator = HiveLiveAgentProof::WorkflowCreator
  SHA = "a" * 40

  def test_candidate_computes_and_validates_the_exact_caller_supplied_closure
    with_installation("candidate") do |fixture|
      result = Installation.candidate!(**fixture.fetch(:arguments))

      assert_equal %i[candidate! openclaw!], Installation.singleton_methods(false).sort
      assert_equal Creator::Vocabulary.fetch("member_roles").fetch("candidate"),
                   result.value.fetch("required_roles").keys
      assert_equal fixture.fetch(:inventory).sort,
                   result.value.fetch("inventory").map { |record| record.fetch("path") }
      assert_equal fixture.fetch(:manifest).fetch("hive_version"), result.value.fetch("version")
      assert_equal result.canonical_bytes, Creator::Values.capture(result.value).canonical_bytes
      validated = Creator.validate_installation!(
        document: result.value, kind: "candidate", manifest: fixture.fetch(:manifest), candidate_sha: SHA
      )
      assert_equal result.canonical_bytes, validated.canonical_bytes
    end
  end

  def test_openclaw_uses_the_exact_caller_supplied_version_without_selecting_or_installing
    with_installation("openclaw") do |fixture|
      arguments = fixture.fetch(:arguments).merge(version: "openclaw-2026.8.4")

      result = Installation.openclaw!(**arguments)

      assert_equal "openclaw", result.value.fetch("kind")
      assert_equal "openclaw-2026.8.4", result.value.fetch("version")
      assert_equal Creator::Vocabulary.fetch("member_roles").fetch("openclaw"),
                   result.value.fetch("required_roles").keys
      assert_equal [], Dir.children(fixture.fetch(:root)).grep(/manifest/)
    end
  end

  def test_refuses_missing_duplicate_outside_and_unmanifested_inputs
    with_installation("candidate") do |fixture|
      arguments = fixture.fetch(:arguments)
      assert_invalid(arguments.merge(inventory: arguments.fetch(:inventory) - [ "runtime/dependency.rb" ]))
      assert_invalid(arguments.merge(inventory: arguments.fetch(:inventory) + [ "lock/lockfile" ]))
      assert_invalid(arguments.merge(executable: "../outside"))

      File.write(File.join(fixture.fetch(:root), "unmanifested"), "foreign")
      assert_invalid(arguments)
    end
  end

  def test_refuses_symlinks_hardlinks_special_files_and_mutable_directories
    with_installation("candidate") do |fixture|
      arguments = fixture.fetch(:arguments)
      executable = File.join(fixture.fetch(:root), arguments.fetch(:executable))
      FileUtils.rm_f(executable)
      File.symlink("../lock/lockfile", executable)
      assert_invalid(arguments)
    end

    with_installation("candidate") do |fixture|
      arguments = fixture.fetch(:arguments)
      source = File.join(fixture.fetch(:root), arguments.fetch(:executable))
      File.link(source, File.join(fixture.fetch(:root), "executable-alias"))
      assert_invalid(arguments.merge(inventory: arguments.fetch(:inventory) + [ "executable-alias" ]))
    end

    with_installation("candidate") do |fixture|
      FileUtils.chmod(0o777, fixture.fetch(:root))
      assert_invalid(fixture.fetch(:arguments))
    end
  end

  def test_refuses_stale_candidate_package_identity_and_invalid_openclaw_version
    with_installation("candidate") do |fixture|
      package = File.join(fixture.fetch(:root), fixture.dig(:arguments, :package))
      File.binwrite(package, "changed")
      assert_invalid(fixture.fetch(:arguments))
    end

    with_installation("openclaw") do |fixture|
      assert_raises(Installation::Error) do
        Installation.openclaw!(**fixture.fetch(:arguments), version: "")
      end
    end
  end

  private

  def assert_invalid(arguments)
    error = assert_raises(Installation::Error) { Installation.candidate!(**arguments) }
    assert_equal "workflow-creator installation closure is invalid", error.message
  end

  def with_installation(kind)
    with_tmp_dir do |root|
      roles = Creator::Vocabulary.fetch("member_roles").fetch(kind)
      role_paths = roles.to_h { |role| [ role.to_sym, role_path(role) ] }
      inventory = [ *role_paths.values, "runtime/dependency.rb" ].sort
      inventory.each do |path|
        target = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        File.binwrite(target, "bytes:#{path}")
      end
      manifest = artifact_manifest(File.binread(File.join(root, role_paths.fetch(:package))))
      arguments = {
        root:, candidate_sha: SHA, manifest:, inventory:,
        **role_paths
      }
      arguments.delete(:audit_gateway) if kind == "openclaw"
      yield root:, manifest:, inventory:, arguments:
    end
  end

  def role_path(role)
    role == "package" ? "packages/package.tgz" : "#{role}/fixture"
  end

  def artifact_manifest(candidate_package)
    version = "1.2.3"
    names = [ "hive-agent-skills-#{SHA}.tar.gz", "hive-cli-#{version}.gem", "hive-source-#{SHA}.tar.gz" ]
    files = names.to_h do |name|
      bytes = name.start_with?("hive-cli-") ? candidate_package : "artifact:#{name}"
      [ name, { "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize } ]
    end
    {
      "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1,
      "candidate_sha" => SHA, "hive_version" => version, "skill_version" => "2026.8.4",
      "canonical_digest" => Digest::SHA256.hexdigest("canonical"), "files" => files
    }
  end
end
