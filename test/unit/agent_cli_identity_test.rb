require "test_helper"
require "hive/agent_profiles"
require "hive/agent_cli_identity"

class AgentCliIdentityTest < Minitest::Test
  include HiveTestHelper
  def setup
    @root = Dir.mktmpdir("cli-identity")
    @profile = Hive::AgentProfiles.lookup(:codex)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def executable(path, body = "#!/bin/sh\nexit 0\n")
    path = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o777, path)
    path
  end

  def observe(profile = @profile, **options)
    Hive::AgentCliIdentity.observe(profile: profile, environment: { "PATH" => "#{@root}/bin" },
                                  cwd: @root, **options)
  end

  def npm(profile, package, version = "0.153.4")
    target = executable("packages/#{profile}/bin/#{profile}")
    File.write(File.join(@root, "packages", profile, "package.json"),
               JSON.generate(name: package, version: version, bin: { profile => "bin/#{profile}" }))
    FileUtils.mkdir_p(File.join(@root, "bin"))
    File.symlink(target, File.join(@root, "bin", profile))
    target
  end

  def test_default_observation_is_filesystem_only_and_links_provider_metadata
    target = npm("codex", "@openai/codex")
    identity = observe(runner: ->(**) { flunk "default observation launched an agent" })
    assert_equal "#{@root}/bin/codex", identity.launch_path
    assert_equal target, identity.effective_target
    assert_equal "0.153.4", identity.version
    assert_equal "npm_manifest", identity.version_source
    assert_equal "child_path", identity.authority
    assert_predicate identity, :frozen?
  end

  def test_all_registered_provider_manifests_require_matching_name_and_bin_linkage
    { claude: "@anthropic-ai/claude-code", pi: "@earendil-works/pi-coding-agent",
      grok: "@xai-official/grok", opencode: "opencode-ai" }.each do |name, package|
      target = npm(name.to_s, package, "1.2.3-beta.1")
      profile = Hive::AgentProfiles.lookup(name)
      assert_equal "1.2.3-beta.1", observe(profile).version
      manifest = File.join(File.dirname(File.dirname(target)), "package.json")
      File.write(manifest, JSON.generate(name: "wrong-provider", version: "9.8.7", bin: { name => "bin/#{name}" }))
      assert_equal "provider_metadata_mismatch", observe(profile).version_reason
      File.write(manifest, JSON.generate(name: package, version: "9.8.7", bin: { name => "elsewhere" }))
      assert_nil observe(profile).version
    end
  end

  def test_configured_relative_absolute_and_override_precedence
    target = executable("local/codex")
    profile = @profile.with_overrides("bin" => "./local/codex", "env_override" => "MY_CODEX")
    assert_equal target, observe(profile).launch_path
    env = { "MY_CODEX" => target, "HIVE_CODEX_BIN" => "/missing", "PATH" => "" }
    assert_equal target, observe(profile, environment: env).launch_path
    env.delete("MY_CODEX")
    assert_nil observe(profile, environment: env).launch_path
    assert_equal "executable_unavailable", observe(profile, environment: env).reason
    assert_equal target, observe(@profile.with_overrides("bin" => target)).launch_path
  end

  def test_plain_selects_first_trampoline_but_isolated_preserves_existing_skip_rule
    shim = executable("shims/codex", "#!/bin/sh\nexec mise exec -- codex\n")
    concrete = executable("mise/installs/codex/1.2.3/bin/codex")
    env = { "PATH" => [ File.dirname(shim), File.dirname(concrete) ].join(":") }
    plain = observe(environment: env)
    assert_equal shim, plain.launch_path
    assert_nil plain.effective_target
    assert_equal "opaque_launcher", plain.reason
    isolated = observe(environment: {}, selector_environment: env, regime: :isolated)
    assert_equal concrete, isolated.launch_path
    assert_equal "isolated_selector_path", isolated.authority
    assert_nil isolated.version # the tool runtime's version is not an agent version
    managed = observe(environment: env, regime: :managed, executable: concrete,
                      sandbox_executable: "/runner/codex", command_prefix: [ "bwrap" ])
    assert_equal concrete, managed.launch_path
    assert_equal "/runner/codex", managed.sandbox_executable
    assert_equal "prepared_runtime_binding", managed.authority
  end

  def test_isolated_configured_selection_uses_controller_override_before_child_scrub
    target = executable("custom/codex")
    profile = @profile.with_overrides("env_override" => "MY_CODEX")
    identity = observe(profile, environment: { "PATH" => "/missing" },
                       selector_environment: { "MY_CODEX" => target }, regime: :isolated)
    assert_equal target, identity.configured
    assert_equal target, identity.launch_path
  end

  def test_isolated_selector_skips_an_alternative_removed_during_resolution
    shim = executable("shims/codex", "#!/bin/sh\nexec mise exec -- codex\n")
    concrete = executable("native/codex")
    environment = { "PATH" => [ File.dirname(shim), File.dirname(concrete) ].join(":") }
    original = File.method(:realpath)
    resolver = lambda do |path, *arguments|
      File.unlink(concrete) if path == concrete && File.exist?(concrete)
      original.call(path, *arguments)
    end

    with_replaced_singleton_method(File, :realpath, resolver) do
      identity = observe(environment: environment, regime: :isolated)
      assert_equal shim, identity.launch_path
      assert_equal "opaque_launcher", identity.reason
    end
    refute File.exist?(concrete)
  end

  def test_isolated_selector_falls_back_when_its_first_shim_disappears
    shim = executable("shims/codex", "#!/bin/sh\nexec mise exec -- codex\n")
    original = File.method(:realpath)
    resolver = lambda do |path, *arguments|
      File.unlink(shim) if path == shim && File.exist?(shim)
      original.call(path, *arguments)
    end

    with_replaced_singleton_method(File, :realpath, resolver) do
      assert_equal "codex", Hive::AgentCliIdentity.isolated_executable(
        "codex", environment: { "PATH" => File.dirname(shim) }, cwd: @root
      )
    end
    refute File.exist?(shim)
  end

  def test_custom_profile_never_claims_another_providers_package_or_native_version
    target = npm("codex", "@openai/codex")
    profile = Hive::AgentProfile.new(
      name: :custom, bin_default: target, headless_flag: "-p",
      version_flag: "--version", skill_syntax_format: "%s"
    )
    identity = observe(profile)
    assert_equal target, identity.effective_target
    assert_nil identity.version
    assert_equal "provider_metadata_mismatch", identity.version_reason

    native = executable("home/.local/share/claude/versions/2.1.118")
    identity = observe(profile.with_overrides("bin" => native))
    assert_equal native, identity.effective_target
    assert_nil identity.version
    assert_equal "unrecognized_install_layout", identity.version_reason
  end

  def test_missing_directories_nonexecutables_and_symlink_loops_are_unavailable
    target = executable("bin/codex")
    File.chmod(0o600, target)
    assert_nil observe.launch_path
    File.unlink(target)
    Dir.mkdir(target)
    assert_nil observe.launch_path
    Dir.rmdir(target)
    File.symlink(target, target)
    assert_nil observe.launch_path
    assert_nil observe(regime: :managed).launch_path
  end

  def test_native_claude_versions_require_provider_layout_and_concrete_target
    target = executable("home/.local/share/claude/versions/2.1.118")
    profile = Hive::AgentProfiles.lookup(:claude).with_overrides("bin" => target)
    assert_equal "2.1.118", observe(profile).version
    copied = executable("node/22.1.0/claude")
    assert_equal "unrecognized_install_layout", observe(profile.with_overrides("bin" => copied)).version_reason
  end

  def test_combined_prerelease_and_build_suffixes_survive_both_observation_sources
    npm("codex", "@openai/codex", "0.156.1-rc.10+build.2")
    assert_equal "0.156.1-rc.10+build.2", observe.version
    assert_equal "0.156.1-rc.10+build.2",
                 observe(probe: true, runner: ->(**) { [ "codex 0.156.1-rc.10+build.2", "", true ] }).version
  end

  def test_grok_native_version_requires_provider_installer_metadata_and_selected_link
    target = executable("home/.grok/bin/grok-0.2.90")
    launcher = File.join(File.dirname(target), "grok")
    File.symlink(target, launcher)
    metadata = File.join(@root, "home/.grok/config.toml")
    File.write(metadata, "[cli]\ninstaller = \"npm\"\n")
    profile = Hive::AgentProfiles.lookup(:grok).with_overrides("bin" => launcher)
    assert_equal "0.2.90", observe(profile).version
    File.write(metadata, "[unrelated]\ninstaller = \"npm\"\n")
    assert_nil observe(profile).version
    File.write(metadata, "[cli]\ninstaller = \"npm\"\n")
    File.unlink(launcher)
    assert_nil observe(profile.with_overrides("bin" => target)).version
  end

  def test_unrelated_grok_package_is_not_the_registered_provider
    npm("grok", "@vibe-kit/grok-cli")
    identity = observe(Hive::AgentProfiles.lookup(:grok))
    assert_nil identity.version
    assert_equal "provider_metadata_mismatch", identity.version_reason
  end

  def test_grok_bootstrap_package_does_not_claim_the_dynamic_native_target_version
    target = npm("grok", "@xai-official/grok", "0.2.90")
    File.write(target, "#!/usr/bin/env node\nrequire('./grok-bootstrap.js');\n")
    identity = observe(Hive::AgentProfiles.lookup(:grok))
    assert_equal "#{@root}/bin/grok", identity.launch_path
    assert_nil identity.effective_target
    assert_nil identity.version
    assert_equal "opaque_launcher", identity.reason
    original = File.method(:open)
    with_replaced_singleton_method(File, :open, ->(path, *args, &block) {
      raise Errno::EACCES if path == target
      original.call(path, *args, &block)
    }) do
      assert_equal "opaque_launcher", observe(Hive::AgentProfiles.lookup(:grok)).reason
    end
  end

  def test_homebrew_receipts_require_provider_and_exact_linked_install
    %w[claude codex opencode].each do |name|
      formula = { "claude" => "claude-code", "codex" => "codex", "opencode" => "opencode" }.fetch(name)
      target = executable("Cellar/#{formula}/1.2.3/bin/#{name}")
      receipt = File.join(@root, "Cellar", formula, "1.2.3", "INSTALL_RECEIPT.json")
      File.write(receipt, JSON.generate(source: { path: "/Formula/#{formula}.rb", versions: { stable: "1.2.3" } }))
      profile = Hive::AgentProfiles.lookup(name).with_overrides("bin" => target)
      assert_equal "1.2.3", observe(profile).version
      File.write(receipt, JSON.generate(source: { path: "/Formula/node.rb", versions: { stable: "1.2.3" } }))
      assert_nil observe(profile).version
    end
  end

  def test_probe_accepts_relative_shared_and_opaque_executables_under_exact_context
    path = executable("shared/codex", "#!/bin/sh\nexec mise exec -- codex\n")
    profile = @profile.with_overrides("bin" => "./shared/codex")
    calls = []
    runner = ->(**args) { calls << args; [ "codex-cli 0.156.1\n", "", true ] }
    identity = observe(profile, probe: true, runner: runner)
    assert_equal "0.156.1", identity.version
    assert_nil identity.effective_target
    assert_equal path, calls.first[:executable]
    assert_equal @root, calls.first[:cwd]
    refute identity.to_h.to_s.include?("low_trust")
  end

  def test_homebrew_cask_receipt_links_the_provider_binary_artifact
    target = executable("Caskroom/codex/0.153.4/codex-aarch64-apple-darwin")
    receipt = File.join(@root, "Caskroom/codex/.metadata/INSTALL_RECEIPT.json")
    FileUtils.mkdir_p(File.dirname(receipt))
    data = { source: { path: "/Casks/c/codex.rb", version: "0.153.4" },
             uninstall_artifacts: [ { binary: [ "codex-aarch64-apple-darwin", { target: "codex" } ] } ] }
    File.write(receipt, JSON.generate(data))
    profile = @profile.with_overrides("bin" => target)
    assert_equal "0.153.4", observe(profile).version
    data[:source][:version] = "0.156.1"
    File.write(receipt, JSON.generate(data))
    assert_nil observe(profile).version
  end

  def test_probe_unknowns_do_not_expose_output_and_budget_prevents_further_launches
    executable("bin/codex")
    runner = ->(**) { [ "0.1.2 0.3.4", "sk-#{'a' * 30}", true ] }
    assert_equal "probe_version_ambiguous", observe(probe: true, runner: runner).version_reason
    assert_equal "probe_failed", observe(probe: true, runner: ->(**) { [ "", "secret", false ] }).version_reason
    assert_equal "probe_version_unparseable", observe(probe: true, runner: ->(**) { [ "noise", "", true ] }).version_reason
    budget = Hive::AgentCliIdentity::ProbeBudget.new(seconds: 0)
    result = observe(probe: true, budget: budget, runner: ->(**) { flunk "budget exhausted" })
    assert_equal "probe_budget_exhausted", result.version_reason
    assert_equal "environment_incomplete", observe(probe: true, probe_allowed: false, runner: runner).version_reason
  end

  def test_real_probe_has_a_deadline_and_terminates_descendants
    executable("bin/codex", "#!/bin/sh\ntrap '' TERM\n/bin/sleep 30 &\necho $! > '#{@root}/descendant'\nwait\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = observe(probe: true, budget: Hive::AgentCliIdentity::ProbeBudget.new(seconds: 0.4))
    assert_equal "probe_timeout", result.version_reason
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
    descendant = File.read(File.join(@root, "descendant")).strip
    stat = "/proc/#{descendant}/stat"
    assert_equal "Z", File.read(stat).split[2] if File.exist?(stat)
  end

  def test_real_probe_captures_small_output_and_bounds_excessive_output
    executable("bin/codex", "#!/bin/sh\nprintf 'codex-cli 0.156.1\\n'\n")
    assert_equal "0.156.1", observe(probe: true).version
    executable("bin/codex", "#!#{RbConfig.ruby}\nSTDOUT.write('x' * 100_000)\nsleep 1\n")
    assert_equal "probe_output_limit", observe(probe: true).version_reason
    assert_equal "probe_failed", observe(probe: true, runner: ->(**) { raise IOError, "secret output" }).version_reason
  end

  def test_malformed_metadata_and_resolution_errors_are_typed_without_raw_errors
    npm("codex", "@openai/codex")
    File.write(File.join(@root, "packages/codex/package.json"), "{malformed")
    assert_equal "provider_metadata_mismatch", observe.version_reason
    with_replaced_singleton_method(File, :realpath, ->(*) { raise Errno::EIO }) do
      assert_equal "resolution_failed", observe.reason
    end
    assert_equal({ nested: [ "[REDACTED:openai_api_key]" ] },
                 Hive::AgentCliIdentity.freeze_diagnostic({ nested: [ "sk-#{'a' * 25}" ] }))
  end
end
