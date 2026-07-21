require "open3"
require "rbconfig"
require "rubygems"
require "timeout"

require "hive"
require "hive/paths"
require "hive/agent_profiles"

module Hive
  module Setup
    class Diagnostics
      Result = Struct.new(:name, :status, :detail, :fix_command, :bootstrappable, keyword_init: true) do
        # The closed set of diagnostic statuses. Validated at construction so a
        # typo or a new state can't silently flow into the JSON contract.
        STATUSES = %w[ok missing version_too_old unauthenticated].freeze

        def initialize(...)
          super
          return if STATUSES.include?(status)

          raise ArgumentError,
                "invalid diagnostics status #{status.inspect} (expected one of #{STATUSES.join(', ')})"
        end

        def ok?
          status == "ok"
        end

        def to_h
          {
            "name" => name,
            "status" => status,
            "detail" => detail,
            "fix_command" => fix_command,
            "bootstrappable" => bootstrappable
          }
        end
      end

      Aggregate = Struct.new(:results, keyword_init: true) do
        def ok?
          results.all? { |row| row.ok? || row.bootstrappable }
        end

        def to_h
          { "ok" => ok?, "results" => results.map(&:to_h) }
        end
      end

      REQUIRED = {
        "ruby" => "3.4.0",
        "git" => "2.40.0",
        "tmux" => "3.0",
        "claude" => "2.1.118",
        "codex" => "0.125.0"
      }.freeze

      CHECKS = %w[ruby git tmux gh claude codex node npm qmd web_bundle sqlite].freeze

      def initialize(runner: nil, env: ENV.to_h, path: nil, ruby_version: RUBY_VERSION)
        @runner = runner || method(:default_run)
        @env = env
        @path = path || env.fetch("PATH", "")
        @ruby_version = ruby_version
      end

      def run
        Aggregate.new(results: CHECKS.map { |name| public_send("check_#{name}") })
      end

      def check_ruby
        version_result("ruby", @ruby_version, REQUIRED.fetch("ruby"), "Install Ruby #{REQUIRED.fetch("ruby")} or newer")
      end

      def check_git
        check_versioned_binary("git", [ "git", "--version" ], REQUIRED.fetch("git"), install_command("git"))
      end

      def check_tmux
        check_versioned_binary("tmux", [ "tmux", "-V" ], REQUIRED.fetch("tmux"), install_command("tmux"))
      end

      def check_gh
        path = which("gh")
        return missing("gh", install_command("gh")) unless path

        out, err, status = run_command([ path, "auth", "status" ])
        return ok("gh", "authenticated") if status.success?

        Result.new(
          name: "gh",
          status: "unauthenticated",
          detail: diagnostic(err, out, "gh is installed but not authenticated"),
          fix_command: "gh auth login",
          bootstrappable: false
        )
      end

      def check_claude
        check_agent("claude", REQUIRED.fetch("claude"), [ "claude", "setup-token" ])
      end

      def check_codex
        check_agent("codex", REQUIRED.fetch("codex"), [ "codex", "login" ])
      end

      def check_node
        check_versioned_binary("node", [ "node", "--version" ], nil, install_command("node"))
      end

      def check_npm
        check_versioned_binary("npm", [ "npm", "--version" ], nil, install_command("node"))
      end

      def check_qmd
        path = which("qmd") || managed_qmd
        return bootstrappable("qmd", "qmd can be installed by hive setup") unless path && File.executable?(path)

        ok("qmd", path)
      end

      def check_web_bundle
        require "hive/web/app_bundle"
        unless Hive::Web::AppBundle.present?
          return bootstrappable("web_bundle", "managed web app can be installed by hive setup")
        end

        if Hive::Web::AppBundle.stale?
          # Present but older than the CLI — `hive web`/`hive setup` refreshes
          # it automatically, so still a bootstrap candidate.
          Result.new(name: "web_bundle", status: "version_too_old",
                     detail: "managed web bundle is stale", fix_command: nil, bootstrappable: true)
        elsif !Hive::Web::AppBundle.assets_ready?
          Result.new(name: "web_bundle", status: "missing",
                     detail: "managed web bundle assets are missing", fix_command: nil, bootstrappable: true)
        else
          # Installed and current: a real success, NOT a bootstrap candidate
          # (the old code emitted status "ok" with bootstrappable: true — an
          # illegal ok? && bootstrappable state).
          ok("web_bundle", Hive::Web::AppBundle.app_dir)
        end
      rescue LoadError => e
        # A genuine code-load failure (missing dependency, syntax error) is NOT
        # something `hive setup` bootstraps — report it as an un-bootstrappable
        # failure so the user isn't misdirected toward a reinstall that can't
        # fix a load problem.
        Result.new(name: "web_bundle", status: "missing",
                   detail: "web bundle support failed to load: #{e.message}",
                   fix_command: nil, bootstrappable: false)
      end

      def check_sqlite
        if which("sqlite3")
          ok("sqlite", "sqlite3 binary present")
        else
          Result.new(
            name: "sqlite",
            status: "missing",
            detail: "sqlite3 is not on PATH",
            fix_command: install_command("sqlite"),
            bootstrappable: false
          )
        end
      end

      private

      def check_agent(name, required, auth_fix)
        path = which(name)
        return missing(name, install_command(name)) unless path

        result = check_versioned_binary(name, [ path, "--version" ], required, install_command(name))
        return result unless result.ok?

        return result if agent_authenticated?(name)

        Result.new(
          name: name,
          status: "unauthenticated",
          detail: "#{name} is installed but no local auth signal was found",
          fix_command: auth_fix.join(" "),
          bootstrappable: false
        )
      end

      # Auth is satisfied by an env API key OR an on-disk token persisted by
      # the CLI's own login flow (`claude setup-token` / `codex login`). The
      # on-disk probe reuses Hive::AgentProfiles.logged_in? (the same artifact
      # check the agent profiles use), so a token-authenticated user — who has
      # no env var set — is no longer reported as a false negative (plan U1).
      # CODEX_HOME is intentionally NOT treated as an auth signal: it only
      # points at the config dir and is set even when no credential exists.
      def agent_authenticated?(name)
        env_keys = name == "claude" ? %w[ANTHROPIC_API_KEY CLAUDE_API_KEY] : %w[OPENAI_API_KEY]
        return true if env_keys.any? { |key| @env[key].to_s != "" }

        Hive::AgentProfiles.logged_in?(name, home: @env.fetch("HOME", Dir.home))
      end

      def check_versioned_binary(name, argv, required, fix_command)
        path = which(argv.first)
        return missing(name, fix_command) unless path

        out, err, status = run_command([ path, *argv.drop(1) ])
        return Result.new(name: name, status: "missing", detail: diagnostic(err, out, "#{name} failed"), fix_command: fix_command, bootstrappable: false) unless status.success?

        version = extract_version(out, err)
        return ok(name, [ path, version ].compact.join(" ")) unless required

        version_result(name, version, required, fix_command)
      end

      def version_result(name, actual, required, fix_command)
        if actual && Gem::Version.new(actual) >= Gem::Version.new(required)
          ok(name, actual)
        else
          Result.new(
            name: name,
            status: "version_too_old",
            detail: "#{name} #{actual || "unknown"} is older than required >= #{required}",
            fix_command: fix_command,
            bootstrappable: false
          )
        end
      end

      def ok(name, detail)
        Result.new(name: name, status: "ok", detail: detail, fix_command: nil, bootstrappable: false)
      end

      def missing(name, fix_command)
        Result.new(name: name, status: "missing", detail: "#{name} is not on PATH", fix_command: fix_command, bootstrappable: false)
      end

      def bootstrappable(name, detail)
        Result.new(name: name, status: "missing", detail: detail, fix_command: nil, bootstrappable: true)
      end

      def extract_version(*parts)
        parts.join(" ")[/\d+(?:\.\d+)+/]
      end

      def diagnostic(*parts)
        fallback = parts.pop
        parts.join("\n").lines.map(&:strip).find { |line| !line.empty? } || fallback
      end

      def managed_qmd
        File.join(Hive::Paths.data_home, "qmd", "bin", "qmd")
      end

      def which(name)
        return name if name.to_s.include?(File::SEPARATOR) && File.executable?(name)

        @path.split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def run_command(argv)
        @runner.call(argv)
      rescue Timeout::Error, SystemCallError => e
        [ "", e.message, FailureStatus.new ]
      end

      def default_run(argv)
        Timeout.timeout(10) { Open3.capture3(@env, *argv) }
      end

      def install_command(name)
        case platform
        when :macos
          package = name == "node" ? "node" : name
          "brew install #{package}"
        when :linux
          package = { "sqlite" => "sqlite3", "node" => "nodejs npm" }.fetch(name, name)
          "sudo apt install #{package}"
        else
          "install #{name}"
        end
      end

      def platform
        host_os = RbConfig::CONFIG["host_os"].to_s
        return :macos if host_os.include?("darwin")
        return :linux if host_os.include?("linux")

        :other
      end

      class FailureStatus
        def success?
          false
        end
      end
    end
  end
end
