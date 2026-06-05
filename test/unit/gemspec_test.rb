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

  # Regression: the installed gem must ship the hivebox web UI assets. The
  # source tree masks their absence (views/public resolve relative to __dir__
  # at dev time), but a packaged gem without them makes `hive web` 500 on
  # every rendered page.
  def test_gem_package_includes_web_view_and_public_assets
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "lib/hive/web/views/login.erb",
                    "web ERB view templates must be packaged"
    assert_includes spec.files, "lib/hive/web/views/layout.erb"
    assert_includes spec.files, "public/css/app.css",
                    "web static CSS must be packaged"
    assert_includes spec.files, "public/js/sse.js",
                    "web static JS must be packaged"
  end
end
