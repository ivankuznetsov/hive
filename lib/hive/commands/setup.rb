require "json"
require "open3"

require "hive/config"
require "hive/invoked_binary"
require "hive/paths"
require "hive/setup/diagnostics"
require "hive/web/app_bundle"
require "hive/web/environment"
require "hive/web/service_status"

module Hive
  module Commands
    class Setup
      def initialize(json: false, service: true, no_bootstrap: false,
                     no_init: false, output: $stdout, error: nil,
                     environment: ENV)
        @json = json
        @service = service
        @no_bootstrap = no_bootstrap
        @no_init = no_init
        @output = output
        @error = error
        @environment = environment
        @phases = []
      end

      def call
        Hive::Web::Environment.emit_warnings(
          environment: @environment,
          output: @error || $stderr,
          prefix: "hive setup"
        )
        diagnostics = Hive::Setup::Diagnostics.new.run
        add_phase("diagnostics", diagnostics.ok?, diagnostics.to_h)

        # `--no-bootstrap` is diagnose-only (U6): it must provision NOTHING —
        # not the qmd/web bundles, and not the daemon/web services or project
        # enrollment either. Otherwise a "diagnose" run silently force-installs
        # the daemon and enrolls the cwd.
        unless @no_bootstrap
          bootstrap_qmd_if_missing(diagnostics)
          web_bundle = bootstrap_web_bundle
          install_daemon
          enroll_project unless @no_init
          if @service
            if web_bundle["ok"]
              install_web_service
            else
              add_phase(
                "web_service", false,
                "mutation" => "blocked",
                "message" => "web service not installed because web_bundle failed"
              )
            end
          else
            observe_web_service
          end
        end
        add_web_phase

        emit(diagnostics)
        successful?(diagnostics) ? 0 : 1
      end

      private

      # Setup succeeded only if BOTH diagnostics have no hard failure AND every
      # recorded phase (diagnostics / qmd / web_bundle / daemon_service /
      # enroll / web_service / web) reported ok. The exit code AND the --json
      # `ok` field both derive from this, so automation branching on either
      # (AE5) is never told a half-provisioned setup succeeded.
      def successful?(diagnostics)
        hard_failures = diagnostics.results.reject { |row| row.ok? || row.bootstrappable }
        hard_failures.empty? && all_phases_ok?
      end

      def all_phases_ok?
        @phases.all? { |phase| phase["ok"] }
      end

      def add_phase(name, ok, data = {})
        row = { "name" => name, "ok" => ok }.merge(data)
        @phases << row
        row
      end

      # Run one provisioning phase. The block returns [ok, data]; ANY raise
      # is recorded as a failed phase (→ non-zero exit) instead of aborting
      # `hive setup` with a raw backtrace before `emit` — the --json envelope
      # must still emit for automation branching on it (AE5). Provisioning
      # raises more than Hive::Error: OpenURI::HTTPError (404), SocketError /
      # Errno::ECONNREFUSED (offline), Zlib errors (corrupt asset), and
      # permission-denied writes from the service installers.
      def phase(name)
        ok, data = yield
        add_phase(name, ok, data)
      rescue StandardError => e
        add_phase(name, false, "message" => "#{e.class}: #{e.message}")
      end

      def bootstrap_qmd_if_missing(diagnostics)
        row = diagnostics.results.find { |result| result.name == "qmd" }
        return unless row&.bootstrappable && row.status == "missing"

        phase("qmd") do
          prefix = File.join(Hive::Paths.data_home, "qmd")
          # Capture npm's stderr so a failed install records WHY on the phase,
          # instead of a bare ok:false with no reason for the operator or
          # automation to act on.
          _out, err, status = Open3.capture3("npm", "install", "--global", "--prefix", prefix, "@tobilu/qmd")
          data = { "prefix" => prefix }
          data["message"] = err.strip unless status.success?
          [ status.success?, data ]
        end
      end

      def bootstrap_web_bundle
        phase("web_bundle") do
          Hive::Web::AppBundle.ensure!
          [ true, { "path" => Hive::Web::AppBundle.app_dir } ]
        end
      end

      def install_daemon
        phase("daemon_service") do
          require "hive/commands/daemon/service_installer"
          installer = Hive::Commands::Daemon::ServiceInstaller.new(binary_path: Hive::InvokedBinary.path)
          outcome = installer.install!(autostart: true, force: true)
          [ outcome.success?, {
            "outcome" => outcome.wire_outcome,
            "target_path" => installer.target_path,
            "messages" => installer.messages
          } ]
        end
      end

      def enroll_project
        phase("enroll") do
          require "hive/commands/init"
          begin
            Hive::Commands::Init.new(Dir.pwd, force: true, json: false).call
          rescue Hive::AlreadyInitialized
            require "hive/commands/daemon"
            Hive::Commands::Daemon.new("enable", current_project_name).call
          end
          [ true, { "path" => Dir.pwd } ]
        end
      end

      def install_web_service
        phase("web_service") do
          require "hive/commands/web/service_installer"
          # Pass the same resolved binary as install_daemon so both managed
          # services point at one hive binary (R8 same-binary guarantee).
          installer = Hive::Commands::Web::ServiceInstaller.new(binary_path: Hive::InvokedBinary.path)
          # Ordinary setup is intentionally drift-safe. A customized unit is
          # observed and preserved; explicit `hive web install --force` owns
          # the backup-producing repair path.
          outcome = installer.install!(autostart: true, force: false)
          state = Hive::Web::ServiceStatus.snapshot(installer: installer, config: web_config)
          @web_service = state
          ok = outcome.success? && service_available?(state)
          data = {
            "mutation" => "attempted",
            "outcome" => outcome.wire_outcome,
            "target_path" => installer.target_path,
            "messages" => installer.messages
          }.merge(state)
          unless ok
            data["message"] = if outcome.wire_outcome == "drifted"
              "customized web service preserved; repair explicitly with `hive web install --force`"
            else
              "web service did not reach installed, enabled, running, and ready state"
            end
          end
          [ ok, data ]
        end
      end

      def observe_web_service
        phase("web_service") do
          require "hive/commands/web/service_installer"
          installer = Hive::Commands::Web::ServiceInstaller.new(binary_path: Hive::InvokedBinary.path)
          state = Hive::Web::ServiceStatus.snapshot(installer: installer, config: web_config)
          @web_service = state
          [ true, { "mutation" => "opted_out", "messages" => installer.messages }.merge(state) ]
        end
      end

      def service_available?(state)
        state.values_at("service_installed", "service_enabled", "service_running", "ready").all?
      end

      def current_project_name
        current = File.realpath(Dir.pwd)
        entry = Hive::Config.registered_projects.find do |project|
          File.exist?(project["path"].to_s) && File.realpath(project["path"].to_s) == current
        end
        entry ? entry.fetch("name") : File.basename(current)
      rescue Hive::ConfigError, SystemCallError => e
        # A corrupt registry or a realpath/stat failure is recoverable — fall
        # back to the directory name — but surface it so `daemon enable`
        # running against a guessed name isn't silent. Programming errors are
        # NOT swallowed: they propagate.
        warn "hive setup: could not resolve registered project name " \
             "(#{e.class}: #{e.message}); using directory name #{File.basename(Dir.pwd)}"
        File.basename(Dir.pwd)
      end

      def web_url
        Hive::Web::ServiceStatus.effective_url(web_config)
      end

      def web_config
        @web_config ||= Hive::Config.load_global_web
      end

      def add_web_phase
        if @no_bootstrap
          add_phase(
            "web", true,
            "url" => web_url,
            "available" => false,
            "readiness" => "not_observed",
            "mutation" => "diagnose_only"
          )
          return
        end

        state = @web_service || {
          "url" => web_url,
          "ready" => false,
          "readiness" => "not_observed"
        }
        managed = @service
        add_phase(
          "web", managed ? state["ready"] == true : true,
          "url" => state["url"],
          "available" => state["ready"] == true,
          "readiness" => state["readiness"]
        )
      end

      def emit(diagnostics)
        # `ok` derives from successful? (the same predicate the exit code uses)
        # so the JSON envelope and the process exit status can never disagree —
        # a hard diagnostic failure must not report "ok": true while exiting 1.
        mode = if @no_bootstrap
          "diagnose_only"
        elsif @service
          "managed_service"
        else
          "service_opt_out"
        end
        payload = {
          "schema" => "hive-setup",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-setup"),
          "ok" => successful?(diagnostics),
          "mode" => mode,
          "url" => web_url,
          "service" => @web_service,
          "warnings" => Hive::Web::Environment.warnings(environment: @environment),
          "phases" => @phases
        }
        if @json
          @output.puts JSON.generate(payload)
        else
          @phases.each do |phase|
            @output.puts "hive setup: #{phase["name"]} #{phase["ok"] ? "ok" : "needs attention"}"
          end
          diagnostics.results.each do |row|
            next if row.ok? || row.bootstrappable || row.fix_command.to_s.empty?

            @output.puts "fix #{row.name}: #{row.fix_command}"
          end
          if @web_service && @web_service["ready"]
            @output.puts "hive setup: Hive web ready at #{@web_service["url"]}"
          elsif @service && !@no_bootstrap
            @output.puts "hive setup: Hive web is not ready at #{web_url}; inspect `hive web status`"
          else
            @output.puts "hive setup: Hive web configured at #{web_url}; foreground command: `hive web`"
          end
        end
      end
    end
  end
end
