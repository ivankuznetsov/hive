module Hive
  module LlmWikiBootstrap
    module Pages
      module_function

      def index
        <<~MARKDOWN
          # Project Wiki

          This wiki is maintained for coding agents. Read it before planning,
          implementation, review, or debugging work, and update it when project facts
          change.

          ## Core Pages

          - [[architecture]] - system shape, runtime flows, and important modules.
          - [[decisions]] - durable design decisions and tradeoffs.
          - [[dependencies]] - runtime, development, and service dependencies.
          - [[gaps]] - missing, uncertain, or stale wiki coverage.

          ## Update Protocol

          - Update affected pages when code behavior, architecture, commands, or
            dependencies change.
          - Add a new `wiki/log.d/<timestamp>-<slug>.md` fragment after every wiki update,
            but do not edit the compiled `wiki/log.md` in feature PRs.
          - Record uncertainty in [[gaps]] instead of inventing facts.
        MARKDOWN
      end

      def log
        <<~MARKDOWN
          # Wiki Changelog

          Append-only log of meaningful wiki updates. New work is added through
          `wiki/log.d/*.md` fragments and compiled with `hive wiki compile-log`
          after merge or when a local checkout needs refreshed aggregate output.
        MARKDOWN
      end

      def gaps
        <<~MARKDOWN
          # Wiki Gaps

          | Area | Gap | Notes |
          |------|-----|-------|
        MARKDOWN
      end

      def architecture
        <<~MARKDOWN
          # Architecture

          Initial placeholder. Replace with the project's current structure, key flows,
          and module responsibilities.
        MARKDOWN
      end

      def decisions
        <<~MARKDOWN
          # Decisions

          Record durable technical decisions here with date, context, decision, and
          consequence.
        MARKDOWN
      end

      def dependencies
        <<~MARKDOWN
          # Dependencies

          Initial placeholder. Summarize runtime dependencies, development tools, and
          external services when they are confirmed.
        MARKDOWN
      end
    end
  end
end
