require "json"

module AgentCliRuntime
  class CLI
    USAGE = <<~TEXT.freeze
      Usage:
        agent-runtime probe PROVIDER [--json]
        agent-runtime probe --all [--json]
        agent-runtime --version

      Providers: #{Profiles.names.join(', ')}
    TEXT

    class << self
      def run(argv, out: $stdout, err: $stderr, home: nil, env: ENV)
        arguments = argv.dup
        if arguments == [ "--version" ]
          out.puts VERSION
          return 0
        end
        return usage_error(err) unless arguments.shift == "probe"

        json = arguments.delete("--json")
        all = arguments.delete("--all")
        return usage_error(err) if arguments.any? { |arg| arg.start_with?("-") }
        return usage_error(err) if all && !arguments.empty?
        return usage_error(err) unless all || arguments.length == 1

        results =
          if all
            Probe.all(home: home, env: env)
          else
            [ Probe.call(Profiles.fetch(arguments.fetch(0)), home: home, env: env) ]
          end
        json ? render_json(results, out) : render_text(results, out)
        results.all?(&:ready) ? 0 : 1
      rescue UnknownProvider => e
        err.puts e.message
        err.print USAGE
        64
      end

      private

      def usage_error(err)
        err.print USAGE
        64
      end

      def render_json(results, out)
        payload = {
          schema_version: 1,
          probes: results.map { |result| probe_hash(result) }
        }
        out.puts JSON.generate(payload)
      end

      def render_text(results, out)
        results.each do |result|
          state = result.ready ? "ready" : "unavailable"
          version = result.version || "unknown"
          auth = result.auth_configuration.status
          out.puts(
            "#{result.provider}: #{state} " \
            "(installed=#{result.installed} version=#{version} " \
            "auth_configuration=#{auth})"
          )
          out.puts "  #{result.diagnostic}" if result.diagnostic
        end
      end

      def probe_hash(result)
        {
          provider: result.provider.to_s,
          ready: result.ready,
          installed: result.installed,
          executable: Redactor.diagnostic(result.executable, bytes: 256),
          version: result.version,
          minimum_version: result.minimum_version,
          auth_configuration: {
            status: result.auth_configuration.status.to_s,
            source: Redactor.diagnostic(
              result.auth_configuration.source,
              bytes: 256
            )
          },
          capabilities: result.capability_evidence.map do |evidence|
            {
              capability: evidence.capability.to_s,
              supported: evidence.supported
            }
          end,
          diagnostic: result.diagnostic
        }
      end
    end
  end
end
