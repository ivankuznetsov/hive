require "json"
require "time"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/stages"
require "hive/task_action"

module Hive
  module Commands
    class Status
      ICON = {
        none: "·",
        waiting: "⏸",
        complete: "✓",
        agent_working: "🤖",
        execute_waiting: "⏸",
        execute_complete: "✓",
        execute_stale: "⚠",
        review_working: "🤖",
        review_waiting: "⏸",
        review_ci_stale: "⚠",
        review_stale: "⚠",
        review_complete: "✓",
        review_error: "⚠",
        error: "⚠"
      }.freeze

      def initialize(json: false)
        @json = json
      end

      def call
        projects = Hive::Config.registered_projects
        if @json
          puts JSON.generate(json_payload(projects))
          return
        end

        if projects.empty?
          puts "(no projects registered; run `hive init <path>`)"
          return
        end

        projects.each do |project|
          render_project(project, project_count: projects.size)
        end
      end

      # Stable schema for agent / wrapper consumption. Adding new keys is
      # non-breaking; removing or renaming keys must bump a documented
      # version. `tasks[].marker` is the lowercased symbol name as a string;
      # `tasks[].attrs` is the marker's attribute map.
      def json_payload(projects)
        {
          "schema" => "hive-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
          "generated_at" => Time.now.utc.iso8601,
          "projects" => projects.map { |p| project_payload(p, project_count: projects.size) }
        }
      end

      def project_payload(project, project_count:)
        path = project["path"]
        hive_state = project["hive_state_path"]
        base = {
          "name" => project["name"],
          "path" => path,
          "hive_state_path" => hive_state
        }
        if !File.directory?(path)
          base.merge("error" => "missing_project_path", "tasks" => [])
        elsif !File.directory?(hive_state)
          base.merge("error" => "not_initialised", "tasks" => [])
        else
          rows = annotate_actions(collect_rows(hive_state), project, project_count)
          base.merge("tasks" => rows.map { |r| task_payload(r) })
        end
      end

      def task_payload(row)
        {
          "stage" => row[:stage],
          "slug" => row[:slug],
          "folder" => row[:folder],
          "state_file" => row[:state_file],
          "marker" => row[:marker_name].to_s,
          "attrs" => row[:marker_attrs],
          "mtime" => row[:mtime].utc.iso8601,
          "age_seconds" => (Time.now - row[:mtime]).to_i,
          "claude_pid" => row[:claude_pid],
          "claude_pid_alive" => row[:claude_pid_alive],
          "action" => row[:action_key],
          "action_label" => row[:action_label],
          "suggested_command" => row[:suggested_command]
        }
      end

      def render_project(project, project_count:)
        path = project["path"]
        unless File.directory?(path)
          puts "#{project['name']}: missing project path #{path}"
          return
        end
        hive_state = project["hive_state_path"]
        unless File.directory?(hive_state)
          puts "#{project['name']}: not initialised (no .hive-state)"
          return
        end

        rows = annotate_actions(collect_rows(hive_state), project, project_count)
        puts project["name"]
        if rows.empty?
          puts "  no active tasks"
          return
        end

        action_labels(rows).each do |label|
          stage_rows = rows.select { |r| r[:action_label] == label }
          next if stage_rows.empty?

          puts "  #{label}"
          stage_rows.sort_by { |r| -r[:mtime].to_i }.each do |r|
            command = r[:suggested_command] || "-"
            puts "    #{r[:icon]} #{r[:slug].ljust(36)} #{r[:state_label].ljust(24)} #{command} #{r[:age]}"
          end
        end
      end

      def collect_rows(hive_state)
        rows = []
        Hive::Stages::DIRS.each do |stage|
          stage_dir = File.join(hive_state, "stages", stage)
          next unless File.directory?(stage_dir)

          Dir[File.join(stage_dir, "*")].each do |entry|
            next unless File.directory?(entry)

            slug = File.basename(entry)
            begin
              task = Hive::Task.new(entry)
            rescue Hive::InvalidTaskPath
              next
            end
            marker = Hive::Markers.current(task.state_file)
            mtime = File.exist?(task.state_file) ? File.mtime(task.state_file) : File.mtime(entry)
            icon, state_label = decorate(task, marker)
            claude_pid = lookup_claude_pid(task)
            rows << {
              stage: stage,
              slug: slug,
              folder: entry,
              state_file: task.state_file,
              task: task,
              marker_name: marker.name,
              marker_attrs: marker.attrs,
              icon: icon,
              state_label: state_label,
              mtime: mtime,
              age: humanise_age(mtime),
              claude_pid: claude_pid,
              claude_pid_alive: claude_pid ? pid_alive?(claude_pid.to_i) : nil
            }
          end
        end
        rows
      end

      def decorate(task, marker)
        if marker.name == :agent_working
          # Marker only carries the hive runner PID; the claude subprocess PID
          # is recorded in the per-task .lock file by Hive::Agent.
          pid = lookup_claude_pid(task) || marker.attrs["pid"]
          if pid && pid_alive?(pid.to_i)
            [ "🤖", "agent_working pid=#{pid}" ]
          else
            [ "⚠", "stale lock pid=#{pid}" ]
          end
        else
          [ ICON.fetch(marker.name, "·"), label_for(marker) ]
        end
      end

      ACTION_LABEL_ORDER = [
        "Ready to brainstorm",
        "Needs your input",
        "Ready to plan",
        "Ready to develop",
        "Review findings",
        "Needs recovery",
        "Ready for PR",
        "Ready to archive",
        "Archived",
        "Error"
      ].freeze

      def annotate_actions(rows, project, project_count)
        slug_counts = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[:slug]] += 1 }
        rows.map do |row|
          action = Hive::TaskAction.for(
            row[:task],
            marker_from_row(row),
            project_name: project["name"],
            project_count: project_count,
            stage_collision: slug_counts[row[:slug]] > 1
          )
          row.merge(
            action_key: action.key,
            action_label: action.label,
            suggested_command: action.command
          )
        end
      end

      def marker_from_row(row)
        Hive::Markers::State.new(name: row[:marker_name], attrs: row[:marker_attrs], raw: nil)
      end

      def action_labels(rows)
        labels = rows.map { |row| row[:action_label] }.uniq
        labels.sort_by { |label| ACTION_LABEL_ORDER.index(label) || ACTION_LABEL_ORDER.length }
      end

      def label_for(marker)
        attrs = marker.attrs.map { |k, v| "#{k}=#{v}" }.join(" ")
        attrs.empty? ? marker.name.to_s : "#{marker.name} #{attrs}"
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def lookup_claude_pid(task)
        lock_file = File.join(task.folder, ".lock")
        return nil unless File.exist?(lock_file)

        data = YAML.safe_load(File.read(lock_file)) || {}
        data.is_a?(Hash) ? data["claude_pid"] : nil
      rescue StandardError
        nil
      end

      def humanise_age(mtime)
        seconds = (Time.now - mtime).to_i
        if seconds < 60
          "#{seconds}s ago"
        elsif seconds < 3600
          "#{seconds / 60}m ago"
        elsif seconds < 86_400
          "#{seconds / 3600}h ago"
        else
          "#{seconds / 86_400}d ago"
        end
      end
    end
  end
end
