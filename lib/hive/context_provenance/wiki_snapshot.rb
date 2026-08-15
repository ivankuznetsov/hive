require "digest"
require "pathname"
require "hive/context_provenance/repository_snapshot"

module Hive
  module ContextProvenance
    module WikiSnapshot
      MAX_FILES = 100
      MAX_BYTES = 512 * 1024
      MAX_ENTRIES = 1_000
      MAX_ELAPSED_SECONDS = 2.0

      module_function

      def capture(project_root, max_files: MAX_FILES, max_bytes: MAX_BYTES)
        root = File.realpath(File.expand_path(project_root))
        wiki = File.join(root, "wiki")
        return missing unless File.exist?(wiki)

        stat = File.lstat(wiki)
        return unavailable("symlink_refused") if stat.symlink? || !stat.directory?

        wiki_root = File.realpath(wiki)
        return unavailable("containment_escape") unless contained?(root, wiki_root)

        dirty = RepositorySnapshot.git(root, %w[status --porcelain=v1 --untracked-files=all -- wiki])
        tree = RepositorySnapshot.git(root, %w[rev-parse --verify HEAD:wiki])
        if tree&.match?(/\A[0-9a-f]{40,64}\z/) && dirty.to_s.empty?
          return {
            "state" => "current", "identity_kind" => "git_tree",
            "identifier" => tree, "file_count" => nil, "byte_count" => nil,
            "truncated" => false, "diagnostics" => []
          }
        end

        digest_tree(wiki_root, max_files: max_files, max_bytes: max_bytes)
      rescue SystemCallError, IOError, ArgumentError => e
        unavailable(e.class.name)
      end

      def digest_tree(wiki_root, max_files:, max_bytes:)
        digest = Digest::SHA256.new
        files = 0
        bytes = 0
        truncated = false
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_ELAPSED_SECONDS
        entries, traversal_truncated = bounded_entries(wiki_root, deadline: deadline)
        truncated ||= traversal_truncated
        entries.each do |path|
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            truncated = true
            break
          end
          relative = path.delete_prefix("#{wiki_root}/")
          next if relative.empty? || relative.split("/").any? { |part| %w[. ..].include?(part) }

          stat = File.lstat(path)
          next if stat.directory?
          if stat.symlink? || !stat.file?
            truncated = true
            next
          end
          if files >= max_files || bytes + stat.size > max_bytes
            truncated = true
            break
          end
          content = descriptor_read(path, stat, max_bytes - bytes)
          digest << relative << "\0" << stat.size.to_s << "\0" << Digest::SHA256.hexdigest(content)
          files += 1
          bytes += content.bytesize
        end
        state = truncated ? "partial" : "current"
        diagnostics = truncated ? [ diagnostic("wiki_digest_truncated") ] : []
        {
          "state" => state, "identity_kind" => "bounded_digest",
          "identifier" => digest.hexdigest, "file_count" => files,
          "byte_count" => bytes, "truncated" => truncated,
          "diagnostics" => diagnostics
        }
      rescue SystemCallError, IOError => e
        unavailable(e.class.name)
      end

      def bounded_entries(root, deadline:, max_entries: MAX_ENTRIES)
        queue = [ root ]
        entries = []
        truncated = false
        until queue.empty?
          break truncated = true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          directory = queue.shift
          names = []
          Dir.each_child(directory) do |name|
            if entries.length + names.length >= max_entries
              truncated = true
              break
            end
            names << name
          end
          names.sort.each do |name|
            path = File.join(directory, name)
            entries << path
            stat = File.lstat(path)
            queue << path if stat.directory? && !stat.symlink?
          end
          break if truncated
        end
        [ entries.sort, truncated ]
      end

      def descriptor_read(path, before, remaining)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |io|
          opened = io.stat
          unless opened.file? && opened.dev == before.dev && opened.ino == before.ino
            raise IOError, "wiki descriptor changed"
          end
          content = io.read(remaining + 1).to_s
          after = io.stat
          unless after.dev == opened.dev && after.ino == opened.ino &&
                 after.size == opened.size && after.mtime == opened.mtime
            raise IOError, "wiki source changed"
          end
          raise IOError, "wiki source exceeds remaining budget" if content.bytesize > remaining

          content
        end
      end

      def missing
        {
          "state" => "missing", "identity_kind" => "missing", "identifier" => nil,
          "file_count" => 0, "byte_count" => 0, "truncated" => false,
          "diagnostics" => [ diagnostic("wiki_missing") ]
        }
      end

      def unavailable(reason)
        {
          "state" => "unavailable", "identity_kind" => "unavailable", "identifier" => nil,
          "file_count" => nil, "byte_count" => nil, "truncated" => false,
          "diagnostics" => [ diagnostic("wiki_capture_failed", reason) ]
        }
      end

      def contained?(root, path)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def diagnostic(code, detail = nil)
        { "code" => code, "detail" => detail }
      end
    end
  end
end
