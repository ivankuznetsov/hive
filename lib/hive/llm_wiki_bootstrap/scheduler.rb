require "digest"
require "fileutils"
require "rbconfig"

module Hive
  module LlmWikiBootstrap
    module Scheduler
      module_function

      def install(project_root)
        return if ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] == "1"
        return unless RbConfig::CONFIG["host_os"].include?("linux")

        slug = project_slug(project_root)
        user_dir = File.expand_path("~/.config/systemd/user")
        service_name = "llm-wiki-#{slug}.service"
        timer_name = "llm-wiki-#{slug}.timer"
        FileUtils.mkdir_p(user_dir)
        Hive::LlmWikiBootstrap.write_file(File.join(user_dir, service_name), systemd_service(project_root, service_name))
        Hive::LlmWikiBootstrap.write_file(File.join(user_dir, timer_name), systemd_timer(service_name))
        enable_timer_symlink(user_dir, timer_name)
      end

      def enable_timer_symlink(user_dir, timer_name)
        wants_dir = File.join(user_dir, "timers.target.wants")
        link_path = File.join(wants_dir, timer_name)
        FileUtils.mkdir_p(wants_dir)
        return if File.exist?(link_path) || File.symlink?(link_path)

        File.symlink(File.join("..", timer_name), link_path)
      end

      def systemd_service(project_root, service_name)
        <<~UNIT
          [Unit]
          Description=Refresh LLM wiki for #{service_name.sub(/\.service\z/, "")}

          [Service]
          Type=oneshot
          WorkingDirectory=#{systemd_path(project_root)}
          ExecStart=#{systemd_path(File.join(project_root, ".llm-wiki", "refresh-wiki.sh"))}
          TimeoutStartSec=45min
        UNIT
      end

      def systemd_timer(service_name)
        <<~UNIT
          [Unit]
          Description=Run #{service_name} daily

          [Timer]
          OnBootSec=10min
          OnUnitActiveSec=1d
          Persistent=true
          Unit=#{service_name}

          [Install]
          WantedBy=timers.target
        UNIT
      end

      def systemd_path(path)
        path.gsub("\\", "\\x5c")
            .gsub(" ", "\\x20")
            .gsub("\"", "\\x22")
      end

      def project_slug(project_root)
        base = File.basename(project_root).gsub(/[^A-Za-z0-9_.-]/, "-")
        "#{base}-#{Digest::SHA256.hexdigest(project_root)[0, 8]}"
      end
    end
  end
end
