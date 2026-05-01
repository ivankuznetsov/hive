module Hive
  module E2E
    # Per-scenario mutable state shared across step handlers. Owns the slug,
    # the registered-projects map, and the most recent pre-keystroke pane
    # snapshot used by ArtifactCapture (F#18).
    #
    # The slug has a deliberate `||=`-style setter (`slug_default!`) AND an
    # explicit override (`slug=`) — latter complains if the slug was already
    # pinned, so a second seed_state with a contradictory slug surfaces as a
    # loud error instead of silently overwriting.
    class ScenarioContext
      class SlugConflict < StandardError; end

      attr_reader :sandbox_dir, :run_home, :run_id, :projects, :sandbox
      attr_accessor :pre_keystroke_pane, :last_json, :harness_state

      def initialize(sandbox:, run_home:, run_id:)
        @sandbox = sandbox
        @sandbox_dir = sandbox.sandbox_dir
        @run_home = run_home
        @run_id = run_id
        @projects = { File.basename(@sandbox_dir) => @sandbox_dir }
        @slug = nil
        @pre_keystroke_pane = nil
        @last_json = nil
        @harness_state = {}
      end

      def slug
        @slug
      end

      # Sets the slug if not already pinned; no-op if it already matches.
      # Raises if a conflicting slug arrives — that's almost always a scenario
      # authoring bug worth surfacing.
      def slug=(value)
        return if value.nil? || value.to_s.empty?
        @slug ||= value.to_s
        return if @slug == value.to_s

        raise SlugConflict, "scenario slug already pinned to #{@slug.inspect}; refusing reset to #{value.inspect}"
      end

      # Convenience for "set the slug only if blank" — used by step handlers
      # that derive a slug from the sandbox state (current_slug discovery).
      def slug_default!(value)
        return if @slug
        return if value.nil? || value.to_s.empty?

        @slug = value.to_s
      end

      def register_project(name, path)
        @projects[name] = path
      end

      def project_dir(name)
        return @sandbox_dir if name.nil?

        @projects.fetch(name)
      end

      # Hash form fed into StringExpander so callers don't have to repackage
      # the same fields on every call.
      def expander_context(slug_resolver: nil)
        {
          sandbox_dir: @sandbox_dir,
          run_home: @run_home,
          run_id: @run_id,
          slug: @slug,
          slug_resolver: slug_resolver
        }
      end
    end
  end
end
