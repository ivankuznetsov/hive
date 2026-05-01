module Hive
  module E2E
    # Expands `{placeholder}` tokens in scenario strings against a context hash.
    # Pure function over its inputs — no I/O, no instance state. Lives in its
    # own file so step kinds (cli, json_assert, seed_state, …) reuse exactly
    # one expander rather than each carrying its own `gsub` chain.
    #
    # Recognised tokens:
    #   {sandbox}          → context[:sandbox_dir]
    #   {run_home}         → context[:run_home]
    #   {project}          → File.basename(context[:sandbox_dir])
    #   {slug}             → context[:slug] (resolved via :slug_resolver if blank)
    #   {run_id}           → context[:run_id]
    #   {task_dir:<stage>} → "<sandbox>/.hive-state/stages/<stage>/<slug>"
    #
    # `:slug_resolver` is an optional callable that returns a slug when the
    # caller can't pre-fill one (e.g. an early step that hasn't seeded yet).
    # Errors raised by the resolver are swallowed and the empty string is
    # substituted, matching the prior in-class behaviour.
    module StringExpander
      module_function

      def expand(value, context)
        case value
        when Hash then value.transform_values { |v| expand(v, context) }
        when Array then value.map { |v| expand(v, context) }
        when String then expand_string(value, context)
        else value
        end
      end

      def expand_string(value, context)
        sandbox_dir = context.fetch(:sandbox_dir)
        run_home = context.fetch(:run_home)
        slug_value = context[:slug] || resolve_slug(context)
        value
          .gsub("{sandbox}", sandbox_dir)
          .gsub("{run_home}", run_home)
          .gsub("{project}", File.basename(sandbox_dir))
          .gsub("{slug}", slug_value.to_s)
          .gsub("{run_id}", context[:run_id].to_s)
          .gsub(/\{task_dir:([^}]+)\}/) { File.join(sandbox_dir, ".hive-state", "stages", Regexp.last_match(1), slug_value.to_s) }
      end

      def resolve_slug(context)
        resolver = context[:slug_resolver]
        return "" unless resolver

        resolver.call.to_s
      rescue StandardError
        ""
      end
    end
  end
end
