require "test_helper"

class GemspecTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../../hive.gemspec", __dir__)

  def test_gem_package_includes_babysitter_dry_run_stubs
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "bin/hive-babysitter-stub-gh"
    assert_includes spec.files, "bin/hive-babysitter-stub-git"
  end
end
