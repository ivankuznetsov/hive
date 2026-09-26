require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/errors"
require "hive/lock"
require "hive/one_shot/project_liveness"
require "hive/paths"
require "hive/pid_file"
require "hive/runtime_control_plane/process_guard"

module Hive
  module OneShot
    class ProjectGuard
      LOCK_NAME = "project-execution.lock".freeze
      OWNER_CODES = {
        "daemon" => "daemon_owned",
        "babysitter" => "babysitter_owned",
        "one_shot" => "one_shot_busy"
      }.freeze
      UNVERIFIABLE_OWNER = Object.new.freeze

      class OwnershipError < Hive::Error
        attr_reader :code, :owner

        def initialize(message, code:, owner: nil)
          @code = code
          @owner = owner
          super(message)
        end

        def exit_code = Hive::ExitCodes::TEMPFAIL
      end

      attr_reader :path, :owner_path, :project, :kind

      def self.canonical_state_root(state_root)
        path = File.expand_path(state_root)
        suffix = []
        until File.exist?(path)
          suffix.unshift(File.basename(path))
          path = File.dirname(path)
        end
        File.join(File.realpath(path), *suffix)
      end

      class Collection
        attr_reader :contentions

        def initialize(kind:, registry:, enabled:, guard_factory: nil, drained: nil)
          @kind = kind
          @registry = registry
          @enabled = enabled
          @guard_factory = guard_factory || lambda do |entry|
            ProjectGuard.new(
              state_root: entry.fetch("hive_state_path"),
              project: entry.fetch("name"), kind: @kind
            )
          end
          @drained = drained || ->(entry) { ProjectLiveness.new(entry: entry).safe_to_stop? }
          @guards = {}
          @entries = {}
          @projects = {}
          @contentions = {}
        end

        def refresh!
          entries = Array(@registry.call)
          seen = {}
          enabled_associations = {}
          entries.each do |entry|
            name = entry.fetch("name").to_s
            seen[name] = true
            identity = nil

            begin
              identity = canonical_identity(entry)
              @projects[name] = identity
              (@entries[identity] ||= {})[name] = entry
              enabled = @enabled.call(entry)
              enabled_associations[[ identity, name ]] = enabled
              unless enabled
                @contentions.delete(name)
                next
              end
              if @guards.key?(identity)
                @contentions.delete(name)
                next
              end

              @guards[identity] = @guard_factory.call(entry).acquire!
              @contentions.delete(name)
            rescue OwnershipError => error
              @contentions[name] = error
            rescue StandardError => error
              @projects[name] = nil if identity.nil?
              @contentions[name] = OwnershipError.new(
                "project #{name} configuration is unavailable: #{error.message}",
                code: "project_config_unavailable"
              )
            end
          end
          removed = @projects.keys - seen.keys
          removed.each do |name|
            @projects.delete(name)
            @contentions.delete(name)
          end
          release_drained_associations(enabled_associations)
          owned_projects
        end

        def owned?(project)
          name = project.to_s
          if @projects.key?(name)
            identity = @projects[name]
            return identity && @guards.key?(identity) && @entries.fetch(identity, {}).key?(name)
          end

          @entries.any? do |identity, identity_entries|
            @guards.key?(identity) && identity_entries.key?(name)
          end
        end

        def owned_projects
          @entries.each_with_object([]) do |(identity, identity_entries), names|
            names.concat(identity_entries.keys) if @guards.key?(identity)
          end.uniq.select { |name| owned?(name) }.sort
        end

        def release_all!
          @guards.each_value(&:release!)
          @guards.clear
          @entries.clear
          @projects.clear
          true
        end

        private

        def canonical_identity(entry)
          ProjectGuard.canonical_state_root(entry.fetch("hive_state_path"))
        end

        def release_drained_associations(enabled_associations)
          empty_identities = []
          @entries.each do |identity, identity_entries|
            identity_entries.delete_if do |name, entry|
              current = @projects[name] == identity
              should_drain = !current || enabled_associations[[ identity, name ]] == false
              should_drain && (!@guards.key?(identity) || @drained.call(entry))
            end
            empty_identities << identity if identity_entries.empty?
          end
          empty_identities.each do |identity|
            @guards.delete(identity)&.release!
            @entries.delete(identity)
          end
        end
      end

      def initialize(state_root:, project:, kind:, lock_name: LOCK_NAME,
                     process_start_time: Hive::Lock.method(:process_start_time),
                     process_alive: nil, legacy_daemon_owner: nil,
                     contention_sleeper: ->(seconds) { sleep(seconds) })
        FileUtils.mkdir_p(state_root, mode: 0o700)
        @state_root = File.realpath(state_root)
        @project = project.to_s
        @kind = kind.to_s
        raise ArgumentError, "invalid project guard kind #{@kind.inspect}" unless OWNER_CODES.key?(@kind)

        lock_dir = File.join(@state_root, "scheduler")
        FileUtils.mkdir_p(lock_dir, mode: 0o700)
        unless File.basename(lock_name.to_s) == lock_name.to_s && !lock_name.to_s.empty?
          raise ArgumentError, "invalid project guard lock name"
        end
        @path = File.join(lock_dir, lock_name)
        @owner_path = "#{@path}.owner"
        @process_start_time = process_start_time
        @process_alive = process_alive || method(:process_alive?)
        @legacy_daemon_owner = legacy_daemon_owner || method(:legacy_daemon_owner)
        @contention_sleeper = contention_sleeper
        @handle = nil
      end

      def acquire!
        return self if @handle

        handle = open_handle
        unless acquire_handle(handle)
          owner = verified_owner
          raise ownership_error(owner)
        end
        if kind == "one_shot" && File.basename(path) == LOCK_NAME
          owner = @legacy_daemon_owner.call
          raise ownership_error(owner) if owner
        end
        write_owner
        @handle = handle
        Hive::RuntimeControlPlane::ProcessGuard.register_fork_resource(self)
        self
      rescue Hive::Error
        handle&.close
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => error
        handle&.close
        raise Hive::ConfigError, "project execution guard is unavailable (#{error.class}: #{error.message})"
      end

      def release!
        handle = @handle
        return false unless handle

        @handle = nil
        Hive::RuntimeControlPlane::ProcessGuard.unregister_fork_resource(self)
        begin
          File.unlink(owner_path) if File.exist?(owner_path)
        ensure
          handle.flock(File::LOCK_UN)
          handle.close
        end
        true
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError, "project execution guard could not be released (#{error.class}: #{error.message})"
      end

      def synchronize
        acquired_here = !@handle
        acquire!
        yield self
      ensure
        release! if acquired_here && @handle
      end

      def after_fork_child!
        @handle&.close
        @handle = nil
        true
      end

      private

      def open_handle
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags, 0o600).tap { |handle| handle.close_on_exec = true }
      end

      def write_owner
        identity = @process_start_time.call(Process.pid)
        raise Hive::ConfigError, "project execution guard cannot verify its process identity" if identity.nil?

        payload = {
          "kind" => kind, "project" => project, "pid" => Process.pid,
          "process_identity" => identity.to_s, "state_root" => @state_root,
          "started_at" => Time.now.utc.iso8601(6)
        }
        Hive::AtomicFile.write(owner_path, "#{JSON.generate(payload)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(File.dirname(owner_path))
      end

      def verified_owner
        payload = parse_owner
        return unless payload

        pid = Integer(payload.fetch("pid"))
        recorded = payload.fetch("process_identity").to_s
        return unless pid.positive? && OWNER_CODES.key?(payload["kind"])
        return unless @process_alive.call(pid)

        live = @process_start_time.call(pid)
        return if live.nil? || recorded.empty? || live.to_s != recorded

        payload
      rescue ArgumentError, KeyError, TypeError
        nil
      end

      def parse_owner
        value = JSON.parse(File.binread(owner_path))
        value if value.is_a?(Hash)
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end

      def acquire_handle(handle)
        return true if handle.flock(File::LOCK_EX | File::LOCK_NB)

        10.times do
          return false if verified_owner
          @contention_sleeper.call(0.005)
          return true if handle.flock(File::LOCK_EX | File::LOCK_NB)
        end
        false
      end

      def ownership_error(owner)
        return OwnershipError.new(
          "project #{@project} ownership cannot be verified",
          code: "ownership_unverifiable", owner: nil
        ) if owner.equal?(UNVERIFIABLE_OWNER)

        code = owner ? OWNER_CODES.fetch(owner.fetch("kind"), "one_shot_busy") :
          "ownership_unverifiable"
        OwnershipError.new(
          owner ? "project #{@project} is owned by #{owner.fetch("kind")} pid #{owner.fetch("pid")}" :
            "project #{@project} ownership cannot be verified",
          code: code, owner: owner
        )
      end

      def legacy_daemon_owner
        pid_path = File.join(Hive::Paths.state_home, ".daemon.pid")
        return unless File.exist?(pid_path)

        payload = Hive::PidFile.read(pid_path)
        return UNVERIFIABLE_OWNER if payload.empty?

        pid = payload["pid"]
        return UNVERIFIABLE_OWNER unless pid.is_a?(Integer) && pid.positive?
        return unless Hive::PidFile.alive?(pid)

        case Hive::PidFile.ownership(payload, pid)
        when :reused then return nil
        when :verified then nil
        else return UNVERIFIABLE_OWNER
        end

        entry = Hive::Config.find_project(project)
        return unless entry &&
          self.class.canonical_state_root(entry.fetch("hive_state_path")) == @state_root
        return unless Hive::Config.load(entry.fetch("path")).dig("daemon", "enabled") == true

        {
          "kind" => "daemon", "project" => project, "pid" => pid,
          "process_identity" => payload.fetch("process_start_time").to_s,
          "state_root" => @state_root
        }
      rescue Hive::Error, Psych::Exception, SystemCallError, IOError, ArgumentError, TypeError
        UNVERIFIABLE_OWNER
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, RangeError
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
