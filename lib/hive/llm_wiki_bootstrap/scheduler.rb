require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "set"
require "hive/llm_wiki_bootstrap/scripts"

module Hive
  module LlmWikiBootstrap
    module Scheduler
      module_function

      UNIT_PREFIX = "llm-wiki-".freeze

      def install(project_root)
        return if scheduler_disabled?

        project_root = scheduled_project_root(project_root)
        return unless project_root

        flock_path = executable_path("flock")
        return unless flock_path

        user_dir = systemd_user_dir
        FileUtils.mkdir_p(user_dir)
        changed, timer_name, service_name = install_root(
          project_root, user_dir, flock_path, enable_timer: true
        )
        changed_services = changed ? [ service_name ] : []
        reconcile_existing!(
          initial_change: changed,
          additional_timers: [ timer_name ],
          additional_services_to_stop: changed_services
        )
      rescue StandardError => e
        warn "hive: warning: could not activate LLM-wiki scheduler: #{e.message}"
      end

      # Upgrade old path-keyed Hive units in place. This is intentionally safe
      # to run at CLI startup: unchanged units do no I/O beyond inspection, and
      # only units that point at Hive-managed projects (or dead paths) migrate.
      def reconcile_existing!(initial_change: false, additional_timers: [], additional_services_to_stop: [])
        return if scheduler_disabled?

        user_dir = systemd_user_dir
        return unless Dir.exist?(user_dir)

        flock_path = executable_path("flock")
        pending_marker = File.join(user_dir, ".hive-llm-wiki-reconcile-pending")
        recovering = File.exist?(pending_marker)
        changed = initial_change || recovering
        canonical_timers = Set.new(additional_timers)
        services_to_stop = Set.new(additional_services_to_stop)
        obsolete = []

        Dir[File.join(user_dir, "#{UNIT_PREFIX}*.service")].sort.each do |service_path|
          contents = File.read(service_path)
          next unless managed_service?(contents)

          configured_root = working_directory(contents)
          if configured_root && Dir.exist?(configured_root)
            next unless hive_owned_service?(contents, configured_root)

            canonical_root = scheduled_project_root(configured_root)
            unless canonical_root && flock_path
              obsolete << unit_paths(user_dir, File.basename(service_path))
              next
            end

            legacy_timer = File.basename(service_path).sub(/\.service\z/, ".timer")
            enabled = timer_enabled?(user_dir, legacy_timer)
            unit_changed, timer_name, canonical_service = install_root(
              canonical_root, user_dir, flock_path, enable_timer: enabled
            )
            changed ||= unit_changed
            canonical_timers << timer_name if enabled
            services_to_stop << canonical_service if unit_changed || recovering
            obsolete << unit_paths(user_dir, File.basename(service_path)) \
              unless File.basename(service_path) == canonical_service
          elsif configured_root.nil? || !Dir.exist?(configured_root)
            next unless hive_managed_marker?(contents) || known_hive_test_root?(configured_root)

            obsolete << unit_paths(user_dir, File.basename(service_path))
          end
        rescue Errno::ENOENT, Errno::EACCES
          next
        end

        # A service may have been deleted independently. Only remove orphaned
        # timers carrying Hive's explicit marker; legacy timer-only files are
        # ambiguous and belong to their original installer until proven
        # otherwise.
        Dir[File.join(user_dir, "#{UNIT_PREFIX}*.timer")].sort.each do |timer_path|
          service_path = timer_path.sub(/\.timer\z/, ".service")
          next if File.exist?(service_path)

          contents = File.read(timer_path)
          next unless hive_managed_marker?(contents)

          obsolete.concat(timer_paths(user_dir, File.basename(timer_path)))
        rescue Errno::ENOENT, Errno::EACCES
          next
        end

        obsolete.flatten!(1)
        obsolete.uniq!
        obsolete_timers = obsolete.filter_map do |path|
          next unless path.end_with?(".timer") && !path.include?("timers.target.wants")

          timer_name = File.basename(path)
          timer_name if File.exist?(path) || timer_enabled?(user_dir, timer_name)
        end
        obsolete_services = obsolete.filter_map do |path|
          File.basename(path) if path.end_with?(".service")
        end
        planned_change = changed || !obsolete.empty?
        return unless planned_change

        write_if_changed(pending_marker, "pending\n")
        obsolete_timers.each { |name| run_systemctl!("disable", "--now", name) }
        services_to_stop.merge(obsolete_services)
        services_to_stop.each { |name| run_systemctl!("stop", name) }
        obsolete.each do |path|
          next unless File.exist?(path) || File.symlink?(path)

          FileUtils.rm_f(path)
          changed = true
        end

        run_systemctl!("daemon-reload")
        canonical_timers.sort.each { |name| run_systemctl!("start", name) }
        FileUtils.rm_f(pending_marker)
      end

      def install_root(project_root, user_dir, flock_path, enable_timer:)
        slug = raw_project_slug(project_root)
        service_name = "#{UNIT_PREFIX}#{slug}.service"
        timer_name = "#{UNIT_PREFIX}#{slug}.timer"
        refresh_script, runtime_changed = deploy_shared_runtime(project_root, service_name: service_name)
        service_changed = write_if_changed(
          File.join(user_dir, service_name),
          systemd_service(
            project_root,
            service_name,
            flock_path: flock_path,
            refresh_script: refresh_script
          )
        )
        changed = runtime_changed || service_changed
        changed = write_if_changed(
          File.join(user_dir, timer_name),
          systemd_timer(service_name)
        ) || changed
        changed = enable_timer_symlink(user_dir, timer_name) || changed if enable_timer
        [ changed, timer_name, service_name ]
      end

      def deploy_shared_runtime(project_root, service_name:)
        shared_dir = File.join(Hive::LlmWikiBootstrap.git_common_dir(project_root), "llm-wiki")
        refresh_script = File.join(shared_dir, "post-commit-refresh.sh")
        changed = write_if_changed(
          refresh_script,
          Hive::LlmWikiBootstrap::Scripts.post_commit_refresh,
          mode: 0o755
        )
        changed = write_if_changed(
          File.join(shared_dir, "compile-log.sh"),
          Hive::LlmWikiBootstrap::Scripts.compile_log,
          mode: 0o755
        ) || changed
        config = File.binread(File.join(project_root, ".llm-wiki", "config.json"))
        changed = write_if_changed(File.join(shared_dir, "config.json"), config) || changed
        changed = write_if_changed(File.join(shared_dir, "scheduler-service"), "#{service_name}\n") || changed
        [ refresh_script, changed ]
      end

      def write_if_changed(path, contents, mode: nil)
        if File.exist?(path) && File.binread(path) == contents.b
          if mode && (File.stat(path).mode & 0o777) != mode
            File.chmod(mode, path)
            return true
          end
          return false
        end

        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.binwrite(tmp, contents)
        File.chmod(mode, tmp) if mode
        File.rename(tmp, path)
        true
      ensure
        FileUtils.rm_f(tmp) if defined?(tmp) && tmp
      end

      def enable_timer_symlink(user_dir, timer_name)
        wants_dir = File.join(user_dir, "timers.target.wants")
        link_path = File.join(wants_dir, timer_name)
        FileUtils.mkdir_p(wants_dir)
        return false if File.symlink?(link_path) && File.readlink(link_path) == File.join("..", timer_name)

        FileUtils.rm_f(link_path)
        File.symlink(File.join("..", timer_name), link_path)
        true
      end

      def systemd_service(project_root, service_name, flock_path: executable_path("flock"), refresh_script: nil)
        raise ArgumentError, "flock is required for the LLM-wiki scheduler" unless flock_path

        refresh_script ||= File.join(project_root, ".llm-wiki", "refresh-wiki.sh")
        encoded_refresh_script = systemd_path(refresh_script)
        encoded_project_root = systemd_path(project_root)

        <<~UNIT
          [Unit]
          Description=Refresh LLM wiki for #{service_name.sub(/\.service\z/, "")}
          X-HiveManaged=yes
          ConditionFileIsExecutable=#{encoded_refresh_script}

          [Service]
          Type=oneshot
          Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1
          WorkingDirectory=#{encoded_project_root}
          ExecStart=#{systemd_path(flock_path)} --nonblock --conflict-exit-code 0 %t/llm-wiki-refresh.lock #{encoded_refresh_script} --project #{encoded_project_root} --drain
          # A scheduled drain may run three batches. Each batch permits a
          # 30-minute agent plus two independently bounded 15-minute QMD
          # phases, so the outer service must outlive that bounded worst case.
          TimeoutStartSec=4h
          MemoryMax=4G
          MemorySwapMax=0
        UNIT
      end

      def systemd_timer(service_name)
        <<~UNIT
          [Unit]
          Description=Run #{service_name} daily
          X-HiveManaged=yes

          [Timer]
          OnActiveSec=10min
          OnUnitActiveSec=1d
          RandomizedDelaySec=6h
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

      def decode_systemd_path(path)
        path.gsub("\\x22", "\"")
            .gsub("\\x20", " ")
            .gsub("\\x5c", "\\")
      end

      def project_slug(project_root)
        project_root = scheduled_project_root(project_root) || File.expand_path(project_root)
        raw_project_slug(project_root)
      end

      def raw_project_slug(project_root)
        base = File.basename(project_root).gsub(/[^A-Za-z0-9_.-]/, "-")
        "#{base}-#{::Digest::SHA256.hexdigest(project_root)[0, 8]}"
      end

      # A repository owns one timer. Linked worktrees share the primary
      # checkout's unit and continue to contribute through the common
      # post-commit hook instead of creating path-specific schedulers. Resolve
      # failures are fail-closed so a transient Git problem cannot recreate a
      # timer for every linked checkout.
      def scheduled_project_root(project_root)
        expanded_root = File.expand_path(project_root)
        out, _err, status = Open3.capture3(
          "git", "-C", expanded_root, "worktree", "list", "--porcelain", "-z"
        )
        return unless status.success?

        record = out.split("\0").find { |field| field.start_with?("worktree ") }
        path = record&.delete_prefix("worktree ")
        return if path.nil? || path.empty?

        File.expand_path(path)
      rescue Errno::ENOENT
        nil
      end

      def managed_service?(contents)
        hive_managed_marker?(contents) || (
          contents.include?("Description=Refresh LLM wiki for llm-wiki-") &&
          contents.match?(%r{^ExecStart=.*?/\.llm-wiki/refresh-wiki\.sh(?:\s|$)})
        )
      end

      def hive_managed_marker?(contents)
        contents.match?(/^X-HiveManaged=yes$/)
      end

      def hive_owned_service?(contents, project_root)
        hive_managed_marker?(contents) || hive_managed_root?(project_root)
      end

      def known_hive_test_root?(project_root)
        return false unless project_root

        expanded = File.expand_path(project_root)
        return true if [
          "/tmp/hive-test", "/tmp/hive-web-test",
          "/var/tmp/hive-test", "/var/tmp/hive-web-test"
        ].any? { |prefix| expanded.start_with?(prefix) }

        [ "/tmp/", "/var/tmp/" ].any? do |prefix|
          next false unless expanded.start_with?(prefix)

          top_level = expanded.delete_prefix(prefix).split("/", 2).first
          top_level.match?(/\Ae2e-runs?\d{8}-\d+-[a-z0-9]+\z/)
        end
      end

      def working_directory(contents)
        encoded = contents[/^WorkingDirectory=(.+)$/, 1]
        encoded && decode_systemd_path(encoded)
      end

      def hive_managed_root?(project_root)
        config_path = File.join(project_root, ".llm-wiki", "config.json")
        JSON.parse(File.read(config_path))["created_by"] == "hive"
      rescue Errno::ENOENT, JSON::ParserError, TypeError
        false
      end

      def unit_paths(user_dir, service_name)
        timer_name = service_name.sub(/\.service\z/, ".timer")
        [
          File.join(user_dir, service_name),
          File.join(user_dir, timer_name),
          File.join(user_dir, "timers.target.wants", timer_name)
        ]
      end

      def timer_paths(user_dir, timer_name)
        [
          File.join(user_dir, timer_name),
          File.join(user_dir, "timers.target.wants", timer_name)
        ]
      end

      def timer_enabled?(user_dir, timer_name)
        File.symlink?(File.join(user_dir, "timers.target.wants", timer_name))
      end

      def executable_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return File.expand_path(candidate) if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def run_systemctl(*args)
        return true if ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] == "1"

        _out, _err, status = Open3.capture3(
          user_systemd_environment, "systemctl", "--user", *args
        )
        status.success?
      rescue Errno::ENOENT
        false
      end

      # Git hooks and other headless callers often retain access to the user
      # bus but not the interactive shell variables that identify it. Restore
      # only the standard per-user socket environment; a missing socket keeps
      # systemctl's normal failure semantics and the durable reconcile marker.
      def user_systemd_environment
        runtime_dir = ENV["XDG_RUNTIME_DIR"]
        runtime_dir = "/run/user/#{Process.uid}" if runtime_dir.nil? || runtime_dir.empty?
        bus_path = File.join(runtime_dir, "bus")
        return {} unless File.socket?(bus_path)

        bus_address = ENV["DBUS_SESSION_BUS_ADDRESS"]
        bus_address = "unix:path=#{bus_path}" if bus_address.nil? || bus_address.empty?

        {
          "XDG_RUNTIME_DIR" => runtime_dir,
          "DBUS_SESSION_BUS_ADDRESS" => bus_address
        }
      end

      def run_systemctl!(*args)
        return if run_systemctl(*args)

        raise "systemctl --user #{args.join(' ')} failed"
      end

      def scheduler_disabled?
        ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] == "1" ||
          !RbConfig::CONFIG["host_os"].include?("linux")
      end

      def systemd_user_dir
        File.expand_path("~/.config/systemd/user")
      end
    end
  end
end
