require_relative "../../test_helper"
require_relative "sandbox"

class E2ESandboxTest < Minitest::Test
  def test_bootstrap_initializes_registered_project
    Dir.mktmpdir("e2e-run") do |dir|
      sandbox = Hive::E2E::Sandbox.bootstrap(dir)

      assert File.directory?(File.join(sandbox.sandbox_dir, ".hive-state"))
      config = YAML.safe_load(File.read(File.join(sandbox.run_home, "config.yml")))
      assert_equal [ "sandbox" ], config.fetch("registered_projects").map { |project| project.fetch("name") }
    end
  end
end
