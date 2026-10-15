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
    skills/hive/references/setup-and-platforms.md
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
    skills/hive/references/setup-and-platforms.md
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

  # Hive has two supported routes: native Hive (Homebrew, AUR, the glibc
  # Linux installer, or WSL with systemd on Windows) for people who want to
  # tinker, or the hosted cloud product for everyone else. The Docker
  # Hivebox distribution is discontinued, so no maintained entry point may
  # route a reader to it.
  def test_designated_entry_points_lead_with_native_setup
    NATIVE_FIRST_ENTRY_POINTS.each do |path|
      text = read(path)

      refute_nil text.index("hive setup"), "#{path} must teach hive setup"
    end
  end

  def test_maintained_entry_points_no_longer_route_to_the_hivebox_container
    MAINTAINED_ENTRY_POINTS.each do |path|
      text = read(path)

      refute_includes text, "packaging/docker", "#{path} still points at the removed Hivebox packaging"
      refute_match(/install-box\.(?:sh|ps1|\{)/, text, "#{path} still teaches the removed Hivebox installer")
      refute_match(/choose Hivebox/i, text, "#{path} still offers Hivebox as an install route")
    end
  end

  def test_windows_route_is_native_hive_under_wsl
    setup = read("skills/hive/references/setup-and-platforms.md")

    assert_match(/WSL/, setup)
    refute_match(/Docker Desktop/i, setup)
  end

  def test_agent_installer_pre_authorizes_unattended_native_setup_after_approval
    installer = read("install.md")

    assert_includes installer, '"$hive_cmd" setup --no-init --yes --json'
    assert_includes installer, '"$hive_cmd" setup --no-service --yes --json'
    refute_includes installer, '"$hive_cmd" setup --no-init --json'
    refute_includes installer, '"$hive_cmd" setup --no-service --json'
    refute_includes installer, '"$hive_cmd" setup --json'
  end

  def test_canonical_agent_setup_exposes_the_managed_web_service_contract
    setup = read("skills/hive/references/setup-and-platforms.md")

    assert_includes setup, "hive setup --no-init --yes --json"
    assert_includes setup, "hive setup --no-init --no-service --yes --json"
    assert_match(/installs,\s+enables, starts, and bounded-probes the loopback Hive web service/m, setup)
    %w[
      service_manager_available
      service_installed
      service_enabled
      service_running
      ready
      readiness
      url
    ].each { |field| assert_includes setup, "service.#{field}" }
    assert_includes setup, "hive web status --json"
    assert_match(/read-only follow-up.*without installing, enabling, starting, or restarting/m, setup)
    refute_match(/Hivebox/i, setup)
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

  def test_launchd_smoke_validates_install_mechanics_when_the_unbootstrapped_app_is_not_ready
    workflow = read(".github/workflows/ci.yml")

    assert_includes workflow, 'out="$(bundle exec hive web install --no-bootstrap --json)"'
    assert_includes workflow, 'WEB_INSTALL_RC="$web_install_rc"'
    assert_includes workflow, 'd["outcome"] == "written"'
    assert_includes workflow, 'rc == 1 && !d["ok"] && !d["ready"]'
    assert_includes workflow, '%w[inactive active_not_ready].include?(d["readiness"])'
  end

  def test_hivebox_container_and_installer_jobs_are_gone
    ci = read(".github/workflows/ci.yml")
    release = read(".github/workflows/release.yml")
    install_smoke = read(".github/workflows/install-smoke.yml")
    install_verify = read(".github/workflows/install-verify.yml")

    [ ci, release, install_smoke ].each do |workflow|
      refute_match(/hivebox/i, workflow)
      refute_includes workflow, "packaging/docker"
    end
    refute_path_exists File.join(ROOT, ".github/workflows/hivebox-recover.yml")
    refute_path_exists File.join(ROOT, "packaging/docker")
    refute_path_exists File.join(ROOT, ".dockerignore")
    assert_includes install_verify, "packaging/verify-channel.sh"
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
