require "test_helper"
require "open3"
require "json_schemer"
require "hive/commands/setup"
require "hive/setup/diagnostics"
require "hive/web/app_bundle"
require "hive/agent_skills/provisioner"
require "hive/config"
require "hive/invoked_binary"
require "hive/commands/init"
require "hive/commands/daemon"
require "hive/commands/daemon/service_installer"
require "hive/commands/web/service_installer"

# End-to-end coverage of the `hive setup` orchestrator (lib/hive/commands/setup.rb):
# #call phase ordering, the --no-bootstrap / --no-init / --service branches, each
# private phase helper's success + failure recording, and the JSON/human emit.
#
# Every collaborator is stubbed via with_replaced_singleton_method so no real
# npm/launchctl/systemctl/git runs, but each test asserts a real behavior:
# recorded phase order, phase ok flag, the message captured from a failure, the
# JSON envelope shape, the exit code, and the human-readable lines.
class SetupOrchestratorTest < Minitest::Test
  include HiveTestHelper

  def test_unattended_probe_uses_tty_state_and_fails_closed_on_ioerror
    interactive = Object.new
    interactive.define_singleton_method(:tty?) { true }
    noninteractive = Object.new
    noninteractive.define_singleton_method(:tty?) { false }
    closed = Object.new
    closed.define_singleton_method(:tty?) { raise IOError, "closed input" }

    refute Hive::Commands::Setup.new(input: interactive).send(:unattended_without_yes?)
    assert Hive::Commands::Setup.new(input: noninteractive).send(:unattended_without_yes?)
    assert Hive::Commands::Setup.new(input: closed).send(:unattended_without_yes?)
  end

  # ── diagnostics fakes ────────────────────────────────────────────────

  def diag(*rows, ok: nil)
    Diag.new(rows, ok)
  end

  # Minimal Aggregate stand-in: #ok?, #results, #to_h — the three the
  # orchestrator reads. `ok` overrides the derived value when a test wants
  # to pin the diagnostics phase flag independently of the rows.
  Diag = Struct.new(:results, :forced_ok) do
    def ok?
      forced_ok.nil? ? results.all? { |r| r.ok? || r.bootstrappable } : forced_ok
    end

    def to_h
      { "ok" => ok?, "results" => results.map(&:to_h) }
    end
  end

  def result(name:, status: "ok", detail: "d", fix_command: nil, bootstrappable: false)
    Hive::Setup::Diagnostics::Result.new(
      name: name, status: status, detail: detail,
      fix_command: fix_command, bootstrappable: bootstrappable
    )
  end

  def ok_row(name = "ruby")
    result(name: name, status: "ok")
  end

  def qmd_missing_bootstrappable
    result(name: "qmd", status: "missing", detail: "installable", bootstrappable: true)
  end

  # ── installer / init fakes ───────────────────────────────────────────

  FakeOutcome = Struct.new(:success, :wire) do
    def success?
      success
    end

    def wire_outcome
      wire
    end
  end

  def fake_installer(success: true, wire: "written", target_path: "/tmp/unit.service", messages: [ "note" ],
                     state: nil)
    installer = Object.new
    installer.define_singleton_method(:install!) { |**_kw| FakeOutcome.new(success, wire) }
    installer.define_singleton_method(:target_path) { target_path }
    installer.define_singleton_method(:messages) { messages }
    observed = state || {
      "platform" => "linux", "unit_path" => target_path,
      "service_installed" => true, "service_enabled" => true,
      "service_running" => true, "service_manager_available" => true
    }
    installer.define_singleton_method(:service_state) { observed }
    installer.define_singleton_method(:service_lifecycle_state) { observed }
    installer.define_singleton_method(:restart!) { true }
    installer
  end

  # A no-op web bind config for web_url; the default from Config is loopback.
  def stub_web_config(bind: "127.0.0.1", port: 4567)
    with_replaced_singleton_method(Hive::Config, :load_global_web,
      ->(*) { { "bind" => bind, "port" => port } }) do
      yield
    end
  end

  # Run the given block with EVERY provisioning collaborator stubbed to a
  # benign success. Individual tests re-stub the one collaborator they
  # exercise on top of this baseline.
  def with_all_collaborators_ok(diagnostics:)
    fake_diag = Object.new
    fake_diag.define_singleton_method(:run) { diagnostics }
    # Precompute the installers in local scope: the `new` stubs are defined as
    # singleton methods on the installer classes, so `self` inside the lambda is
    # the class, not this test — a bare `fake_installer` call would NameError.
    daemon_installer = fake_installer
    web_installer = fake_installer
    agent_plan = Hive::AgentSkills::ProvisioningPlan.new(
      inspections: [].freeze,
      operations: [].freeze,
      conflicts: [].freeze,
      filters: { "agents" => [], "skills" => [] }.freeze,
      fingerprint: "none"
    ).freeze
    agent_result = Hive::AgentSkills::ProvisioningResult.new(
      preview: agent_plan,
      consent: { "granted" => false, "provenance" => "not_required" }.freeze,
      operation_results: [].freeze,
      final_health: [].freeze,
      exit_code: 0,
      classification: "no_op"
    ).freeze
    agent_setup = Object.new
    agent_setup.define_singleton_method(:run) { agent_result }
    with_replaced_singleton_method(Hive::Setup::Diagnostics, :new, ->(*) { fake_diag }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { "/bundle" }) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :app_dir, ->(*) { "/bundle" }) do
          with_replaced_singleton_method(Hive::Web::AppBundle, :present?, ->(*) { true }) do
            with_replaced_singleton_method(Hive::Web::AppBundle, :stale?, ->(*) { false }) do
              with_replaced_singleton_method(Hive::Web::AppBundle, :assets_ready?, ->(*) { true }) do
                with_replaced_singleton_method(Hive::InvokedBinary, :path, ->(*) { "/usr/bin/hive" }) do
            with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new,
              ->(**_kw) { daemon_installer }) do
              with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new,
                ->(**_kw) { web_installer }) do
                with_replaced_singleton_method(Hive::Commands::SetupAgents, :new,
                  ->(**_kw) { agent_setup }) do
                  require "hive/web/service_status"
                  status = web_installer.service_state.merge(
                    "ready" => true, "readiness" => "ready", "url" => "http://127.0.0.1:4567"
                  )
                  with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot,
                    ->(**_kw) { status }) do
                    stub_web_config { yield }
                  end
                end
              end
            end
                end
              end
            end
          end
        end
      end
    end
  end

  def with_fake_init(success: true)
    fake = Object.new
    if success
      fake.define_singleton_method(:call) { true }
    else
      fake.define_singleton_method(:call) { raise Hive::AlreadyInitialized, "already" }
    end
    with_replaced_singleton_method(Hive::Commands::Init, :new, ->(*_a, **_kw) { fake }) do
      yield
    end
  end

  def with_manager_unavailable_web(diagnostics:, success: true, wire: "unsupported")
    state = {
      "platform" => "linux", "unit_path" => "/tmp/hive-web.service",
      "service_installed" => true, "service_enabled" => false,
      "service_running" => false, "service_manager_available" => false
    }
    installer = fake_installer(
      success: success,
      wire: wire,
      target_path: state.fetch("unit_path"),
      messages: [
        "systemd not detected; web unit was written but autostart was not enabled. " \
          "Enable systemd in WSL or run `hive web start` manually."
      ],
      state: state
    )
    snapshot = state.merge(
      "url" => "http://127.0.0.1:4567",
      "ready" => false,
      "readiness" => "manager_unavailable"
    )

    with_all_collaborators_ok(diagnostics: diagnostics) do
      with_fake_init do
        with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new,
          ->(**) { installer }) do
          with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot,
            ->(**) { snapshot }) do
            yield
          end
        end
      end
    end
  end

  # ── #call happy path ─────────────────────────────────────────────────

  def test_call_happy_path_records_all_phases_in_order_and_returns_zero
    output = StringIO.new
    diagnostics = diag(ok_row)
    require "hive/commands/init"
    require "hive/commands/daemon/service_installer"
    require "hive/commands/web/service_installer"

    exit_code = with_all_collaborators_ok(diagnostics: diagnostics) do
      with_fake_init do
        setup = Hive::Commands::Setup.new(json: true, yes: true, output: output)
        setup.call
      end
    end

    assert_equal 0, exit_code, "clean diagnostics + all phases ok must exit 0"
    payload = JSON.parse(output.string)
    assert_equal "hive-setup", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_equal "managed_service", payload["mode"]
    assert_equal true, payload["ok"]
    names = payload["phases"].map { |p| p["name"] }
    assert_equal %w[diagnostics agent_skills web_bundle daemon_service enroll web_service web], names,
                 "phases must be recorded in provisioning order"
    assert payload["phases"].all? { |p| p["ok"] }, "every phase ok on the happy path"
  end

  def test_setup_json_and_stderr_include_deduplicated_alias_guidance
    output = StringIO.new
    error = StringIO.new
    diagnostics = diag(ok_row)
    environment = {
      "HIVEBOX_STORAGE_DIR" => "/legacy/storage",
      "HIVEBOX_ORIGIN" => "https://legacy.example",
      "HIVE_WEB_ORIGIN" => "https://canonical.example"
    }
    require "hive/commands/init"
    require "hive/commands/daemon/service_installer"
    require "hive/commands/web/service_installer"

    exit_code = with_all_collaborators_ok(diagnostics: diagnostics) do
      with_fake_init do
        Hive::Commands::Setup.new(
          json: true,
          yes: true,
          output: output,
          error: error,
          environment: environment
        ).call
      end
    end

    assert_equal 0, exit_code
    warnings = JSON.parse(output.string).fetch("warnings")
    assert_equal 2, warnings.length
    assert_equal true, warnings.find { |warning| warning["alias"] == "HIVEBOX_ORIGIN" }.fetch("ignored")
    assert_equal 1, error.string.scan("HIVEBOX_ORIGIN").length
    assert_equal 1, error.string.scan("HIVEBOX_STORAGE_DIR").length
  end

  # ── --no-bootstrap (diagnose-only) ───────────────────────────────────

  def test_no_bootstrap_provisions_nothing_and_only_records_diagnostics_and_web
    output = StringIO.new
    diagnostics = diag(ok_row)
    fake_diag = Object.new
    fake_diag.define_singleton_method(:run) { diagnostics }

    # Trip-wire stubs: if --no-bootstrap wrongly provisions, these raise.
    exit_code =
      with_replaced_singleton_method(Hive::Setup::Diagnostics, :new, ->(*) { fake_diag }) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!,
          ->(*) { flunk "web bundle must not be provisioned in --no-bootstrap" }) do
          with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new,
            ->(**_kw) { flunk "daemon must not be installed in --no-bootstrap" }) do
            stub_web_config do
              Hive::Commands::Setup.new(json: true, no_bootstrap: true, output: output).call
            end
          end
        end
      end

    payload = JSON.parse(output.string)
    assert_equal "diagnose_only", payload["mode"]
    assert_equal %w[diagnostics web], payload["phases"].map { |p| p["name"] },
                 "diagnose-only run records only diagnostics + web"
    assert_equal 0, exit_code, "clean diagnostics with no provisioning still exits via successful?"
  end

  def test_no_bootstrap_exit_reflects_hard_diagnostic_failure
    output = StringIO.new
    hard = result(name: "git", status: "missing", fix_command: "brew install git", bootstrappable: false)
    diagnostics = diag(ok_row, hard)
    fake_diag = Object.new
    fake_diag.define_singleton_method(:run) { diagnostics }

    exit_code =
      with_replaced_singleton_method(Hive::Setup::Diagnostics, :new, ->(*) { fake_diag }) do
        stub_web_config do
          Hive::Commands::Setup.new(json: true, no_bootstrap: true, output: output).call
        end
      end

    assert_equal 1, exit_code, "a hard diagnostic failure must fail the exit-code contract"
    assert_equal false, JSON.parse(output.string)["ok"]
  end

  def test_json_without_yes_reports_consent_required_before_any_mutation
    output = StringIO.new
    exit_code = with_replaced_singleton_method(Hive::Setup::Diagnostics, :new,
      ->(*) { flunk "diagnostics must wait for unattended --yes consent" }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { flunk "web bootstrap must wait for --yes" }) do
        with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new,
          ->(**_kw) { flunk "daemon install must wait for --yes" }) do
          stub_web_config do
            Hive::Commands::Setup.new(
              json: true,
              output: output,
              setup_agents_factory: ->(**_kwargs) { flunk "agent inspection must wait for --yes" }
            ).call
          end
        end
      end
    end

    assert_equal 1, exit_code
    payload = JSON.parse(output.string)
    assert_equal %w[diagnostics agent_skills web], payload.fetch("phases").map { |phase| phase.fetch("name") }
    diagnostics_phase = payload.fetch("phases").find { |phase| phase.fetch("name") == "diagnostics" }
    assert_equal true, diagnostics_phase.fetch("skipped")
    assert_equal "consent_required", diagnostics_phase.fetch("reason")
    agent_phase = payload.fetch("phases").find { |phase| phase.fetch("name") == "agent_skills" }
    assert_equal false, agent_phase.fetch("ok")
    assert_equal "consent_required", agent_phase.fetch("classification")
    assert_equal "json_requires_yes", agent_phase.dig("consent", "provenance")
  end

  # ── --no-init: enroll skipped ────────────────────────────────────────

  def test_no_init_skips_enroll_phase
    output = StringIO.new
    diagnostics = diag(ok_row)
    require "hive/commands/init"

    with_all_collaborators_ok(diagnostics: diagnostics) do
      with_replaced_singleton_method(Hive::Commands::Init, :new,
        ->(*_a, **_kw) { flunk "enroll must be skipped with --no-init" }) do
        Hive::Commands::Setup.new(json: true, no_init: true, yes: true, output: output).call
      end
    end

    names = JSON.parse(output.string)["phases"].map { |p| p["name"] }
    refute_includes names, "enroll", "--no-init must not record an enroll phase"
    assert_equal %w[diagnostics agent_skills web_bundle daemon_service web_service web], names
  end

  # ── --service: web service installed ─────────────────────────────────

  def test_default_installs_web_service_phase
    output = StringIO.new
    diagnostics = diag(ok_row)

    with_all_collaborators_ok(diagnostics: diagnostics) do
      with_fake_init do
        Hive::Commands::Setup.new(json: true, yes: true, output: output).call
      end
    end

    names = JSON.parse(output.string)["phases"].map { |p| p["name"] }
    assert_includes names, "web_service", "default setup must record the web_service phase"
    web_service = JSON.parse(output.string)["phases"].find { |p| p["name"] == "web_service" }
    assert_equal true, web_service["ok"]
    assert_equal "written", web_service["outcome"]
    assert_equal "/tmp/unit.service", web_service["target_path"]
    assert_equal true, web_service["service_installed"]
    assert_equal true, web_service["service_enabled"]
    assert_equal true, web_service["service_running"]
    assert_equal true, web_service["ready"]
  end

  def test_manager_unavailable_is_a_successful_json_platform_exception
    output = StringIO.new

    exit_code = with_manager_unavailable_web(diagnostics: diag(ok_row)) do
      Hive::Commands::Setup.new(json: true, yes: true, output: output).call
    end

    assert_equal 0, exit_code
    payload = JSON.parse(output.string)
    assert_equal true, payload["ok"]
    assert_equal false, payload.dig("service", "service_manager_available")
    assert_equal true, payload.dig("service", "service_installed")
    assert_equal false, payload.dig("service", "service_enabled")
    assert_equal false, payload.dig("service", "service_running")
    assert_equal false, payload.dig("service", "ready")
    assert_equal "manager_unavailable", payload.dig("service", "readiness")

    web_service = payload.fetch("phases").find { |phase| phase.fetch("name") == "web_service" }
    assert_equal true, web_service["ok"]
    assert_equal "unsupported", web_service["outcome"]
    assert_match(/foreground/, web_service["message"])
    assert_match(/Hivebox/, web_service["message"])

    web = payload.fetch("phases").find { |phase| phase.fetch("name") == "web" }
    assert_equal true, web["ok"]
    assert_equal false, web["available"]
    assert_equal "manager_unavailable", web["readiness"]

    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-setup"))))
    assert_empty schemer.validate(payload).to_a,
                 "manager-unavailable setup success must validate against hive-setup.v1"
  end

  def test_manager_unavailable_human_output_reports_foreground_and_hivebox_recovery
    output = StringIO.new

    exit_code = with_manager_unavailable_web(diagnostics: diag(ok_row)) do
      Hive::Commands::Setup.new(json: false, yes: true, output: output).call
    end

    assert_equal 0, exit_code
    assert_includes output.string, "hive setup: web_service ok"
    assert_includes output.string,
                    "manager_available=false installed=true enabled=false running=false ready=false"
    assert_includes output.string, "foreground command: `hive web`"
    assert_includes output.string, "enable systemd in WSL"
    assert_includes output.string, "Hivebox"
  end

  def test_manager_unavailable_does_not_hide_a_failed_install
    output = StringIO.new

    exit_code = with_manager_unavailable_web(
      diagnostics: diag(ok_row), success: false, wire: "failed"
    ) do
      Hive::Commands::Setup.new(json: true, yes: true, output: output).call
    end

    assert_equal 1, exit_code
    payload = JSON.parse(output.string)
    assert_equal false, payload["ok"]
    assert_equal false,
                 payload.fetch("phases").find { |phase| phase.fetch("name") == "web_service" }.fetch("ok")
    assert_equal false,
                 payload.fetch("phases").find { |phase| phase.fetch("name") == "web" }.fetch("ok")
  end

  def test_no_service_performs_no_service_mutation_and_reports_observed_state
    output = StringIO.new
    diagnostics = diag(ok_row)
    installer = fake_installer
    installer.define_singleton_method(:install!) { |**| flunk "--no-service must not mutate the service" }

    with_all_collaborators_ok(diagnostics: diagnostics) do
      with_fake_init do
        with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new, ->(**) { installer }) do
          Hive::Commands::Setup.new(json: true, service: false, yes: true, output: output).call
        end
      end
    end

    payload = JSON.parse(output.string)
    assert_equal "service_opt_out", payload["mode"]
    phase = payload["phases"].find { |row| row["name"] == "web_service" }
    assert_equal "opted_out", phase["mutation"]
    assert_equal true, phase["service_running"]
    assert_equal true, phase["ready"]
  end

  def test_failed_web_bundle_blocks_service_install
    output = StringIO.new
    diagnostics = diag(ok_row)
    fake_diag = Object.new
    fake_diag.define_singleton_method(:run) { diagnostics }

    with_replaced_singleton_method(Hive::Setup::Diagnostics, :new, ->(*) { fake_diag }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { raise Hive::Error, "bad bundle" }) do
        with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new,
          ->(**) { fake_installer }) do
          observed = fake_installer(state: {
            "platform" => "linux", "unit_path" => "/tmp/unit.service",
            "service_installed" => true, "service_enabled" => true,
            "service_running" => true, "service_manager_available" => true
          })
          observed.define_singleton_method(:install!) { |**| flunk "blocked setup must not mutate service" }
            with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new,
              ->(**) { observed }) do
              stub_web_config do
                state = observed.service_state.merge(
                  "ready" => true, "readiness" => "ready", "url" => "http://127.0.0.1:4567"
                )
                with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, ->(**) { state }) do
                  Hive::Commands::Setup.new(json: true, no_init: true, yes: true, output: output).call
                end
              end
          end
        end
      end
    end

    payload = JSON.parse(output.string)
    phase = payload["phases"].find { |row| row["name"] == "web_service" }
    assert_equal false, phase["ok"]
    assert_equal "blocked", phase["mutation"]
    assert_match(/web_bundle/, phase["message"])
    assert_equal true, phase["service_running"]
    assert_equal true, payload.dig("service", "ready")
  end

  def test_web_service_failure_records_message_and_fails_exit
    output = StringIO.new
    diagnostics = diag(ok_row)

    exit_code =
      with_all_collaborators_ok(diagnostics: diagnostics) do
        with_fake_init do
          with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new,
            ->(**_kw) { raise Errno::EACCES, "/Library/LaunchAgents" }) do
            Hive::Commands::Setup.new(json: true, yes: true, output: output).call
          end
        end
      end

    assert_equal 1, exit_code
    phase = JSON.parse(output.string)["phases"].find { |p| p["name"] == "web_service" }
    assert_equal false, phase["ok"]
    assert_match(/Errno::EACCES/, phase["message"], "the raised class+message must be recorded")
  end

  def test_observed_web_service_failure_records_safe_fallback_state
    environment = { "HIVE_WEB_LOCAL_LOOPBACK" => "1" }
    setup = Hive::Commands::Setup.new(output: StringIO.new, environment: environment)
    fallback = {
      "platform" => "unsupported", "unit_path" => nil,
      "service_installed" => false, "service_enabled" => false,
      "service_running" => false, "service_manager_available" => false,
      "url" => "http://127.0.0.1:4567", "ready" => false,
      "readiness" => "manager_unavailable"
    }
    snapshot_args = nil

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new,
        ->(**_kw) { raise Errno::EACCES, "/Library/LaunchAgents" }) do
        with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, lambda { |**kwargs|
          snapshot_args = kwargs
          fallback
        }) do
          stub_web_config do
            setup.send(:observe_web_service, mutation: "blocked", ok: false, message: "bundle failed")
          end
        end
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_equal "blocked", phase["mutation"]
    assert_match(/Errno::EACCES/, phase["message"])
    assert_equal [], phase["messages"]
    assert_equal false, phase["service_manager_available"]
    assert_nil snapshot_args[:installer]
    assert_equal environment, snapshot_args[:environment]
    assert_equal fallback, setup.instance_variable_get(:@web_service)
  end

  def test_drifted_web_service_is_preserved_with_explicit_repair_guidance
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    installer = fake_installer(success: false, wire: "drifted")
    state = installer.service_state.merge(
      "ready" => false, "readiness" => "inactive", "url" => "http://127.0.0.1:4567"
    )

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new, ->(**) { installer }) do
        with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, ->(**) { state }) do
          stub_web_config { setup.send(:install_web_service) }
        end
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_equal "drifted", phase["outcome"]
    assert_match(/customized web service preserved/, phase["message"])
    assert_match(/hive web install --force/, phase["message"])
  end

  def test_active_but_not_ready_web_service_uses_truthful_failure_guidance
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    installer = fake_installer(success: true, wire: "unchanged")
    state = installer.service_state.merge(
      "ready" => false, "readiness" => "active_not_ready", "url" => "http://127.0.0.1:4567"
    )

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new, ->(**) { installer }) do
        with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, ->(**) { state }) do
          stub_web_config { setup.send(:install_web_service) }
        end
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/did not reach installed, enabled, running, and ready state/, phase["message"])
    refute setup.send(:successful?, diag(ok_row)), "active-but-not-ready must remain nonzero"
  end

  def test_refreshed_bundle_restarts_an_already_running_service
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    setup.instance_variable_set(:@web_bundle_refreshed, true)
    installer = fake_installer(success: true, wire: "unchanged")
    restart_calls = 0
    installer.define_singleton_method(:restart!) { restart_calls += 1; true }
    state = installer.service_state.merge(
      "ready" => true, "readiness" => "ready", "url" => "http://127.0.0.1:4567"
    )

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Web::ServiceInstaller, :new, ->(**) { installer }) do
        with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, ->(**) { state }) do
          stub_web_config { setup.send(:install_web_service) }
        end
      end
    end

    assert_equal 1, restart_calls
    assert_equal true, setup.instance_variable_get(:@phases).last["restarted"]
  end

  # ── bootstrap_qmd_if_missing ─────────────────────────────────────────

  def test_qmd_bootstrap_success_records_ok_phase_with_prefix
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: true, output: output)
    diagnostics = diag(qmd_missing_bootstrappable)
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }

    qmd = File.join(Hive::Paths.data_home, "qmd", "bin", "qmd")
    FileUtils.mkdir_p(File.dirname(qmd))
    File.write(qmd, "#!/bin/sh\n")
    FileUtils.chmod(0o755, qmd)
    npm_call = nil
    probe_call = nil
    with_replaced_singleton_method(Open3, :capture3, lambda { |*argv|
      npm_call = argv
      [ "", "", ok_status ]
    }) do
      with_replaced_singleton_method(Hive::Setup::QmdProbe, :call, lambda { |path, **_kwargs|
        probe_call = path
        [ "qmd 2.0.0", "", ok_status ]
      }) do
        setup.send(:bootstrap_qmd_if_missing, diagnostics)
      end
    end

    assert_equal %w[npm install --global --prefix], npm_call[0..3],
                 "must invoke the global npm install for the qmd package"
    assert_equal "@tobilu/qmd", npm_call.last
    assert_equal qmd, probe_call
    phase = setup.instance_variable_get(:@phases).last
    assert_equal "qmd", phase["name"]
    assert_equal true, phase["ok"]
    assert phase["prefix"].end_with?("qmd"), "the install prefix must be recorded"
    refute phase.key?("message"), "a successful install records no error message"
  end

  def test_qmd_bootstrap_failure_records_stderr_message_and_ok_false
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: true, output: output)
    diagnostics = diag(qmd_missing_bootstrappable)
    fail_status = Object.new
    fail_status.define_singleton_method(:success?) { false }

    with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "  EACCES: permission denied  ", fail_status ] }) do
      setup.send(:bootstrap_qmd_if_missing, diagnostics)
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_equal "EACCES: permission denied", phase["message"], "stripped npm stderr must be the phase message"
  end

  def test_qmd_bootstrap_fails_when_npm_does_not_publish_the_executable
    setup = Hive::Commands::Setup.new(json: true, output: StringIO.new)
    diagnostics = diag(qmd_missing_bootstrappable)
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }
    FileUtils.rm_f(File.join(Hive::Paths.data_home, "qmd", "bin", "qmd"))

    with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "", ok_status ] }) do
      setup.send(:bootstrap_qmd_if_missing, diagnostics)
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/npm install succeeded but no executable was found/, phase["message"])
  end

  def test_qmd_bootstrap_fails_when_the_installed_binary_cannot_start
    setup = Hive::Commands::Setup.new(json: true, output: StringIO.new)
    diagnostics = diag(qmd_missing_bootstrappable)
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }
    fail_status = Object.new
    fail_status.define_singleton_method(:success?) { false }
    qmd = File.join(Hive::Paths.data_home, "qmd", "bin", "qmd")
    FileUtils.mkdir_p(File.dirname(qmd))
    File.write(qmd, "#!/bin/sh\n")
    FileUtils.chmod(0o755, qmd)
    secret = [ "sk", "B" * 24 ].join("-")
    probe_argv = nil

    with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "", ok_status ] }) do
      with_replaced_singleton_method(Hive::Setup::QmdProbe, :call, lambda { |path, **_kwargs|
        probe_argv = path
        [ "", "NODE_MODULE_VERSION mismatch #{secret}\u0000#{'y' * 1_500}", fail_status ]
      }) do
        setup.send(:bootstrap_qmd_if_missing, diagnostics)
      end
    end

    assert_equal qmd, probe_argv
    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/failed to start/, phase["message"])
    assert_match(/NODE_MODULE_VERSION mismatch/, phase["message"])
    assert_includes phase["message"], "[REDACTED:openai_api_key]"
    refute_includes phase["message"], secret
    assert_operator phase["message"].length, :<, 1_100
  end

  def test_qmd_bootstrap_reports_a_probe_failure_without_empty_detail_punctuation
    setup = Hive::Commands::Setup.new(json: true, output: StringIO.new)
    diagnostics = diag(qmd_missing_bootstrappable)
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }
    fail_status = Object.new
    fail_status.define_singleton_method(:success?) { false }
    qmd = File.join(Hive::Paths.data_home, "qmd", "bin", "qmd")
    FileUtils.mkdir_p(File.dirname(qmd))
    File.write(qmd, "#!/bin/sh\n")
    FileUtils.chmod(0o755, qmd)

    with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "", ok_status ] }) do
      with_replaced_singleton_method(Hive::Setup::QmdProbe, :call, ->(_path, **_kwargs) { [ "", "", fail_status ] }) do
        setup.send(:bootstrap_qmd_if_missing, diagnostics)
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_equal "qmd was installed but failed to start", phase["message"]
  end

  def test_qmd_bootstrap_records_a_bounded_probe_timeout_as_phase_failure
    setup = Hive::Commands::Setup.new(json: true, output: StringIO.new)
    diagnostics = diag(qmd_missing_bootstrappable)
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }
    qmd = File.join(Hive::Paths.data_home, "qmd", "bin", "qmd")
    FileUtils.mkdir_p(File.dirname(qmd))
    File.write(qmd, "#!/bin/sh\n")
    FileUtils.chmod(0o755, qmd)
    probe_call = nil

    with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "", ok_status ] }) do
      with_replaced_singleton_method(Hive::Setup::QmdProbe, :call, lambda { |path, **_kwargs|
        probe_call = path
        raise Hive::Error, "hive setup: qmd startup probe timed out after 10s"
      }) do
        setup.send(:bootstrap_qmd_if_missing, diagnostics)
      end
    end

    assert_equal qmd, probe_call
    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/qmd startup probe timed out after 10s/, phase["message"])
  end

  def test_qmd_bootstrap_skipped_when_not_bootstrappable
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    # qmd present (ok) → not bootstrappable → early return, no phase, no npm.
    diagnostics = diag(result(name: "qmd", status: "ok"))

    with_replaced_singleton_method(Open3, :capture3, ->(*_a) { flunk "npm must not run when qmd is not bootstrappable" }) do
      setup.send(:bootstrap_qmd_if_missing, diagnostics)
    end

    assert_empty setup.instance_variable_get(:@phases), "no qmd phase when qmd is already present"
  end

  def test_qmd_bootstrap_skipped_when_row_absent
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    diagnostics = diag(ok_row("ruby")) # no qmd row at all

    with_replaced_singleton_method(Open3, :capture3, ->(*_a) { flunk "npm must not run without a qmd row" }) do
      setup.send(:bootstrap_qmd_if_missing, diagnostics)
    end

    assert_empty setup.instance_variable_get(:@phases)
  end

  # ── bootstrap_web_bundle ─────────────────────────────────────────────

  def test_web_bundle_success_records_path
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { "/managed/web" }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :app_dir, ->(*) { "/managed/web" }) do
        setup.send(:bootstrap_web_bundle)
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal "web_bundle", phase["name"]
    assert_equal true, phase["ok"]
    assert_equal "/managed/web", phase["path"]
  end

  def test_web_bundle_failure_records_class_and_message
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { raise SocketError, "offline" }) do
      setup.send(:bootstrap_web_bundle)
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_equal "SocketError: offline", phase["message"],
                 "a download/network failure must be recorded, not raised"
  end

  # ── install_daemon ───────────────────────────────────────────────────

  def test_install_daemon_success_records_outcome_target_and_messages
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    require "hive/commands/daemon/service_installer"
    installer = fake_installer(success: true, wire: "upgraded",
                               target_path: "/etc/hive-daemon.service", messages: [ "restarted" ])

    with_replaced_singleton_method(Hive::InvokedBinary, :path, ->(*) { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kw) { installer }) do
        setup.send(:install_daemon)
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal "daemon_service", phase["name"]
    assert_equal true, phase["ok"]
    assert_equal "upgraded", phase["outcome"]
    assert_equal "/etc/hive-daemon.service", phase["target_path"]
    assert_equal [ "restarted" ], phase["messages"]
  end

  def test_install_daemon_raise_records_message_and_ok_false
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    require "hive/commands/daemon/service_installer"

    with_replaced_singleton_method(Hive::InvokedBinary, :path, ->(*) { "/usr/bin/hive" }) do
      with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new,
        ->(**_kw) { raise Errno::EACCES, "/etc/systemd" }) do
        setup.send(:install_daemon)
      end
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/Errno::EACCES/, phase["message"])
  end

  # ── enroll_project ───────────────────────────────────────────────────

  def test_enroll_success_via_init
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    require "hive/commands/init"

    with_fake_init(success: true) do
      setup.send(:enroll_project)
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal "enroll", phase["name"]
    assert_equal true, phase["ok"]
    assert_equal Dir.pwd, phase["path"]
  end

  def test_enroll_suppresses_nested_init_agent_skill_preflight
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:call) { true }

    with_replaced_singleton_method(Hive::Commands::Init, :new, lambda { |*_args, **kwargs|
      captured = kwargs
      fake
    }) do
      setup.send(:enroll_project)
    end

    assert_equal false, captured.fetch(:agent_skill_preflight)
  end

  def test_agent_skill_phase_exposes_aggregate_target_states
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    target = lambda do |agent, capability|
      Hive::AgentSkills::Target.new(
        surfaces: [ "hive.operations" ], kind: "operating", agent: agent,
        configured_skill: capability, invocation: "/#{capability}", capability_id: capability,
        package_id: "hive-operations", managed: true
      )
    end
    rows = {
      "unchanged" => "healthy",
      "unavailable" => "unavailable",
      "drifted" => "stale",
      "would_write" => "missing",
      "failed" => "conflicting"
    }.map do |capability, health|
      Hive::AgentSkills::Inspection.new(
        target: target.call("claude", capability), expected: {}, native: {}, resolution: {},
        health: health, severity: "error", explanation: health, remediation: "repair"
      )
    end
    operation = Hive::AgentSkills::Adapters::Operation.new(
      id: "claude:hive:publish", agent: "claude", package_id: "hive-operations",
      capabilities: [ "would_write" ], kind: "bundled_skill_publish", argv: [], files: [],
      depends_on: [], preconditions: {}, metadata: {}
    )
    plan = Hive::AgentSkills::ProvisioningPlan.new(
      inspections: rows, operations: [ operation ], conflicts: [],
      filters: { "agents" => [], "skills" => [] }, fingerprint: "test"
    )

    states = setup.send(:setup_target_states, plan).to_h do |row|
      [ row.fetch("capability"), row.fetch("state") ]
    end
    assert_equal %w[unchanged unavailable drifted would_write failed].sort, states.values.sort
  end

  def test_enroll_already_initialized_falls_back_to_daemon_enable
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    require "hive/commands/init"
    require "hive/commands/daemon"

    enable_calls = []
    fake_daemon = Object.new
    fake_daemon.define_singleton_method(:call) { enable_calls << :called }

    with_fake_init(success: false) do
      with_replaced_singleton_method(Hive::Commands::Daemon, :new, lambda { |verb, name|
        enable_calls << [ verb, name ]
        fake_daemon
      }) do
        # current_project_name resolves against the registry; stub to a name.
        setup.define_singleton_method(:current_project_name) { "myproj" }
        setup.send(:enroll_project)
      end
    end

    assert_equal [ "enable", "myproj" ], enable_calls.first,
                 "an already-enrolled project must fall through to `daemon enable <name>`"
    assert_includes enable_calls, :called
    phase = setup.instance_variable_get(:@phases).last
    assert_equal true, phase["ok"]
  end

  def test_enroll_other_error_records_ok_false
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    require "hive/commands/init"
    fake = Object.new
    fake.define_singleton_method(:call) { raise Hive::Error, "corrupt registry" }

    with_replaced_singleton_method(Hive::Commands::Init, :new, ->(*_a, **_kw) { fake }) do
      setup.send(:enroll_project)
    end

    phase = setup.instance_variable_get(:@phases).last
    assert_equal false, phase["ok"]
    assert_match(/corrupt registry/, phase["message"])
  end

  # ── current_project_name ─────────────────────────────────────────────

  def test_current_project_name_returns_registered_name_on_realpath_match
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    current = File.realpath(Dir.pwd)
    with_replaced_singleton_method(Hive::Config, :registered_projects,
      ->(*) { [ { "name" => "registered-name", "path" => current } ] }) do
      assert_equal "registered-name", setup.send(:current_project_name)
    end
  end

  def test_current_project_name_falls_back_to_basename_when_unregistered
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    with_replaced_singleton_method(Hive::Config, :registered_projects, ->(*) { [] }) do
      assert_equal File.basename(Dir.pwd), setup.send(:current_project_name)
    end
  end

  def test_current_project_name_warns_and_uses_basename_on_config_error
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    result_name = nil
    _out, err = capture_io do
      with_replaced_singleton_method(Hive::Config, :registered_projects,
        ->(*) { raise Hive::ConfigError, "bad registry" }) do
        result_name = setup.send(:current_project_name)
      end
    end

    assert_equal File.basename(Dir.pwd), result_name
    assert_match(/could not resolve registered project name/, err)
    assert_match(/Hive::ConfigError/, err)
  end

  # ── web_url ──────────────────────────────────────────────────────────

  def test_web_url_builds_from_global_web_config
    setup = Hive::Commands::Setup.new(output: StringIO.new)
    with_replaced_singleton_method(Hive::Config, :load_global_web,
      ->(*) { { "bind" => "127.0.0.1", "port" => 8080 } }) do
      assert_equal "http://127.0.0.1:8080", setup.send(:web_url)
    end
  end

  # ── emit (human path) ────────────────────────────────────────────────

  def test_emit_human_lists_phase_lines_fix_hints_and_web_url
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: false, output: output)
    setup.send(:add_phase, "diagnostics", true)
    setup.send(:add_phase, "web_bundle", false, "message" => "boom")
    # A hard-failing, non-bootstrappable row with a fix_command → prints a fix line.
    # A bootstrappable row and an ok row must NOT print fix lines.
    diagnostics = diag(
      ok_row("ruby"),
      result(name: "git", status: "missing", fix_command: "brew install git", bootstrappable: false),
      qmd_missing_bootstrappable
    )

    with_replaced_singleton_method(Hive::Config, :load_global_web,
      ->(*) { { "bind" => "127.0.0.1", "port" => 4567 } }) do
      setup.send(:emit, diagnostics)
    end

    text = output.string
    assert_includes text, "hive setup: diagnostics ok"
    assert_includes text, "hive setup: web_bundle needs attention"
    assert_includes text, "fix git: brew install git", "a hard-failing row with a fix_command must print a fix hint"
    refute_includes text, "fix qmd", "a bootstrappable row must not print a fix hint"
    refute_includes text, "fix ruby", "an ok row must not print a fix hint"
    assert_includes text, "Hive web is not ready at http://127.0.0.1:4567"
  end

  def test_emit_human_reports_observed_ready_url
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: false, output: output)
    setup.instance_variable_set(:@web_service, {
      "platform" => "linux", "unit_path" => "/tmp/hive-web.service",
      "service_manager_available" => true, "service_installed" => true,
      "service_enabled" => true, "service_running" => true,
      "ready" => true,
      "readiness" => "ready",
      "url" => "http://127.0.0.1:4567"
    })

    stub_web_config { setup.send(:emit, diag(ok_row)) }

    assert_includes output.string, "Hive web ready at http://127.0.0.1:4567"
    assert_includes output.string, "manager_available=true installed=true enabled=true running=true ready=true"
  end

  def test_emit_human_reports_foreground_path_when_service_opted_out
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: false, service: false, output: output)

    stub_web_config { setup.send(:emit, diag(ok_row)) }

    assert_includes output.string, "Hive web configured at http://127.0.0.1:4567"
    assert_includes output.string, "foreground command: `hive web`"
  end

  def test_emit_json_matches_successful_predicate
    output = StringIO.new
    setup = Hive::Commands::Setup.new(json: true, output: output)
    setup.send(:add_phase, "diagnostics", true)
    setup.send(:add_phase, "web_bundle", false) # a failed phase forces ok:false

    with_replaced_singleton_method(Hive::Config, :load_global_web,
      ->(*) { { "bind" => "127.0.0.1", "port" => 4567 } }) do
      setup.send(:emit, diag(ok_row))
    end

    payload = JSON.parse(output.string)
    assert_equal "hive-setup", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_equal false, payload["ok"], "a failed phase must make the JSON envelope ok:false"
    assert_equal 2, payload["phases"].size
  end
end
