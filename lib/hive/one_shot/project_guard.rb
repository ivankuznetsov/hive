require "fileutils"
require "json"
require "time"
require "hive/errors"
require "hive/lock"
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

      class OwnershipError < Hive::Error
        attr_reader :code, :owner

        def initialize(message, code:, owner: nil)
          @code = code
          @owner = owner
          super(message)
        end

        def exit_code = Hive::ExitCodes::TEMPFAIL
      end

      attr_reader :path, :project, :kind

      class Collection
        attr_reader :contentions

        def initialize(kind:, registry:, enabled:, guard_factory: nil)
          @kind = kind
          @registry = registry
          @enabled = enabled
          @guard_factory = guard_factory || lambda do |entry|
            ProjectGuard.new(
              state_root: entry.fetch("hive_state_path"),
              project: entry.fetch("name"), kind: @kind
            )
          end
          @guards = {}
          @contentions = {}
        end

        def refresh!
          Array(@registry.call).each do |entry|
            name = entry.fetch("name").to_s
            next if @guards.key?(name) || !@enabled.call(entry)

            begin
              @guards[name] = @guard_factory.call(entry).acquire!
              @contentions.delete(name)
            rescue OwnershipError => error
              @contentions[name] = error
            end
          end
          owned_projects
        end

        def owned?(project) = @guards.key?(project.to_s)
        def owned_projects = @guards.keys.sort

        def release_all!
          @guards.each_value(&:release!)
          @guards.clear
          true
        end
      end

      def initialize(state_root:, project:, kind:, process_start_time: Hive::Lock.method(:process_start_time),
                     process_alive: nil)
        FileUtils.mkdir_p(state_root, mode: 0o700)
        @state_root = File.realpath(state_root)
        @project = project.to_s
        @kind = kind.to_s
        raise ArgumentError, "invalid project guard kind #{@kind.inspect}" unless OWNER_CODES.key?(@kind)

        lock_dir = File.join(@state_root, "scheduler")
        FileUtils.mkdir_p(lock_dir, mode: 0o700)
        @path = File.join(lock_dir, LOCK_NAME)
        @process_start_time = process_start_time
        @process_alive = process_alive || method(:process_alive?)
        @handle = nil
      end

      def acquire!
        return self if @handle

        handle = open_handle
        unless handle.flock(File::LOCK_EX | File::LOCK_NB)
          owner = verified_owner(handle)
          code = owner ? OWNER_CODES.fetch(owner.fetch("kind"), "one_shot_busy") : "ownership_unverifiable"
          raise OwnershipError.new(
            owner ? "project #{@project} is owned by #{owner.fetch("kind")} pid #{owner.fetch("pid")}" :
              "project #{@project} ownership cannot be verified",
            code: code, owner: owner
          )
        end
        write_owner(handle)
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
        handle.flock(File::LOCK_UN)
        handle.close
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

      def owner
        return unless @handle

        parse_owner(@handle)
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

      def write_owner(handle)
        identity = @process_start_time.call(Process.pid)
        raise Hive::ConfigError, "project execution guard cannot verify its process identity" if identity.nil?

        payload = {
          "kind" => kind, "project" => project, "pid" => Process.pid,
          "process_identity" => identity.to_s, "state_root" => @state_root,
          "started_at" => Time.now.utc.iso8601(6)
        }
        handle.rewind
        handle.truncate(0)
        handle.write("#{JSON.generate(payload)}\n")
        handle.flush
        handle.fsync
      end

      def verified_owner(handle)
        payload = parse_owner(handle)
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

      def parse_owner(handle)
        handle.rewind
        value = JSON.parse(handle.read)
        value if value.is_a?(Hash)
      rescue JSON::ParserError, SystemCallError, IOError
        nil
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
