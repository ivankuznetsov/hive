require "test_helper"

require "hive/agent_skills/filesystem_inventory"
require "hive/agent_skills/manifest"

class AgentSkillsFilesystemInventoryTest < Minitest::Test
  include HiveTestHelper

  Profile = Struct.new(:name)

  def test_unsupported_provider_returns_typed_incompatible_evidence
    result = inventory.inspect(
      profile: Profile.new("Mystery"), bin: "/bin/mystery",
      native_spec: native_spec(provider: "mystery"), root: "/tmp/mystery"
    )

    assert_equal "filesystem", result.fetch("inventory_source")
    assert_nil result.fetch("package")
    assert_match(/unsupported provider/, result.fetch("issues").first.last)
  end

  def test_claude_uses_a_scope_fallback_and_legacy_marketplace_source
    with_tmp_dir do |root|
      spec = native_spec(provider: "claude", marketplace: "market")
      write_json(
        File.join(root, "plugins", "installed_plugins.json"),
        "plugins" => {
          spec.package => [ { "scope" => "project", "version" => "1.2.3", "installPath" => "/tmp/plugin" } ]
        }
      )
      write_json(
        File.join(root, "plugins", "known_marketplaces.json"),
        "market" => { "repo" => "owner/repository" }
      )

      result = inspect_provider(spec, root)

      assert_empty result.fetch("issues")
      assert_equal "1.2.3", result.dig("package", "version")
      assert_equal "owner/repository", result.dig("marketplace", "source")
    end
  end

  def test_claude_rejects_malformed_marketplace_and_enabled_settings
    cases = [
      [
        { "plugins" => {} },
        { "market" => "not-an-object" },
        {},
        /known_marketplaces.*must be an object/
      ],
      [
        { "plugins" => {} },
        {},
        { "enabledPlugins" => [] },
        /enabledPlugins must be an object/
      ],
      [
        { "plugins" => {} },
        {},
        { "enabledPlugins" => { "package@market" => "yes" } },
        /enabledPlugins entry .* must be boolean/
      ]
    ]

    cases.each do |plugins, marketplaces, settings, message|
      with_tmp_dir do |root|
        write_json(File.join(root, "plugins", "installed_plugins.json"), plugins)
        write_json(File.join(root, "plugins", "known_marketplaces.json"), marketplaces)
        write_json(File.join(root, "settings.json"), settings)

        result = inspect_provider(native_spec(provider: "claude", marketplace: "market"), root)

        assert_match message, result.fetch("issues").first.last
      end
    end
  end

  def test_codex_missing_config_is_empty_and_unsupported_scalar_is_incompatible
    with_tmp_dir do |root|
      missing = inspect_provider(native_spec(provider: "codex", marketplace: "market"), root)
      assert_empty missing.fetch("issues")
      assert_nil missing.fetch("package")

      write(
        File.join(root, "config.toml"),
        "[plugins.\"package@market\"]\nenabled = 1\n"
      )
      malformed = inspect_provider(native_spec(provider: "codex", marketplace: "market"), root)
      assert_match(/unsupported config\.toml value/, malformed.fetch("issues").first.last)
    end
  end

  def test_codex_ignores_cache_directories_with_invalid_versions
    with_tmp_dir do |root|
      spec = native_spec(provider: "codex", marketplace: "market")
      invalid = File.join(root, "plugins", "cache", "market", "package", "not a version!")
      FileUtils.mkdir_p(invalid)

      path = inventory.send(:codex_install_path, root, spec)

      assert_nil path
    end
  end

  def test_pi_handles_missing_roots_invalid_sources_and_fallback_discovery
    spec = native_spec(
      provider: "pi", package: "https://github.com/EveryInc/compound-engineering-plugin",
      marketplace: nil, source: "https://github.com/EveryInc/compound-engineering-plugin"
    )
    with_tmp_dir do |root|
      result = inspect_provider(spec, root)
      assert_empty result.fetch("issues")
      assert_nil result.fetch("package")

      assert_nil inventory.send(:direct_pi_install_path, File.join(root, "git"), "https://bad host/%")
    end

    with_tmp_dir do |root|
      fallback_spec = spec.with(source: "https://GITHUB.com/EveryInc/compound-engineering-plugin")
      install = File.join(root, "git", "github.com", "EveryInc", "compound-engineering-plugin")
      write_json(File.join(install, "package.json"), "version" => "3.19.0")

      result = inspect_provider(fallback_spec, root)

      assert_empty result.fetch("issues")
      assert_equal install, result.dig("package", "install_path")
      assert_equal "https://github.com/EveryInc/compound-engineering-plugin", result.dig("package", "source")
    end
  end

  def test_grok_reads_native_registry_and_enabled_plugin_config
    with_tmp_dir do |root|
      spec = native_spec(
        provider: "grok",
        package: "compound-engineering",
        marketplace: nil,
        source: "EveryInc/compound-engineering-plugin"
      )
      install = File.join(root, "installed-plugins", "compound-engineering-plugin-abc123")
      write_json(
        File.join(root, "installed-plugins", "registry.json"),
        "version" => 1,
        "repos" => {
          "compound-engineering-plugin-abc123" => {
            "kind" => {
              "type" => "Git",
              "url" => "https://github.com/EveryInc/compound-engineering-plugin"
            },
            "path" => install,
            "plugins" => { "compound-engineering" => { "version" => "3.20.0" } }
          }
        }
      )
      write(File.join(root, "config.toml"), "[plugins]\nenabled = [\"compound-engineering\"]\n")

      result = inspect_provider(spec, root)

      assert_empty result.fetch("issues")
      assert_equal "compound-engineering", result.dig("package", "id")
      assert_equal "3.20.0", result.dig("package", "version")
      assert_equal true, result.dig("package", "enabled")
      assert_equal install, result.dig("package", "install_path")
      assert_equal "https://github.com/EveryInc/compound-engineering-plugin",
                   result.dig("package", "source")
    end
  end

  def test_grok_reports_installed_but_disabled_plugin
    with_tmp_dir do |root|
      spec = native_spec(
        provider: "grok",
        package: "compound-engineering",
        marketplace: nil,
        source: "EveryInc/compound-engineering-plugin"
      )
      write_json(
        File.join(root, "installed-plugins", "registry.json"),
        "version" => 1,
        "repos" => {
          "compound-engineering-plugin-abc123" => {
            "kind" => { "type" => "Git", "url" => spec.source },
            "path" => File.join(root, "installed-plugins", "compound-engineering-plugin-abc123"),
            "plugins" => { "compound-engineering" => { "version" => "3.20.0" } }
          }
        }
      )
      write(File.join(root, "config.toml"), "[plugins]\ndisabled = [\"compound-engineering\"]\n")

      result = inspect_provider(spec, root)

      assert_empty result.fetch("issues")
      assert_equal false, result.dig("package", "enabled")
    end
  end

  private

  def inventory
    Hive::AgentSkills::FilesystemInventory.new
  end

  def native_spec(provider:, package: "package@market", marketplace: "market", source: "owner/repository")
    Hive::AgentSkills::Manifest::NativePackage.new(
      agent: provider,
      provider: provider,
      package: package,
      marketplace: marketplace,
      source: source,
      scope: "user",
      config_home: "TEST_HOME",
      actions: [].freeze
    )
  end

  def inspect_provider(spec, root)
    inventory.inspect(profile: Profile.new(spec.provider.capitalize), bin: "/bin/#{spec.provider}", native_spec: spec, root: root)
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_json(path, document)
    write(path, JSON.generate(document))
  end
end
