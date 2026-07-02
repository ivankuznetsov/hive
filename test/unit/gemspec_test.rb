require "test_helper"

class GemspecTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../../hive.gemspec", __dir__)

  def test_gem_package_includes_babysitter_dry_run_stubs
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "bin/hive-babysitter-skip-log.rb"
    assert_includes spec.files, "bin/hive-babysitter-stub-gh"
    assert_includes spec.files, "bin/hive-babysitter-stub-git"
  end

  def test_gem_package_includes_launcher_scripts
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "lib/hive/scripts/interactive_claude_wrapper.sh"
    assert_includes spec.files, "lib/hive/scripts/stop_hook.sh"
  end

  def test_gem_executables_exclude_bash_hv_launcher
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.executables, "hive"
    refute_includes spec.executables, "hv"
    assert_includes spec.files, "bin/hv"
  end

  # The web tier is a Rails app under web/, supported only in the Docker
  # image or a source checkout — the gem must stay a lean CLI and not
  # package the app or its old Sinatra-era assets.
  def test_gem_package_excludes_the_rails_web_app
    spec = Gem::Specification.load(GEMSPEC_PATH)

    refute spec.files.any? { |f| f.start_with?("web/") },
           "the Rails app must not ship inside the gem"
    refute spec.files.any? { |f| f.start_with?("public/") },
           "no Sinatra-era static assets should be packaged"
  end
end
