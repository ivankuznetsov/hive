require "fileutils"
require "open3"
require "tmpdir"
require "hive/atomic_file"
require "hive/agent_git_gate"
require "hive/errors"

module Hive
  module PatrolFix
    # Gives one Patrol agent private writable Git metadata inside a mount
    # namespace. The real common Git directory and user home stay read-only;
    # only the selected worktree (for Fix) and task report directory are
    # writable host mounts. A successful Fix commit is adopted later through
    # AgentGitGate's exact guarded operation.
    class AgentGitIsolation
      SANDBOX_PATH = "/usr/bin/bwrap".freeze
      GIT_ENVIRONMENT = {
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_COUNT" => "0",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => File::NULL,
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_AUTHOR_NAME" => "Hive Patrol Agent",
        "GIT_AUTHOR_EMAIL" => "patrol-agent@hive.local",
        "GIT_COMMITTER_NAME" => "Hive Patrol Agent",
        "GIT_COMMITTER_EMAIL" => "patrol-agent@hive.local"
      }.freeze

      attr_reader :metadata, :command_prefix, :environment

      def self.prepare!(worktree_path:, task_folder:, writable_worktree:,
                        profile: nil, git_control_paths: nil,
                        provider_environment: {},
                        sandbox_path: SANDBOX_PATH)
        new(
          worktree_path: worktree_path, task_folder: task_folder,
          writable_worktree: writable_worktree, profile: profile,
          git_control_paths: git_control_paths, provider_environment: provider_environment,
          sandbox_path: sandbox_path
        ).tap(&:prepare!)
      end

      def self.git_control_paths!(worktree_path)
        common = git_path!(worktree_path, "--path-format=absolute", "--git-common-dir")
        git_dir = git_path!(worktree_path, "--absolute-git-dir")
        paths = {
          "worktree .git pointer" => File.join(worktree_path, ".git"),
          "repository config" => File.join(common, "config"),
          "worktree config" => File.join(git_dir, "config.worktree")
        }
        Hive::AgentGitGate.tracked_gitlinks(worktree_path).each do |relative_path|
          submodule = File.join(worktree_path, relative_path)
          next unless File.directory?(submodule)

          paths["submodule #{relative_path} .git pointer"] = File.join(submodule, ".git")
        end
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

      def self.git_read_only_paths!(worktree_path, control_paths: nil)
        controls = control_paths || git_control_paths!(worktree_path)
        common = File.dirname(controls.fetch("repository config"))
        git_dir = File.dirname(controls.fetch("worktree config"))
        (controls.values + [ common, git_dir ]).uniq.freeze
      end

      def initialize(worktree_path:, task_folder:, writable_worktree:, profile:,
                     git_control_paths: nil, provider_environment: {}, sandbox_path:)
        @worktree_path = File.realpath(worktree_path)
        @task_folder = File.realpath(task_folder)
        @writable_worktree = writable_worktree == true
        @profile = profile
        @git_control_paths = git_control_paths&.dup&.freeze
        @provider_environment = provider_environment.to_h.transform_keys(&:to_s).freeze
        @sandbox_path = File.expand_path(sandbox_path.to_s)
      rescue SystemCallError => e
        raise Hive::StageError,
              "Patrol agent Git isolation roots are unavailable: #{e.class}"
      end

      def prepare!
        unless File.file?(@sandbox_path) && File.executable?(@sandbox_path)
          raise Hive::StageError,
                "Patrol managed agents require bubblewrap before provider launch"
        end
        home = File.realpath(ENV.fetch("HOME"))
        if home == File::SEPARATOR
          raise Hive::StageError, "Patrol agent Git isolation HOME is invalid"
        end

        @runtime_root = Dir.mktmpdir("agent-git-isolation-", @task_folder)
        @private_tmpdir = File.join(@runtime_root, "tmp")
        Dir.mkdir(@private_tmpdir, 0o700)
        git_dir = File.join(@runtime_root, "repository.git")
        @metadata = Hive::AgentGitGate.prepare_isolated_metadata(
          repository_path: @worktree_path, worktree_path: @worktree_path,
          destination: git_dir, destination_root: @runtime_root
        )
        controls = @git_control_paths || self.class.git_control_paths!(@worktree_path)
        @source_objects = File.realpath(
          File.join(File.dirname(controls.fetch("repository config")), "objects")
        )
        @source_objects_mount = File.join(@runtime_root, "source-objects")
        Dir.mkdir(@source_objects_mount, 0o700)
        protected_paths = self.class.git_read_only_paths!(
          @worktree_path, control_paths: controls
        )
        @worktree_git_dir = File.dirname(controls.fetch("worktree config"))
        protected_paths = protected_paths.reject do |path|
          contained_path?(File.expand_path(path), @worktree_git_dir)
        end
        rebind_private_alternates!
        @command_prefix = sandbox_arguments(home, protected_paths).freeze
        @environment = GIT_ENVIRONMENT.merge("TMPDIR" => @private_tmpdir).freeze
        self
      rescue KeyError, Hive::AgentGitGate::Error, SystemCallError, IOError => e
        cleanup!
        raise Hive::StageError,
              "Patrol agent Git isolation could not be prepared: #{e.message.to_s[0, 300]}"
      end

      def adopt!
        unless @writable_worktree
          raise Hive::StageError, "read-only Patrol agent Git metadata cannot be adopted"
        end

        restore_controller_alternates!
        Hive::AgentGitGate.adopt_isolated_metadata(@metadata)
      rescue Hive::AgentGitGate::Error => e
        raise Hive::StageError,
              "Patrol agent Git commit could not be adopted: #{e.message.to_s[0, 300]}"
      end

      def adopt_if_changed!
        restore_controller_alternates!
        head = Hive::AgentGitGate.read(@metadata.git_dir, :head_oid)
        unless head.success?
          raise Hive::StageError, "Patrol isolated Git HEAD is unavailable"
        end
        return if head.stdout.strip.downcase == @metadata.base_oid

        adopt!
      rescue Hive::AgentGitGate::Error => e
        raise Hive::StageError,
              "Patrol isolated Git commit could not be inspected: #{e.message.to_s[0, 300]}"
      end

      def cleanup!
        return :absent unless @runtime_root

        root = @runtime_root
        FileUtils.remove_entry_secure(root, true)
        @runtime_root = nil
        :removed
      rescue SystemCallError, IOError => e
        warn "hive: retained Patrol agent Git isolation #{root}: #{e.class}"
        :retained
      end

      private

      def sandbox_arguments(home, protected_paths)
        args = [
          @sandbox_path,
          "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
          "--ro-bind", File::SEPARATOR, File::SEPARATOR,
          "--proc", "/proc", "--dev", "/dev"
        ]
        writable_paths(home).each do |path|
          args.concat([ "--bind", path, path ])
        end
        protected_mounts(protected_paths, writable_paths(home)).each do |path|
          args.concat([ "--ro-bind", path, path ])
        end
        args.concat([ "--ro-bind", @source_objects, @source_objects_mount ])
        args.concat([ "--bind", @metadata.git_dir, @worktree_git_dir ])
        args.concat([ "--chdir", @worktree_path, "--" ])
      end

      def writable_paths(home)
        paths = [ @task_folder, @runtime_root ]
        paths << @worktree_path if @writable_worktree
        paths.concat(writable_provider_paths(home))
        paths.uniq.sort_by { |path| [ path.count(File::SEPARATOR), path ] }
      end

      def writable_provider_paths(home)
        environment = provider_environment
        provider_state_candidates(home, environment).filter_map do |label, path|
          canonical_provider_state_path!(label, path, home)
        end.uniq.sort
      end

      def provider_state_candidates(home, environment)
        [
          [ "XDG cache directory", environment["XDG_CACHE_HOME"] ],
          [ "XDG data directory", environment["XDG_DATA_HOME"] ],
          [ "XDG state directory", environment["XDG_STATE_HOME"] ],
          [ "default cache directory", File.join(home, ".cache") ],
          [ "default data directory", File.join(home, ".local", "share") ],
          [ "default state directory", File.join(home, ".local", "state") ],
          [ "provider configuration directory", profile_state_path(home, environment) ]
        ]
      end

      def canonical_provider_state_path!(label, path, home)
        return if path.nil? || path.empty?

        expanded = File.expand_path(path)
        return unless File.exist?(expanded) || File.symlink?(expanded)

        resolved = File.realpath(expanded)
        unless File.directory?(resolved) && strictly_contained_path?(resolved, home)
          raise Hive::StageError,
                "Patrol #{label} must be an existing directory strictly below HOME"
        end
        if provider_state_overlaps_agent_roots?(resolved)
          raise Hive::StageError,
                "Patrol #{label} overlaps the selected task or worktree"
        end

        resolved
      rescue SystemCallError => e
        raise Hive::StageError,
              "Patrol #{label} is unavailable: #{e.class}"
      end

      def provider_environment
        ENV.each_with_object({}) { |(key, value), result| result[key] = value }
          .merge(@provider_environment.reject { |_key, value| value.nil? })
      end

      def provider_state_overlaps_agent_roots?(path)
        paths_overlap?(path, @task_folder) || paths_overlap?(path, @worktree_path)
      end

      def strictly_contained_path?(path, root)
        path != root && contained_path?(path, root)
      end

      def profile_state_path(home, environment)
        @profile&.configuration_directory(home: home, environment: environment)
      end

      def protected_mounts(paths, writable_paths = [])
        paths.map { |path| File.expand_path(path) }
          .each { |path| reject_missing_protected_writable_path!(path, writable_paths) }
          .select { |path| File.exist?(path) || File.symlink?(path) }
          .map { |path| File.realpath(path) }
          .uniq.sort_by { |path| [ path.count(File::SEPARATOR), path ] }
      rescue SystemCallError => e
        raise Hive::StageError,
              "Patrol protected Git path is unavailable: #{e.class}"
      end

      def reject_missing_protected_writable_path!(path, writable_paths)
        return if File.exist?(path) || File.symlink?(path)
        return unless writable_paths.any? { |root| contained_path?(path, root) }

        raise Hive::StageError,
              "Patrol protected Git path is missing below a writable root"
      end

      def rebind_private_alternates!
        Hive::AtomicFile.write(
          File.join(@metadata.git_dir, "objects", "info", "alternates"),
          "#{@source_objects_mount}\n", mode: 0o600
        )
      end

      def restore_controller_alternates!
        Hive::AtomicFile.write(
          File.join(@metadata.git_dir, "objects", "info", "alternates"),
          "#{@source_objects}\n", mode: 0o600
        )
      end

      def contained_path?(path, root)
        path == root || path.start_with?(root + File::SEPARATOR)
      end

      def paths_overlap?(left, right)
        contained_path?(left, right) || contained_path?(right, left)
      end

      class << self
        private

        def unique_paths(paths, root)
          seen = {}
          paths.each_with_object({}) do |(label, path), unique|
            expanded = File.expand_path(path, root)
            next if seen[expanded]

            seen[expanded] = true
            unique[label] = expanded
          end
        end

        def git_path!(worktree_path, *args)
          out, err, status = Open3.capture3(
            "git", "-C", worktree_path, "rev-parse", *args
          )
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            raise Hive::StageError,
                  "managed worktree Git control path is unavailable: #{detail[0, 200]}"
          end

          File.expand_path(out.to_s.strip, worktree_path)
        end
      end
    end
  end
end
