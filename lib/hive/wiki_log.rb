require "fileutils"

module Hive
  module WikiLog
    HEADER = "# Wiki Changelog\n\nAppend-only log of all wiki operations.\n".freeze
    BEGIN_MARKER = "<!-- BEGIN GENERATED WIKI LOG FRAGMENTS -->".freeze
    END_MARKER = "<!-- END GENERATED WIKI LOG FRAGMENTS -->".freeze

    module_function

    def compile(project_root)
      project_root = File.expand_path(project_root)
      log_path = File.join(project_root, "wiki", "log.md")
      fragments = read_fragments(project_root)
      legacy = legacy_body(File.exist?(log_path) ? File.read(log_path) : "")

      sections = [ HEADER.rstrip, generated_block(fragments) ]
      sections << legacy unless legacy.empty?
      "#{sections.join("\n\n")}\n"
    end

    def compile!(project_root)
      project_root = File.expand_path(project_root)
      log_path = File.join(project_root, "wiki", "log.md")
      FileUtils.mkdir_p(File.dirname(log_path))
      content = compile(project_root)
      File.write(log_path, content)
      content
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

    def read_fragments(project_root)
      fragment_paths(project_root).filter_map do |path|
        body = File.read(path).strip
        body.empty? ? nil : body
      end
    end

    def generated_block(fragments)
      body = fragments.join("\n\n")
      if body.empty?
        "#{BEGIN_MARKER}\n#{END_MARKER}"
      else
        "#{BEGIN_MARKER}\n#{body}\n#{END_MARKER}"
      end
    end

    def legacy_body(existing)
      body = existing.to_s.dup
      body.sub!(/#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\n*/m, "")
      body.sub!(/\A# Wiki Changelog\s*\n+/m, "")
      body = body.lstrip
      unless body.start_with?("## ")
        first_entry = body.index(/^## /)
        body = first_entry ? body[first_entry..] : ""
      end
      body.strip
    end
  end
end
