module Hive
  module LlmWikiBootstrap
    module Scripts
      module_function

      # Shared bash QMD helpers interpolated verbatim into both generated
      # scripts. Defined with a non-interpolating heredoc so bash `${...}`
      # and `$(...)` are preserved literally.
      QMD_BASH_HELPERS = <<~'BASH'
        configure_qmd_environment() {
          local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
          if ! mkdir -p "$cache_home/qmd" 2>/dev/null || ! touch "$cache_home/qmd/.write-test" 2>/dev/null; then
            export XDG_CACHE_HOME="$project_root/.llm-wiki/qmd-cache"
            mkdir -p "$XDG_CACHE_HOME/qmd"
            export LLM_WIKI_QMD_CACHE_DIR="$XDG_CACHE_HOME/qmd"
          else
            rm -f "$cache_home/qmd/.write-test"
            export LLM_WIKI_QMD_CACHE_DIR="$cache_home/qmd"
          fi
        }

        configure_git_tool_environment() {
          GIT_ENV_UNSET_ARGS=()
          local name
          while IFS= read -r name; do
            [ -n "$name" ] && GIT_ENV_UNSET_ARGS+=("-u" "$name")
          done < <(git rev-parse --local-env-vars 2>/dev/null || true)
        }

        run_without_git_env() {
          env "${GIT_ENV_UNSET_ARGS[@]+"${GIT_ENV_UNSET_ARGS[@]}"}" "$@"
        }

        configure_qmd_environment
        configure_git_tool_environment

        find_qmd() {
          if [ -n "${HIVE_QMD_BIN:-}" ] && [ -x "$HIVE_QMD_BIN" ]; then
            printf '%s\n' "$HIVE_QMD_BIN"
            return 0
          fi

          if command -v qmd >/dev/null 2>&1; then
            command -v qmd
            return 0
          fi

          local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
          local candidate
          for candidate in "$data_home/hive/qmd/bin/qmd" "$HOME/.local/share/hive/qmd/bin/qmd"; do
            if [ -x "$candidate" ]; then
              printf '%s\n' "$candidate"
              return 0
            fi
          done

          local prefix_file="$data_home/hive/install-prefix"
          if [ -r "$prefix_file" ]; then
            local prefix
            prefix="$(sed -n '1p' "$prefix_file")"
            candidate="${prefix%/}/hive/qmd/bin/qmd"
            if [ -x "$candidate" ]; then
              printf '%s\n' "$candidate"
              return 0
            fi
          fi

          return 1
        }

        qmd_available() {
          find_qmd >/dev/null 2>&1
        }

        # run_qmd never aborts the caller: a missing qmd is a silent no-op,
        # and a timeout (exit 124) or other failure is reported to stderr
        # (captured by callers that log stderr) instead of propagating under
        # `set -e`, so callers need no trailing `|| true`.
        run_qmd() {
          local qmd_bin rc
          qmd_bin="$(find_qmd)" || return 0

          if command -v timeout >/dev/null 2>&1; then
            run_without_git_env timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" "$qmd_bin" "$@" && return 0 || rc=$?
          else
            run_without_git_env "$qmd_bin" "$@" && return 0 || rc=$?
          fi

          if [ "$rc" -eq 124 ]; then
            echo "qmd $1 timed out after ${LLM_WIKI_QMD_TIMEOUT:-900}s; wiki index may be stale" >&2
          else
            echo "qmd $1 failed (exit $rc); wiki index may be stale" >&2
          fi
          return 0
        }
      BASH

      def refresh_wiki
        <<~BASH
          #!/usr/bin/env bash
          set -euo pipefail

          project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
          cd "$project_root"

          #{QMD_BASH_HELPERS}
          run_codex() {
            if command -v timeout >/dev/null 2>&1; then
              run_without_git_env timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt"
            else
              run_without_git_env codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt"
            fi
          }

          if qmd_available; then
            run_qmd update >/dev/null 2>&1
          fi

          prompt="$(cat <<'PROMPT'
          Refresh this project's LLM wiki.
          Read .llm-wiki/config.json, AGENTS.md, CLAUDE.md, wiki/index.md, wiki/gaps.md,
          and recent wiki/log.md entries first.
          If .llm-wiki/config.json contains main_wiki_path, search that exact path before
          changing project pages.
          Also search default main cross-project wiki paths when they exist:
          ~/wikis/master/wiki/, ~/wikis/main/wiki/, ../wikis/master/wiki/, and
          ../wikis/main/wiki/.
          Inspect recent git history and changed source files.
          Update stale wiki pages, update wiki/index.md when page coverage changes, append
          wiki/log.md, and record uncertainty in wiki/gaps.md.
          Do not run qmd update or qmd embed yourself; the wrapper script runs bounded qmd
          maintenance after this Codex refresh finishes.
          Do not invent facts.
          PROMPT
          )"

          codex_status=0
          run_codex || codex_status=$?

          run_qmd update >/dev/null 2>&1
          run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 >/dev/null 2>&1

          exit "$codex_status"
        BASH
      end

      def post_commit_refresh(project_name)
        <<~BASH
          #!/usr/bin/env bash
          set -euo pipefail

          project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
          cd "$project_root"

          #{QMD_BASH_HELPERS}
          log_file="$project_root/.llm-wiki/post-commit-refresh.log"
          lock_dir="$project_root/.llm-wiki/post-commit-refresh.lock"
          changed_files="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)"
          ran_refresh=0

          [ -n "$changed_files" ] || exit 0

          if ! mkdir "$lock_dir" 2>/dev/null; then
            exit 0
          fi
          trap 'rmdir "$lock_dir"' EXIT

          matches() {
            printf '%s\\n' "$changed_files" | grep -Eq "$1"
          }

          run_refresh() {
            local prompt="$1"
            ran_refresh=1
            if command -v timeout >/dev/null 2>&1; then
              run_without_git_env timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt" >>"$log_file" 2>&1 || true
            else
              run_without_git_env codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt" >>"$log_file" 2>&1 || true
            fi
          }

          if matches '(^|/)(schema\\.rb|structure\\.sql|db/migrate/|migrations/|models/|entities/|prisma/schema\\.prisma)'; then
            run_refresh "$(cat <<'PROMPT'
          Refresh this project's LLM wiki data-model coverage after a commit touched schema,
          migration, model, or entity files. Read AGENTS.md, wiki/index.md,
          wiki/architecture.md, wiki/dependencies.md, wiki/gaps.md, and recent wiki/log.md
          entries first. Inspect the committed diff and relevant source files. Update affected
          wiki pages, update wiki/index.md if page coverage changes, append wiki/log.md, and
          record uncertainty in wiki/gaps.md. Do not run qmd update or qmd embed yourself; the
          post-commit wrapper runs bounded qmd maintenance after refreshes finish. Do not
          invent facts.
          PROMPT
          )"
          fi

          if matches '(^|/)(routes|controllers|handlers|resolvers|src/commands/|lib/.*commands|bin/|README\\.md)'; then
            run_refresh "$(cat <<'PROMPT'
          Refresh this project's LLM wiki command and API surface coverage after a commit
          touched routes, handlers, commands, executable entrypoints, or README content. Read
          AGENTS.md, wiki/index.md, wiki/architecture.md, wiki/decisions.md, wiki/gaps.md,
          and recent wiki/log.md entries first. Inspect the committed diff and relevant source
          files. Update affected wiki pages, update wiki/index.md if page coverage changes,
          append wiki/log.md, and record uncertainty in wiki/gaps.md. Do not run qmd update or
          qmd embed yourself; the post-commit wrapper runs bounded qmd maintenance after
          refreshes finish. Do not invent facts.
          PROMPT
          )"
          fi

          if matches '(^|/)(Gemfile|Gemfile\\.lock|package\\.json|package-lock\\.json|go\\.mod|go\\.sum|Cargo\\.toml|Cargo\\.lock|requirements\\.txt|pyproject\\.toml|poetry\\.lock|composer\\.json|composer\\.lock)$'; then
            run_refresh "$(cat <<'PROMPT'
          Refresh this project's LLM wiki dependency coverage after a commit touched dependency
          files. Read AGENTS.md, wiki/index.md, wiki/dependencies.md, wiki/gaps.md, and recent
          wiki/log.md entries first. Inspect the committed diff and dependency files. Update
          wiki/dependencies.md and related pages if facts changed, update wiki/index.md if page
          coverage changes, append wiki/log.md, and record uncertainty in wiki/gaps.md. Do not
          run qmd update or qmd embed yourself; the post-commit wrapper runs bounded qmd
          maintenance after refreshes finish. Do not
          invent facts.
          PROMPT
          )"
          fi

          if matches '(^|/)(docs/|wiki/|raw/notes/|plans/|todos/)|(^|/)(CHANGELOG\\.md|AGENTS\\.md|CLAUDE\\.md)$'; then
            run_refresh "$(cat <<'PROMPT'
          Refresh this project's LLM wiki planning and documentation coverage after a commit
          touched docs, plans, notes, context files, or the wiki itself. Read AGENTS.md,
          wiki/index.md, wiki/decisions.md, wiki/gaps.md, and recent wiki/log.md entries first.
          Inspect the committed diff and relevant source files. Update stale pages, update
          wiki/index.md if page coverage changes, append wiki/log.md, and record uncertainty in
          wiki/gaps.md. Do not run qmd update or qmd embed yourself; the post-commit wrapper
          runs bounded qmd maintenance after refreshes finish. Do not invent facts.
          PROMPT
          )"
          fi

          if [ "$ran_refresh" -eq 1 ]; then
            if qmd_available; then
              run_qmd update >>"$log_file" 2>&1
              run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 >>"$log_file" 2>&1
            fi

            for sync_dir in "$HOME/wikis/.sync-needed" "$(dirname "$project_root")/wikis/.sync-needed"; do
              if [ -d "$(dirname "$sync_dir")" ]; then
                mkdir -p "$sync_dir"
                touch "$sync_dir/#{project_name}"
              fi
            done
          fi
        BASH
      end
    end
  end
end
