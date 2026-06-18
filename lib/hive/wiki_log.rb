require "fileutils"
require "open3"

module Hive
  # Thin Ruby wrapper over the single shared changelog compiler,
  # `.llm-wiki/compile-log.sh`. The shell script is the one source of truth for
  # the log.md format (shared verbatim with the llm-wiki plugin and the
  # post-commit hook); this module just exposes it to Ruby callers (`hive wiki`).
  module WikiLog
    HEADER = "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n".freeze
    BEGIN_MARKER = "<!-- BEGIN GENERATED WIKI LOG FRAGMENTS -->".freeze
    END_MARKER = "<!-- END GENERATED WIKI LOG FRAGMENTS -->".freeze
    SCRIPT_RELATIVE = File.join(".llm-wiki", "compile-log.sh").freeze

    module_function

    def compile(project_root)
      project_root = File.expand_path(project_root)
      out, err, status = Open3.capture3("bash", compiler_path(project_root), project_root, "--print")
      raise Hive::Error, "wiki log compile failed (#{status.exitstatus}): #{err.strip}" unless status.success?

      out
    end

    def compile!(project_root)
      project_root = File.expand_path(project_root)
      _out, err, status = Open3.capture3("bash", compiler_path(project_root), project_root)
      raise Hive::Error, "wiki log compile! failed (#{status.exitstatus}): #{err.strip}" unless status.success?

      File.read(File.join(project_root, "wiki", "log.md"))
    end

    def stale?(project_root)
      project_root = File.expand_path(project_root)
      log_path = File.join(project_root, "wiki", "log.md")
      current = File.exist?(log_path) ? File.read(log_path) : ""
      current != compile(project_root)
    end

    def fragment_paths(project_root)
      Dir[File.join(project_root, "wiki", "log.d", "*.md")].sort.reverse
    end

    # Resolve the shared compiler: prefer the project's own bootstrapped copy,
    # otherwise fall back to hive's bundled copy so the compiler works against any
    # project root (including throwaway dirs that were never bootstrapped). A
    # genuinely missing script surfaces as a non-zero exit from `compile`.
    def compiler_path(project_root)
      project_copy = File.join(project_root, SCRIPT_RELATIVE)
      return project_copy if File.exist?(project_copy)

      File.expand_path("../../#{SCRIPT_RELATIVE}", __dir__)
    end
  end
end
