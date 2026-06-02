require "fileutils"
require "json"

require "hive/llm_wiki_bootstrap/context"
require "hive/llm_wiki_bootstrap/pages"
require "hive/llm_wiki_bootstrap/scheduler"
require "hive/llm_wiki_bootstrap/scripts"

module Hive
  module LlmWikiBootstrap
    HEADLESS_AGENT = "codex".freeze
    CONTEXT_AGENTS = %w[claude codex pi].freeze

    MANAGED_BEGIN = "<!-- BEGIN LLM WIKI -->".freeze
    MANAGED_END = "<!-- END LLM WIKI -->".freeze
    POST_COMMIT_BEGIN = "# BEGIN LLM WIKI POST-COMMIT".freeze
    POST_COMMIT_END = "# END LLM WIKI POST-COMMIT".freeze
    SESSION_HOOK_MARKER = "LLM WIKI SESSION START".freeze

    module_function

    def install!(project_root, post_commit_hook: true, scheduler: true)
      project_root = File.expand_path(project_root)
      FileUtils.mkdir_p(File.join(project_root, ".llm-wiki"))

      ensure_config(project_root)
      ensure_project_wiki(project_root)
      Context.install(project_root)
      ensure_refresh_scripts(project_root)
      ensure_post_commit_hook(project_root) if post_commit_hook
      Scheduler.install(project_root) if scheduler
    end

    def install_runtime_hooks!(project_root)
      project_root = File.expand_path(project_root)
      ensure_post_commit_hook(project_root)
      Scheduler.install(project_root)
    end

    def ensure_config(project_root)
      path = File.join(project_root, ".llm-wiki", "config.json")
      payload = read_json_hash(path).merge(
        "headless_agent" => HEADLESS_AGENT,
        "context_agents" => CONTEXT_AGENTS,
        "created_by" => "hive"
      )
      main_wiki_path = payload["main_wiki_path"] || detect_main_wiki_path(project_root)
      if main_wiki_path
        payload["main_wiki_path"] = main_wiki_path
      else
        payload.delete("main_wiki_path")
      end

      write_file(path, "#{JSON.pretty_generate(payload)}\n")
    end

    def read_json_hash(path)
      return {} unless File.exist?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def detect_main_wiki_path(project_root)
      candidates = [
        File.expand_path("~/wikis/master/wiki"),
        File.expand_path("~/wikis/main/wiki"),
        File.expand_path("../wikis/master/wiki", project_root),
        File.expand_path("../wikis/main/wiki", project_root)
      ]
      candidates.find { |path| File.directory?(path) }
    end

    def ensure_project_wiki(project_root)
      FileUtils.mkdir_p(File.join(project_root, "wiki"))
      FileUtils.mkdir_p(File.join(project_root, "raw", "notes"))
      write_once(File.join(project_root, "raw", "notes", ".gitkeep"), "")
      write_once(File.join(project_root, "wiki", "index.md"), Pages.index)
      write_once(File.join(project_root, "wiki", "log.md"), Pages.log)
      write_once(File.join(project_root, "wiki", "gaps.md"), Pages.gaps)
      write_once(File.join(project_root, "wiki", "architecture.md"), Pages.architecture)
      write_once(File.join(project_root, "wiki", "decisions.md"), Pages.decisions)
      write_once(File.join(project_root, "wiki", "dependencies.md"), Pages.dependencies)
    end

    def write_once(path, content)
      return if File.exist?(path)

      write_file(path, content)
    end

    def ensure_refresh_scripts(project_root)
      llm_wiki_dir = File.join(project_root, ".llm-wiki")
      refresh_path = File.join(llm_wiki_dir, "refresh-wiki.sh")
      post_commit_path = File.join(llm_wiki_dir, "post-commit-refresh.sh")

      write_file(refresh_path, Scripts.refresh_wiki)
      write_file(post_commit_path, Scripts.post_commit_refresh(File.basename(project_root)))
      File.chmod(0o755, refresh_path)
      File.chmod(0o755, post_commit_path)
    end

    def ensure_post_commit_hook(project_root)
      hook_path = File.join(project_root, ".git", "hooks", "post-commit")
      block = <<~BASH.strip
        #{POST_COMMIT_BEGIN}
        if [ "${HIVE_SKIP_LLM_WIKI_POST_COMMIT:-}" != "1" ] && [ -x ".llm-wiki/post-commit-refresh.sh" ]; then
          ".llm-wiki/post-commit-refresh.sh" >/dev/null 2>&1 &
        fi
        #{POST_COMMIT_END}
      BASH
      existing = File.exist?(hook_path) ? File.read(hook_path) : "#!/usr/bin/env bash\n"
      write_file(hook_path, managed_hook_content(existing, block))
      File.chmod(File.stat(hook_path).mode | 0o111, hook_path)
    end

    def project_slug(project_root)
      Scheduler.project_slug(project_root)
    end

    def replace_block(path, begin_marker, end_marker, block)
      existing = File.exist?(path) ? File.read(path) : ""
      write_file(path, managed_content(existing, begin_marker, end_marker, block))
    end

    def managed_hook_content(existing, block)
      pattern = /#{Regexp.escape(POST_COMMIT_BEGIN)}.*?#{Regexp.escape(POST_COMMIT_END)}\n?/m
      content = existing.sub(pattern, "")
      content = "#{content.rstrip}\n" unless content.empty?

      # Insert before a terminal `exit ...` line so the managed block stays reachable.
      # Limitation: an *early-return* exit inside `if/then/fi` short-circuits at runtime
      # and is not detected here — bash parsing is out of scope. Hooks with that pattern
      # must place the managed-block markers manually.
      terminal_exit = /(?<=\A|\n)exit(?:\s+[^\n]*)?\s*\n?\z/
      if (match = content.match(terminal_exit))
        exit_line = match[0].chomp
        return "#{content[0...match.begin(0)]}#{block}\n#{exit_line}\n"
      end

      managed_content(content, POST_COMMIT_BEGIN, POST_COMMIT_END, block)
    end

    def managed_content(existing, begin_marker, end_marker, block)
      pattern = /#{Regexp.escape(begin_marker)}.*?#{Regexp.escape(end_marker)}\n?/m
      return existing.sub(pattern, "#{block}\n") if existing.match?(pattern)

      separator = existing.empty? || existing.end_with?("\n") ? "" : "\n"
      blank_line = existing.empty? ? "" : "\n"
      "#{existing}#{separator}#{blank_line}#{block}\n"
    end

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end
end
