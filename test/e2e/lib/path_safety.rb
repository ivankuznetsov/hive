require "tmpdir"

module Hive
  module E2E
    module PathSafety
      module_function

      SAFE_BASENAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
      RUN_ID = /\A\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-\d+-[0-9a-f]{4}\z/

      def safe_basename!(value, label)
        text = value.to_s
        return text if SAFE_BASENAME.match?(text)

        raise ArgumentError, "#{label} must be a safe basename matching #{SAFE_BASENAME.source} (got #{value.inspect})"
      end

      def relative_path!(value, label)
        text = value.to_s
        invalid_path!(label, value) if text.empty? || text.include?("\0") || absolute_path?(text)
        parts = text.split(/[\\\/]+/)
        invalid_path!(label, value) if parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }
        text
      end

      def contained_path!(root, value, label)
        root_path = File.expand_path(root)
        value_text = value.to_s
        invalid_path!(label, value) if value_text.empty? || value_text.include?("\0")

        resolved = if absolute_path?(value_text)
          File.expand_path(value_text)
        else
          File.expand_path(value_text, root_path)
        end
        return resolved if contained?(root_path, resolved)

        raise ArgumentError, "#{label} #{resolved.inspect} escapes #{root_path.inspect}"
      end

      def contained?(root, path)
        root_path = File.expand_path(root)
        resolved = File.expand_path(path)
        resolved == root_path || resolved.start_with?("#{root_path}/")
      end

      def cleanup_root!(runs_dir, default_runs_dir:)
        root = File.expand_path(runs_dir)
        default_root = File.expand_path(default_runs_dir)
        if File.exist?(root)
          real = File.realpath(root)
          raise ArgumentError, "runs_dir #{root.inspect} must not be a symlinked path" unless real == root
        end

        forbidden = [ "/", Dir.home, File.expand_path("../../..", __dir__) ].map { |path| File.expand_path(path) }
        if forbidden.any? { |path| root == path }
          raise ArgumentError, "refusing to clean unsafe runs_dir #{root.inspect}"
        end

        tmp_root = File.expand_path(Dir.tmpdir)
        return root if root == default_root || contained?(tmp_root, root)

        raise ArgumentError, "runs_dir #{root.inspect} must be the e2e runs directory or a temp test directory"
      end

      def generated_run_dir?(name)
        RUN_ID.match?(name.to_s)
      end

      def absolute_path?(path)
        path.start_with?("/") || path.match?(/\A[A-Za-z]:[\\\/]/)
      end

      def invalid_path!(label, value)
        raise ArgumentError, "#{label} must be a relative path without empty, dot, or traversal components (got #{value.inspect})"
      end
    end
  end
end
