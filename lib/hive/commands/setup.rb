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
      def initialize(json: false, service: false, no_bootstrap: false,
                     no_init: false, output: $stdout)
        @json = json
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
          outcome = installer.install!(autostart: true, force: true)
          [ outcome.success?, { "outcome" => outcome.wire_outcome, "target_path" => installer.target_path } ]
        end
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
