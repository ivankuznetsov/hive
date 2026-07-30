require "test_helper"
require "open3"

require File.expand_path("../../../packaging/render.rb", __dir__)

# packaging/render.rb is the single template-rendering path shared by the
# AUR publish job and the Homebrew tap workflow. These tests pin both the
# in-process rendering API and the CLI contract that CI actually invokes
# (exit codes + the "no partial output on error" guarantee).
class PackagingRenderTest < Minitest::Test
  include HiveTestHelper

  RENDER_RB = File.expand_path("../../../packaging/render.rb", __dir__).freeze
  HOMEBREW_ERB = File.expand_path("../../../packaging/homebrew/hive.rb.erb", __dir__).freeze
  PKGBUILD_TEMPLATE = File.expand_path("../../../packaging/aur/PKGBUILD.template", __dir__).freeze
  AUR_INSTALL = File.expand_path("../../../packaging/aur/hive.install", __dir__).freeze
  AUR_MIGRATION_SERVICE = File.expand_path(
    "../../../packaging/aur/hive-job-schema-migration.service", __dir__
  ).freeze

  SAMPLE_SHA = "a" * 64

  # ─── in-process render API ───────────────────────────────────────────

  def test_renders_homebrew_formula_with_version_and_sha
    template = File.read(HOMEBREW_ERB)
    out = Hive::PackagingRender.render(
      template, { "version" => "0.1.1", "sha256_gem" => SAMPLE_SHA }, HOMEBREW_ERB
    )
    assert_includes out, 'version "0.1.1"'
    assert_includes out, %(sha256 "#{SAMPLE_SHA}")
    assert_includes out, "releases/download/v0.1.1/hive-cli-0.1.1.gem"
    assert_includes out, 'depends_on "cosign"'
    assert_includes out,
                    'system bin/"hive", "refactor-patrol-migrate-installed"'
    refute_match(/sudo .*refactor-patrol-migrate-installed/, out)
    assert_includes out, "must never be run"
  end

  def test_renders_pkgbuild_with_version_and_sha
    template = File.read(PKGBUILD_TEMPLATE)
    out = Hive::PackagingRender.render(
      template, { "version" => "0.1.1", "sha256_gem" => SAMPLE_SHA }, PKGBUILD_TEMPLATE
    )
    assert_includes out, "pkgver=0.1.1"
    assert_includes out, "'#{SAMPLE_SHA}'"
    assert_includes out, "depends=('ruby' 'cosign')"
    assert_includes out, '"hive-job-schema-migration.service"'
    assert_includes out, '"hive-job-schema-migration.timer"'
  end

  def test_pkgbuild_wrapper_preserves_user_facing_binary_for_daemon_units
    template = File.read(PKGBUILD_TEMPLATE)
    out = Hive::PackagingRender.render(
      template, { "version" => "0.1.1", "sha256_gem" => SAMPLE_SHA }, PKGBUILD_TEMPLATE
    )
    export_line = 'export HIVE_INVOKED_BIN="/usr/bin/hive"'
    exec_line =
      'exec /usr/bin/ruby "/usr/share/hive/gems/bin/hive" "\$@"'

    assert_includes out, export_line
    assert_includes out, exec_line
    assert_operator out.index(export_line), :<, out.index(exec_line)
    refute_includes out, "HIVE_INVOKED_BIN:-"
  end

  def test_aur_hook_runs_all_users_and_enables_hourly_retry
    hook = File.read(AUR_INSTALL)

    assert_includes hook,
                    "/usr/bin/hive refactor-patrol-migrate-installed --all-users"
    assert_includes hook,
                    "systemctl enable --now hive-job-schema-migration.timer"
    assert_includes File.read(AUR_MIGRATION_SERVICE),
                    "refactor-patrol-migrate-installed --all-users --resume"
    assert_includes hook,
                    "bounded hourly sweep resumes any deferred profile"
    refute_match(%r{\bfind\s+/home\b}, hook)
  end

  def test_render_raises_on_undefined_variable
    err = assert_raises(Hive::PackagingRender::Error) do
      Hive::PackagingRender.render(
        File.read(HOMEBREW_ERB), { "version" => "0.1.1" }, HOMEBREW_ERB
      )
    end
    assert_match(/undefined variable/, err.message)
    assert_match(/sha256_gem/, err.message)
  end

  # A value with shell metacharacters must be emitted verbatim — the
  # renderer does pure string substitution and never shell-evaluates.
  def test_values_are_substituted_verbatim_without_shell_evaluation
    dangerous = 'abc123";  rm -rf /  #'
    out = Hive::PackagingRender.render(
      "sha=<%= sha256_gem %>\n", { "sha256_gem" => dangerous }, "(inline)"
    )
    assert_equal "sha=#{dangerous}\n", out
  end

  # ─── CLI contract ────────────────────────────────────────────────────

  def test_cli_happy_path_writes_formula_to_stdout
    out, err, status = run_cli(HOMEBREW_ERB, "version=0.1.1", "sha256_gem=#{SAMPLE_SHA}")
    assert_equal 0, status.exitstatus, "expected exit 0, stderr: #{err}"
    assert_includes out, 'version "0.1.1"'
    assert_empty err
  end

  def test_cli_missing_variable_exits_nonzero_with_no_stdout
    out, err, status = run_cli(HOMEBREW_ERB, "version=0.1.1")
    refute_equal 0, status.exitstatus
    assert_empty out, "no partially-rendered output may reach stdout on error"
    assert_match(/sha256_gem/, err)
  end

  def test_cli_missing_template_exits_nonzero
    out, err, status = run_cli("packaging/does-not-exist.erb", "version=0.1.1")
    refute_equal 0, status.exitstatus
    assert_empty out
    assert_match(/template not found/, err)
  end

  def test_cli_malformed_argument_exits_nonzero
    out, err, status = run_cli(HOMEBREW_ERB, "not-a-pair")
    refute_equal 0, status.exitstatus
    assert_empty out
    assert_match(/malformed key=value/, err)
  end

  private

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, RENDER_RB, *args)
  end
end
