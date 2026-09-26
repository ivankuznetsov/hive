require "json"
require "rbconfig"

module Hive
  module Attempts
    # Capability evidence for a containment domain that survives fork,
    # reparenting, and setsid. Polling and inherited environment tokens are not
    # promoted to custody; unsupported platforms remain explicitly fail closed.
    module ProcessCustody
      module_function

      def detect
        # Automatic detection must not adopt the caller's ambient service
        # cgroup: it can contain unrelated processes and no launch boundary
        # proves that Hive owns it exclusively. A future launcher integration
        # may inject an explicitly established LinuxCgroupV2 domain.
        adapter = LinuxCgroupV2.new
        return adapter if adapter.available?

        unsupported(adapter.reason || "delegated cgroup v2 custody is unavailable")
      end

      def unsupported(reason) = Unsupported.new(reason)

      class Unsupported
        attr_reader :reason

        def initialize(reason)
          @reason = reason.to_s
        end

        def available? = false
        def mode = "unverified"
        def current_evidence = { "eligible" => false, "mode" => mode, "reason" => reason }
        def evidence_for(_pid) = current_evidence
        def verifiable?(_row) = false
        def members(_path, timeout_sec: nil) = []
      end

      class LinuxCgroupV2
        MAX_CGROUP_FILES = 16_384
        MAX_MEMBERS = 131_072

        attr_reader :reason

        def initialize(cgroup_root: "/sys/fs/cgroup", current_path_reader: nil,
                       exclusive_domain_path: nil,
                       monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                       sleeper: ->(seconds) { sleep(seconds) })
          @cgroup_root = File.expand_path(cgroup_root)
          @current_path_reader = current_path_reader || -> { path_for_pid("self") }
          @exclusive_domain_path = exclusive_domain_path && normalized_path(exclusive_domain_path)
          @monotonic = monotonic
          @sleeper = sleeper
          @reason = nil
        end

        def mode = "delegated_cgroup_v2"
        def available? = current_evidence.fetch("eligible")

        def current_evidence
          evidence_for_path(@current_path_reader.call)
        rescue SystemCallError, IOError, ArgumentError => error
          failure("cgroup_unavailable", error.class.name)
        end

        def evidence_for(pid)
          evidence_for_path(path_for_pid(Integer(pid)))
        rescue SystemCallError, IOError, ArgumentError, TypeError => error
          failure("cgroup_unavailable", error.class.name)
        end

        def verifiable?(row)
          return false unless value(row, "custody_mode") == mode
          path = value(row, "custody_path")
          evidence = parse_evidence(value(row, "custody_evidence_json"))
          return false unless evidence["eligible"] == true && evidence["path"] == path

          evidence_for_path(path).fetch("eligible")
        rescue JSON::ParserError, TypeError
          false
        end

        def members(path, timeout_sec: 1.0)
          domain = resolve_domain(path)
          freeze_path = File.join(domain, "cgroup.freeze")
          events_path = File.join(domain, "cgroup.events")
          unless File.file?(freeze_path) && File.writable?(freeze_path) && File.file?(events_path)
            raise Hive::Error, "cgroup custody domain cannot be frozen"
          end

          deadline = @monotonic.call + [ Float(timeout_sec), 0.0 ].max
          File.write(freeze_path, "1\n")
          until File.read(events_path).match?(/^frozen 1$/)
            raise Hive::Error, "cgroup custody freeze timed out" if @monotonic.call >= deadline
            remaining = [ deadline - @monotonic.call, 0.0 ].max
            @sleeper.call([ 0.01, remaining ].min)
          end

          files = Dir.glob(File.join(domain, "**", "cgroup.procs"), File::FNM_DOTMATCH)
          raise Hive::Error, "cgroup custody inventory exceeds its bound" if files.length > MAX_CGROUP_FILES

          pids = files.flat_map { |file| File.readlines(file, chomp: true) }
            .filter_map { |value| Integer(value, exception: false) }.uniq.sort
          raise Hive::Error, "cgroup custody membership exceeds its bound" if pids.length > MAX_MEMBERS
          pids
        ensure
          File.write(freeze_path, "0\n") if freeze_path && File.file?(freeze_path) && File.writable?(freeze_path)
        end

        private

        def evidence_for_path(path)
          unless linux? && cgroup_v2?
            return failure("platform_unsupported")
          end
          domain = resolve_domain(path)
          parent = File.dirname(domain)
          unless exclusive_domain?(path)
            return failure("exclusive_domain_unproven")
          end
          unless File.file?(File.join(domain, "cgroup.procs")) &&
                 File.writable?(File.join(domain, "cgroup.procs")) &&
                 File.file?(File.join(domain, "cgroup.subtree_control")) &&
                 File.writable?(File.join(domain, "cgroup.subtree_control"))
            return failure("domain_not_delegated")
          end
          if File.writable?(parent) || File.writable?(File.join(parent, "cgroup.procs"))
            return failure("parent_cgroup_writable")
          end

          @reason = nil
          {
            "eligible" => true, "mode" => mode, "path" => normalized_path(path),
            "delegated" => true, "parent_escape_blocked" => true
          }
        rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM, IOError => error
          failure("cgroup_unavailable", error.class.name)
        end

        def failure(reason, detail = nil)
          @reason = reason
          { "eligible" => false, "mode" => mode, "reason" => reason, "detail" => detail }.compact
        end

        def linux? = RbConfig::CONFIG.fetch("host_os", "").include?("linux")
        def cgroup_v2? = File.file?(File.join(@cgroup_root, "cgroup.controllers"))

        def path_for_pid(pid)
          line = File.foreach("/proc/#{pid}/cgroup").find { |entry| entry.start_with?("0::") }
          raise IOError, "unified cgroup path is unavailable" unless line
          line.split("::", 2).last.to_s.strip
        end

        def normalized_path(path)
          value = path.to_s
          raise ArgumentError, "invalid cgroup path" unless value.start_with?("/")
          clean = File.expand_path(value, "/")
          raise ArgumentError, "invalid cgroup path" if clean == "/"
          clean
        end

        def exclusive_domain?(path)
          return false unless @exclusive_domain_path

          candidate = normalized_path(path)
          candidate == @exclusive_domain_path || candidate.start_with?("#{@exclusive_domain_path}/")
        end

        def resolve_domain(path)
          relative = normalized_path(path).delete_prefix("/")
          domain = File.expand_path(relative, @cgroup_root)
          prefix = "#{File.realpath(@cgroup_root)}#{File::SEPARATOR}"
          resolved = File.realpath(domain)
          raise ArgumentError, "cgroup path escapes the unified hierarchy" unless resolved.start_with?(prefix)
          resolved
        end

        def value(row, key) = row[key] || row[key.to_sym]
        def parse_evidence(value) = value.is_a?(Hash) ? value : JSON.parse(value.to_s)
      end
    end
  end
end
