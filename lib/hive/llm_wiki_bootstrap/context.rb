require "json"
require "fileutils"
require "shellwords"

module Hive
  module LlmWikiBootstrap
    module Context
      module_function

      def install(project_root)
        ensure_context_files(project_root)
        ensure_claude_session_start_hook(project_root)
      end

      def ensure_context_files(project_root)
        block = context_block
        %w[CLAUDE.md AGENTS.md].each do |filename|
          path = File.join(project_root, filename)
          Hive::LlmWikiBootstrap.replace_block(path, MANAGED_BEGIN, MANAGED_END, block)
        end
      end

      def context_block
        <<~MARKDOWN.strip
          #{MANAGED_BEGIN}
          ## LLM Wiki

          This project has a managed LLM wiki. Treat it as required project context.

          - Project wiki: `wiki/`
          - Index: `wiki/index.md`
          - Change log: `wiki/log.md`
          - Known gaps: `wiki/gaps.md`
          - Raw notes: `raw/notes/`

          Before planning, implementation, review, or debugging:

          1. Read `wiki/index.md`.
          2. Search the project wiki with `qmd search "<topic>"` when QMD is available, or `rg "<topic>" wiki/` otherwise.
          3. Use `qmd query "<topic>"` only when local model generation is acceptable; if it hangs or errors, fall back to `qmd search` or `rg`.
          4. If `.llm-wiki/config.json` has `main_wiki_path`, search that main wiki too.
          5. Use `/llm-wiki:wiki-plan` for planning-stage work when available.

          When code behavior, architecture, commands, or dependencies change:

          1. Update affected wiki pages.
          2. Append `wiki/log.md`.
          3. Record uncertainty in `wiki/gaps.md`.

          Headless wiki refresh is managed by `.llm-wiki/refresh-wiki.sh` and
          `.llm-wiki/post-commit-refresh.sh`. Codex is the configured headless wiki agent.
          #{MANAGED_END}
        MARKDOWN
      end

      def ensure_claude_session_start_hook(project_root)
        settings_path = File.join(project_root, ".claude", "settings.json")
        FileUtils.mkdir_p(File.dirname(settings_path))
        settings = Hive::LlmWikiBootstrap.read_json_hash(settings_path)
        hooks = settings["hooks"].is_a?(Hash) ? settings["hooks"] : {}
        session_hooks = Array(hooks["SessionStart"]).filter_map { |entry| cleaned_session_hook(entry) }

        session_hooks << {
          "matcher" => "*",
          "hooks" => [
            {
              "type" => "command",
              "command" => session_start_command
            }
          ]
        }

        hooks["SessionStart"] = session_hooks
        settings["hooks"] = hooks
        Hive::LlmWikiBootstrap.write_file(settings_path, "#{JSON.pretty_generate(settings)}\n")
      end

      def cleaned_session_hook(entry)
        return nil unless entry.is_a?(Hash)

        hook_entries = Array(entry["hooks"]).reject do |hook|
          hook.is_a?(Hash) && hook["command"].to_s.include?(SESSION_HOOK_MARKER)
        end
        return nil if hook_entries.empty? && entry["matcher"].to_s.empty?

        entry.merge("hooks" => hook_entries)
      end

      def session_start_command
        script = <<~SH.strip
          if [ -f wiki/index.md ]; then
            printf '\\n[llm-wiki index]\\n'
            sed -n '1,160p' wiki/index.md
          fi
          if [ -f wiki/log.md ]; then
            printf '\\n[llm-wiki recent log]\\n'
            sed -n '1,80p' wiki/log.md
          fi
        SH
        "bash -lc #{Shellwords.escape(script)} # #{SESSION_HOOK_MARKER}"
      end
    end
  end
end
