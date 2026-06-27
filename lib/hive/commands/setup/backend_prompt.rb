require "hive/agent_profiles"
require "hive/config"

module Hive
  module Commands
    class Setup
      # Interactive prompt for `hive setup`: which agent backends to
      # persist globally (Claude / Codex / Pi). Mirrors Init::Prompts —
      # all collaborators are injectable so the flow is unit-testable
      # without real STDIN/STDOUT or the live AgentProfiles registry, and
      # a non-TTY input stream short-circuits #collect to the defaults
      # with a one-line summary on @summary_io.
      #
      # The class guarantees #collect always yields ≥1 backend: the
      # registry is filtered to GLOBAL_AGENT_BACKENDS at construction
      # (raising if nothing intersects), and the recommended defaults must
      # also intersect the registry (raising otherwise) so neither the
      # non-interactive path nor a blank-Enter answer can return [].
      class BackendPrompt
        class Aborted < StandardError; end

        BACKEND_ORDER = Hive::Config::GLOBAL_AGENT_BACKENDS
        DEFAULT_BACKENDS = Hive::Config::DEFAULT_GLOBAL_AGENTS

        def initialize(input: $stdin, output: $stderr, summary_io: $stdout, registered_agents: nil)
          @input = input
          @output = output
          @summary_io = summary_io
          registered = (registered_agents || Hive::Config.registered_agent_names)
          @backends = BACKEND_ORDER.select { |name| registered.include?(name) }

          raise ArgumentError, "registered_agents must include at least one setup backend" if @backends.empty?

          # Without a registered default, both the non-interactive path and
          # a blank-Enter answer would hand back [] (a selection the prompt
          # is supposed to never produce). Fail loudly at construction —
          # the analogue of Init::Prompts' "default not registered" guard.
          if default_backends.empty?
            raise ArgumentError,
                  "registered_agents must include at least one default backend (#{DEFAULT_BACKENDS.join(', ')})"
          end
        end

        def collect
          return non_interactive_defaults unless interactive?

          # Pure function of @backends; hoist once instead of recomputing
          # per listing row and per prompt iteration below.
          defaults = default_backends

          @output.puts "Select the agent backends Hive should set up globally."
          @output.puts "(Press Enter for Claude + Codex. Add Pi only if you use it.)"
          @output.puts ""
          @backends.each_with_index do |name, index|
            marker = defaults.include?(name) ? " [default]" : ""
            @output.puts "  #{index + 1}) #{name}#{marker}"
          end

          loop do
            @output.print "Backends [#{defaults.join(', ')}]: "
            @output.flush
            answer = read_line
            selection = answer.empty? ? defaults : resolve_selection(answer)
            return selection if selection

            @output.puts "  unknown backend selection #{answer.inspect}; use names or numbers from the list"
          end
        end

        def interactive?
          @input.respond_to?(:tty?) && @input.tty?
        end

        private

        def default_backends
          # Frozen to match the Config layer's "frozen array of frozen
          # strings on every path" contract — both collaborators produce
          # "a backend selection" and must agree on mutability. This is the
          # array #collect hands back on the non-interactive and blank-Enter
          # paths, so freezing here covers both return sites.
          DEFAULT_BACKENDS.select { |name| @backends.include?(name) }.freeze
        end

        def non_interactive_defaults
          selected = default_backends
          @summary_io.puts "hive setup: using default backends — #{selected.join(', ')}"
          selected
        end

        def resolve_selection(answer)
          selected = []
          answer.split(",").map(&:strip).reject(&:empty?).each do |token|
            name = resolve_token(token)
            return nil unless name

            selected << name
          end

          # Frozen to match the Config layer's frozen-array contract (see
          # #default_backends); this is #collect's third return site.
          selected = BACKEND_ORDER.select { |name| selected.include?(name) }.freeze
          selected.empty? ? nil : selected
        end

        def resolve_token(token)
          match = @backends.find { |name| name.casecmp(token).zero? }
          return match if match

          if token.match?(/\A\d+\z/)
            index = token.to_i
            return @backends[index - 1] if index >= 1 && index <= @backends.size
          end

          nil
        end

        def read_line
          line = @input.gets
          raise Aborted, "input stream closed (EOF)" if line.nil?

          line.chomp.strip
        end
      end
    end
  end
end
