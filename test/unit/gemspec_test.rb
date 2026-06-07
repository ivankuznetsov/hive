require "test_helper"

class GemspecTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../../hive.gemspec", __dir__)

  def test_gem_package_includes_babysitter_dry_run_stubs
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "bin/hive-babysitter-stub-gh"
    assert_includes spec.files, "bin/hive-babysitter-stub-git"
  end

  def test_gem_executables_exclude_bash_hv_launcher
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.executables, "hive"
    refute_includes spec.executables, "hv"
    assert_includes spec.files, "bin/hv"
  end
end
