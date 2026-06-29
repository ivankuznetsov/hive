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

        unless @no_bootstrap
          bootstrap_qmd_if_missing(diagnostics)
          bootstrap_web_bundle
        end

        install_daemon
        enroll_project unless @no_init
        install_web_service if @service
        add_phase("web", true, "url" => web_url)

        emit(diagnostics)
        hard_failures = diagnostics.results.reject { |row| row.ok? || row.bootstrappable }
        hard_failures.empty? ? 0 : 1
      end

      private

      def add_phase(name, ok, data = {})
        @phases << { "name" => name, "ok" => ok }.merge(data)
      end

      def bootstrap_qmd_if_missing(diagnostics)
        row = diagnostics.results.find { |result| result.name == "qmd" }
        return unless row&.bootstrappable && row.status == "missing"

        prefix = File.join(Hive::Paths.data_home, "qmd")
        ok = system("npm", "install", "--global", "--prefix", prefix, "@tobilu/qmd")
        add_phase("qmd", ok, "prefix" => prefix)
      end

      def bootstrap_web_bundle
        Hive::Web::AppBundle.ensure!
        add_phase("web_bundle", true, "path" => Hive::Web::AppBundle.app_dir)
      rescue Hive::Error => e
        add_phase("web_bundle", false, "message" => e.message)
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
      end

      def enroll_project
        require "hive/commands/init"
        Hive::Commands::Init.new(Dir.pwd, force: true, json: false).call
        add_phase("enroll", true, "path" => Dir.pwd)
      rescue Hive::AlreadyInitialized
        require "hive/commands/daemon"
        Hive::Commands::Daemon.new("enable", current_project_name).call
        add_phase("enroll", true, "path" => Dir.pwd)
      end

      def install_web_service
        require "hive/commands/web/service_installer"
        installer = Hive::Commands::Web::ServiceInstaller.new
        outcome = installer.install!(autostart: true, force: true)
        add_phase("web_service", outcome.success?, "outcome" => outcome.wire_outcome, "target_path" => installer.target_path)
      end

      def current_project_name
        current = File.realpath(Dir.pwd)
        entry = Hive::Config.registered_projects.find do |project|
          File.exist?(project["path"].to_s) && File.realpath(project["path"].to_s) == current
        end
        entry ? entry.fetch("name") : File.basename(current)
      rescue StandardError
        File.basename(Dir.pwd)
      end

      def web_url
        cfg = Hive::Config.load_global_web
        "http://#{cfg.fetch("bind")}:#{cfg.fetch("port")}"
      end

      def emit(diagnostics)
        payload = { "schema" => "hive-setup", "ok" => @phases.all? { |p| p["ok"] }, "phases" => @phases }
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
