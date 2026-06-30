require "json"
require "open3"

require "hive/config"
require "hive/invoked_binary"
require "hive/paths"
require "hive/setup/diagnostics"
require "hive/web/app_bundle"

module Hive
  module Commands
    class Setup
      def initialize(json: false, yes: false, service: false, no_bootstrap: false,
                     no_init: false, output: $stdout)
        @json = json
        @yes = yes
        @service = service
        @no_bootstrap = no_bootstrap
        @no_init = no_init
        @output = output
        @phases = []
      end

      def call
        diagnostics = Hive::Setup::Diagnostics.new.run
        add_phase("diagnostics", diagnostics.ok?, diagnostics.to_h)

        # `--no-bootstrap` is diagnose-only (U6): it must provision NOTHING —
        # not the qmd/web bundles, and not the daemon/web services or project
        # enrollment either. Otherwise a "diagnose" run silently force-installs
        # the daemon and enrolls the cwd.
        unless @no_bootstrap
          bootstrap_qmd_if_missing(diagnostics)
          bootstrap_web_bundle
          install_daemon
          enroll_project unless @no_init
          install_web_service if @service
        end
        add_phase("web", true, "url" => web_url)

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
        @phases << { "name" => name, "ok" => ok }.merge(data)
      end

      def bootstrap_qmd_if_missing(diagnostics)
        row = diagnostics.results.find { |result| result.name == "qmd" }
        return unless row&.bootstrappable && row.status == "missing"

        prefix = File.join(Hive::Paths.data_home, "qmd")
        # Capture npm's stderr so a failed install records WHY on the phase
        # (mirrors bootstrap_web_bundle), instead of a bare ok:false with no
        # reason for the operator/automation to act on.
        _out, err, status = Open3.capture3("npm", "install", "--global", "--prefix", prefix, "@tobilu/qmd")
        data = { "prefix" => prefix }
        data["message"] = err.strip unless status.success?
        add_phase("qmd", status.success?, data)
      end

      def bootstrap_web_bundle
        Hive::Web::AppBundle.ensure!
        add_phase("web_bundle", true, "path" => Hive::Web::AppBundle.app_dir)
      rescue StandardError => e
        # `ensure!` downloads + unpacks a release tarball, so beyond
        # Hive::Error it can raise OpenURI::HTTPError (404), SocketError /
        # Errno::ECONNREFUSED (offline), or Zlib errors (corrupt asset).
        # Record any of these as a phase failure (→ non-zero exit) instead of
        # aborting `hive setup` with a raw backtrace.
        add_phase("web_bundle", false, "message" => "#{e.class}: #{e.message}")
      end

      def install_daemon
        require "hive/commands/daemon/service_installer"
        installer = Hive::Commands::Daemon::ServiceInstaller.new(binary_path: Hive::InvokedBinary.path)
        outcome = installer.install!(autostart: true, force: true)
        add_phase(
          "daemon_service",
          outcome.success?,
          "outcome" => outcome.wire_outcome,
          "target_path" => installer.target_path,
          "messages" => installer.messages
        )
      rescue StandardError => e
        # A permission-denied / write failure in the installer must not abort
        # `hive setup` with a raw backtrace before `emit` — record the phase
        # ok:false (→ non-zero exit) so the --json envelope still emits (AE5).
        add_phase("daemon_service", false, "message" => "#{e.class}: #{e.message}")
      end

      def enroll_project
        require "hive/commands/init"
        Hive::Commands::Init.new(Dir.pwd, force: true, json: false).call
        add_phase("enroll", true, "path" => Dir.pwd)
      rescue Hive::AlreadyInitialized
        require "hive/commands/daemon"
        Hive::Commands::Daemon.new("enable", current_project_name).call
        add_phase("enroll", true, "path" => Dir.pwd)
      rescue StandardError => e
        # Any other init/enable failure (write error, corrupt registry) records
        # the phase ok:false so `emit` still produces a --json envelope instead
        # of aborting with a backtrace (AE5).
        add_phase("enroll", false, "message" => "#{e.class}: #{e.message}")
      end

      def install_web_service
        require "hive/commands/web/service_installer"
        # Pass the same resolved binary as install_daemon so both managed
        # services point at one hive binary (R8 same-binary guarantee).
        installer = Hive::Commands::Web::ServiceInstaller.new(binary_path: Hive::InvokedBinary.path)
        outcome = installer.install!(autostart: true, force: true)
        add_phase("web_service", outcome.success?, "outcome" => outcome.wire_outcome, "target_path" => installer.target_path)
      rescue StandardError => e
        # Mirror install_daemon: a service-write failure records ok:false so the
        # --json envelope still emits instead of aborting with a backtrace (AE5).
        add_phase("web_service", false, "message" => "#{e.class}: #{e.message}")
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
        cfg = Hive::Config.load_global_web
        "http://#{cfg.fetch("bind")}:#{cfg.fetch("port")}"
      end

      def emit(diagnostics)
        # `ok` derives from successful? (the same predicate the exit code uses)
        # so the JSON envelope and the process exit status can never disagree —
        # a hard diagnostic failure must not report "ok": true while exiting 1.
        payload = { "schema" => "hive-setup", "ok" => successful?(diagnostics), "phases" => @phases }
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
          @output.puts "hive setup: web available with `hive web` at #{web_url}"
        end
      end
    end
  end
end
