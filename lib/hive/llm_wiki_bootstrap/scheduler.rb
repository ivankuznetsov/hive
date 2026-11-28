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

      UNIT_KEYS = {
        "Unit" => %w[Description X-HiveManaged X-HivePathEncoding ConditionFileIsExecutable],
        "Service" => %w[Type Environment WorkingDirectory ExecStart TimeoutStartSec MemoryMax MemorySwapMax],
        "Timer" => %w[OnActiveSec OnBootSec OnUnitActiveSec RandomizedDelaySec Persistent Unit],
        "Install" => %w[WantedBy]
      }.freeze
      PATH_ENCODING = "literal-v1".freeze
      PENDING = ".hive-llm-wiki-reconcile-pending".freeze
      Classification = Data.define(:disposition, :encoding, :root, :primary, :protected_services) do
        def initialize(disposition:, encoding: nil, root: nil, primary: nil, protected_services: [])
          super
        end

        def proven?
          %i[current proven_unversioned_literal proven_legacy].include?(disposition)
        end
      end

      # Bootstrap can create or replace the project config. An occupied unit
      # must already have an owner before that evidence changes. The install
      # pass inspects both ends again immediately before applying any writes.
      def bootstrap_allowed?(project_root)
        validate_path!(project_root)
        config = File.join(project_root, ".llm-wiki/config.json")
        return false if entry_type(config) && !hive_managed_root?(project_root)

        path = File.join(systemd_user_dir, service_name(project_root))
        !entry_type(path) || classify_service(path, executable_path("flock")).proven?
      rescue SystemCallError, ArgumentError
        false
      end

      def install(project_root)
        return if scheduler_disabled?

        project_root = File.expand_path(project_root)
        return unless bootstrap_allowed?(project_root)
        primary = scheduled_project_root(project_root)
        return unless primary && executable_path("flock")

        reconcile(primary)
      rescue StandardError => e
        warn "hive: warning: could not activate LLM-wiki scheduler: #{e.message}"
      end

      def reconcile_existing!
        reconcile(nil) unless scheduler_disabled?
      end

      def reconcile(primary)
        dir = systemd_user_dir
        type = entry_type(dir)
        return unless [ nil, "directory" ].include?(type)
        unless type
          # A rejected first install must leave even the unit directory absent.
          return unless primary && Reconciliation.new(dir).prepare(primary)

          FileUtils.mkdir_p(dir)
        end

        # Concurrent Hive startups share the directory inode, including across
        # atomic unit replacements. No lock file is needed on an idle scan.
        File.open(dir) do |directory|
          directory.flock(File::LOCK_EX)
          plan = Reconciliation.new(dir)
          plan.apply if plan.prepare(primary)
        end
      end

      def service_name(root)
        "#{UNIT_PREFIX}#{raw_project_slug(root)}.service"
      end

      def entry_type(path)
        File.lstat(path).ftype
      rescue Errno::ENOENT
        nil
      end

      def install_outputs(root, flock)
        name = service_name(root)
        config = owned_config(root)
        return unless config

        shared = File.join(Hive::LlmWikiBootstrap.git_common_dir(root), "llm-wiki")
        return unless shared_record_agrees?(shared, name)

        runner = File.join(shared, "post-commit-refresh.sh")
        service = systemd_service(root, name, flock_path: flock, refresh_script: runner)
        {
          runner => [ Scripts.post_commit_refresh, 0o755 ],
          File.join(shared, "compile-log.sh") => [ Scripts.compile_log, 0o755 ],
          File.join(shared, "config.json") => [ config, nil ],
          File.join(shared, "scheduler-service") => [ "#{name}\n", nil ],
          File.join(systemd_user_dir, name) => [ service, nil ],
          File.join(systemd_user_dir, name.sub(/\.service\z/, ".timer")) => [ systemd_timer(name), nil ]
        }
      end

      def shared_record_agrees?(shared, name)
        return false unless [ nil, "directory" ].include?(entry_type(shared))

        record = File.join(shared, "scheduler-service")
        case entry_type(record)
        when nil then true
        when "file" then File.binread(record) == "#{name}\n".b
        else false
        end
      end

      # Read only the INI subset emitted by Hive. Keep every identity byte,
      # including whitespace. Unsupported syntax and duplicate assignments
      # cannot establish ownership of a replacement.
      def unit_fields(path)
        raise ArgumentError unless entry_type(path) == "file"
        text = File.binread(path).force_encoding(Encoding::UTF_8)
        raise ArgumentError unless text.valid_encoding? && !text.match?(/[\0\r]/)

        section = nil
        fields = {}
        text.each_line(chomp: true) do |line|
          next if line.empty? || line.start_with?("#", ";")
          raise ArgumentError if line.end_with?("\\")
          if line.match?(/\A\[(Unit|Service|Timer|Install)\]\z/)
            section = line[1...-1]
            next
          end
          key, separator, value = line.partition("=")
          raise ArgumentError unless section && !separator.empty? && UNIT_KEYS.fetch(section).include?(key)

          location = [ section, key ]
          raise ArgumentError if fields.key?(location)

          fields[location] = value
        end
        fields
      end

      def classify_service(path, flock)
        protected_services = []
        fields = unit_fields(path)
        name = File.basename(path)
        description = "Refresh LLM wiki for #{name.delete_suffix('.service')}"
        marker = fields[[ "Unit", "X-HiveManaged" ]]
        version = fields[[ "Unit", "X-HivePathEncoding" ]]
        return Classification.new(disposition: :unowned, encoding: version) unless fields[[ "Unit", "Description" ]] == description
        return Classification.new(disposition: :invalid, encoding: version) unless [ nil, "yes" ].include?(marker) &&
          [ nil, PATH_ENCODING ].include?(version)
        stored = fields.fetch([ "Service", "WorkingDirectory" ])
        candidates = version ? [ stored.gsub("%%", "%") ] : [ stored, decode_legacy_path(stored) ].uniq
        proofs = candidates.filter_map do |root|
          next unless name == service_name(root)
          validate_path!(root)
          next if Dir.exist?(root) && !executable_path("git")
          primary = scheduled_project_root(root) if Dir.exist?(root)
          # A matching basename identifies a possible destination to protect,
          # even when the remaining fields cannot authorize a migration.
          protected_services << service_name(primary) if primary
          common = primary ? Hive::LlmWikiBootstrap.git_common_dir(root) : File.join(root, ".git")
          config = File.join(root, ".llm-wiki/config.json")
          owned = if entry_type(config)
            hive_managed_root?(root)
          else
            !Dir.exist?(root) && known_hive_test_root?(root)
          end
          next unless owned && shared_record_agrees?(File.join(common, "llm-wiki"), service_name(primary || root))

          disposition = service_layout(fields, root, common, flock, version, marker)
          Classification.new(disposition: disposition, encoding: version, root: root, primary: primary) if disposition
        end
        return proofs.first if proofs.one?

        Classification.new(disposition: :ambiguous, encoding: version, protected_services: protected_services)
      rescue SystemCallError, ArgumentError, KeyError
        Classification.new(disposition: :invalid, encoding: version, protected_services: protected_services)
      end

      def service_layout(fields, root, common, flock, version, marker)
        directory = fields.fetch([ "Service", "WorkingDirectory" ])
        command = fields.fetch([ "Service", "ExecStart" ])
        condition = fields[[ "Unit", "ConditionFileIsExecutable" ]]
        local = File.join(root, ".llm-wiki/refresh-wiki.sh")
        runner = File.join(common, "llm-wiki/post-commit-refresh.sh")
        if version
          return :current if marker == "yes" && directory == literal_path(root) && condition == literal_path(runner) &&
            flock && command == flock_command(flock, runner, root)
          return
        end

        if condition.nil?
          return unless marker.nil? && directory == legacy_word(root) && command == legacy_word(local)
        else
          return unless marker == "yes" && flock
          return unless [ runner, local ].any? do |script|
            layout_matches = (directory == root && condition == script) ||
              (directory == legacy_word(root) && condition == legacy_word(script))
            layout_matches && %w[llm-wiki-refresh.lock hive-llm-wiki-refresh.lock].any? do |lock|
              command == "#{legacy_word(flock)} --nonblock --conflict-exit-code 0 %t/#{lock} " \
                "#{legacy_word(script)} --project #{legacy_word(root)} --drain"
            end
          end
        end
        directory == root ? :proven_unversioned_literal : :proven_legacy
      end

      def legacy_word(path)
        path.gsub(/[ "\\]/) { |char| format("\\x%02x", char.ord) }
      end

      def decode_legacy_path(path)
        path.gsub(/\\x(20|22|5c)/) { Regexp.last_match(1).hex.chr }
      end
      private_class_method :legacy_word, :decode_legacy_path

      def compatible_timer?(path, service, orphan: false)
        fields = unit_fields(path)
        return false unless fields[[ "Timer", "Unit" ]] == service

        marker = fields[[ "Unit", "X-HiveManaged" ]]
        description = fields[[ "Unit", "Description" ]]
        return false if description && description != "Run #{service} daily"

        marker == "yes" || (!orphan && marker.nil? && description)
      rescue SystemCallError, ArgumentError
        false
      end

      class Reconciliation
        include Scheduler

        def initialize(dir)
          @dir = dir
          @flock = executable_path("flock")
          @sources = {}
          @destinations = Hash.new { |h, root| h[root] = [] }
          @reserved = Set.new
          @writes = {}
          @links = {}
          @retire = Set.new
          @stop = Set.new
          @start = Set.new
          @unresolved = false
        end

        def prepare(requested_root)
          marker_type = entry_type(File.join(@dir, PENDING))
          return unless [ nil, "file" ].include?(marker_type)
          @recovering = marker_type == "file"

          names = Dir.exist?(@dir) ? Dir.children(@dir).select { |name| name.start_with?(UNIT_PREFIX) } : []
          names.select { |name| name.end_with?(".service") }.sort.each do |name|
            source = classify_service(File.join(@dir, name), @flock)
            @sources[name] = source
            @reserved.merge(source.protected_services)
            if source.proven? && source.primary && @flock
              @destinations[source.primary] << name
            elsif source.proven? && !source.primary && safe_timer?(name)
              @retire << name
            else
              @unresolved = true
            end
          end
          @destinations[requested_root] if requested_root
          @destinations.keys.group_by { |root| service_name(root) }.each do |name, roots|
            vacant_claim = @reserved.add?(name)
            @unresolved = true unless vacant_claim && roots.one? && plan_destination(roots.first, @destinations.fetch(roots.first))
          end
          @retire.subtract(@reserved)
          names.select { |name| name.end_with?(".timer") }.each do |timer|
            name = timer.delete_suffix(".timer") + ".service"
            next if @sources.key?(name) || @reserved.include?(name)
            if safe_timer?(name, orphan: true)
              @retire << name
            else
              @unresolved = true
            end
          end
          # A dangling wants entry is occupied too, even without either unit.
          wants = File.join(@dir, "timers.target.wants")
          if File.directory?(wants)
            @unresolved ||= Dir.children(wants).any? do |name|
              name.start_with?(UNIT_PREFIX) && name.end_with?(".timer") && !names.include?(name)
            end
          end
          @writes.any? || @links.any? || @retire.any? || (@recovering && (!@unresolved || @stop.any?))
        end

        def plan_destination(root, sources)
          name = service_name(root)
          existing = @sources[name]
          return false if existing && !(existing.proven? && existing.root == root)
          return false unless (sources | [ name ]).all? { |source| safe_timer?(source) }

          service, timer, link = unit_paths(@dir, name)
          if existing || entry_type(timer)
            enabled = File.symlink?(link)
          else
            states = sources.map { |source| File.symlink?(unit_paths(@dir, source).last) }.uniq
            return false if states.size > 1
            enabled = states.empty? || states.first
          end

          outputs = install_outputs(root, @flock)
          return false unless outputs
          changes = outputs.select do |path, (contents, mode)|
            type = entry_type(path)
            return false unless [ nil, "file" ].include?(type)

            type.nil? || File.binread(path) != contents.b || (mode && (File.stat(path).mode & 0o777) != mode)
          end
          link_missing = enabled && !File.symlink?(link)
          retiring = sources - [ name ]
          @writes.merge!(changes)
          @links[link] = "../#{File.basename(timer)}" if link_missing
          @retire.merge(retiring)
          changed = !changes.empty? || link_missing
          @stop << File.basename(service) if changed || @recovering
          @start << File.basename(timer) if enabled && (changed || @recovering || !retiring.empty?)
          true
        rescue SystemCallError, ArgumentError
          false
        end

        def safe_timer?(name, orphan: false)
          _, timer, link = unit_paths(@dir, name)
          type = entry_type(timer)
          return false if type && !compatible_timer?(timer, name, orphan: orphan)
          return false unless [ nil, "directory" ].include?(entry_type(File.dirname(link)))

          case entry_type(link)
          when nil then true
          when "link" then type == "file" && File.readlink(link) == "../#{File.basename(timer)}"
          else false
          end
        rescue SystemCallError, ArgumentError
          false
        end

        def apply
          marker = File.join(@dir, PENDING)
          write_if_changed(marker, "pending\n")
          @writes.each { |path, (bytes, mode)| write_if_changed(path, bytes, mode: mode) }
          @links.each do |path, target|
            FileUtils.mkdir_p(File.dirname(path))
            File.symlink(target, path)
          end
          removals = @retire.flat_map do |name|
            service, timer, link = unit_paths(@dir, name)
            Scheduler.run_systemctl!("disable", "--now", File.basename(timer)) if entry_type(timer)
            @stop << name if entry_type(service)
            [ link, timer, service ]
          end
          @stop.sort.each { |name| Scheduler.run_systemctl!("stop", name) }
          removals.each { |path| File.unlink(path) if entry_type(path) }
          Scheduler.run_systemctl!("daemon-reload")
          @start.sort.each { |name| Scheduler.run_systemctl!("start", name) }
          File.unlink(marker)
        end
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

      def systemd_service(project_root, service_name, flock_path: executable_path("flock"), refresh_script: nil)
        raise ArgumentError, "flock is required for the LLM-wiki scheduler" unless flock_path

        refresh_script ||= File.join(project_root, ".llm-wiki", "refresh-wiki.sh")
        [ project_root, refresh_script, flock_path ].each { |path| validate_path!(path) }

        <<~UNIT
          [Unit]
          Description=Refresh LLM wiki for #{service_name.sub(/\.service\z/, "")}
          X-HiveManaged=yes
          X-HivePathEncoding=#{PATH_ENCODING}
          ConditionFileIsExecutable=#{literal_path(refresh_script)}

          [Service]
          Type=oneshot
          Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1
          WorkingDirectory=#{literal_path(project_root)}
          ExecStart=#{flock_command(flock_path, refresh_script, project_root)}
          # A scheduled drain may run three batches. Each batch permits a
          # 30-minute agent plus two independently bounded 15-minute QMD
          # phases, so the outer service must outlive that bounded worst case.
          TimeoutStartSec=4h
          MemoryMax=4G
          MemorySwapMax=0
        UNIT
      end

      def flock_command(flock_path, refresh_script, project_root)
        ":#{command_word(flock_path)} --nonblock --conflict-exit-code 0 %t/llm-wiki-refresh.lock " \
          "#{command_word(refresh_script)} --project #{command_word(project_root)} --drain"
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

      def validate_path!(path)
        unless path.dup.force_encoding(Encoding::UTF_8).valid_encoding? &&
               path.start_with?("/") && !path.match?(/[\x00-\x08\x0a-\x1f\x7f]|[\\ \t]\z/) &&
               File.expand_path(path) == path
          raise ArgumentError, "unrepresentable LLM-wiki scheduler pathname: #{path.inspect}"
        end
      end

      def literal_path(path)
        path.gsub("%", "%%")
      end

      def command_word(path)
        literal_path(path).gsub(/[ \t"'\\]/) { |char| format("\\x%02x", char.ord) }
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
        Hive::LlmWikiBootstrap.primary_worktree_root(File.expand_path(project_root))
      rescue Errno::ENOENT, ArgumentError
        nil
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

      def hive_managed_root?(project_root)
        !owned_config(project_root).nil?
      end

      def owned_config(project_root)
        path = File.join(project_root, ".llm-wiki/config.json")
        return unless entry_type(File.dirname(path)) == "directory" && entry_type(path) == "file"

        bytes = File.binread(path).force_encoding(Encoding::UTF_8)
        return unless bytes.valid_encoding?

        config = JSON.parse(bytes)
        bytes if config.is_a?(Hash) && config["created_by"] == "hive"
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      def unit_paths(user_dir, service_name)
        timer_name = service_name.sub(/\.service\z/, ".timer")
        [
          File.join(user_dir, service_name),
          File.join(user_dir, timer_name),
          File.join(user_dir, "timers.target.wants", timer_name)
        ]
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
