require "base64"
require "json"
require "open3"
require "time"
require "hive/atomic_file"
require "hive/attempts/output_reference"

module Hive
  module Attempts
    DirtyCapture = Data.define(:references, :manifest, :directory)

    # Read-only, binary-safe inventory of a lost attempt's worktree. No stash,
    # reset, checkout, clean, add, or commit command is ever executed here.
    class DirtyStateCapture
      def initialize(store:)
        @store = store
      end

      def capture(attempt:, worktree:, now: Time.now.utc)
        raise StoreError, "attempt worktree is unavailable" unless worktree && File.directory?(worktree)

        directory = @store.output_directory(
          attempt.attempt_id,
          "dirty-state",
          create: true
        )

        revision = git(worktree, "rev-parse", "HEAD").strip
        status = git(worktree, "status", "--porcelain=v2", "-z", "--untracked-files=all")
        staged = git(worktree, "diff", "--binary", "--cached", "--no-ext-diff")
        unstaged = git(worktree, "diff", "--binary", "--no-ext-diff")
        untracked = git(worktree, "ls-files", "--others", "--exclude-standard", "-z")

        files = {
          "status.porcelain-v2.z" => status,
          "staged.patch" => staged,
          "unstaged.patch" => unstaged
        }
        files.each { |name, bytes| write(File.join(directory, name), bytes) }

        manifest = {
          "schema" => "hive-dirty-state-capture",
          "schema_version" => 1,
          "attempt_id" => attempt.attempt_id,
          "task_generation" => attempt.task_generation,
          "captured_at" => now.utc.iso8601(6),
          "revision" => revision,
          "status_size" => status.bytesize,
          "staged_patch_size" => staged.bytesize,
          "unstaged_patch_size" => unstaged.bytesize,
          "untracked" => untracked.split("\0", -1).reject(&:empty?).map do |path|
            untracked_metadata(worktree, path)
          end
        }
        manifest_path = File.join(directory, "manifest.json")
        write(manifest_path, JSON.generate(manifest) + "\n")

        references = (files.keys.map { |name| File.join(directory, name) } + [ manifest_path ]).map do |path|
          OutputReference.build(path, root: @store.root)
        end
        DirtyCapture.new(references: references.freeze, manifest: manifest.freeze, directory: directory)
      end

      private

      def git(worktree, *args)
        stdout, stderr, status = Open3.capture3(
          { "GIT_OPTIONAL_LOCKS" => "0" },
          "git", "-C", worktree, *args
        )
        raise StoreError, "dirty-state git #{args.first} failed: #{stderr.strip}" unless status.success?

        stdout.b
      end

      def untracked_metadata(worktree, relative_path)
        path = File.join(worktree, relative_path)
        stat = File.lstat(path)
        metadata = {
          "path_base64" => Base64.strict_encode64(relative_path.b),
          "size" => stat.file? ? stat.size : nil,
          "mode" => stat.mode & 0o7777,
          "type" => stat.ftype
        }
        if stat.file?
          metadata["sha256"] = ::Digest::SHA256.file(path).hexdigest
        elsif stat.symlink?
          metadata["target_base64"] = Base64.strict_encode64(File.readlink(path).b)
        end
        metadata
      rescue SystemCallError => e
        {
          "path_base64" => Base64.strict_encode64(relative_path.b),
          "unreadable" => e.class.name
        }
      end

      def write(path, bytes)
        Hive::AtomicFile.write(path, bytes, mode: 0o600)
        File.chmod(0o600, path)
      end
    end
  end
end
