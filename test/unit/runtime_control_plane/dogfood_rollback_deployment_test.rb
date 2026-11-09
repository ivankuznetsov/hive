require "test_helper"
require "fileutils"
require "open3"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/runtime_control_plane/dogfood_rollback_deployment"

class DogfoodRollbackDeploymentTest < Minitest::Test
  include HiveTestHelper

  Rollback = Hive::RuntimeControlPlane::DogfoodRollbackDeployment
  SOURCE_ROOT = File.expand_path("../../..", __dir__)
  MARKER_FILES = Rollback::SCHEMA_MARKERS.map(&:first).uniq.freeze

  def test_resolves_the_newest_previous_receipt_aware_deployment_and_pins_its_digest
    with_deployments do |root|
      older = deployment(root, time: 100)
      previous = deployment(root, time: 200)
      running = deployment(root, time: 300)

      coordinates = Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))

      assert_equal "dogfood_deployment", coordinates.fetch(:kind)
      assert_equal previous.fetch(:id), coordinates.fetch(:deployment_id)
      assert_equal File.realpath(previous.fetch(:path)), coordinates.fetch(:path)
      assert_equal previous.fetch(:sha), coordinates.fetch(:build_sha)
      assert_equal "bin/hive+lib", coordinates.fetch(:digest_scope)
      assert_equal Time.at(200).utc.iso8601, coordinates.fetch(:committed_at)
      assert_equal Rollback.digest(previous.fetch(:path)), coordinates.fetch(:sha256)
      refute_equal Rollback.digest(older.fetch(:path)), coordinates.fetch(:sha256)
      assert_same coordinates, Rollback.verify!(coordinates)
      assert_same coordinates,
                  Hive::RuntimeControlPlane::CommandSchemaInstallation.validate_coordinates!(coordinates)
    end
  end

  def test_dirty_newest_candidate_falls_back_to_the_next_clean_one
    with_deployments do |root|
      clean = deployment(root, time: 100)
      dirty = deployment(root, time: 200)
      File.write(File.join(dirty.fetch(:path), "bin/hive"), "#!/bin/sh\necho tampered\n")
      running = deployment(root, time: 300)

      coordinates = Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))

      assert_equal clean.fetch(:id), coordinates.fetch(:deployment_id)
    end
  end

  def test_refuses_when_only_the_running_deployment_is_retained
    with_deployments do |root|
      running = deployment(root, time: 300)
      FileUtils.mkdir_p(File.join(root, "unrelated"))
      File.write(File.join(root, "hive-dogfood-#{'f' * 9}"), "not a directory")

      error = assert_raises(Hive::ConfigError) do
        Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))
      end

      assert_match(/no eligible previous dogfood deployment/, error.message)
      assert_match(/only the running deployment is retained/, error.message)
    end
  end

  def test_refuses_pre_receipt_mismatched_newer_dirty_and_unexecutable_builds_by_name
    with_deployments do |root|
      pre_receipt = deployment(root, time: 50, omit: "lib/hive/runtime_control_plane/command_schema.rb")
      mismatched = deployment(root, time: 60, receipt_sha: "0" * 64)
      unexecutable = deployment(root, time: 70, executable: false)
      dirty = deployment(root, time: 80)
      File.write(File.join(dirty.fetch(:path), "bin/hive"), "#!/bin/sh\necho tampered\n")
      running = deployment(root, time: 300)
      newer = deployment(root, time: 400)
      FileUtils.mkdir_p(File.join(root, "hive-dogfood-#{'e' * 9}"))

      error = assert_raises(Hive::ConfigError) do
        Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))
      end

      assert_includes error.message, "pre-receipt build (no command receipt schema): #{pre_receipt.fetch(:id)}"
      assert_includes error.message, "different receipt or base runtime schema: #{mismatched.fetch(:id)}"
      assert_includes error.message, "no executable bin/hive: #{unexecutable.fetch(:id)}"
      assert_includes error.message, "tracked files modified: #{dirty.fetch(:id)}"
      assert_includes error.message, "newer than the running build: #{newer.fetch(:id)}"
      assert_includes error.message, "same build as the running deployment: #{running.fetch(:id)}"
      assert_includes error.message, "build commit unreadable or not matching its directory name: " \
                                     "hive-dogfood-#{'e' * 9}"
      assert_includes error.message, "receipt schema v#{Hive::RuntimeControlPlane::CommandSchema::VERSION}"
    end
  end

  def test_refusal_message_caps_names_per_reason
    with_deployments do |root|
      running = deployment(root, time: 300)
      %w[a b c d e].each { |letter| FileUtils.mkdir_p(File.join(root, "hive-dogfood-#{letter * 9}")) }

      error = assert_raises(Hive::ConfigError) do
        Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))
      end

      assert_includes error.message, "hive-dogfood-#{'c' * 9} (+2 more)"
      refute_includes error.message, "hive-dogfood-#{'d' * 9}"
    end
  end

  def test_requires_a_validated_identity_that_matches_the_running_code
    with_deployments do |root|
      running = deployment(root, time: 300)
      other = deployment(root, time: 200)

      [ nil, { "channel" => "release" }, identity(running).merge("build_sha" => "short") ].each do |value|
        error = assert_raises(Hive::ConfigError) do
          Rollback.resolve!(identity: value, running_root: running.fetch(:path))
        end
        assert_match(/validated dogfood runtime identity/, error.message)
      end
      error = assert_raises(Hive::ConfigError) do
        Rollback.resolve!(identity: identity(running), running_root: other.fetch(:path))
      end
      assert_match(/is not dogfood deployment #{running.fetch(:id)}/, error.message)
    end
  end

  def test_verify_rejects_malformed_missing_and_drifted_coordinates
    with_deployments do |root|
      previous = deployment(root, time: 200)
      running = deployment(root, time: 300)
      coordinates = Rollback.resolve!(identity: identity(running), running_root: running.fetch(:path))

      malformed = assert_raises(Hive::ConfigError) { Rollback.verify!(coordinates.merge(sha256: "nope")) }
      assert_match(/malformed/, malformed.message)
      string_keyed = coordinates.transform_keys(&:to_s)
      assert_same string_keyed, Rollback.verify!(string_keyed)
      assert Rollback.dogfood?(string_keyed)
      refute Rollback.dogfood?(nil)
      refute Rollback.dogfood?(version: "1")

      File.symlink("hive", File.join(previous.fetch(:path), "lib", "hive-link"))
      drifted = assert_raises(Hive::ConfigError) { Rollback.verify!(coordinates) }
      assert_match(/no longer matches its recorded bin\/hive\+lib digest/, drifted.message)

      FileUtils.rm_rf(previous.fetch(:path))
      missing = assert_raises(Hive::ConfigError) do
        Hive::RuntimeControlPlane::CommandSchemaInstallation.validate_coordinates!(coordinates)
      end
      assert_match(/no longer retained/, missing.message)
    end
  end

  def test_digest_covers_bin_hive_and_every_lib_file
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/hive"))
      File.write(File.join(dir, "lib/hive/a.rb"), "a")
      missing_bin = Rollback.digest(dir)
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/hive"), "bin")
      with_bin = Rollback.digest(dir)
      File.write(File.join(dir, "lib/hive/.hidden"), "hidden")
      with_hidden = Rollback.digest(dir)

      assert_equal 3, [ missing_bin, with_bin, with_hidden ].uniq.length
      assert_equal with_hidden, Rollback.digest(dir)
    end
  end

  private

  def with_deployments
    with_tmp_dir do |dir|
      root = File.join(dir, "deployments")
      FileUtils.mkdir_p(root)
      yield root
    end
  end

  def identity(entry)
    { "channel" => "dogfood", "deployment_id" => entry.fetch(:id), "build_sha" => entry.fetch(:sha) }
  end

  # Builds one retained deployment the way hive-dogfood-deploy names it: a
  # git checkout at hive-dogfood-<sha9> whose source pins the schema markers.
  def deployment(root, time:, omit: nil, receipt_sha: nil, executable: true)
    staging = File.join(root, ".staging-#{time}")
    FileUtils.mkdir_p(File.join(staging, "bin"))
    File.write(File.join(staging, "bin/hive"), "#!/bin/sh\necho #{time}\n")
    File.chmod(executable ? 0o755 : 0o644, File.join(staging, "bin/hive"))
    MARKER_FILES.each do |relative|
      next if relative == omit

      target = File.join(staging, relative)
      FileUtils.mkdir_p(File.dirname(target))
      content = File.read(File.join(SOURCE_ROOT, relative))
      if receipt_sha && relative.end_with?("command_schema.rb")
        content = content.sub(/EXPECTED_SCHEMA_SHA256 = "\h{64}"/, %(EXPECTED_SCHEMA_SHA256 = "#{receipt_sha}"))
      end
      File.write(target, content)
    end
    git(staging, "init", "--quiet")
    git(staging, "add", "-A")
    git(staging, "commit", "--quiet", "-m", "build #{time}", time: time)
    sha = git(staging, "rev-parse", "HEAD").strip
    path = File.join(root, "hive-dogfood-#{sha[0, 9]}")
    File.rename(staging, path)
    { id: File.basename(path), path: path, sha: sha }
  end

  def git(dir, *args, time: 0)
    date = "@#{time} +0000"
    env = {
      "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.invalid",
      "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.invalid",
      "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date
    }
    output, status = Open3.capture2e(env, "git", "-C", dir, "-c", "commit.gpgsign=false", *args)
    assert status.success?, output
    output
  end
end
