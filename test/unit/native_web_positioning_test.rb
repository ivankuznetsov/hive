require "test_helper"

class NativeWebPositioningTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  MAINTAINED_ENTRY_POINTS = %w[
    README.md
    install.md
    docs/getting-started.md
    docs/cli.md
    docs/faq.md
    docs/architecture.md
    docs/hive-site-companion.md
    docs/RELEASING.md
    openclaw/README.md
    openclaw/skills/hive/SKILL.md
    wiki/index.md
    wiki/cli.md
    wiki/commands.md
    wiki/commands/setup.md
    wiki/commands/web.md
    wiki/architecture.md
    wiki/operating.md
    wiki/modules/config.md
  ].freeze

  NATIVE_FIRST_ENTRY_POINTS = %w[
    README.md
    install.md
    docs/getting-started.md
    docs/hive-site-companion.md
    openclaw/README.md
    openclaw/skills/hive/SKILL.md
    wiki/index.md
    wiki/commands.md
    wiki/operating.md
  ].freeze

  HISTORICAL_ALLOWLIST = [
    "CHANGELOG.md",
    "wiki/gaps.md",
    "wiki/log.md",
    "wiki/log.d/",
    "docs/plans/"
  ].freeze

  LEGACY_ALIAS_DOC_ALLOWLIST = %w[
    docs/architecture.md
    openclaw/skills/hive/SKILL.md
    wiki/commands/setup.md
    wiki/commands/web.md
    wiki/modules/config.md
  ].freeze

  FORBIDDEN_MAINTAINED_PHRASES = [
    /why no built-in web ui/i,
    /golden-path docker/i,
    /hivebox web ui/i
  ].freeze

  def test_maintained_entry_points_do_not_reintroduce_stale_positioning
    MAINTAINED_ENTRY_POINTS.each do |path|
      text = read(path)
      FORBIDDEN_MAINTAINED_PHRASES.each do |phrase|
        refute_match phrase, text, "#{path} contains stale native-web positioning"
      end
    end
  end

  def test_designated_entry_points_lead_with_native_setup_before_hivebox
    NATIVE_FIRST_ENTRY_POINTS.each do |path|
      text = read(path)
      native = text.index("hive setup")
      hivebox = text.index(/Hivebox/i)

      refute_nil native, "#{path} must teach hive setup"
      refute_nil hivebox, "#{path} must retain a concise Hivebox choice"
      assert_operator native, :<, hivebox, "#{path} must put native setup first"
    end
  end

  def test_legacy_native_aliases_are_confined_to_explicit_migration_docs
    legacy = /HIVEBOX_(?:WEB_APP_DIR|ORIGIN|STORAGE_DIR|LOCAL_LOOPBACK|DIFF_TIMEOUT_SEC|CLONE_TIMEOUT_SEC)/

    MAINTAINED_ENTRY_POINTS.each do |path|
      next unless read(path).match?(legacy)

      assert_includes LEGACY_ALIAS_DOC_ALLOWLIST, path,
        "#{path} reads like a current alias consumer instead of migration documentation"
    end
  end

  def test_historical_allowlist_is_explicit_and_does_not_include_entry_points
    HISTORICAL_ALLOWLIST.each do |entry|
      refute_includes MAINTAINED_ENTRY_POINTS, entry
    end
    assert HISTORICAL_ALLOWLIST.any? { |entry| entry.end_with?("/") }
  end

  def test_ci_labels_the_shared_rails_app_as_hive_web
    workflow = read(".github/workflows/ci.yml")

    assert_includes workflow, "name: Hive web (Rails tests + system)"
    assert_includes workflow, "name: Hive web golden-path E2E"
    refute_includes workflow, "name: hivebox web (Rails tests + system)"
  end

  def test_hivebox_container_and_installer_jobs_remain_pinned
    ci = read(".github/workflows/ci.yml")
    release = read(".github/workflows/release.yml")
    install_smoke = read(".github/workflows/install-smoke.yml")
    install_verify = read(".github/workflows/install-verify.yml")

    assert_includes ci, "hivebox-installer-windows:"
    assert_includes ci, "packaging/docker/test-install-box.ps1"
    assert_includes release, "hivebox-image-amd64:"
    assert_includes release, "hivebox-image-arm64:"
    assert_includes release, "hivebox-image:"
    assert_operator release.scan("packaging/docker/smoke.sh").length, :>=, 2
    assert_includes install_smoke, "packaging/docker/test-install-box.sh"
    assert_includes install_verify, "packaging/verify-channel.sh"
  end

  def test_dedicated_hivebox_documentation_keeps_complete_container_contract
    readme = read("packaging/docker/README.md")

    assert_includes readme, "Hivebox"
    assert_includes readme, "install-box.{sh,ps1}"
    assert_match(/upgrade/i, readme)
    assert_match(/troubleshoot/i, readme)
    assert_includes readme, "127.0.0.1"
  end

  def test_hive_site_companion_handoff_pins_pages_build_and_delivery_boundary
    handoff = read("docs/hive-site-companion.md")

    %w[
      index.md
      _includes/landing/hero.html
      docs/getting-started.md
      docs/configuration.md
      docs/operating.md
      docs/commands/setup.md
      docs/commands/web.md
      box/index.md
    ].each { |path| assert_includes handoff, path }

    assert_includes handoff, "bundle exec jekyll build"
    assert_includes handoff, "npx -y pagefind@^1 --site _site"
    assert_includes handoff, "non-draft PR"
    assert_includes handoff, "without merge"
    assert_match(/without merge,\s+auto-merge, version bump, publication, or Cloudflare deployment/, handoff)
    assert_includes handoff, "Hive PR release-note block"
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
