require_relative "test_helper"

class AgentCliRuntimeOpenCodePreparationTest < Minitest::Test
  def test_builtin_profile_is_appended_without_changing_legacy_transports
    assert_equal %i[claude codex pi grok opencode], AgentCliRuntime::Profiles.names

    profile = AgentCliRuntime::Profiles.fetch(:opencode)
    assert_equal "1.18.16", profile.min_version
    assert_equal "opencode-cli/v1", profile.launcher_identity
    assert_equal :piped_stdin, profile.prompt_style
    assert_equal [ "--model", "anthropic/claude-sonnet-4-5" ],
                 profile.identity_arguments(
                   model: "anthropic/claude-sonnet-4-5",
                   effort: nil
                 ).native_arguments

    error = assert_raises(AgentCliRuntime::ConfigurationError) do
      AgentCliRuntime.compile(
        AgentCliRuntime::Request.new(profile: :opencode, prompt: "hello")
      )
    end
    assert_match(/explicit OpenCode permission policy/, error.message)
  end

  def test_route_probe_gives_only_the_large_model_inventory_a_longer_deadline
    calls = []
    success = Object.new
    success.define_singleton_method(:success?) { true }
    profile = Object.new
    profile.define_singleton_method(:name) { :opencode }
    profile.define_singleton_method(:binary_installed?) { |env:| !env.nil? }
    profile.define_singleton_method(:bin) { |env:| env && "opencode" }
    profile.define_singleton_method(:check_version!) { |env:| env && "1.18.18" }
    profile.define_singleton_method(:min_version) { "1.18.16" }
    profile.define_singleton_method(:launcher_identity) { "opencode-cli/v1" }
    profile.define_singleton_method(:env_bin_override_keys) { [] }
    profile.define_singleton_method(:capture_local) do |*arguments, env:, timeout_sec: 10|
      calls << [ arguments, timeout_sec, env ]
      output = case arguments
      when [ "run", "--help" ]
        "--model --variant --format --dir --pure --auto"
      when [ "export", "--help" ]
        "--sanitize"
      when [ "auth", "list" ]
        "openrouter\n"
      when [ "models", "openrouter", "--verbose" ]
        "openrouter/stealth/ox-alpha\n{\"variants\":{\"high\":{}}}\n"
      else
        raise "unexpected inspection call: #{arguments.inspect}"
      end
      [ output, "", success ]
    end
    request = AgentCliRuntime::ProbeRequest.new(
      profile: :opencode,
      route: "openrouter/stealth/ox-alpha",
      variant: "high",
      environment: {},
      credential_environment_keys: [ "OPENROUTER_API_KEY" ]
    )

    profiles = AgentCliRuntime::Profiles
    singleton = profiles.singleton_class
    original_resolve = profiles.method(:resolve)
    singleton.define_method(:resolve) { |_value| profile }
    result = begin
      AgentCliRuntime::OpenCode::Probe.call!(
        request, env: { "OPENROUTER_API_KEY" => "selected" }
      )
    ensure
      singleton.define_method(:resolve, original_resolve)
    end

    assert result.ready
    inventory = calls.find do |arguments, _timeout, _env|
      arguments == [ "models", "openrouter", "--verbose" ]
    end
    assert_equal 30, inventory.fetch(1)
    assert_equal [ 10 ], calls.reject { |entry| entry == inventory }
                             .map { |entry| entry.fetch(1) }.uniq
  end

  def test_prepare_builds_a_private_hermetic_invocation_without_spawning_run
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        source = File.join(dir, "selected-config.json")
        root = File.join(dir, "invocation")
        FileUtils.mkdir_p(work)
        File.write(source, JSON.pretty_generate(
          "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
        ))
        original = File.binread(source)
        env = fixture.fetch(:env).merge("ANTHROPIC_API_KEY" => "secret-canary")

        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root:, source:,
            credential_environment_keys: [ "ANTHROPIC_API_KEY" ]
          ),
          env:
        )

        assert_equal [
          fixture.fetch(:bin), "run", "--auto",
          "--model", "anthropic/claude-sonnet-4-5",
          "--variant", "high", "--dir", work, "--pure",
          "--format", "json"
        ], prepared.invocation.argv
        assert_equal "make the atomic edit", prepared.invocation.stdin_data
        assert_equal :opencode, prepared.invocation.provider
        assert_equal "anthropic/claude-sonnet-4-5", prepared.requested_route.to_s
        assert_equal [ "ANTHROPIC_API_KEY" ],
                     prepared.credential_environment_keys
        refute_includes prepared.environment.inspect, "secret-canary"
        assert_equal "secret-canary",
                     prepared.environment_for(env:).fetch("ANTHROPIC_API_KEY")

        assert_equal "true", prepared.environment.fetch(
          "OPENCODE_DISABLE_PROJECT_CONFIG"
        )
        assert_equal "true", prepared.environment.fetch(
          "OPENCODE_DISABLE_MODELS_FETCH"
        )
        assert_equal "true", prepared.environment.fetch(
          "OPENCODE_DISABLE_AUTOUPDATE"
        )
        assert_equal "true", prepared.environment.fetch(
          "OPENCODE_DISABLE_CLAUDE_CODE"
        )
        assert_equal "true", prepared.environment.fetch("OPENCODE_PURE")
        %w[XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME].each do |key|
          assert prepared.environment.fetch(key).start_with?(root), key
        end

        assert_equal 0o700, File.stat(root).mode & 0o777
        prepared.generated_paths.each do |path|
          assert path.start_with?(root), path
          mode = File.stat(path).mode & 0o777
          File.directory?(path) ? assert_equal(0o700, mode, path) :
            assert_equal(0o600, mode, path)
        end
        config = JSON.parse(File.read(prepared.configuration_path))
        assert_equal "deny", config.dig("permission", "*")
        assert_equal "allow", config.dig("permission", "read", "*")
        assert_equal "deny", config.dig("permission", "edit")
        assert_equal "deny", config.dig("permission", "bash")
        assert_equal "deny", config.dig("permission", "external_directory", "*")
        temporary = prepared.environment.fetch("TMPDIR")
        assert_equal "allow",
                     config.dig("permission", "external_directory", temporary)
        assert_equal "allow",
                     config.dig("permission", "external_directory", "#{temporary}/**")
        assert_equal original, File.binread(source)

        calls = File.readlines(fixture.fetch(:log), chomp: true)
        assert calls.any? { |line| line.include?("--version") }
        assert calls.any? { |line| line.include?("run --help") }
        assert calls.any? { |line| line.include?("export --help") }
        assert calls.any? { |line| line.include?("auth list") }
        assert calls.any? { |line| line.include?("models anthropic --verbose") }
        refute calls.any? { |line| line.include?("make the atomic edit") }

        prepared.cleanup!
        refute File.exist?(root)
        prepared.cleanup!
        assert File.file?(source)
        assert File.directory?(work)
      end
    end
  end

  def test_prepared_invocation_pipes_a_prompt_larger_than_linux_allows_in_one_argument
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        root = File.join(dir, "invocation")
        source = selected_config(dir)
        FileUtils.mkdir_p(work)
        prompt = "implement the reviewed plan\n" + ("x" * 150_000)

        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root:, source:, prompt:,
            credential_environment_keys: [ "ANTHROPIC_API_KEY" ]
          ),
          env: fixture.fetch(:env).merge("ANTHROPIC_API_KEY" => "configured")
        )

        refute_includes prepared.invocation.argv, prompt
        assert_operator prepared.invocation.argv.join.bytesize, :<, 8_192
        assert_equal prompt, prepared.invocation.stdin_data
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_selected_custom_model_survives_a_stale_local_inventory
    with_fixture_cli(mode: :wrong_route) do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        root = File.join(dir, "invocation")
        FileUtils.mkdir_p(work)
        config = {
          "provider" => {
            "anthropic" => {
              "models" => {
                "claude-sonnet-4-5" => {
                  "variants" => { "high" => {} }
                }
              }
            }
          }
        }

        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root:, source: nil, configuration: config,
            credential_environment_keys: [ "ANTHROPIC_API_KEY" ]
          ),
          env: fixture.fetch(:env)
        )

        assert prepared.probe_result.ready
        assert_equal [ "high" ], prepared.probe_result.available_variants
        calls = File.readlines(fixture.fetch(:log), chomp: true)
        refute calls.any? { |line| line.include?("models anthropic --verbose") }
        prepared.cleanup!
      end
    end
  end

  def test_stale_inventory_still_fails_without_a_selected_model_declaration
    with_fixture_cli(mode: :wrong_route) do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)

        assert_raises(AgentCliRuntime::RouteUnavailable) do
          AgentCliRuntime.prepare!(
            preparation_request(
              work:, root: File.join(dir, "invocation"),
              source: selected_config(dir)
            ),
            env: fixture.fetch(:env)
          )
        end
      end
    end
  end

  def test_workspace_write_policy_allows_edits_only_in_declared_roots
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        writable = File.join(dir, "artifacts")
        readable = File.join(dir, "reference")
        FileUtils.mkdir_p([ work, writable, readable ])
        source = selected_config(dir)
        request = preparation_request(
          work:, root: File.join(dir, "invocation"), source:,
          permission_mode: "workspace-write",
          additional_read_roots: [ readable ],
          additional_write_roots: [ writable ]
        )

        prepared = AgentCliRuntime.prepare!(request, env: fixture.fetch(:env))
        policy = JSON.parse(File.read(prepared.configuration_path))
                     .fetch("permission")

        assert_equal "deny", policy.fetch("*")
        assert_equal "deny", policy.fetch("bash")
        assert_equal "deny", policy.dig("edit", "*")
        assert_equal "allow", policy.dig("edit", "**")
        refute policy.fetch("edit").key?(work)
        assert_equal "deny", policy.dig("edit", "#{readable}/**")
        assert_equal "allow", policy.dig("edit", "#{writable}/**")
        assert_equal "allow",
                     policy.dig("external_directory", "#{readable}/**")
        assert_equal "allow",
                     policy.dig("external_directory", "#{writable}/**")
        temporary = prepared.environment.fetch("TMPDIR")
        assert_equal "allow", policy.dig("external_directory", temporary)
        assert_equal "allow", policy.dig("external_directory", "#{temporary}/**")
        assert_equal "allow", policy.dig("edit", temporary)
        assert_equal "allow", policy.dig("edit", "#{temporary}/**")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_workspace_write_reapplies_nested_read_only_exceptions_after_parent_allow
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        readable = File.join(work, "reference")
        FileUtils.mkdir_p(readable)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(dir, "invocation"), source: selected_config(dir),
            permission_mode: "workspace-write", additional_read_roots: [ readable ]
          ),
          env: fixture.fetch(:env)
        )
        edit = JSON.parse(File.read(prepared.configuration_path)).dig("permission", "edit")

        assert_equal "deny", edit.fetch("*")
        assert_equal "allow", edit.fetch("**")
        assert_equal "deny", edit.fetch("reference")
        assert_equal "deny", edit.fetch("reference/**")
        assert_operator edit.keys.index("reference/**"), :>, edit.keys.index("**")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_workspace_write_compiles_declared_edit_patterns_relative_to_worktree
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        docs = File.join(work, "docs")
        FileUtils.mkdir_p(docs)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(dir, "invocation"), source: selected_config(dir),
            permission_mode: "workspace-write", additional_write_roots: [ work ],
            edit_patterns: [ "#{docs}/**" ]
          ),
          env: fixture.fetch(:env)
        )
        edit = JSON.parse(File.read(prepared.configuration_path)).dig("permission", "edit")

        assert_equal "deny", edit.fetch("*")
        assert_equal "allow", edit.fetch("docs/**")
        refute edit.key?("**")
        refute edit.key?("#{work}/**")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_workspace_write_compiles_only_declared_bash_patterns
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(dir, "invocation"), source: selected_config(dir),
            permission_mode: "workspace-write",
            bash_patterns: [ "bundle*", "bin/*", "git*" ]
          ),
          env: fixture.fetch(:env)
        )
        bash = JSON.parse(File.read(prepared.configuration_path)).dig("permission", "bash")

        assert_equal "deny", bash.fetch("*")
        assert_equal "allow", bash.fetch("bundle*")
        assert_equal "allow", bash.fetch("bin/*")
        assert_equal "allow", bash.fetch("git*")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_selected_agent_permissions_cannot_override_generated_policy
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(dir, "invocation"), source: nil,
            configuration: {
              "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } },
              "agent" => { "build" => { "permission" => { "bash" => "allow" }, "mode" => "primary" } }
            }
          ),
          env: fixture.fetch(:env)
        )
        config = JSON.parse(File.read(prepared.configuration_path))

        refute config.dig("agent", "build").key?("permission")
        assert_equal "primary", config.dig("agent", "build", "mode")
        assert_equal "deny", config.dig("permission", "bash")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_explicit_overlay_default_and_credential_file_are_staged_privately
    with_fixture_cli(mode: :missing_auth) do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        source = File.join(dir, "selected-config.json")
        File.write(source, JSON.generate(
          "model" => "anthropic/claude-sonnet-4-5",
          "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
        ))
        credentials = File.join(dir, "auth.json")
        File.write(credentials, JSON.generate("anthropic" => { "type" => "oauth" }))
        File.chmod(0o600, credentials)
        root = File.join(dir, "invocation")

        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root:, source:,
            model: nil, credential_environment_keys: [],
            credential_file: credentials
          ),
          env: fixture.fetch(:env)
        )

        assert_equal "anthropic/claude-sonnet-4-5",
                     prepared.requested_route.to_s
        staged = prepared.generated_paths.find do |path|
          path.end_with?("/opencode/auth.json")
        end
        assert staged
        assert_equal 0o600, File.stat(staged).mode & 0o777
        assert_equal File.binread(credentials), File.binread(staged)
        prepared.cleanup!
        refute File.exist?(root)
        refute File.exist?(staged)
        assert File.file?(credentials)
        prepared = nil
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_nil_permission_mode_requires_a_typed_policy
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        source = selected_config(dir)
        request = preparation_request(
          work:, root: File.join(dir, "missing-policy"), source:,
          permission_mode: nil
        )

        error = assert_raises(AgentCliRuntime::ConfigurationError) do
          AgentCliRuntime.prepare!(request, env: fixture.fetch(:env))
        end
        assert_match(/explicit OpenCode permission policy/, error.message)

        policy = AgentCliRuntime::OpenCodePermissionPolicy.new(
          "*" => "deny", "read" => "allow"
        )
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(dir, "typed-policy"), source:,
            permission_mode: nil, permission_policy: policy
          ),
          env: fixture.fetch(:env)
        )
        assert_equal policy.rules,
                     JSON.parse(File.read(prepared.configuration_path))
                         .fetch("permission")
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_probe_fails_closed_for_capability_auth_route_and_variant_mismatches
    cases = {
      old_version: AgentCliRuntime::VersionError,
      missing_capability: AgentCliRuntime::UnsupportedCapability,
      missing_export_capability: AgentCliRuntime::UnsupportedCapability,
      missing_auth: AgentCliRuntime::AuthenticationError,
      wrong_route: AgentCliRuntime::RouteUnavailable,
      wrong_variant: AgentCliRuntime::RouteUnavailable
    }

    cases.each do |mode, error_class|
      with_fixture_cli(mode:) do |fixture|
        Dir.mktmpdir do |dir|
          work = File.join(dir, "work")
          FileUtils.mkdir_p(work)
          error = assert_raises(error_class) do
            AgentCliRuntime.prepare!(
              preparation_request(
                work:, root: File.join(dir, "invocation"),
                source: selected_config(dir)
              ),
              env: fixture.fetch(:env)
            )
          end
          refute_includes error.message, "secret-canary"
          refute File.exist?(File.join(dir, "invocation")), mode
        end
      end
    end
  end

  def test_probe_rejects_credentials_that_are_not_bound_to_requested_provider
    with_fixture_cli(mode: :missing_auth) do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        env = fixture.fetch(:env).merge("OPENAI_API_KEY" => "wrong-provider-secret")
        error = assert_raises(AgentCliRuntime::AuthenticationError) do
          AgentCliRuntime.prepare!(
            preparation_request(
              work:, root: File.join(dir, "invocation"), source: selected_config(dir),
              credential_environment_keys: [ "OPENAI_API_KEY" ]
            ),
            env:
          )
        end
        refute_includes error.message, "wrong-provider-secret"
        refute File.exist?(File.join(dir, "invocation"))
      end
    end
  end

  def test_probe_rejects_staged_credentials_for_a_different_provider
    with_fixture_cli(mode: :missing_auth) do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        credentials = File.join(dir, "auth.json")
        File.write(credentials, JSON.generate("openai" => { "type" => "api" }))
        error = assert_raises(AgentCliRuntime::AuthenticationError) do
          AgentCliRuntime.prepare!(
            preparation_request(
              work:, root: File.join(dir, "invocation"), source: selected_config(dir),
              credential_environment_keys: [], credential_file: credentials
            ),
            env: fixture.fetch(:env)
          )
        end
        refute_includes error.message, File.binread(credentials)
        refute File.exist?(File.join(dir, "invocation"))
      end
    end
  end

  def test_probe_environment_explicitly_unsets_ambient_unselected_values
    profile = AgentCliRuntime::Profiles.fetch(:opencode)
    request = AgentCliRuntime::ProbeRequest.new(
      profile:, route: "anthropic/claude-sonnet-4-5", environment: {},
      credential_environment_keys: []
    )
    ENV["UNSELECTED_PROBE_SECRET"] = "secret-canary"

    child = AgentCliRuntime::OpenCode::Probe.send(
      :child_environment, profile, request, env: { "PATH" => ENV.fetch("PATH") }
    )

    assert child.key?("UNSELECTED_PROBE_SECRET")
    assert_nil child.fetch("UNSELECTED_PROBE_SECRET")
  ensure
    ENV.delete("UNSELECTED_PROBE_SECRET")
  end

  def test_credential_environment_keys_cannot_override_overlay_controls
    error = assert_raises(ArgumentError) do
      AgentCliRuntime::OpenCodePreparationRequest.new(
        request: AgentCliRuntime::Request.new(profile: :opencode, prompt: "test"),
        working_directory: Dir.pwd,
        invocation_root: File.join(Dir.tmpdir, "unused-opencode-root"),
        credential_environment_keys: [ "OPENCODE_CONFIG" ]
      )
    end
    assert_match(/cannot override the OpenCode overlay/, error.message)
  end

  def test_route_probe_is_fail_soft_when_the_binary_is_missing
    request = AgentCliRuntime::ProbeRequest.new(
      profile: :opencode,
      route: "anthropic/claude-sonnet-4-5",
      environment: {},
      credential_environment_keys: [ "ANTHROPIC_API_KEY" ]
    )
    result = AgentCliRuntime.probe(
      request,
      env: {
        "AGENT_CLI_RUNTIME_OPENCODE_BIN" => "/missing/opencode",
        "PATH" => "/usr/bin:/bin",
        "ANTHROPIC_API_KEY" => "secret-canary"
      }
    )

    refute result.ready
    refute result.installed
    refute result.route_available
    assert_equal :installation,
                 result.capability_evidence.fetch(0).capability
    refute_includes result.diagnostic, "secret-canary"
  end

  def test_preparation_rejects_unsafe_roots_and_secret_inline_configuration
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        target = File.join(dir, "target")
        FileUtils.mkdir_p(target)
        root = File.join(dir, "invocation")
        File.symlink(target, root)

        assert_raises(AgentCliRuntime::UnsafePathError) do
          AgentCliRuntime.prepare!(
            preparation_request(work:, root:, source: selected_config(dir)),
            env: fixture.fetch(:env)
          )
        end
        assert File.directory?(target)

        secret_request = preparation_request(
          work:, root: File.join(dir, "secret-root"), source: nil,
          configuration: {
            "provider" => {
              "anthropic" => { "options" => { "apiKey" => "secret-canary" } }
            }
          }
        )
        error = assert_raises(AgentCliRuntime::ConfigurationError) do
          AgentCliRuntime.prepare!(secret_request, env: fixture.fetch(:env))
        end
        refute_includes error.message, "secret-canary"
        refute File.exist?(File.join(dir, "secret-root"))
      end
    end
  end

  def test_invocation_root_resolves_safe_symlinked_ancestors
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        real_parent = File.join(dir, "real-parent")
        linked_parent = File.join(dir, "linked-parent")
        work = File.join(dir, "work")
        FileUtils.mkdir_p([ real_parent, work ])
        File.symlink(real_parent, linked_parent)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(
            work:, root: File.join(linked_parent, "invocation"), source: selected_config(dir)
          ),
          env: fixture.fetch(:env)
        )

        assert_equal File.join(real_parent, "invocation"), prepared.invocation_root
        assert File.directory?(prepared.invocation_root)
      ensure
        prepared&.cleanup!
      end
    end
  end

  def test_cleanup_refuses_a_replaced_root_without_deleting_either_tree
    with_fixture_cli do |fixture|
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        root = File.join(dir, "invocation")
        original = "#{root}.original"
        FileUtils.mkdir_p(work)
        prepared = AgentCliRuntime.prepare!(
          preparation_request(work:, root:, source: selected_config(dir)),
          env: fixture.fetch(:env)
        )
        File.rename(root, original)
        Dir.mkdir(root, 0o700)
        File.write(File.join(root, "replacement"), "keep\n")

        error = assert_raises(AgentCliRuntime::UnsafePathError) do
          prepared.cleanup!
        end
        assert_match(/replaced OpenCode invocation root/, error.message)
        assert File.file?(File.join(root, "replacement"))
        assert File.file?(File.join(original, "selected-config", "opencode.json"))
      ensure
        FileUtils.remove_entry_secure(root) if root && File.directory?(root)
        FileUtils.remove_entry_secure(original) if original && File.directory?(original)
      end
    end
  end

  private

  def preparation_request(work:, root:, source:, configuration: nil,
                          credential_environment_keys: [ "ANTHROPIC_API_KEY" ],
                          credential_file: nil, model: "anthropic/claude-sonnet-4-5",
                          permission_mode: "read-only", permission_policy: nil,
                          additional_read_roots: [], additional_write_roots: [],
                          edit_patterns: [], bash_patterns: [],
                          prompt: "make the atomic edit")
    AgentCliRuntime::OpenCodePreparationRequest.new(
      request: AgentCliRuntime::Request.new(
        profile: :opencode,
        prompt:,
        permission_mode:,
        model:,
        effort: "high"
      ),
      working_directory: work,
      invocation_root: root,
      configuration_path: source,
      configuration:,
      credential_environment_keys:,
      credential_file:,
      permission_policy:,
      additional_read_roots:,
      additional_write_roots:,
      edit_patterns:,
      bash_patterns:
    )
  end

  def selected_config(dir)
    path = File.join(dir, "selected-config.json")
    File.write(path, JSON.generate(
      "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
    ))
    path
  end

  def with_fixture_cli(mode: :ready)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "opencode")
      log = File.join(dir, "calls.log")
      run_help = File.read(File.expand_path(
        "fixtures/opencode/v1.18.16/run-help.txt", __dir__
      ))
      run_help = run_help.sub(/.*--variant.*\n/, "") if mode == :missing_capability
      export_help = File.read(File.expand_path(
        "fixtures/opencode/v1.18.16/export-help.txt", __dir__
      ))
      export_help = export_help.sub(/.*--sanitize.*\n/, "") if
        mode == :missing_export_capability
      auth = mode == :missing_auth ? "" : "anthropic\n"
      route = mode == :wrong_route ? "anthropic/other-model" :
        "anthropic/claude-sonnet-4-5"
      variants = mode == :wrong_variant ? { "low" => {} } :
        { "low" => {}, "high" => {}, "max" => {} }
      models_output = "#{route}\n#{JSON.pretty_generate("variants" => variants)}\n"
      write_executable(bin, <<~RUBY)
        #!/usr/bin/ruby --disable-gems
        File.open(#{log.dump}, "a") { |file| file.puts(ARGV.join(" ")) }
        case ARGV
        when ["--version"]
          puts #{(mode == :old_version ? "opencode 1.17.0\n" : "opencode 1.18.16\n").dump}
        when ["run", "--help"]
          print #{run_help.dump}
        when ["export", "--help"]
          print #{export_help.dump}
        when ["auth", "list"]
          print #{auth.dump}
        when ["models", "anthropic", "--verbose"]
          print #{models_output.dump}
        else
          warn "unexpected fake OpenCode call: \#{ARGV.inspect}"
          exit 64
        end
      RUBY
      env = ENV.to_h.merge(
        "AGENT_CLI_RUNTIME_OPENCODE_BIN" => bin,
        "ANTHROPIC_API_KEY" => (mode == :missing_auth ? "" : "secret-canary")
      )
      yield({ bin:, log:, env: })
    end
  end
end
