module Hive
  module LlmWikiBootstrap
    module Scripts
      module_function

      def refresh_wiki
        File.read(template_path("refresh-wiki.sh"))
      end

      # The scheduled drain wrapper, transactional post-commit refresh, and
      # shared log compiler are
      # maintained as real, tested files under templates/llm-wiki/ (shared
      # verbatim with the llm-wiki plugin and with Hive::WikiLog) rather than
      # embedded heredocs. The refresh runner queues source commits and writes
      # only in a disposable llm-wiki/refresh worktree; bootstrap copies all
      # scripts into the project's .llm-wiki/.
      def post_commit_refresh
        File.read(template_path("post-commit-refresh.sh"))
      end

      def compile_log
        File.read(template_path("compile-log.sh"))
      end

      def template_path(name)
        File.expand_path("../../../templates/llm-wiki/#{name}", __dir__)
      end
    end
  end
end
