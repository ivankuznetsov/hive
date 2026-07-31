require "test_helper"
require "hive/modules/migration/qualification_installed_target"

class ModulesMigrationQualificationInstalledTargetTest <
    Minitest::Test
  include HiveTestHelper

  TARGET =
    Hive::Modules::Migration::QualificationInstalledTarget
  GEM_SHA = ("a" * 64).freeze
  SKILLS_SHA = ("b" * 64).freeze

  def test_materializes_the_exact_descriptor_bound_installed_tree
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      files = installed_files
      digest = tree_digest(files)

      result = TARGET.new.materialize(
        files: files,
        destination: File.join(root, "installed"),
        expected_tree_sha256: digest,
        expected_gem_sha256: GEM_SHA,
        expected_skills_sha256: SKILLS_SHA,
        expected_executable: "bin/hive"
      )

      assert_equal digest, result.tree_sha256
      assert_equal(
        File.join(root, "installed", "bin", "hive"),
        result.executable
      )
      assert_equal 0o700,
                   File.stat(result.executable).mode & 0o777
      assert_equal 0o600,
                   File.stat(
                     File.join(
                       root,
                       "installed",
                       "gems",
                       "hive-cli-0.7.0",
                       "lib",
                       "hive.rb"
                     )
                   ).mode & 0o777
      assert_equal(
        File.join(
          root,
          "installed",
          "gems",
          "hive-cli-0.7.0"
        ),
        result.package_root
      )
      assert_equal "candidate", result.manifest.fetch("role")
    end
  end

  def test_rejects_digest_manifest_mode_and_path_substitution
    mutations = [
      lambda do |files|
        files.fetch(
          "inputs/installed-target/target.json"
        )[:bytes] = target_manifest.merge(
          "gem_sha256" => "f" * 64
        ).then { |value| canonical(value) }
      end,
      lambda do |files|
        files.fetch(
          "inputs/installed-target/gems/" \
            "hive-cli-0.7.0/lib/hive.rb"
        )[:mode] = 0o700
      end,
      lambda do |files|
        files.fetch(
          "inputs/installed-target/target.json"
        )[:bytes] = target_manifest.merge(
          "version" => "../../escape"
        ).then { |value| canonical(value) }
      end,
      lambda do |files|
        files[
          "inputs/installed-target/../escape"
        ] = { bytes: "escape\n", mode: 0o600 }
      end
    ]

    mutations.each do |mutation|
      with_tmp_dir do |root|
        File.chmod(0o700, root)
        files = deep_copy_files(installed_files)
        mutation.call(files)

        assert_raises(Hive::ConfigError) do
          TARGET.new.materialize(
            files: files,
            destination: File.join(root, "installed"),
            expected_tree_sha256: tree_digest(installed_files),
            expected_gem_sha256: GEM_SHA,
            expected_skills_sha256: SKILLS_SHA,
            expected_executable: "bin/hive"
          )
        end
        refute_path_exists File.join(root, "installed")
      end
    end
  end

  private

  def installed_files
    {
      "inputs/installed-target/bin/hive" => {
        bytes: "#!/usr/bin/env ruby\n".b,
        mode: 0o700
      },
      "inputs/installed-target/gems/" \
        "hive-cli-0.7.0/lib/hive.rb" => {
        bytes: "module Hive; end\n".b,
        mode: 0o600
      },
      "inputs/installed-target/target.json" => {
        bytes: canonical(target_manifest),
        mode: 0o600
      }
    }
  end

  def target_manifest
    {
      "schema" => "hive-release-candidate-installed-target",
      "schema_version" => 1,
      "role" => "candidate",
      "version" => "0.7.0",
      "gem_sha256" => GEM_SHA,
      "executable" => "bin/hive",
      "skills" => {
        "archive_sha256" => SKILLS_SHA,
        "import_root" => "skills"
      }
    }
  end

  def tree_digest(files)
    digest = Digest::SHA256.new
    digest << "hive-installed-tree-v1\0"
    files.keys.sort.each do |ref|
      snapshot = files.fetch(ref)
      relative =
        ref.delete_prefix("inputs/installed-target/")
      bytes = snapshot.fetch(:bytes)
      digest << relative << "\0"
      digest << snapshot.fetch(:mode).to_s(8) << "\0"
      digest << bytes.bytesize.to_s << "\0"
      digest << Digest::SHA256.hexdigest(bytes) << "\0"
    end
    digest.hexdigest
  end

  def deep_copy_files(files)
    files.to_h do |ref, snapshot|
      [
        ref.dup,
        {
          bytes: snapshot.fetch(:bytes).dup,
          mode: snapshot.fetch(:mode)
        }
      ]
    end
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end
end
