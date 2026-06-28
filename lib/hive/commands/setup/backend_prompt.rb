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
      # The class guarantees #collect returns ≥1 backend whenever it
      # returns a selection: the registry is filtered to
      # GLOBAL_AGENT_BACKENDS at construction (raising if nothing
      # intersects), and the recommended defaults must also intersect the
      # registry (raising otherwise) so neither the non-interactive path
      # nor a blank-Enter answer can return []. The one path that does NOT
      # return a selection is an interactive EOF / closed input stream,
      # which raises Aborted.
      class BackendPrompt
        # Raised when an interactive #collect hits EOF (Ctrl-D / closed
        # pipe) before a selection is made. NOTE: a DISTINCT class from
        # Init::Prompts::Aborted — the two share no ancestor beyond
        # StandardError, so the deferred U2 consumer must rescue
        # Setup::BackendPrompt::Aborted specifically (or introduce a shared
        # Hive::Commands::PromptAborted base) rather than assuming one
        # rescue clause catches both prompts' aborts.
        class Aborted < StandardError; end

        BACKEND_ORDER = Hive::Config::GLOBAL_AGENT_BACKENDS
        DEFAULT_BACKENDS = Hive::Config::DEFAULT_GLOBAL_AGENTS

        def initialize(input: $stdin, output: $stderr, summary_io: $stdout, registered_agents: nil)
          @input = input
          @output = output
          @summary_io = summary_io
          # Normalize to strings: an injected registry may pass the
          # AgentProfiles registry's native symbol names, which would never
          # match the String BACKEND_ORDER entries under `&`.
          registered = (registered_agents || Hive::Config.registered_agent_names).map(&:to_s)
          @backends = BACKEND_ORDER & registered

          raise ArgumentError, "registered_agents must include at least one setup backend" if @backends.empty?

          # Computed once at construction: every later path (#collect,
          # #non_interactive_defaults, and the guard below) reuses the same
          # frozen default selection instead of recomputing it.
          @default_backends = (DEFAULT_BACKENDS & @backends).freeze

          # Without a registered default, both the non-interactive path and
          # a blank-Enter answer would hand back [] (a selection the prompt
          # is supposed to never produce). Fail loudly at construction. This
          # is the analogue of Init::Prompts' "default not registered"
          # guard, but with a weaker bar: Init requires ALL its recommended
          # agents to be registered, whereas here ANY one default suffices.
          if @default_backends.empty?
            raise ArgumentError,
                  "registered_agents must include at least one default backend (#{DEFAULT_BACKENDS.join(', ')})"
          end
        end

        def collect
          return non_interactive_defaults unless interactive?

          # Memoized frozen default selection; bind locally for the listing
          # markers and the prompt label below.
          defaults = default_backends

          @output.puts "Select the agent backends Hive should set up globally " \
                       "(comma-separated names or numbers)."
          @output.puts "(Press Enter for the recommended defaults: #{defaults.join(', ')}.)"
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

            @output.puts "  unknown backend selection #{answer.inspect}; " \
                         "pick #{@backends.join(', ')} or 1..#{@backends.size}"
          end
        end

        def interactive?
          return false unless @input.respond_to?(:tty?)

          @input.tty?
        rescue IOError
          # A closed real IO answers respond_to?(:tty?) with true but raises
          # IOError on #tty?; degrade to the non-interactive defaults path
          # (hive setup under a closed stdin: daemon / CI) instead of
          # escaping #collect with an IOError.
          false
        end

        private

        # The frozen default selection, computed once at construction (see
        # #initialize). Frozen to match the Config layer's frozen-selection
        # contract — both collaborators produce "a backend selection" and
        # must agree on mutability. This is the array #collect hands back on
        # the non-interactive and blank-Enter paths.
        def default_backends
          @default_backends
        end

        def non_interactive_defaults
          selected = default_backends
          @summary_io.puts "hive: using default backends — #{selected.join(', ')}"
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
          selected = (BACKEND_ORDER & selected).freeze
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
