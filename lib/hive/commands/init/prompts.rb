require "hive/agent_profiles"
require "hive/config"

module Hive
  module Commands
    class Init
      # Interactive first-run prompt flow for `hive init`. Asks the operator
      # which agents to use for planning / development / review and (if they
      # want) tweaks the per-stage budget+timeout sanity caps. On non-TTY
      # input streams (CI, pipes, test harnesses) `#collect` short-circuits
      # to the recommended defaults and emits a one-line summary so callers
      # see what was applied.
      #
      # All collaborators are injectable so the class is unit-testable
      # without touching real STDIN/STDOUT or the live AgentProfiles
      # registry. See plan 2026-05-04-001 / ADR-023.
      class Prompts
        # Raised when the operator declines to proceed: either by
        # answering `n` at the final confirmation OR by closing the input
        # stream mid-flow (Ctrl-D / EOF / disconnected pipe). Caught in
        # `Init#collect_prompt_answers`, which warns to stderr and exits
        # with `Hive::ExitCodes::USAGE` (64) — distinct from generic
        # crashes at exit 1, so a scripted caller can tell the two apart.
        class Aborted < StandardError; end

        DEFAULT_PLANNING_AGENT = "claude".freeze
        DEFAULT_DEVELOPMENT_AGENT = "codex".freeze

        # Reviewer entries shipped in templates/project_config.yml.erb. The
        # multi-select prompt offers these as the toggleable set; rendering
        # honours the user's subset. The order is the stable iteration
        # contract documented in wiki/commands/init.md (see "Stable-iteration-
        # order contract") — reordering is a breaking change for scripted
        # automation that uses index answers.
        DEFAULT_REVIEWER_NAMES = %w[
          claude-ce-code-review
          codex-ce-code-review
          pr-review-toolkit
        ].freeze

        # The 8 effective budget/timeout keys after dropping the deprecated
        # execute_review (5-review owns reviewer budgets per ADR-014).
        # Order is intentional: matches templates/project_config.yml.erb
        # render order, so a printed prompt list reads top-to-bottom in the
        # same shape as the resulting YAML.
        LIMIT_KEYS = %w[
          brainstorm
          plan
          execute_implementation
          pr
          review_ci
          review_triage
          review_fix
          review_browser
        ].freeze

        # Streams default to stderr for prompt UI (intro / menus / re-prompts /
        # confirmation) and stdout for the machine-parseable result line emitted
        # in non-TTY mode. This matches standard CLI discipline: a caller running
        # `summary=$(hive init)` captures only the result, not the menu choreography.
        # Tests inject `output: StringIO.new, summary_io: StringIO.new` to assert
        # both streams independently.
        def initialize(input: $stdin, output: $stderr, summary_io: $stdout,
                       registered_agents: nil)
          @input = input
          @output = output
          @summary_io = summary_io
          # registered_agents is a list of strings (agent profile names).
          # When not injected, ask the live registry. Tests inject a fixed
          # list so they don't depend on registration order.
          @registered_agents = (registered_agents || Hive::AgentProfiles.registered_names.map(&:to_s))

          # Construction-time guards: turn latent invariant violations
          # (empty registry, recommended-default not in the registry)
          # into loud ArgumentErrors at construction instead of an
          # infinite re-prompt loop or a downstream Config.load failure.
          raise ArgumentError, "registered_agents must be non-empty" if @registered_agents.empty?

          missing = [ DEFAULT_PLANNING_AGENT, DEFAULT_DEVELOPMENT_AGENT ] - @registered_agents
          unless missing.empty?
            raise ArgumentError,
                  "default agents not in registered_agents: #{missing.inspect} " \
                  "(registered: #{@registered_agents.inspect})"
          end
        end

        # Run the prompt flow (or short-circuit to defaults).
        # Returns the answers hash with shape:
        #   {
        #     "planning_agent"    => String,           # one of @registered_agents
        #     "development_agent" => String,           # one of @registered_agents
        #     "enabled_reviewers" => Array<String>,    # subset of DEFAULT_REVIEWER_NAMES
        #     "budgets"  => Hash<String, Integer>,     # 8 keys (LIMIT_KEYS)
        #     "timeouts" => Hash<String, Integer>      # 8 keys (LIMIT_KEYS)
        #   }
        # Raises Aborted when the user declines confirmation.
        def collect
          return non_interactive_defaults unless interactive?

          intro
          planning = prompt_agent("Planning agent (brainstorm + plan)", DEFAULT_PLANNING_AGENT)
          development = prompt_agent("Development agent (4-execute)", DEFAULT_DEVELOPMENT_AGENT)
          reviewers = prompt_reviewers
          budgets, timeouts = prompt_limits

          answers = {
            "planning_agent" => planning,
            "development_agent" => development,
            "enabled_reviewers" => reviewers,
            "budgets" => budgets,
            "timeouts" => timeouts
          }

          summarize(answers)
          confirm!
          answers
        end

        # Whether prompts will fire. Public so the caller can pre-flight-
        # check before opening the prompt; also matches the test contract
        # in plan U3 (R9 testability — agents not yet installed on the
        # machine still get listed if registered).
        def interactive?
          @input.respond_to?(:tty?) && @input.tty?
        end

        private

        def non_interactive_defaults
          answers = {
            "planning_agent" => DEFAULT_PLANNING_AGENT,
            "development_agent" => DEFAULT_DEVELOPMENT_AGENT,
            "enabled_reviewers" => DEFAULT_REVIEWER_NAMES.dup,
            "budgets" => default_budgets,
            "timeouts" => default_timeouts
          }
          # Goes to @summary_io (stdout by default) so a non-TTY caller's
          # `summary=$(hive init)` capture has a parseable single line.
          @summary_io.puts(
            "hive: using defaults — planning=#{DEFAULT_PLANNING_AGENT}, " \
            "dev=#{DEFAULT_DEVELOPMENT_AGENT}, " \
            "reviewers=all#{DEFAULT_REVIEWER_NAMES.size}, limits=defaults"
          )
          answers
        end

        def default_budgets
          # `fetch` rather than `[]`: if LIMIT_KEYS and Config::DEFAULTS["budget_usd"]
          # ever drift (a key added to one but not the other), surface as KeyError
          # at first run instead of silently rendering a YAML key with no value
          # (which YAML.safe_load parses to nil and validate_review_attempts!
          # accepts only for the four `review_*` paths it knows about).
          LIMIT_KEYS.each_with_object({}) { |k, h| h[k] = Hive::Config::DEFAULTS["budget_usd"].fetch(k) }
        end

        def default_timeouts
          LIMIT_KEYS.each_with_object({}) { |k, h| h[k] = Hive::Config::DEFAULTS["timeout_sec"].fetch(k) }
        end

        def intro
          @output.puts "Welcome to hive! Let's set up agents and limits for this project."
          @output.puts "(Press Enter to accept the [default] for any question.)"
          @output.puts ""
        end

        def prompt_agent(label, default)
          agent_menu = @registered_agents.each_with_index.map { |name, i| "#{i + 1}) #{name}" }.join("  ")
          @output.puts "Agents: #{agent_menu}"
          loop do
            @output.print "#{label} [#{default}]: "
            @output.flush
            answer = read_line
            return default if answer.empty?

            resolved = resolve_agent_choice(answer)
            return resolved if resolved

            @output.puts "  unknown agent #{answer.inspect}; pick a name (#{@registered_agents.join(', ')}) " \
                         "or 1..#{@registered_agents.size}"
          end
        end

        def resolve_agent_choice(answer)
          if answer =~ /\A\d+\z/
            idx = answer.to_i
            return @registered_agents[idx - 1] if idx >= 1 && idx <= @registered_agents.size

            return nil
          end
          @registered_agents.find { |a| a.casecmp(answer).zero? }
        end

        def prompt_reviewers
          @output.puts ""
          @output.puts "Review agents — pick numbers/names, comma-separated, blank = all enabled:"
          DEFAULT_REVIEWER_NAMES.each_with_index { |name, i| @output.puts "  #{i + 1}) #{name}" }
          loop do
            @output.print "  > "
            @output.flush
            answer = read_line
            return DEFAULT_REVIEWER_NAMES.dup if answer.empty?

            resolved = resolve_reviewer_tokens(answer)
            return resolved if resolved.is_a?(Array)

            # resolved is an error message string
            @output.puts "  #{resolved}"
          end
        end

        def resolve_reviewer_tokens(answer)
          tokens = answer.split(",").map(&:strip).reject(&:empty?)
          # Comma-only input (e.g. ",", ",,", "  ,  ") drops to zero tokens
          # after the reject. Treating that as "user picked zero reviewers"
          # would render `reviewers:` as a YAML key with no value, which
          # YAML.safe_load parses to nil, which validate_reviewers! then
          # rejects on the next `hive run` — silent corruption between
          # init and the first hive run. Re-prompt explicitly: blank input
          # already maps to "all enabled" via the empty?-early-return at
          # prompt_reviewers; non-blank input that resolves to zero tokens
          # is a typo, not a valid selection.
          return "input had no reviewer tokens; type a name/index list, or blank for all" if tokens.empty?

          out = []
          tokens.each do |token|
            if token =~ /\A\d+\z/
              idx = token.to_i
              return "invalid index #{token}; pick 1..#{DEFAULT_REVIEWER_NAMES.size}" unless idx.between?(1, DEFAULT_REVIEWER_NAMES.size)

              out << DEFAULT_REVIEWER_NAMES[idx - 1]
            else
              # Case-insensitive match for parity with prompt_agent's
              # resolve_agent_choice. Closes ce-code-review F9.
              match = DEFAULT_REVIEWER_NAMES.find { |r| r.casecmp(token).zero? }
              return "unknown reviewer #{token.inspect}; valid names: #{DEFAULT_REVIEWER_NAMES.join(', ')}" unless match

              out << match
            end
          end
          out.uniq
        end

        def prompt_limits
          @output.puts ""
          @output.puts "Limits for each stage / review role. Format: <budget_usd>,<timeout_sec> (blank = defaults)."
          @output.puts "Defaults are generous sanity caps — most tasks finish well within them."

          budgets = {}
          timeouts = {}
          width = LIMIT_KEYS.map(&:length).max

          LIMIT_KEYS.each do |key|
            default_b = Hive::Config::DEFAULTS["budget_usd"][key]
            default_t = Hive::Config::DEFAULTS["timeout_sec"][key]
            b, t = prompt_one_limit(key, default_b, default_t, width)
            budgets[key] = b
            timeouts[key] = t
          end

          [ budgets, timeouts ]
        end

        def prompt_one_limit(key, default_b, default_t, width)
          loop do
            @output.print(format("  %-#{width}s [%d,%d]: ", key, default_b, default_t))
            @output.flush
            answer = read_line
            return [ default_b, default_t ] if answer.empty?

            parts = answer.split(",", -1).map(&:strip)
            unless parts.size == 2
              @output.puts "  expected <budget>,<timeout>; got #{answer.inspect}"
              next
            end

            b_str, t_str = parts
            b = b_str.empty? ? default_b : parse_positive_int(b_str)
            t = t_str.empty? ? default_t : parse_positive_int(t_str)
            if b.nil? || t.nil?
              @output.puts "  budget and timeout must be positive integers"
              next
            end

            return [ b, t ]
          end
        end

        def parse_positive_int(str)
          return nil unless /\A\d+\z/.match?(str)

          v = str.to_i
          v.positive? ? v : nil
        end

        def summarize(answers)
          @output.puts ""
          @output.puts "Summary:"
          @output.puts "  planning_agent    = #{answers['planning_agent']}"
          @output.puts "  development_agent = #{answers['development_agent']}"
          @output.puts "  review_agents     = [#{answers['enabled_reviewers'].join(', ')}]"
          @output.puts "  limits            = #{summarize_limits(answers)}"
        end

        def summarize_limits(answers)
          changed = LIMIT_KEYS.reject do |k|
            answers["budgets"][k] == Hive::Config::DEFAULTS["budget_usd"][k] &&
              answers["timeouts"][k] == Hive::Config::DEFAULTS["timeout_sec"][k]
          end
          return "all defaults" if changed.empty?

          changed.map { |k| "#{k}=#{answers['budgets'][k]}/#{answers['timeouts'][k]}s" }.join(", ")
        end

        def confirm!
          loop do
            @output.print "OK to proceed? [Y/n]: "
            @output.flush
            answer = read_line.downcase
            return if answer.empty? || answer == "y" || answer == "yes"
            raise Aborted, "user aborted init prompts" if answer == "n" || answer == "no"

            @output.puts "  please answer y or n"
          end
        end

        def read_line
          line = @input.gets
          # Distinguish nil (EOF — closed pipe / Ctrl-D / terminal disconnect)
          # from "" (blank line / Enter for default). Treating EOF as a blank
          # answer would silently confirm init at the final prompt, writing
          # disk state with whatever was already collected. Bubble Aborted
          # so Init#call's rescue path catches it cleanly.
          raise Aborted, "input stream closed (EOF)" if line.nil?

          line.chomp.strip
        end
      end
    end
  end
end
