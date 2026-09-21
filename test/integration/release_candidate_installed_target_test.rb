require "test_helper"
require "digest"
require "fileutils"
require_relative "../../packaging/release_candidate/installed_target"

class ReleaseCandidateInstalledTargetTest < Minitest::Test
  include HiveTestHelper

  def test_resolves_only_owned_manifest_roles_and_scrubs_host_environment
    with_tmp_dir do |dir|
      baseline = target(dir, "baseline", "same-version baseline")
      candidate = target(dir, "candidate", "same-version candidate")

      refute_equal baseline.executable, candidate.executable
      assert_equal "baseline", File.read(baseline.executable)
      assert_equal "candidate", File.read(candidate.executable)
      env = candidate.environment(
        "PATH" => "/host/bin", "RUBYLIB" => "/checkout/lib",
        "BUNDLE_GEMFILE" => "/checkout/Gemfile", "HIVE_HOME" => "/host/hive",
        "GH_TOKEN" => "secret", "AWS_ACCESS_KEY_ID" => "aws",
        "SSH_AUTH_SOCK" => "/run/user/1000/ssh.sock", "DB_PASSWORD" => "database",
        "LANG" => "en_GB.UTF-8", "TZ" => "Europe/London"
      )
      refute_includes env.fetch("PATH"), "/host/bin"
      refute env.key?("RUBYLIB")
      refute env.key?("BUNDLE_GEMFILE")
      refute env.key?("GH_TOKEN")
      refute env.key?("AWS_ACCESS_KEY_ID")
      refute env.key?("SSH_AUTH_SOCK")
      refute env.key?("DB_PASSWORD")
      assert_equal "en_GB.UTF-8", env.fetch("LANG")
      assert_equal "Europe/London", env.fetch("TZ")
      assert_equal File.join(candidate.state_root, "hive"), env.fetch("HIVE_HOME")

      assert_raises(HiveReleaseCandidate::UsageError) do
        HiveReleaseCandidate::InstalledTarget.new(
          role: "arbitrary", root: candidate.root, state_root: candidate.state_root
        )
      end
    end
  end

  def test_install_contract_is_offline_and_binds_gem_plus_skill_import
    with_tmp_dir do |dir|
      package = File.join(dir, "hive-cli-0.6.9.gem")
      skills = File.join(dir, "hive-agent-skills-deadbeef.tar.gz")
      File.binwrite(package, "gem")
      File.binwrite(skills, "skills")
      install_root = File.join(dir, "installed")
      offline_cache = File.join(dir, "cache")
      FileUtils.mkdir_p(offline_cache)
      dependency = File.join(offline_cache, "dependency-1.0.0.gem")
      File.binwrite(dependency, "dependency")

      contract = HiveReleaseCandidate::InstalledTarget.install_contract(
        role: "baseline", install_root: install_root, gem_path: package,
        skills_archive: skills, offline_cache: offline_cache,
        dependency_gems: [ dependency ]
      )

      assert_equal false, contract.fetch("network")
      assert_includes contract.fetch("gem_install_argv"), "--local"
      assert_includes contract.fetch("gem_install_argv"), "--ignore-dependencies"
      assert_equal dependency, contract.fetch("dependency_install_argv").first.fetch(2)
      assert_equal skills, contract.fetch("skills").fetch("archive")
      assert_equal File.join(install_root, "skills"), contract.fetch("skills").fetch("import_root")
    end
  end


  def target(dir, role, bytes)
    root = File.join(dir, role)
    executable = File.join(root, "bin", "hive")
    FileUtils.mkdir_p(File.dirname(executable))
    File.binwrite(executable, role)
    File.chmod(0o755, executable)
    File.binwrite(File.join(root, "target.json"), JSON.generate(
      "schema" => "hive-release-candidate-installed-target",
      "schema_version" => 1,
      "role" => role,
      "version" => "0.6.9",
      "gem_sha256" => Digest::SHA256.hexdigest(bytes),
      "executable" => "bin/hive",
      "skills" => { "archive_sha256" => "c" * 64, "import_root" => "skills" }
    ))
    HiveReleaseCandidate::InstalledTarget.new(
      role: role, root: root, state_root: File.join(dir, "state")
    )
  end
end
