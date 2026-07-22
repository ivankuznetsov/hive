require "test_helper"
require "open3"

class LiveAgentCandidateGemInstallerTest < Minitest::Test
  include HiveTestHelper

  INSTALLER = File.expand_path(
    "../../packaging/live_agent_skills/install_candidate_gem.sh",
    __dir__
  )

  def test_private_install_wrapper_restores_its_gem_home
    with_tmp_dir do |root|
      source = File.join(root, "fixture-source")
      executable = File.join(source, "exe", "hive")
      gem_file = File.join(root, "hive-cli-fixture.gem")
      install_root = File.join(root, "private gem home")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "#!/usr/bin/env ruby\nputs 'private-candidate-ok'\n")
      FileUtils.chmod(0o755, executable)
      File.write(File.join(source, "fixture.gemspec"), <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "hive-cli"
          spec.version = "9.9.9"
          spec.summary = "Private candidate wrapper fixture"
          spec.authors = ["Hive tests"]
          spec.files = ["exe/hive"]
          spec.bindir = "exe"
          spec.executables = ["hive"]
          spec.require_paths = ["lib"]
        end
      RUBY

      build_out, build_err, build_status = Open3.capture3(
        "gem", "build", "fixture.gemspec", "--output", gem_file,
        chdir: source
      )
      assert build_status.success?, "#{build_out}\n#{build_err}"

      install_out, install_err, install_status = Open3.capture3(
        INSTALLER, gem_file, install_root
      )
      assert install_status.success?, "#{install_out}\n#{install_err}"

      wrapper = File.join(install_root, "bin", "hive")
      assert File.executable?(wrapper)
      out, err, status = Open3.capture3(
        { "GEM_HOME" => nil, "GEM_PATH" => nil },
        wrapper, "--version"
      )
      assert status.success?, err
      assert_equal "private-candidate-ok\n", out
    end
  end
end
