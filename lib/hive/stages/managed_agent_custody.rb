require "open3"
require "hive/artifact_firewall"

module Hive
  module Stages
    # Local controller-custody primitives shared by managed agent stages.
    # This module does not create worktrees, authenticate, publish, or decide
    # stage outcomes; those remain responsibilities of the owning workflow.
    module ManagedAgentCustody
      module_function

      def manifest(root:, worktree_path:, protected_task_paths:, required_outputs:)
        Hive::ArtifactFirewall::Manifest.new(
          root: root,
          protected_anchors: protected_task_paths.merge(git_control_paths!(worktree_path)),
          permitted_writable_roots: [ root, worktree_path ],
          required_outputs: required_outputs
        )
      end

      def validate_regular_or_absent!(root, names)
        names.each do |name|
          stat = File.lstat(File.join(root, name))
          unless stat.file? && !stat.symlink?
            raise Hive::StageError, "protected task file #{name} must be a regular file"
          end
        rescue Errno::ENOENT
          next
        end
      end

      def prepare_output!(path, label: File.basename(path))
        stat = File.lstat(path)
        raise Hive::StageError, "#{label} must be a regular file, not a symlink" if stat.symlink?
        raise Hive::StageError, "#{label} must be a regular file" unless stat.file?

        File.unlink(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, IOError => e
        raise Hive::StageError, "could not prepare #{label}: #{e.class}: #{e.message}"
      end

      def git_control_paths!(worktree_path)
        common = git_path!(worktree_path, "--path-format=absolute", "--git-common-dir")
        git_dir = git_path!(worktree_path, "--absolute-git-dir")
        paths = {
          "worktree .git pointer" => File.join(worktree_path, ".git"),
          "repository config" => File.join(common, "config"),
          "worktree config" => File.join(git_dir, "config.worktree")
        }
        home = ENV["HOME"].to_s
        unless home.empty?
          paths["global Git config"] = File.join(home, ".gitconfig")
          paths["XDG Git config"] = File.join(home, ".config", "git", "config")
        end
        xdg = ENV["XDG_CONFIG_HOME"].to_s
        paths["explicit XDG Git config"] = File.join(xdg, "git", "config") unless xdg.empty?
        global = ENV["GIT_CONFIG_GLOBAL"].to_s
        paths["global Git config override"] = global unless global.empty?
        system = ENV["GIT_CONFIG_SYSTEM"].to_s
        paths["system Git config override"] = system unless system.empty?
        unique_paths(paths, worktree_path)
      end

      def unique_paths(paths, root)
        seen = {}
        paths.each_with_object({}) do |(label, path), unique|
          expanded = File.expand_path(path, root)
          next if seen[expanded]

          seen[expanded] = true
          unique[label] = expanded
        end
      end
      private_class_method :unique_paths

      def git_path!(worktree_path, *args)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", *args)
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::StageError, "managed worktree Git control path is unavailable: #{detail[0, 200]}"
        end

        File.expand_path(out.to_s.strip, worktree_path)
      end
      private_class_method :git_path!
    end
  end
end
