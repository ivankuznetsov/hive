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
    MAX_LOCK_BYTES = 16 * 1024
    MAX_METADATA_BYTES = 64 * 1024
    MAX_DAEMON_PID_BYTES = 4 * 1024
    MAX_PROJECTS_SCANNED = 256
    MAX_FILESYSTEM_ENTRIES_SCANNED = 10_000
    class MalformedLock < StandardError; end
    class OversizedFile < MalformedLock; end
    class ScanLimitReached < StandardError; end

    def initialize(daemon_state: nil, daemon_report: nil)
      @daemon_state = daemon_state
      @daemon_report = daemon_report
    end

    def payload(projects, now: Time.now.utc)
      counters = source_counters(projects.length)
      rows = []
      seen = Set.new
      observed_count = 0

      selected_projects = projects.first(max_projects_scanned)
      counters["projects_omitted"] = projects.length - selected_projects.length
      counters["scan_truncated"] = counters["projects_omitted"].positive?

      begin
        selected_projects.sort_by { |project| project["name"].to_s }.each do |project|
          each_project_row(project, counters) do |row|
            identity = [ project["name"].to_s, row.fetch("slug") ]
            next unless seen.add?(identity)

            observed_count += 1
            retain_row(rows, row)
          end
        end
      rescue ScanLimitReached
        counters["scan_truncated"] = true
      end

      rows.sort_by! { |row| row.values_at("project", "slug", "stage") }
      document = build_payload(rows, observed_count, counters, now)
      fit_output_bound!(document)
      document
    end

    private

    def each_project_row(project, counters)
      hive_state = project["hive_state_path"].to_s
      if hive_state.empty?
        counters["projects_unavailable"] += 1
        return
      end
      stages_root = File.join(hive_state, "stages")
      unless real_directory?(stages_root)
        counters["projects_unavailable"] += 1
        return
      end

      counters["projects_scanned"] += 1
      Dir.each_child(stages_root) do |stage|
        consume_filesystem_entry!(counters)
        next unless Hive::Workflows.stage_dir?(stage)

        stage_folder = File.join(stages_root, stage)
        next unless real_directory?(stage_folder)

        Dir.each_child(stage_folder) do |slug|
          consume_filesystem_entry!(counters)
          next unless Hive::Stages.task_slug?(slug)

          task_folder = File.join(stage_folder, slug)
          next unless real_directory?(task_folder)

          counters["tasks_scanned"] += 1
          lock_path = File.join(task_folder, ".lock")

          begin
            lock = read_lock_payload(lock_path)
            row = live_row(project, stage, slug, task_folder, lock)
            if row
              yield row
            else
              counters["stale_locks"] += 1
            end
          rescue MalformedLock
            counters["malformed_locks"] += 1
          rescue Errno::ENOENT
            # A task can move stages atomically between directory enumeration
            # and its bounded lock/metadata reads. It will appear at the new
            # location on this or the next invocation.
            counters["transition_skips"] += 1 unless real_directory?(task_folder)
          rescue SystemCallError, IOError
            counters["malformed_locks"] += 1
          end
        end
      end
    rescue SystemCallError, IOError, ArgumentError
      counters["projects_unavailable"] += 1
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
        "action" => "agent_running",
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

    def read_lock_payload(lock_path)
      raw = bounded_file_read(lock_path, MAX_LOCK_BYTES)
      lock = YAML.safe_load(raw, permitted_classes: [ Time ]) || {}
      raise MalformedLock unless lock.is_a?(Hash)

      lock
    rescue Psych::Exception
      raise MalformedLock
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
    rescue Psych::Exception
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
      omitted_count = observed_count - rows.length
      incomplete_source = counters.values_at(
        "projects_unavailable", "malformed_locks", "transition_skips"
      ).any?(&:positive?)
      scan_truncated = counters.fetch("scan_truncated")
      {
        "schema" => "hive-running-status",
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-running-status"),
        "ok" => true,
        "generated_at" => now.iso8601(6),
        "daemon" => daemon_payload,
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
          "max_filesystem_entries_scanned" => max_filesystem_entries_scanned
        },
        "source" => counters,
        "tasks" => rows
      }
    end

    def daemon_payload
      state = @daemon_state || daemon_report.running_state(max_pid_bytes: MAX_DAEMON_PID_BYTES)
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

    def consume_filesystem_entry!(counters)
      raise ScanLimitReached if
        counters.fetch("filesystem_entries_scanned") >= max_filesystem_entries_scanned

      counters["filesystem_entries_scanned"] += 1
    end

    def daemon_report
      @daemon_report ||= Hive::Daemon::StatusReport.new
    end

    def max_projects_scanned = MAX_PROJECTS_SCANNED

    def max_filesystem_entries_scanned = MAX_FILESYSTEM_ENTRIES_SCANNED

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
