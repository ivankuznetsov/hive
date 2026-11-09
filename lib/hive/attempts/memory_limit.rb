require "open3"

module Hive
  module Attempts
    # Memory cap for the transient systemd user scope that hosts a durable
    # attempt (`hive-attempt-*.scope`). Everything an attempt starts — the
    # agent CLI, its tool shells, ad-hoc probes, and the project's own test
    # or CI commands — is a descendant of that scope, so one `MemoryMax=` on
    # the scope bounds the whole attempt instead of letting a runaway child
    # push a small shared host into systemd-oomd or the kernel OOM killer.
    #
    # Config lives in the global `daemon` block next to the other launch
    # controls: `daemon.attempt_memory_max` and `daemon.attempt_memory_swap_max`.
    # `false` disables the cap (no properties are passed at all).
    module MemoryLimit
      FAILURE_REASON = "memory_limit_exceeded".freeze

      # systemd accepts a byte count with an optional base-1024 suffix, a
      # percentage of physical memory, or `infinity`.
      SIZE_PATTERN = /\A(?:\d+(?:\.\d+)?[KMGT]?|\d+(?:\.\d+)?%|infinity)\z/

      # OOMPolicy= became a scope property in systemd 253. Older managers
      # take no unit-level action on a scope OOM kill, so omitting it there
      # keeps the same "kill only the offending process" behavior.
      SCOPE_OOM_POLICY_MIN_SYSTEMD = 253

      module_function

      # Returns nil when valid, or a short description of the accepted shapes.
      def invalid_reason(value, allow_zero:)
        return nil if value == false
        return nil if value.is_a?(Integer) && (allow_zero ? value >= 0 : value.positive?)
        if value.is_a?(String) && value.match?(SIZE_PATTERN) &&
           (allow_zero || !value.match?(/\A0+(?:\.0+)?[KMGT%]?\z/))
          return nil
        end

        "must be false (disabled), #{allow_zero ? 'a non-negative' : 'a positive'} byte " \
          "Integer, or a systemd size such as \"6G\", \"512M\", \"50%\", or \"infinity\""
      end

      # systemd-run `--property=` arguments for one attempt scope. The swap
      # cap applies only alongside a memory cap. OOMPolicy=continue matters:
      # systemd's default (`stop`) tears down the whole scope on an OOM kill,
      # which would take the attempt supervisor down with the offending
      # process and turn a bounded failure into a lost attempt.
      def scope_properties(memory_max:, memory_swap_max:, systemd_version:)
        return [] if memory_max == false || memory_max.nil?

        properties = [ "--property=MemoryMax=#{memory_max}" ]
        unless memory_swap_max == false || memory_swap_max.nil?
          properties << "--property=MemorySwapMax=#{memory_swap_max}"
        end
        if systemd_version.to_i >= SCOPE_OOM_POLICY_MIN_SYSTEMD
          properties << "--property=OOMPolicy=continue"
        end
        properties
      end

      # Leading integer of `systemd-run --version` ("systemd 262 (262.1-1)"),
      # or nil when the binary cannot report one.
      def systemd_version(systemd_run)
        output, status = Open3.capture2e(systemd_run, "--version")
        return nil unless status.success?

        output[/\Asystemd (\d+)/, 1]&.to_i
      rescue SystemCallError
        nil
      end

      # Cumulative kernel OOM kills inside the current process's cgroup v2
      # (`memory.events` `oom_kill`). Nil when unavailable (cgroup v1, not
      # Linux, or no memory controller), so callers only classify when the
      # kernel actually reported a kill.
      def oom_kill_count(proc_cgroup: "/proc/self/cgroup", cgroup_root: "/sys/fs/cgroup")
        line = File.foreach(proc_cgroup).find { |entry| entry.start_with?("0::") }
        return nil unless line

        events = File.join(cgroup_root, line.chomp.delete_prefix("0::"), "memory.events")
        File.foreach(events) do |entry|
          key, value = entry.split
          return Integer(value) if key == "oom_kill"
        end
        nil
      rescue SystemCallError, ArgumentError
        nil
      end
    end
  end
end
