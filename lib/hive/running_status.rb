require "json"
require "set"
require "time"
require "yaml"

require "hive/daemon/status_report"
require "hive/lock"
require "hive/pid_file"
require "hive/stages"
require "hive/task_meta"
require "hive/terminal_text"
require "hive/workflows"

module Hive
  # Dedicated, bounded producer for clients that need daemon health plus the
  # tasks with a process that is alive right now. It deliberately does not
  # build the complete status graph or read task history/conditions.
  class RunningStatus
    MAX_TASKS = 32
    MAX_OUTPUT_BYTES = 64 * 1024
    MAX_STRING_BYTES = 256
    MAX_LOCK_BYTES = Hive::RuntimeControlPlane::TaskLeaseRepository::MAX_PAYLOAD_BYTES
    MAX_METADATA_BYTES = 64 * 1024
    MAX_DAEMON_PID_BYTES = 4 * 1024
    MAX_PROJECTS_SCANNED = 256
    MAX_LEASES_SCANNED = 10_000
    class MalformedLock < StandardError; end
    class OversizedFile < MalformedLock; end

    def initialize(daemon_state: nil, daemon_report: nil,
                   runtime_identity: Hive::RuntimeIdentity.new.to_h)
      @daemon_state = daemon_state
      @daemon_report = daemon_report
      @runtime_identity = runtime_identity
    end

    def payload(projects, now: Time.now.utc)
      counters = source_counters(projects.length)
      rows = []
      seen = Set.new
      observed_count = 0

      selected_projects = projects.first(max_projects_scanned)
      counters["projects_omitted"] = projects.length - selected_projects.length
      counters["scan_truncated"] = counters["projects_omitted"].positive?

      each_active_lease_row(selected_projects, counters) do |project, row|
        identity = [ project["name"].to_s, row.fetch("slug") ]
        next unless seen.add?(identity)

        observed_count += 1
        retain_row(rows, row)
      end

      rows.sort_by! { |row| row.values_at("project", "slug", "stage") }
      document = build_payload(rows, observed_count, counters, now)
      fit_output_bound!(document)
      document
    end

    private

    def each_active_lease_row(projects, counters)
      by_state_root = {}
      projects.each do |project|
        begin
          root = project["hive_state_path"].to_s
          raise Errno::ENOENT if root.empty? || !real_directory?(File.join(root, "stages"))

          expanded = File.expand_path(root)
          by_state_root[expanded] = project
          counters["projects_scanned"] += 1
        rescue SystemCallError, IOError, ArgumentError
          counters["projects_unavailable"] += 1
        end
      end

      leases = Hive::Lock.task_lease_repository.active_leases(
        state_roots: by_state_root.keys, limit: max_leases_scanned + 1
      )
      if leases.size > max_leases_scanned
        counters["scan_truncated"] = true
        leases = leases.first(max_leases_scanned)
      end
      leases.each do |lease|
        # Keep the v1 field name: each SQL lease row is now the source entry.
        counters["filesystem_entries_scanned"] += 1
        counters["tasks_scanned"] += 1
        if lease.fetch(:malformed)
          counters["malformed_locks"] += 1
          next
        end
        project = by_state_root[File.expand_path(lease.fetch(:state_root_path))]
        next unless project

        folder = File.expand_path(lease.fetch(:observed_path))
        stage = File.basename(File.dirname(folder))
        slug = lease.fetch(:task_slug)
        unless folder.start_with?("#{File.expand_path(project.fetch('hive_state_path'))}/stages/") &&
               File.basename(folder) == slug && Hive::Workflows.stage_dir?(stage) &&
               real_directory?(folder)
          counters["transition_skips"] += 1
          next
        end
        begin
          row = live_row(project, stage, slug, folder, lease.fetch(:payload))
          row ? yield(project, row) : counters["stale_locks"] += 1
        rescue MalformedLock
          counters["malformed_locks"] += 1
        end
      end
    rescue Hive::RuntimeControlPlane::Error, SystemCallError, IOError, ArgumentError
      counters["projects_unavailable"] += by_state_root&.size.to_i
    end

    def live_row(project, stage, folder_slug, task_folder, lock)
      runner_pid = lock["pid"]
      raise MalformedLock unless runner_pid.is_a?(Integer) && runner_pid.positive?

      task_lock_alive = Hive::PidFile.identity_alive?(
        runner_pid, recorded_start_time: lock["process_start_time"], require_start_time: true
      )
      raw_agent_pid = lock["claude_pid"]
      agent_pid_alive = if raw_agent_pid.nil?
        nil
      elsif raw_agent_pid.is_a?(Integer) && raw_agent_pid.positive?
        Hive::PidFile.identity_alive?(
          raw_agent_pid, recorded_start_time: lock["claude_pid_start_time"],
          require_start_time: true
        )
      else
        false
      end
      return nil unless task_lock_alive || agent_pid_alive

      metadata_status, metadata = read_metadata(task_folder)
      source = if task_lock_alive && agent_pid_alive
        "task_lock_and_agent_pid"
      elsif task_lock_alive
        "task_lock"
      else
        "agent_pid"
      end

      {
        "project" => bounded_string(project["name"]),
        "slug" => bounded_string(folder_slug),
        "display_name" => bounded_nullable_string(metadata["display_name"]),
        "stage" => bounded_string(stage),
        "workflow" => bounded_nullable_string(metadata["workflow"]),
        "status" => "running",
        "marker" => nil,
        "action" => Hive::Schemas::TaskActionKind::AGENT_RUNNING,
        "metadata_status" => metadata_status,
        "liveness" => {
          "state" => "running",
          "running" => true,
          "source" => source,
          "task_lock_alive" => task_lock_alive,
          "agent_pid_alive" => agent_pid_alive,
          "runner_pid" => task_lock_alive ? runner_pid : nil,
          "agent_pid" => agent_pid_alive ? raw_agent_pid : nil
        }
      }
    end

    def read_metadata(task_folder)
      path = Hive::TaskMeta.path(task_folder)
      raw = bounded_file_read(path, MAX_METADATA_BYTES)
      parsed = YAML.safe_load(raw)
      return [ "absent", {} ] if parsed.nil?
      return [ "invalid", {} ] unless parsed.is_a?(Hash)

      [
        "ok",
        {
          "display_name" => scalar_string(parsed["display_name"] || parsed[:display_name]),
          "workflow" => scalar_string(parsed["workflow"] || parsed[:workflow])
        }
      ]
    rescue OversizedFile
      [ "too_large", {} ]
    rescue MalformedLock
      [ "unreadable", {} ]
    rescue Psych::Exception, SystemStackError, NoMemoryError
      [ "invalid", {} ]
    rescue Errno::ENOENT
      raise unless real_directory?(task_folder)

      [ "absent", {} ]
    rescue SystemCallError, IOError
      [ "unreadable", {} ]
    end

    def bounded_file_read(path, max_bytes)
      flags = File::RDONLY
      nofollow = File.const_defined?(:NOFOLLOW)
      flags |= File::NOFOLLOW if nofollow
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
      File.open(path, flags) do |file|
        stat = file.stat
        raise MalformedLock unless stat.file?
        raise OversizedFile if stat.size > max_bytes
        unless nofollow
          path_stat = File.lstat(path)
          raise MalformedLock if path_stat.symlink? ||
                                 path_stat.dev != stat.dev || path_stat.ino != stat.ino
        end

        raw = file.read(max_bytes + 1)
        raise OversizedFile if raw.bytesize > max_bytes

        raw
      end
    end

    def build_payload(rows, observed_count, counters, now)
      state = resolved_daemon_state
      omitted_count = observed_count - rows.length
      incomplete_source = counters.values_at(
        "projects_unavailable", "malformed_locks", "transition_skips"
      ).any?(&:positive?)
      scan_truncated = counters.fetch("scan_truncated")
      {
        "schema" => "hive-running-status",
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-running-status"),
        "ok" => true,
        "runtime" => runtime_identity_for(state),
        "generated_at" => now.iso8601(6),
        "daemon" => daemon_payload(state),
        "complete" => !incomplete_source && !scan_truncated && omitted_count.zero?,
        "count" => rows.length,
        "observed_count" => observed_count,
        "observed_count_exact" => !scan_truncated,
        "truncated" => scan_truncated || omitted_count.positive?,
        "omitted_count" => omitted_count,
        "omitted_count_exact" => !scan_truncated,
        "limits" => {
          "max_tasks" => MAX_TASKS,
          "max_output_bytes" => MAX_OUTPUT_BYTES,
          "max_string_bytes" => MAX_STRING_BYTES,
          "max_lock_bytes" => MAX_LOCK_BYTES,
          "max_metadata_bytes" => MAX_METADATA_BYTES,
          "max_daemon_pid_bytes" => MAX_DAEMON_PID_BYTES,
          "max_projects_scanned" => max_projects_scanned,
          "max_filesystem_entries_scanned" => max_leases_scanned
        },
        "source" => counters,
        "tasks" => rows
      }
    end

    def resolved_daemon_state
      @daemon_state || daemon_report.running_state(
        max_pid_bytes: MAX_DAEMON_PID_BYTES,
        require_start_time: true
      )
    end

    def runtime_identity_for(state)
      if state.fetch(:running) == true
        return Hive::RuntimeIdentity.parse(state[:runtime]) || Hive::RuntimeIdentity.unknown
      end
      return Hive::RuntimeIdentity.unknown if state[:runtime_observable] == false

      @runtime_identity
    end

    def daemon_payload(state)
      running = state.fetch(:running) == true
      {
        "running" => running,
        "pid" => running ? state[:pid] : nil,
        "uptime_sec" => running ? state[:uptime_sec] : nil
      }
    end

    def fit_output_bound!(document)
      while JSON.generate(document).bytesize + 1 > MAX_OUTPUT_BYTES && document.fetch("tasks").any?
        document.fetch("tasks").pop
        document["count"] = document.fetch("tasks").length
        document["omitted_count"] = document.fetch("observed_count") - document.fetch("count")
        document["truncated"] = true
        document["complete"] = false
      end
      raise "hive-running-status base document exceeds #{MAX_OUTPUT_BYTES} bytes" if
        JSON.generate(document).bytesize + 1 > MAX_OUTPUT_BYTES
    end

    def source_counters(projects_total)
      {
        "projects_total" => projects_total,
        "projects_scanned" => 0,
        "projects_omitted" => 0,
        "projects_unavailable" => 0,
        "filesystem_entries_scanned" => 0,
        "tasks_scanned" => 0,
        "malformed_locks" => 0,
        "stale_locks" => 0,
        "transition_skips" => 0,
        "scan_truncated" => false
      }
    end

    def retain_row(rows, row)
      rows << row
      rows.sort_by! { |candidate| candidate.values_at("project", "slug", "stage") }
      rows.pop if rows.length > MAX_TASKS
    end

    def daemon_report
      @daemon_report ||= Hive::Daemon::StatusReport.new
    end

    def max_projects_scanned = MAX_PROJECTS_SCANNED

    def max_leases_scanned = MAX_LEASES_SCANNED

    def real_directory?(path)
      stat = File.lstat(path)
      stat.directory? && !stat.symlink?
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def scalar_string(value)
      value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
    end

    def bounded_nullable_string(value)
      value.nil? ? nil : bounded_string(value)
    end

    def bounded_string(value)
      string = Hive::TerminalText.escape(value)
      return string if string.bytesize <= MAX_STRING_BYTES

      prefix = string.byteslice(0, MAX_STRING_BYTES - 3).scrub("")
      "#{prefix}…"
    end
  end
end
