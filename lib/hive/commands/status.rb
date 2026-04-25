require "time"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"

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
        error: "⚠"
      }.freeze
      STAGE_ORDER = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done].freeze

      def call
        projects = Hive::Config.registered_projects
        if projects.empty?
          puts "(no projects registered; run `hive init <path>`)"
          return
        end

        projects.each do |project|
          render_project(project)
        end
      end

      def render_project(project)
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

        rows = collect_rows(hive_state)
        puts project["name"]
        if rows.empty?
          puts "  no active tasks"
          return
        end

        STAGE_ORDER.each do |stage|
          stage_rows = rows.select { |r| r[:stage] == stage }
          next if stage_rows.empty?

          puts "  #{stage}/"
          stage_rows.sort_by { |r| -r[:mtime].to_i }.each do |r|
            puts "    #{r[:icon]} #{r[:slug].ljust(36)} #{r[:state_label].ljust(28)} #{r[:age]}"
          end
        end
      end

      def collect_rows(hive_state)
        rows = []
        STAGE_ORDER.each do |stage|
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
            rows << {
              stage: stage,
              slug: slug,
              icon: icon,
              state_label: state_label,
              mtime: mtime,
              age: humanise_age(mtime)
            }
          end
        end
        rows
      end

      def decorate(_task, marker)
        if marker.name == :agent_working
          pid = marker.attrs["claude_pid"] || marker.attrs["pid"]
          if pid && pid_alive?(pid.to_i)
            ["🤖", "agent_working pid=#{pid}"]
          else
            ["⚠", "stale lock pid=#{pid}"]
          end
        else
          [ICON.fetch(marker.name, "·"), label_for(marker)]
        end
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
