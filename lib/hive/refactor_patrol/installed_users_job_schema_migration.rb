require "digest"
require "etc"
require "json"
require "open3"
require "rbconfig"
require "set"
require "time"
require "hive"
require "hive/invoked_binary"
require "hive/managed_directory"
require "hive/paths"
require "hive/refactor_patrol/registered_project_migration_status"
require "hive/secret_patterns"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Privileged package-upgrade boundary for every known local Hive user.
    #
    # Discovery never parses user-owned Hive configuration as root. The
    # coordinator binds an NSS identity and a canonical home, then the
    # executor drops supplementary groups, gid, and uid before the exact
    # candidate binary reads that user's registry or touches project state.
    class InstalledUsersJobSchemaMigration
      SCHEMA = "hive-installed-users-job-schema-migration".freeze
      SCHEMA_VERSION = 1
      TARGET_SCHEMA_VERSION = 3
      MAX_ERROR_BYTES = 2_048
      DEFAULT_SWEEP_TIMEOUT_SEC = 600
      SWEEP_CLEANUP_RESERVE_SEC = 0.25

      Profile = Data.define(
        :username, :uid, :gid, :home, :real_home, :environment, :source,
        :supplementary_gids, :root_bindings
      )
      RootBinding = Data.define(
        :kind, :logical_path, :canonical_path, :existing, :dev, :ino,
        :owner_uid, :mode, :anchor_path, :anchor_dev, :anchor_ino, :suffix
      )
      Candidate = Data.define(
        :path, :dev, :ino, :size, :mode, :uid, :gid, :mtime, :ctime,
        :sha256, :version
      )
      DiscoveryIssue = Data.define(:kind, :username, :uid, :detail)
      NssEntry = Data.define(:name, :uid, :gid, :dir)
      Snapshot = Data.define(
        :profiles, :issues, :closed, :inventory_path, :inventory_digest
      )

      module BoundedDiagnostic
        module_function

        def call(value)
          Hive::SecretPatterns.redact(value.to_s)
            .byteslice(0, MAX_ERROR_BYTES).to_s.scrub("")
        end
      end
      private_constant :BoundedDiagnostic

      module PathValue
        module_function

        def absolute?(value)
          value.is_a?(String) &&
            !value.empty? &&
            value.valid_encoding? &&
            value.encoding.ascii_compatible? &&
            value.each_byte.none? { |byte| byte < 0x20 || byte == 0x7f } &&
            File.absolute_path(value) == value
        end
      end
      private_constant :PathValue

      module ProcessGroup
        module_function

        def kill(process_kill, pid)
          process_kill.call("KILL", -pid)
        rescue Errno::ESRCH
          begin
            process_kill.call("KILL", pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
      private_constant :ProcessGroup

      module ProfileRoots
        module_function

        def resolve(profile)
          environment = profile.environment
          hive_home = environment["HIVE_HOME"]
          {
            config_home:
              hive_home ||
              File.join(
                environment.fetch(
                  "XDG_CONFIG_HOME",
                  File.join(profile.home, ".config")
                ),
                "hive"
              ),
            state_home:
              hive_home ||
              File.join(
                environment.fetch(
                  "XDG_STATE_HOME",
                  File.join(profile.home, ".local", "state")
                ),
                "hive"
              )
          }.transform_values { |path| File.expand_path(path).freeze }.freeze
        end

        def canonical_environment(environment, bindings)
          result = environment.dup
          by_kind = bindings.to_h { |binding| [ binding.kind, binding ] }
          if result.key?("HIVE_HOME")
            result["HIVE_HOME"] =
              by_kind.fetch(:config_home).canonical_path
          end
          result[Hive::Paths::JOB_SCHEMA_CONFIG_HOME] =
            by_kind.fetch(:config_home).canonical_path
          result[Hive::Paths::JOB_SCHEMA_STATE_HOME] =
            by_kind.fetch(:state_home).canonical_path
          result.freeze
        end
      end

      class ProfileRootBindings
        def initialize(
          lstat: File.method(:lstat),
          realpath: File.method(:realpath)
        )
          @lstat = lstat
          @realpath = realpath
        end

        def bind(home:, environment:, uid:)
          roots = ProfileRoots.resolve(
            Struct.new(:home, :environment).new(home, environment)
          )
          roots.map do |kind, path|
            bind_root(kind, path, uid)
          end.freeze
        end

        def verify!(profile)
          profile.root_bindings.each do |binding|
            verify_binding!(binding, profile.uid)
          end
          true
        end

        def key(binding)
          if binding.existing
            [ :existing, binding.dev, binding.ino ].freeze
          else
            [
              :missing, binding.anchor_dev, binding.anchor_ino,
              binding.suffix
            ].freeze
          end
        end

        private

        def bind_root(kind, path, uid)
          expanded = File.expand_path(path)
          @lstat.call(expanded)
          canonical = @realpath.call(expanded)
          canonical_stat = @lstat.call(canonical)
          validate_directory!(
            canonical_stat, canonical, kind: kind, uid: uid
          )
          RootBinding.new(
            kind: kind,
            logical_path: expanded,
            canonical_path: canonical,
            existing: true,
            dev: canonical_stat.dev,
            ino: canonical_stat.ino,
            owner_uid: canonical_stat.uid,
            mode: canonical_stat.mode & 0o777,
            anchor_path: nil,
            anchor_dev: nil,
            anchor_ino: nil,
            suffix: nil
          ).freeze
        rescue Errno::ENOENT, Errno::ENOTDIR
          bind_missing_root(kind, expanded, uid)
        end

        def bind_missing_root(kind, path, uid)
          candidate = path
          suffix = []
          loop do
            parent = File.dirname(candidate)
            raise Hive::ConfigError,
                  "Hive profile root has no safe existing anchor" if
              parent == candidate
            suffix.unshift(File.basename(candidate))
            candidate = parent
            begin
              @lstat.call(candidate)
              canonical = @realpath.call(candidate)
              canonical_stat = @lstat.call(canonical)
              validate_directory!(
                canonical_stat, canonical, kind: kind, uid: uid
              )
              return RootBinding.new(
                kind: kind,
                logical_path: path,
                canonical_path: File.join(canonical, *suffix),
                existing: false,
                dev: nil,
                ino: nil,
                owner_uid: nil,
                mode: nil,
                anchor_path: canonical,
                anchor_dev: canonical_stat.dev,
                anchor_ino: canonical_stat.ino,
                suffix: suffix.join("/")
              ).freeze
            rescue Errno::ENOENT, Errno::ENOTDIR
              next
            end
          end
        end

        def verify_binding!(binding, uid)
          if binding.existing
            stat = @lstat.call(binding.canonical_path)
            validate_directory!(
              stat, binding.canonical_path, kind: binding.kind, uid: uid
            )
            unless stat.dev == binding.dev && stat.ino == binding.ino
              raise Hive::ConfigError,
                    "Hive profile root identity changed after discovery"
            end
            validate_ancestor_custody!(binding.canonical_path, uid)
          else
            begin
              @lstat.call(binding.canonical_path)
              raise Hive::ConfigError,
                    "missing Hive profile root appeared after discovery"
            rescue Errno::ENOENT, Errno::ENOTDIR
              nil
            end
            anchor = @lstat.call(binding.anchor_path)
            validate_directory!(
              anchor, binding.anchor_path, kind: binding.kind, uid: uid
            )
            unless anchor.dev == binding.anchor_dev &&
                   anchor.ino == binding.anchor_ino
              raise Hive::ConfigError,
                    "Hive profile root anchor changed after discovery"
            end
            validate_ancestor_custody!(binding.anchor_path, uid)
          end
          true
        rescue SystemCallError => error
          raise Hive::ConfigError,
                "cannot revalidate Hive profile root " \
                "(#{error.class}: #{error.message})"
        end

        def validate_directory!(stat, path, kind:, uid:)
          allowed_owner =
            kind == :state_home ? stat.uid == uid : [ 0, uid ].include?(stat.uid)
          readable =
            if stat.uid == uid
              (stat.mode & 0o500) == 0o500
            else
              (stat.mode & 0o005) == 0o005
            end
          unless stat.directory? && !stat.symlink? && allowed_owner &&
                 readable && (stat.mode & 0o022).zero?
            raise Hive::ConfigError,
                  "Hive #{kind} root is not a safe owned directory: #{path}"
          end
        end

        def validate_ancestor_custody!(path, uid)
          candidate = File.dirname(File.expand_path(path))
          loop do
            stat = @lstat.call(candidate)
            sticky_public =
              %w[/tmp /private/tmp /var/tmp].include?(candidate) &&
              (stat.mode & 0o1000) == 0o1000
            filesystem_root = candidate == File::SEPARATOR
            owner_allowed =
              [ 0, uid ].include?(stat.uid) ||
              sticky_public || filesystem_root
            traversable =
              if stat.uid == uid
                (stat.mode & 0o100) == 0o100
              else
                (stat.mode & 0o001) == 0o001
              end
            writable = (stat.mode & 0o022) != 0
            unless stat.directory? && !stat.symlink? &&
                   owner_allowed && traversable &&
                   (!writable || sticky_public)
              raise Hive::ConfigError,
                    "Hive profile root has unsafe ancestor custody: " \
                    "#{candidate}"
            end
            parent = File.dirname(candidate)
            break if parent == candidate

            candidate = parent
          end
        end
      end

      # NSS may be backed by a network directory service. Run every lookup in
      # a separate process group with bounded output and one wall-clock
      # deadline so a package hook cannot hang indefinitely inside libc.
      class NssQuery
        DEFAULT_TIMEOUT_SEC = 10
        MAX_CAPTURE_BYTES = 1024 * 1024
        MAX_ENTRIES = 65_536
        SAFE_ENVIRONMENT = {
          "LANG" => "C.UTF-8",
          "LC_ALL" => "C.UTF-8",
          "PATH" => "/usr/sbin:/usr/bin:/sbin:/bin"
        }.freeze
        SNAPSHOT_SCRIPT = <<~'RUBY'.freeze
          require "etc"
          require "json"

          limit = Integer(ARGV.fetch(0))
          accounts = []
          Etc.passwd do |entry|
            accounts << {
              "name" => entry.name.to_s,
              "uid" => Integer(entry.uid),
              "gid" => Integer(entry.gid),
              "dir" => entry.dir.to_s
            }
            abort "NSS account inventory exceeded limit" if accounts.length > limit
          end
          groups = []
          Etc.group do |entry|
            groups << {
              "gid" => Integer(entry.gid),
              "mem" => Array(entry.mem).map(&:to_s)
            }
            abort "NSS group inventory exceeded limit" if groups.length > limit
          end
          STDOUT.write(JSON.generate("accounts" => accounts, "groups" => groups))
        RUBY
        IDENTITY_SCRIPT = <<~'RUBY'.freeze
          require "etc"
          require "json"

          username = ARGV.fetch(0)
          uid = Integer(ARGV.fetch(1))
          limit = Integer(ARGV.fetch(2))
          encode = lambda do |entry|
            {
              "name" => entry.name.to_s,
              "uid" => Integer(entry.uid),
              "gid" => Integer(entry.gid),
              "dir" => entry.dir.to_s
            }
          end
          by_uid = encode.call(Etc.getpwuid(uid))
          by_name = encode.call(Etc.getpwnam(username))
          Process.initgroups(username, by_uid.fetch("gid"))
          gids = Process.groups.map { |gid| Integer(gid) }
          abort "NSS group inventory exceeded limit" if gids.length > limit
          STDOUT.write(JSON.generate(
            "by_uid" => by_uid,
            "by_name" => by_name,
            "supplementary_gids" => gids.uniq.sort
          ))
        RUBY

        Result = Data.define(:accounts, :groups)
        Identity = Data.define(:by_uid, :by_name, :supplementary_gids)

        def initialize(
          ruby: RbConfig.ruby,
          timeout_sec: DEFAULT_TIMEOUT_SEC,
          monotonic_clock: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          },
          popen3: Open3.method(:popen3),
          process_kill: Process.method(:kill),
          snapshot_script: SNAPSHOT_SCRIPT,
          identity_script: IDENTITY_SCRIPT
        )
          @ruby = File.expand_path(ruby)
          @timeout_sec = Float(timeout_sec)
          raise ArgumentError, "NSS timeout must be positive" unless
            @timeout_sec.positive?

          @monotonic_clock = monotonic_clock
          @popen3 = popen3
          @process_kill = process_kill
          @snapshot_script = snapshot_script
          @identity_script = identity_script
        end

        def snapshot(deadline: nil)
          payload = invoke(
            @snapshot_script, MAX_ENTRIES.to_s, deadline: deadline
          )
          accounts = Array(payload.fetch("accounts")).map do |entry|
            parse_entry(entry)
          end.freeze
          groups = Array(payload.fetch("groups")).map do |entry|
            {
              gid: Integer(entry.fetch("gid")),
              mem: Array(entry.fetch("mem")).map(&:to_s).freeze
            }.freeze
          end.freeze
          Result.new(accounts: accounts, groups: groups)
        rescue KeyError, ArgumentError, TypeError => error
          malformed!(error)
        end

        def accounts
          snapshot.accounts
        end

        def groups
          snapshot.groups
        end

        def identity(username, uid, deadline: nil)
          payload = invoke(
            @identity_script, username.to_s, Integer(uid).to_s,
            MAX_ENTRIES.to_s, deadline: deadline
          )
          Identity.new(
            by_uid: parse_entry(payload.fetch("by_uid")),
            by_name: parse_entry(payload.fetch("by_name")),
            supplementary_gids:
              Array(payload.fetch("supplementary_gids"))
                .map { |gid| Integer(gid) }.uniq.sort.freeze
          )
        rescue KeyError, ArgumentError, TypeError => error
          malformed!(error)
        end

        private

        def invoke(script, *arguments, deadline: nil)
          stdin = stdout = stderr = waiter = nil
          stdin, stdout, stderr, waiter = @popen3.call(
            SAFE_ENVIRONMENT,
            @ruby, "-e", script, *arguments,
            unsetenv_others: true,
            pgroup: true
          )
          stdin.close
          outputs, status = drain_bounded(
            waiter, { stdout: stdout, stderr: stderr },
            deadline: deadline
          )
          unless status.success?
            detail = outputs.fetch(:stderr).to_s.strip
            detail = "lookup process exited #{status.exitstatus}" if
              detail.empty?
            raise Hive::ConfigError,
                  "bounded NSS lookup failed: #{detail.byteslice(0, 512)}"
          end

          JSON.parse(outputs.fetch(:stdout))
        rescue JSON::ParserError => error
          malformed!(error)
        ensure
          [ stdin, stdout, stderr ].each do |io|
            io.close if io && !io.closed?
          rescue IOError
            nil
          end
        end

        def drain_bounded(waiter, streams, deadline: nil)
          local_deadline = @monotonic_clock.call + @timeout_sec
          deadline = [ local_deadline, deadline ].compact.min
          captures = streams.to_h { |name, io| [ io, name ] }
          outputs = streams.to_h { |name, _io| [ name, +"" ] }
          total = 0
          status = nil
          until status && captures.empty?
            remaining = deadline - @monotonic_clock.call
            if remaining <= 0
              terminate(waiter)
              raise Hive::ConfigError,
                    "bounded NSS lookup exceeded #{@timeout_sec} seconds"
            end
            unless captures.empty?
              ready = IO.select(
                captures.keys, nil, nil, [ remaining, 0.05 ].min
              )
              Array(ready&.first).each do |io|
                chunk = io.read_nonblock(16 * 1024, exception: false)
                if chunk.nil?
                  captures.delete(io)
                  io.close
                  next
                end
                next if chunk == :wait_readable

                total += chunk.bytesize
                if total > MAX_CAPTURE_BYTES
                  terminate(waiter)
                  raise Hive::ConfigError,
                        "bounded NSS lookup output exceeded its limit"
                end
                outputs.fetch(captures.fetch(io)) << chunk
              end
            else
              IO.select(nil, nil, nil, [ remaining, 0.05 ].min)
            end
            status = waiter.value if !status && waiter.join(0)
          end
          [ outputs, status ]
        end

        def terminate(waiter)
          @process_kill.call("TERM", -waiter.pid)
          return if waiter.join(0.1)

          @process_kill.call("KILL", -waiter.pid)
          waiter.join(0.1)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def parse_entry(entry)
          NssEntry.new(
            name: entry.fetch("name").to_s,
            uid: Integer(entry.fetch("uid")),
            gid: Integer(entry.fetch("gid")),
            dir: entry.fetch("dir").to_s
          ).freeze
        end

        def malformed!(error)
          raise Hive::ConfigError,
                "bounded NSS lookup returned malformed data " \
                "(#{error.class}: #{error.message})"
        end
      end

      class SupplementaryGroups
        def initialize(groups: lambda {
          NssQuery.new.groups
        })
          @groups = groups
        end

        def call(username, primary_gid)
          gids = [ Integer(primary_gid) ]
          Array(@groups.call).each do |entry|
            members = Array(entry.respond_to?(:mem) ? entry.mem : entry[:mem])
            next unless members.map(&:to_s).include?(username.to_s)

            gid = entry.respond_to?(:gid) ? entry.gid : entry.fetch(:gid)
            gids << Integer(gid)
          end
          gids.uniq.sort.freeze
        rescue ArgumentError, TypeError, KeyError => error
          raise Hive::ConfigError,
                "cannot bind installed-user supplementary groups " \
                "(#{error.class}: #{error.message})"
        end
      end

      # Root-owned traversal checkpoint. Per-user receipts remain the schema
      # authority; this file only makes one bounded host sweep fair and
      # resumable across the hourly retry.
      class SweepProgress
        SCHEMA = "hive-installed-users-job-schema-sweep".freeze
        SCHEMA_VERSION = 1
        FILE_NAME = "installed-users-job-schema-v3.json".freeze
        LOCK_NAME = "installed-users-job-schema-v3.lock".freeze
        DEFAULT_ROOT = "/var/lib/hive/schema-migrations".freeze
        MAX_BYTES = 4 * 1024 * 1024
        MAX_RESULTS = 4_096

        def initialize(root: DEFAULT_ROOT, directory: nil)
          @root = File.expand_path(root)
          @directory = directory ||
            Hive::ManagedDirectory.new(
              root: @root,
              label: "install-wide JobStore schema sweep"
            )
        end

        def try_with_lock(&block)
          @directory.prepare!
          @directory.try_with_lock(LOCK_NAME, &block)
        end

        def read
          bytes = @directory.read(
            FILE_NAME, max_bytes: MAX_BYTES, missing: true
          )
          return nil unless bytes

          payload = JSON.parse(bytes)
          unless bytes ==
                 Hive::WorkflowPackage::CanonicalJSON.generate(payload) &&
                 valid?(payload)
            raise Hive::ConfigError,
                  "install-wide schema sweep checkpoint is malformed"
          end
          payload
        rescue JSON::ParserError, EncodingError => error
          raise Hive::ConfigError,
                "install-wide schema sweep checkpoint is unreadable " \
                "(#{error.class}: #{error.message})"
        end

        def write(payload)
          unless valid?(payload)
            raise Hive::ConfigError,
                  "install-wide schema sweep checkpoint is malformed"
          end
          bytes =
            Hive::WorkflowPackage::CanonicalJSON.generate(payload)
          if bytes.bytesize > MAX_BYTES
            raise Hive::ConfigError,
                  "install-wide schema sweep checkpoint is too large"
          end

          @directory.atomic_write(
            FILE_NAME,
            bytes,
            mode: 0o600,
            max_existing_bytes: MAX_BYTES
          )
          payload
        end

        private

        def valid?(payload)
          payload.is_a?(Hash) &&
            payload.keys.sort ==
              %w[cursor results schema schema_version sweep_key updated_at] &&
            payload["schema"] == SCHEMA &&
            payload["schema_version"] == SCHEMA_VERSION &&
            payload["sweep_key"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
            payload["cursor"].is_a?(Integer) &&
            payload["cursor"] >= 0 &&
            payload["results"].is_a?(Hash) &&
            payload["results"].length <= MAX_RESULTS &&
            payload["results"].all? do |digest, row|
              digest.match?(/\A[0-9a-f]{64}\z/) &&
                row.is_a?(Hash) &&
                row["profile_digest"] == digest &&
                valid_result_row?(row)
            end &&
            timestamp?(payload["updated_at"])
        end

        def valid_result_row?(row)
          return false unless row.is_a?(Hash)

          required = %w[
            home profile_digest projects registry_digest retryable source
            status uid username
          ]
          keys = required.dup
          keys << "error" if row["status"] == "failed"
          valid = row.keys.sort == keys.sort &&
            %w[completed failed].include?(row["status"]) &&
            [ true, false ].include?(row["retryable"]) &&
            row["username"].is_a?(String) &&
            !row["username"].empty? &&
            row["uid"].is_a?(Integer) && row["uid"] >= 0 &&
            row["home"].is_a?(String) &&
            File.absolute_path(row["home"]) == row["home"] &&
            row["profile_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
            %w[default-home root-inventory].include?(row["source"]) &&
            (row["registry_digest"].nil? ||
              row["registry_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)) &&
            RegisteredProjectMigrationStatus.valid_projects?(
              row["projects"]
            )
          return false unless valid

          if row["status"] == "failed"
            row["retryable"] == true &&
              row["registry_digest"].nil? &&
              row["projects"].empty? &&
              valid_diagnostic?(row["error"])
          else
            row["registry_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
              (
                row["retryable"] == true ||
                row["projects"].none? do |project|
                  project["retryable"] == true
                end
              )
          end
        rescue ArgumentError, TypeError
          false
        end

        def valid_diagnostic?(value)
          value.is_a?(String) &&
            !value.empty? &&
            value.valid_encoding? &&
            value.bytesize <= MAX_ERROR_BYTES &&
            value == BoundedDiagnostic.call(value)
        end

        def timestamp?(value)
          Time.iso8601(value.to_s)
          true
        rescue ArgumentError, TypeError
          false
        end
      end

      # Filesystem/NSS-backed discovery can block in libc or an automount.
      # Isolating the catalog in a process group keeps the root coordinator's
      # one host deadline authoritative.
      class CatalogRunner
        WIRE_SCHEMA = "hive-installed-users-catalog".freeze
        WIRE_SCHEMA_VERSION = 1
        MAX_CAPTURE_BYTES = 8 * 1024 * 1024
        CLEANUP_TIMEOUT_SEC = 0.25
        MAX_PROFILES = SweepProgress::MAX_RESULTS
        MAX_ISSUES = SweepProgress::MAX_RESULTS
        MAX_PATH_BYTES = 4_096
        MAX_USERNAME_BYTES = 256
        MAX_SUPPLEMENTARY_GIDS = NssQuery::MAX_ENTRIES
        PROFILE_SOURCES = %w[default-home root-inventory].freeze
        ROOT_KINDS = %w[config_home state_home].freeze
        ENVIRONMENT_KEYS = %w[
          HIVE_HOME HIVE_JOB_SCHEMA_CONFIG_HOME HIVE_JOB_SCHEMA_STATE_HOME
          XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
        ].freeze
        ISSUE_KINDS = %w[
          default_home_unavailable inventory_home_unavailable
          inventory_identity_drift nss_catalog_unavailable nss_uid_ambiguous
          profile_root_ambiguous shared_profile_root
        ].freeze

        def initialize(
          monotonic_clock: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          },
          process_kill: Process.method(:kill),
          process_waitpid2: Process.method(:waitpid2),
          session_setter: Process.method(:setsid),
          exit_process: Process.method(:exit!)
        )
          @monotonic_clock = monotonic_clock
          @process_kill = process_kill
          @process_waitpid2 = process_waitpid2
          @session_setter = session_setter
          @exit_process = exit_process
        end

        def call(catalog, nss_snapshot:, nss_error:, deadline:)
          reader, writer = IO.pipe
          pid = fork { catalog_child(reader, writer, catalog, nss_snapshot:, nss_error:) }
          writer.close
          reader.binmode
          waiter = Thread.new { wait_for_child(pid) }
          waiter.report_on_exception = false
          bytes = +"".b
          loop do
            remaining = deadline - @monotonic_clock.call
            if remaining <= 0
              ProcessGroup.kill(@process_kill, pid)
              raise Hive::ConfigError,
                    "installed-user discovery exceeded the host sweep budget"
            end
            ready = IO.select(
              [ reader ], nil, nil, [ remaining, 0.05 ].min
            )
            if ready
              chunk =
                reader.read_nonblock(16 * 1024, exception: false)
              break if chunk.nil?
              next if chunk == :wait_readable

              bytes << chunk
              if bytes.bytesize > MAX_CAPTURE_BYTES
                ProcessGroup.kill(@process_kill, pid)
                raise Hive::ConfigError,
                      "installed-user discovery output exceeded its limit"
              end
            end
          end
          remaining = [ deadline - @monotonic_clock.call, 0 ].max
          unless waiter.join(remaining)
            ProcessGroup.kill(@process_kill, pid)
            raise Hive::ConfigError,
                  "installed-user discovery did not terminate within budget"
          end
          decode_payload(JSON.parse(bytes))
        rescue JSON::ParserError, EncodingError, TypeError,
               ArgumentError => error
          raise Hive::ConfigError,
                "installed-user discovery returned malformed data " \
                "(#{error.class}: #{error.message})"
        ensure
          cleanup(pid, waiter)
          reader&.close unless reader&.closed?
          writer&.close unless writer&.closed?
        end

        private

        def catalog_child(reader, writer, catalog, nss_snapshot:, nss_error:)
          reader.close
          @session_setter.call
          payload =
            begin
              success_payload(
                catalog.snapshot(
                  nss_snapshot: nss_snapshot,
                  nss_error: nss_error
                )
              )
            rescue StandardError => error
              failure_payload(error)
            end
          writer.binmode
          writer.write(JSON.generate(payload))
          writer.close
          @exit_process.call(0)
        end

        def wait_for_child(pid)
          @process_waitpid2.call(pid)&.last
        rescue Errno::ECHILD
          nil
        end

        def success_payload(snapshot)
          {
            "schema" => WIRE_SCHEMA,
            "schema_version" => WIRE_SCHEMA_VERSION,
            "ok" => true,
            "snapshot" => encode_snapshot(snapshot)
          }
        end

        def failure_payload(error)
          {
            "schema" => WIRE_SCHEMA,
            "schema_version" => WIRE_SCHEMA_VERSION,
            "ok" => false,
            "error" =>
              BoundedDiagnostic.call("#{error.class}: #{error.message}")
          }
        end

        def encode_snapshot(snapshot)
          {
            "profiles" => snapshot.profiles.map do |profile|
              encode_profile(profile)
            end,
            "issues" => snapshot.issues.map do |issue|
              {
                "kind" => issue.kind,
                "username" => issue.username,
                "uid" => issue.uid,
                "detail" => BoundedDiagnostic.call(issue.detail)
              }
            end,
            "closed" => snapshot.closed,
            "inventory_path" => snapshot.inventory_path,
            "inventory_digest" => snapshot.inventory_digest
          }
        end

        def encode_profile(profile)
          {
            "username" => profile.username,
            "uid" => profile.uid,
            "gid" => profile.gid,
            "home" => profile.home,
            "real_home" => profile.real_home,
            "environment" => profile.environment,
            "source" => profile.source,
            "supplementary_gids" => profile.supplementary_gids,
            "root_bindings" => profile.root_bindings.map do |binding|
              binding.to_h.transform_keys(&:to_s).merge(
                "kind" => binding.kind.to_s
              )
            end
          }
        end

        def decode_payload(payload)
          exact_hash!(
            payload,
            %w[ok schema schema_version] +
              (payload.is_a?(Hash) && payload["ok"] == true ?
                [ "snapshot" ] : [ "error" ]),
            "envelope"
          )
          malformed!("unsupported wire schema") unless
            payload["schema"] == WIRE_SCHEMA &&
            payload["schema_version"] == WIRE_SCHEMA_VERSION

          case payload["ok"]
          when true
            decode_snapshot(payload["snapshot"])
          when false
            detail = string!(
              payload["error"], "error", max_bytes: MAX_ERROR_BYTES
            )
            raise Hive::ConfigError,
                  "installed-user discovery failed: #{detail}"
          else
            malformed!("envelope status is invalid")
          end
        end

        def decode_snapshot(value)
          row = exact_hash!(
            value,
            %w[closed inventory_digest inventory_path issues profiles],
            "snapshot"
          )
          profiles = bounded_array!(
            row["profiles"], "profiles", MAX_PROFILES
          ).map { |profile| decode_profile(profile) }.freeze
          expected_order = profiles.sort_by do |profile|
            [ profile.uid, profile.source, profile.home ]
          end
          malformed!("profiles are not canonical") unless
            profiles == expected_order && profiles.uniq.length == profiles.length
          issues = bounded_array!(
            row["issues"], "issues", MAX_ISSUES
          ).map { |issue| decode_issue(issue) }.freeze
          closed = boolean!(row["closed"], "closed")
          inventory_path = absolute_path!(
            row["inventory_path"], "inventory_path"
          )
          inventory_digest = row["inventory_digest"]
          unless inventory_digest.nil? ||
                 (inventory_digest.is_a?(String) &&
                  inventory_digest.match?(/\A[0-9a-f]{64}\z/))
            malformed!("inventory_digest is invalid")
          end
          malformed!("closed inventory has no digest") if
            closed && inventory_digest.nil?

          Snapshot.new(
            profiles: profiles,
            issues: issues,
            closed: closed,
            inventory_path: inventory_path,
            inventory_digest: inventory_digest&.freeze
          ).freeze
        end

        def decode_profile(value)
          row = exact_hash!(
            value,
            %w[
              environment gid home real_home root_bindings source
              supplementary_gids uid username
            ],
            "profile"
          )
          username = username!(
            row["username"], "profile username",
            max_bytes: MAX_USERNAME_BYTES
          )
          uid = nonnegative_integer!(row["uid"], "profile uid")
          gid = nonnegative_integer!(row["gid"], "profile gid")
          home = absolute_path!(row["home"], "profile home")
          real_home = absolute_path!(row["real_home"], "profile real_home")
          environment = decode_environment(row["environment"])
          source = enum!(row["source"], PROFILE_SOURCES, "profile source")
          supplementary_gids = bounded_array!(
            row["supplementary_gids"],
            "supplementary_gids",
            MAX_SUPPLEMENTARY_GIDS
          ).map do |value_gid|
            nonnegative_integer!(value_gid, "supplementary gid")
          end.freeze
          unless supplementary_gids == supplementary_gids.uniq.sort &&
                 supplementary_gids.include?(gid)
            malformed!("supplementary_gids are not canonical")
          end
          root_bindings = bounded_array!(
            row["root_bindings"], "root_bindings", ROOT_KINDS.length
          ).map { |binding| decode_root_binding(binding, uid) }.freeze
          unless root_bindings.map { |binding| binding.kind.to_s } == ROOT_KINDS
            malformed!("root_bindings are not canonical")
          end
          roots = root_bindings.to_h do |binding|
            [ binding.kind, binding.canonical_path ]
          end
          unless environment[Hive::Paths::JOB_SCHEMA_CONFIG_HOME] ==
                 roots.fetch(:config_home) &&
                 environment[Hive::Paths::JOB_SCHEMA_STATE_HOME] ==
                 roots.fetch(:state_home)
            malformed!("profile environment disagrees with root bindings")
          end
          if environment.key?("HIVE_HOME") &&
             (environment["HIVE_HOME"] != roots.fetch(:config_home) ||
              roots.fetch(:config_home) != roots.fetch(:state_home))
            malformed!("profile HIVE_HOME disagrees with root bindings")
          end

          Profile.new(
            username: username,
            uid: uid,
            gid: gid,
            home: home,
            real_home: real_home,
            environment: environment,
            source: source,
            supplementary_gids: supplementary_gids,
            root_bindings: root_bindings
          ).freeze
        end

        def decode_environment(value)
          malformed!("profile environment is invalid") unless
            value.is_a?(Hash) &&
            (value.keys - ENVIRONMENT_KEYS).empty? &&
            value.key?(Hive::Paths::JOB_SCHEMA_CONFIG_HOME) &&
            value.key?(Hive::Paths::JOB_SCHEMA_STATE_HOME)

          value.each_with_object({}) do |(key, path), result|
            result[key.freeze] =
              absolute_path!(path, "profile environment path")
          end.freeze
        end

        def decode_root_binding(value, profile_uid)
          row = exact_hash!(
            value,
            %w[
              anchor_dev anchor_ino anchor_path canonical_path dev existing
              ino kind logical_path mode owner_uid suffix
            ],
            "root binding"
          )
          kind = enum!(row["kind"], ROOT_KINDS, "root binding kind").to_sym
          logical_path = absolute_path!(
            row["logical_path"], "root binding logical_path"
          )
          canonical_path = absolute_path!(
            row["canonical_path"], "root binding canonical_path"
          )
          existing = boolean!(row["existing"], "root binding existing")
          attributes =
            if existing
              decode_existing_binding(row, kind, profile_uid)
            else
              decode_missing_binding(row, canonical_path)
            end

          RootBinding.new(
            kind: kind,
            logical_path: logical_path,
            canonical_path: canonical_path,
            existing: existing,
            **attributes
          ).freeze
        end

        def decode_existing_binding(row, kind, profile_uid)
          anchors_clear =
            %w[anchor_dev anchor_ino anchor_path suffix].all? do |key|
              row[key].nil?
            end
          unless anchors_clear
            malformed!("existing root binding contains anchor fields")
          end
          owner_uid = nonnegative_integer!(
            row["owner_uid"], "root binding owner_uid"
          )
          allowed_owner =
            kind == :state_home ? owner_uid == profile_uid :
              [ 0, profile_uid ].include?(owner_uid)
          malformed!("root binding owner is invalid") unless allowed_owner
          mode = nonnegative_integer!(row["mode"], "root binding mode")
          malformed!("root binding mode is invalid") if
            mode > 0o777 || (mode & 0o022) != 0
          readable =
            if owner_uid == profile_uid
              (mode & 0o500) == 0o500
            else
              (mode & 0o005) == 0o005
            end
          malformed!("root binding mode is unreadable") unless readable

          {
            dev: nonnegative_integer!(row["dev"], "root binding dev"),
            ino: nonnegative_integer!(row["ino"], "root binding ino"),
            owner_uid: owner_uid,
            mode: mode,
            anchor_path: nil,
            anchor_dev: nil,
            anchor_ino: nil,
            suffix: nil
          }
        end

        def decode_missing_binding(row, canonical_path)
          unless %w[dev ino mode owner_uid].all? { |key| row[key].nil? }
            malformed!("missing root binding contains existing fields")
          end
          anchor_path = absolute_path!(
            row["anchor_path"], "root binding anchor_path"
          )
          suffix = string!(
            row["suffix"], "root binding suffix", max_bytes: MAX_PATH_BYTES
          )
          parts = suffix.split("/", -1)
          invalid_part = parts.any? do |part|
            part.empty? || part == "." || part == ".." ||
              part.each_byte.any? { |byte| byte < 0x20 || byte == 0x7f }
          end
          if invalid_part
            malformed!("root binding suffix is invalid")
          end
          malformed!("root binding anchor and suffix disagree") unless
            File.join(anchor_path, *parts) == canonical_path

          {
            dev: nil,
            ino: nil,
            owner_uid: nil,
            mode: nil,
            anchor_path: anchor_path,
            anchor_dev:
              nonnegative_integer!(
                row["anchor_dev"], "root binding anchor_dev"
              ),
            anchor_ino:
              nonnegative_integer!(
                row["anchor_ino"], "root binding anchor_ino"
              ),
            suffix: suffix
          }
        end

        def decode_issue(value)
          row = exact_hash!(
            value, %w[detail kind uid username], "discovery issue"
          )
          kind = enum!(row["kind"], ISSUE_KINDS, "discovery issue kind")
          username =
            if row["username"].nil?
              nil
            else
              username!(
                row["username"], "discovery issue username",
                max_bytes: MAX_USERNAME_BYTES
              )
            end
          uid =
            if row["uid"].nil?
              nil
            else
              nonnegative_integer!(row["uid"], "discovery issue uid")
            end
          detail = string!(
            row["detail"], "discovery issue detail",
            max_bytes: MAX_ERROR_BYTES
          )
          DiscoveryIssue.new(
            kind: kind,
            username: username,
            uid: uid,
            detail: detail
          ).freeze
        end

        def exact_hash!(value, keys, label)
          malformed!("#{label} keys are invalid") unless
            value.is_a?(Hash) && value.keys.sort == keys.sort
          value
        end

        def bounded_array!(value, label, limit)
          malformed!("#{label} is invalid") unless
            value.is_a?(Array) && value.length <= limit
          value
        end

        def string!(value, label, max_bytes:)
          malformed!("#{label} is invalid") unless
            value.is_a?(String) && !value.empty? &&
            value.valid_encoding? && value.bytesize <= max_bytes
          value.freeze
        end

        def username!(value, label, max_bytes:)
          result = string!(value, label, max_bytes: max_bytes)
          malformed!("#{label} is invalid") if
            result.each_byte.any? { |byte| byte < 0x20 || byte == 0x7f }
          result
        end

        def absolute_path!(value, label)
          malformed!("#{label} is invalid") unless
            value.is_a?(String) && value.bytesize <= MAX_PATH_BYTES &&
            PathValue.absolute?(value)
          value.freeze
        end

        def nonnegative_integer!(value, label)
          malformed!("#{label} is invalid") unless
            value.is_a?(Integer) && value >= 0
          value
        end

        def boolean!(value, label)
          malformed!("#{label} is invalid") unless
            value == true || value == false
          value
        end

        def enum!(value, allowed, label)
          malformed!("#{label} is invalid") unless allowed.include?(value)
          value.freeze
        end

        def malformed!(detail)
          raise Hive::ConfigError,
                "installed-user discovery returned malformed data (#{detail})"
        end

        def cleanup(pid, waiter)
          return unless pid
          return if waiter && !waiter.alive?

          ProcessGroup.kill(@process_kill, pid)
          if waiter
            waiter.join(CLEANUP_TIMEOUT_SEC)
          else
            @process_waitpid2.call(pid, Process::WNOHANG)
          end
          nil
        rescue SystemCallError
          nil
        end
      end

      attr_reader :last_payload

      def initialize(
        catalog: nil,
        executor: nil,
        binary_path: Hive::InvokedBinary.method(:path),
        candidate: nil,
        clock: -> { Time.now.utc },
        effective_uid: -> { Process.euid },
        nss_query: nil,
        catalog_runner: nil,
        status_store: :default,
        sweep_timeout_sec: DEFAULT_SWEEP_TIMEOUT_SEC,
        monotonic_clock: lambda {
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        }
      )
        @production_catalog = catalog.nil?
        @catalog = catalog || Catalog.new
        @executor = executor
        @binary_path = binary_path
        @candidate = candidate
        @clock = clock
        @effective_uid = effective_uid
        @monotonic_clock = monotonic_clock
        @sweep_timeout_sec = Float(sweep_timeout_sec)
        raise ArgumentError, "sweep timeout must be positive" unless
          @sweep_timeout_sec.positive?

        @nss_query =
          nss_query || (@production_catalog ? NssQuery.new(
            monotonic_clock: monotonic_clock
          ) : nil)
        @catalog_runner =
          catalog_runner || (@production_catalog ? CatalogRunner.new(
            monotonic_clock: monotonic_clock
          ) : nil)
        @status_store =
          if status_store == :default
            @production_catalog ? SweepProgress.new : nil
          else
            status_store
          end
        @last_payload = nil
      end

      def call(now: nil, force: true)
        candidate = nil
        unless @effective_uid.call.zero?
          raise Hive::ConfigError,
                "install-wide JobStore migration requires root authority"
        end

        time = utc(now || @clock.call)
        deadline = @monotonic_clock.call + @sweep_timeout_sec
        candidate = @candidate || CandidateIdentity.capture(candidate_binary)
        operation = lambda do
          perform_sweep(
            time: time,
            deadline: deadline,
            candidate: candidate,
            force: force
          )
        end
        if @status_store
          result = @status_store.try_with_lock(&operation)
          @last_payload =
            result || busy_payload(time: time, candidate: candidate)
        else
          @last_payload = operation.call
        end
      ensure
        CandidateIdentity.verify!(candidate) if candidate
      end

      private

      def perform_sweep(time:, deadline:, candidate:, force:)
        nss_snapshot = nil
        nss_error = nil
        if @nss_query
          begin
            nss_snapshot = @nss_query.snapshot(deadline: deadline)
          rescue Hive::ConfigError => error
            nss_error =
              BoundedDiagnostic.call("#{error.class}: #{error.message}")
            nss_snapshot = NssQuery::Result.new(
              accounts: [].freeze, groups: [].freeze
            )
          end
        end
        snapshot = discover_profiles(
          nss_snapshot: nss_snapshot,
          nss_error: nss_error,
          deadline: deadline
        )
        executor = @executor ||
          Executor.new(
            binary: candidate.path,
            candidate: candidate,
            force: force,
            identity_validator:
              @nss_query ? NssIdentity.new(query: @nss_query) :
                NssIdentity.new
          )
        pairs = snapshot.profiles.map do |profile|
          [ profile_digest(profile), profile ]
        end
        sweep_key = sweep_key(
          candidate: candidate,
          snapshot: snapshot,
          nss_snapshot: nss_snapshot,
          profile_digests: pairs.map(&:first)
        )
        progress = matching_progress(sweep_key)
        results = progress.fetch("results").dup
        cursor =
          pairs.empty? ? 0 : progress.fetch("cursor") % pairs.length
        order = (0...pairs.length).to_a.rotate(cursor)
        exhausted = false
        deferred = 0
        order.each_with_index do |index, offset|
          digest, profile = pairs.fetch(index)
          if remaining_budget(deadline) <= SWEEP_CLEANUP_RESERVE_SEC
            exhausted = true
            deferred = order.length - offset
            break
          end
          prior_result = results[digest]
          prior_cursor = cursor
          results[digest] = migrate_profile(
            profile, executor, deadline: deadline
          )
          cursor = pairs.empty? ? 0 : (index + 1) % pairs.length
          unless results[digest] == prior_result && cursor == prior_cursor
            persist_progress(
              sweep_key: sweep_key,
              cursor: cursor,
              results: results,
              time: time
            )
          end
        end
        profiles = pairs.filter_map do |digest, _profile|
          results[digest]
        end
        issues = snapshot.issues.dup
        if exhausted
          issues << DiscoveryIssue.new(
            kind: "sweep_budget_exhausted",
            username: nil,
            uid: nil,
            detail:
              "#{deferred} discovered installed-user profiles are deferred " \
              "to the next hourly retry"
          )
        end
        build_payload(
          time: time,
          candidate: candidate,
          snapshot: snapshot,
          profiles: profiles,
          issues: issues
        )
      end

      def discover_profiles(nss_snapshot:, nss_error:, deadline:)
        if @catalog_runner
          @catalog_runner.call(
            @catalog,
            nss_snapshot: nss_snapshot,
            nss_error: nss_error,
            deadline: deadline
          )
        elsif nss_snapshot || nss_error
          @catalog.snapshot(
            nss_snapshot: nss_snapshot,
            nss_error: nss_error
          )
        else
          @catalog.snapshot
        end
      rescue Hive::ConfigError => error
        Snapshot.new(
          profiles: [].freeze,
          issues: [
            DiscoveryIssue.new(
              kind: "installed_user_discovery_unavailable",
              username: nil,
              uid: nil,
              detail:
                BoundedDiagnostic.call("#{error.class}: #{error.message}")
            )
          ].freeze,
          closed: false,
          inventory_path: Inventory::DEFAULT_PATH,
          inventory_digest: nil
        )
      end

      def build_payload(time:, candidate:, snapshot:, profiles:, issues:)
        issues = issues.map do |issue|
          {
            "kind" => issue.kind,
            "username" => issue.username,
            "uid" => issue.uid,
            "detail" => BoundedDiagnostic.call(issue.detail)
          }
        end.freeze
        failed_profiles =
          profiles.count { |row| row["status"] == "failed" }
        retryable_profiles =
          profiles.count { |row| row["retryable"] == true }
        attempted_uids = profiles.map { |row| row.fetch("uid") }.uniq
        failed_uids = profiles.filter_map do |row|
          row.fetch("uid") if row["status"] == "failed"
        end.uniq
        retryable_uids = profiles.filter_map do |row|
          row.fetch("uid") if row["retryable"] == true
        end.uniq
        status =
          if failed_profiles.positive?
            "failed"
          elsif retryable_profiles.positive? ||
                !snapshot.closed || issues.any?
            "partial"
          else
            "complete"
          end
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "target_schema_version" => TARGET_SCHEMA_VERSION,
          "status" => status,
          "discovery_closed" => snapshot.closed == true,
          "attempted_users" => attempted_uids.length,
          "failed_users" => failed_uids.length,
          "retryable_users" => retryable_uids.length,
          "attempted_profiles" => profiles.length,
          "failed_profiles" => failed_profiles,
          "retryable_profiles" => retryable_profiles,
          "completed_at" => time.iso8601(6),
          "candidate" => {
            "path" => candidate.path,
            "size" => candidate.size,
            "mode" => candidate.mode,
            "uid" => candidate.uid,
            "gid" => candidate.gid,
            "sha256" => candidate.sha256,
            "version" => candidate.version
          },
          "inventory" => {
            "path" => snapshot.inventory_path,
            "sha256" => snapshot.inventory_digest,
            "discovery_closed" => snapshot.closed == true
          },
          "profiles" => profiles,
          "discovery_issues" => issues
        }.freeze
      end

      def busy_payload(time:, candidate:)
        snapshot = Snapshot.new(
          profiles: [].freeze,
          issues: [].freeze,
          closed: false,
          inventory_path: Inventory::DEFAULT_PATH,
          inventory_digest: nil
        )
        build_payload(
          time: time,
          candidate: candidate,
          snapshot: snapshot,
          profiles: [],
          issues: [
            DiscoveryIssue.new(
              kind: "sweep_lock_busy",
              username: nil,
              uid: nil,
              detail:
                "another install-wide migration owns the machine sweep; " \
                "the hourly retry remains scheduled"
            )
          ]
        )
      end

      def matching_progress(sweep_key)
        current = @status_store&.read
        return current if
          current.is_a?(Hash) &&
          current["sweep_key"] == sweep_key

        {
          "schema" => SweepProgress::SCHEMA,
          "schema_version" => SweepProgress::SCHEMA_VERSION,
          "sweep_key" => sweep_key,
          "cursor" => 0,
          "results" => {}
        }
      end

      def persist_progress(sweep_key:, cursor:, results:, time:)
        return unless @status_store

        @status_store.write(
          "schema" => SweepProgress::SCHEMA,
          "schema_version" => SweepProgress::SCHEMA_VERSION,
          "sweep_key" => sweep_key,
          "cursor" => cursor,
          "results" => results,
          "updated_at" => time.iso8601(6)
        )
      end

      def sweep_key(candidate:, snapshot:, nss_snapshot:,
                    profile_digests:)
        nss = if nss_snapshot
          {
            "accounts" => nss_snapshot.accounts.map(&:to_h),
            "groups" => nss_snapshot.groups
          }
        end
        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(
            {
              "candidate" => {
                "path" => candidate.path,
                "sha256" => candidate.sha256,
                "version" => candidate.version
              },
              "discovery_closed" => snapshot.closed == true,
              "inventory_digest" => snapshot.inventory_digest,
              "nss" => nss,
              "profiles" => profile_digests
            }
          )
        )
      end

      def remaining_budget(deadline)
        deadline - @monotonic_clock.call
      end

      def candidate_binary
        path = @binary_path.call
        unless path && File.file?(path) && File.executable?(path)
          raise Hive::UnavailableError,
                "install-wide JobStore migration candidate binary is unavailable"
        end

        File.expand_path(path)
      end

      def migrate_profile(profile, executor, deadline:)
        parameters = executor.method(:call).parameters
        payload =
          if parameters.any? do |kind, name|
               %i[key keyreq].include?(kind) && name == :deadline
             end
            executor.call(profile, deadline: deadline)
          else
            executor.call(profile)
          end
        projects = Array(payload["projects"])
        retryable =
          payload["daemon_restart_pending"] == true ||
          projects.any? { |project| project["retryable"] == true }
        {
          "username" => profile.username,
          "uid" => profile.uid,
          "home" => profile.home,
          "profile_digest" => profile_digest(profile),
          "source" => profile.source,
          "status" => "completed",
          "retryable" => retryable,
          "registry_digest" => payload["registry_digest"],
          "projects" => projects
        }
      rescue StandardError => error
        {
          "username" => profile.username,
          "uid" => profile.uid,
          "home" => profile.home,
          "profile_digest" => profile_digest(profile),
          "source" => profile.source,
          "status" => "failed",
          "retryable" => true,
          "registry_digest" => nil,
          "projects" => [],
          "error" =>
            BoundedDiagnostic.call("#{error.class}: #{error.message}")
        }
      end

      def profile_digest(profile)
        Digest::SHA256.hexdigest(JSON.generate(
          "uid" => profile.uid,
          "home" => profile.home,
          "real_home" => profile.real_home,
          "environment" => profile.environment.sort.to_h,
          "supplementary_gids" => profile.supplementary_gids,
          "root_bindings" => profile.root_bindings.map(&:to_h)
        ))
      end

      def utc(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "install-wide JobStore migration time is malformed"
      end

      # Root-owned exact profile inventory supplements deterministic default
      # home discovery. `discovery_closed: true` is an explicit operator claim
      # that legacy custom roots have been inventoried; its absence keeps the
      # aggregate receipt partial.
      class Inventory
        SCHEMA = "hive-installed-user-inventory".freeze
        SCHEMA_VERSION = 1
        DEFAULT_PATH = "/var/lib/hive/installed-users.v1.json".freeze
        MAX_BYTES = 256 * 1024
        MAX_PROFILES = 1_024
        ENV_KEYS = %w[
          HIVE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
          XDG_STATE_HOME
        ].freeze

        Result = Data.define(
          :profiles, :issues, :closed, :path, :digest
        )

        def initialize(path: DEFAULT_PATH, stat: nil, reader: nil,
                       trusted_uid: 0, lstat: File.method(:lstat),
                       open_file: File.method(:open),
                       realpath: File.method(:realpath),
                       nofollow_supported: File.const_defined?(:NOFOLLOW))
          unless path.is_a?(String) && File.absolute_path(path) == path
            raise ArgumentError, "installed-user inventory path must be absolute"
          end
          unless trusted_uid.is_a?(Integer) && trusted_uid >= 0
            raise ArgumentError,
                  "installed-user inventory trusted uid must be non-negative"
          end
          @path = path.freeze
          @stat = stat
          @reader = reader
          @trusted_uid = trusted_uid
          @lstat = lstat
          @open_file = open_file
          @realpath = realpath
          @nofollow_supported = nofollow_supported
          if @stat.nil? != @reader.nil?
            raise ArgumentError, "stat and reader test seams must be supplied together"
          end
        end

        def read
          bytes = @reader ? injected_snapshot : secure_snapshot

          document = JSON.parse(bytes)
          validate_document!(document)
          profiles = document.fetch("profiles").map do |entry|
            parse_profile(entry)
          end.freeze
          if profiles.uniq.length != profiles.length
            raise Hive::ConfigError,
                  "installed-user inventory contains duplicate profiles"
          end
          Result.new(
            profiles: profiles,
            issues: [].freeze,
            closed: document["discovery_closed"] == true,
            path: @path,
            digest: Digest::SHA256.hexdigest(bytes)
          )
        rescue Errno::ENOENT
          Result.new(
            profiles: [].freeze,
            issues: [].freeze,
            closed: false,
            path: @path,
            digest: nil
          )
        rescue JSON::ParserError => error
          raise Hive::ConfigError,
                "installed-user inventory is malformed JSON: #{error.message}"
        end

        private

        def injected_snapshot
          before = @stat.call(@path)
          validate_stat!(before)
          bytes = @reader.call(@path)
          after = @stat.call(@path)
          validate_stable_snapshot!(before, after, bytes)
          bytes
        end

        def secure_snapshot
          unless @nofollow_supported
            raise Hive::ConfigError,
                  "installed-user inventory requires no-follow file support"
          end

          before = @lstat.call(@path)
          validate_parent!
          validate_stat!(before)
          flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
          bytes = nil
          opened = nil
          after_read = nil
          @open_file.call(@path, flags) do |file|
            opened = file.stat
            validate_stat!(opened)
            unless same_file?(before, opened)
              raise Hive::ConfigError,
                    "installed-user inventory changed before it was opened"
            end
            bytes = file.read(MAX_BYTES + 1) || +""
            after_read = file.stat
          end
          after_path = @lstat.call(@path)
          validate_stable_snapshot!(opened, after_read, bytes)
          unless same_file?(after_read, after_path)
            raise Hive::ConfigError,
                  "installed-user inventory changed while it was read"
          end

          bytes
        end

        def validate_parent!
          parent = File.dirname(File.expand_path(@path))
          stat = @lstat.call(parent)
          unless stat.directory? && stat.uid == @trusted_uid &&
                 (stat.mode & 0o022).zero? &&
                 @realpath.call(parent) == parent
            raise Hive::ConfigError,
                  "installed-user inventory parent must be a canonical, " \
                  "root-owned, non-writable directory"
          end
        rescue SystemCallError => error
          raise Hive::ConfigError,
                "cannot validate installed-user inventory parent: " \
                "#{error.class}: #{error.message}"
        end

        def validate_stat!(stat)
          unless stat.file? && stat.uid == @trusted_uid &&
                 (stat.mode & 0o022).zero?
            raise Hive::ConfigError,
                  "installed-user inventory must be a root-owned, non-writable regular file"
          end
          raise Hive::ConfigError, "installed-user inventory is too large" if
            stat.size > MAX_BYTES
        end

        def validate_stable_snapshot!(before, after, bytes)
          unless stable_file?(before, after, bytes.bytesize)
            raise Hive::ConfigError,
                  "installed-user inventory changed while it was read"
          end
          raise Hive::ConfigError, "installed-user inventory is too large" if
            bytes.bytesize > MAX_BYTES
        end

        def stable_file?(before, after, bytesize)
          same_file?(before, after) && after.size == bytesize
        end

        def same_file?(before, after)
          fields = %i[dev ino uid gid mode size]
          fields.concat(%i[mtime ctime]) if
            before.respond_to?(:mtime) && after.respond_to?(:mtime) &&
            before.respond_to?(:ctime) && after.respond_to?(:ctime)
          fields.all? do |field|
            before.public_send(field) == after.public_send(field)
          end
        end

        def validate_document!(document)
          unless document.is_a?(Hash) &&
                 document.keys.sort ==
                   %w[discovery_closed profiles schema schema_version] &&
                 document["schema"] == SCHEMA &&
                 document["schema_version"] == SCHEMA_VERSION &&
                 [ true, false ].include?(document["discovery_closed"]) &&
                 document["profiles"].is_a?(Array) &&
                 document["profiles"].length <= MAX_PROFILES
            raise Hive::ConfigError,
                  "installed-user inventory has an unsupported or malformed schema"
          end
        end

        def parse_profile(entry)
          unless entry.is_a?(Hash) &&
                 entry.keys.sort == %w[environment home uid username] &&
                 entry["username"].is_a?(String) &&
                 !entry["username"].empty? &&
                 entry["uid"].is_a?(Integer) &&
                 entry["uid"] >= 0 &&
                 PathValue.absolute?(entry["home"]) &&
                 entry["environment"].is_a?(Hash) &&
                 (entry["environment"].keys - ENV_KEYS).empty?
            raise Hive::ConfigError,
                  "installed-user inventory contains a malformed profile"
          end
          environment = entry["environment"].each_with_object({}) do |(key, value), result|
            unless PathValue.absolute?(value)
              raise Hive::ConfigError,
                    "installed-user inventory contains a malformed environment path"
            end

            result[key] = File.expand_path(value).freeze
          end.freeze
          {
            username: entry["username"].freeze,
            uid: entry["uid"],
            home: File.expand_path(entry["home"]).freeze,
            environment: environment
          }.freeze
        end
      end

      class Catalog
        DEFAULT_EVIDENCE = %w[
          .config/hive/config.yml
          .hive-state/registry.yml
          Dev/hive/config.yml
        ].freeze

        class PathProbe
          Result = Data.define(:state, :kind, :detail)

          def initialize(lstat: File.method(:lstat))
            @lstat = lstat
          end

          def directory(path)
            probe(path, :directory)
          end

          def regular_file(path)
            probe(path, :regular)
          end

          private

          def probe(path, expected)
            stat = @lstat.call(path)
            present =
              expected == :directory ? stat.directory? : stat.file?
            return Result.new(
              state: :present, kind: expected, detail: nil
            ) if present && !stat.symlink?

            Result.new(
              state: :unavailable,
              kind: expected,
              detail: "unsafe #{stat.ftype} at #{path}"
            )
          rescue Errno::ENOENT, Errno::ENOTDIR
            Result.new(state: :missing, kind: expected, detail: nil)
          rescue SystemCallError, IOError => error
            Result.new(
              state: :unavailable,
              kind: expected,
              detail: "#{error.class}: #{error.message}"
            )
          end
        end

        class PathUnavailable < StandardError; end
        private_constant :PathUnavailable

        def initialize(
          accounts: lambda {
            NssQuery.new.accounts
          },
          inventory: Inventory.new,
          probe: PathProbe.new,
          realpath: File.method(:realpath),
          supplementary_groups: SupplementaryGroups.new,
          root_bindings: ProfileRootBindings.new
        )
          @accounts = accounts
          @inventory = inventory
          @probe = probe
          @realpath = realpath
          @supplementary_groups = supplementary_groups
          @root_bindings = root_bindings
        end

        def snapshot(nss_snapshot: nil, nss_error: nil)
          accounts, account_issues =
            if nss_snapshot
              indexed_accounts(nss_snapshot.accounts)
            else
              indexed_accounts
            end
          if nss_error
            account_issues = account_issues + [
              DiscoveryIssue.new(
                kind: "nss_catalog_unavailable",
                username: nil,
                uid: nil,
                detail: nss_error.to_s
              )
            ]
          end
          supplementary_groups =
            if nss_snapshot
              SupplementaryGroups.new(
                groups: -> { nss_snapshot.groups }
              )
            else
              @supplementary_groups
            end
          inventory = @inventory.read
          issues = inventory.issues.dup.concat(account_issues)
          profiles = default_profiles(
            accounts, issues, supplementary_groups
          )
          inventory.profiles.each do |entry|
            profile = inventory_profile(
              entry, accounts, issues, supplementary_groups
            )
            profiles << profile if profile
          end
          profiles = reject_ambiguous_roots(profiles, issues)
            .sort_by { |profile| [ profile.uid, profile.source, profile.home ] }
          Snapshot.new(
            profiles: profiles.freeze,
            issues: issues.freeze,
            closed: inventory.closed,
            inventory_path: inventory.path,
            inventory_digest: inventory.digest
          )
        end

        private

        def indexed_accounts(rows = nil)
          issues = []
          result = {}
          ambiguous = {}
          Array(rows || @accounts.call).each do |account|
            username = account_field(account, :name).to_s
            uid = Integer(account_field(account, :uid))
            gid = Integer(account_field(account, :gid))
            home = account_field(account, :dir).to_s
            next if username.empty? || home.empty?
            next if uid.negative? || gid.negative?
            next unless PathValue.absolute?(home)

            candidate = {
              username: username,
              uid: uid,
              gid: gid,
              home: File.expand_path(home)
            }.freeze
            next if ambiguous[uid]
            if result.key?(uid) && result.fetch(uid) != candidate
              issues << DiscoveryIssue.new(
                kind: "nss_uid_ambiguous",
                username: username,
                uid: uid,
                detail: "multiple NSS identities share one uid"
              )
              result.delete(uid)
              ambiguous[uid] = true
              next
            end
            result[uid] = candidate
          rescue ArgumentError, TypeError, KeyError
            next
          end
          [ result.freeze, issues.freeze ]
        rescue Hive::ConfigError => error
          issues << DiscoveryIssue.new(
            kind: "nss_catalog_unavailable",
            username: nil,
            uid: nil,
            detail: error.message
          )
          [ {}.freeze, issues.freeze ]
        end

        def default_profiles(accounts, issues, supplementary_groups)
          accounts.values.filter_map do |account|
            home = @probe.directory(account.fetch(:home))
            next if home.state == :missing
            if home.state == :unavailable
              issues << issue_for(
                account, "default_home_unavailable", home.detail
              )
              next
            end

            unavailable = nil
            present = DEFAULT_EVIDENCE.any? do |relative|
              result = @probe.regular_file(
                File.join(account.fetch(:home), relative)
              )
              unavailable ||= result if result.state == :unavailable
              result.state == :present
            end
            unless present
              if unavailable
                issues << issue_for(
                  account, "default_home_unavailable",
                  unavailable.detail
                )
              end
              next
            end

            build_profile(
              account,
              environment: {},
              source: "default-home",
              supplementary_groups: supplementary_groups
            )
          rescue Hive::ConfigError, SystemCallError,
                 PathUnavailable => error
            issues << issue_for(
              account, "default_home_unavailable",
              "#{error.class}: #{error.message}"
            )
            nil
          end
        end

        def inventory_profile(entry, accounts, issues,
                              supplementary_groups)
          account = accounts[entry.fetch(:uid)]
          unless account &&
                 account.fetch(:username) == entry.fetch(:username) &&
                 account.fetch(:home) == entry.fetch(:home)
            issues << DiscoveryIssue.new(
              kind: "inventory_identity_drift",
              username: entry[:username],
              uid: entry[:uid],
              detail: "inventory profile no longer matches the NSS identity"
            )
            return nil
          end

          build_profile(
            account,
            environment: entry.fetch(:environment),
            source: "root-inventory",
            supplementary_groups: supplementary_groups
          )
        rescue Hive::ConfigError, SystemCallError,
               PathUnavailable => error
          issues << issue_for(
            account || entry, "inventory_home_unavailable",
            "#{error.class}: #{error.message}"
          )
          nil
        end

        def build_profile(account, environment:, source:,
                          supplementary_groups:)
          home = account.fetch(:home)
          result = @probe.directory(home)
          unless result.state == :present
            raise PathUnavailable,
                  result.detail || "home is #{result.state}"
          end

          real_home = @realpath.call(home)
          groups = supplementary_groups.call(
            account.fetch(:username), account.fetch(:gid)
          )
          bindings = @root_bindings.bind(
            home: home,
            environment: environment,
            uid: account.fetch(:uid)
          )
          Profile.new(
            username: account.fetch(:username),
            uid: account.fetch(:uid),
            gid: account.fetch(:gid),
            home: home,
            real_home: real_home,
            environment:
              ProfileRoots.canonical_environment(environment, bindings),
            source: source,
            supplementary_gids: groups,
            root_bindings: bindings
          ).freeze
        end

        def reject_ambiguous_roots(profiles, issues)
          exact = {}
          conflicting = Set.new
          environment_conflicts = []
          environment_conflict_owners = Set.new
          profiles.each do |profile|
            key = profile_key(profile)
            if exact.key?(key)
              prior = exact.fetch(key)
              if prior.environment != profile.environment
                conflicting << prior
                conflicting << profile
                owner = [ profile.uid, profile.username ]
                unless environment_conflict_owners.include?(owner)
                  environment_conflict_owners << owner
                  environment_conflicts << profile
                end
              end
              next
            end
            exact[key] = profile
          end
          roots = Hash.new { |hash, key| hash[key] = [] }
          exact.each do |identity, profile|
            canonical_profile_roots(profile).each_value do |root_key|
              roots[root_key] << [ identity, profile ]
            end
          end
          roots.each do |root_key, members|
            identities = members.map(&:first).uniq
            next unless identities.length > 1

            members.each do |_identity, profile|
              conflicting << profile
              issues << DiscoveryIssue.new(
                kind: "shared_profile_root",
                username: profile.username,
                uid: profile.uid,
                detail:
                  "one Hive profile root is assigned to distinct installed " \
                  "user profiles (root identity #{root_key.inspect})"
              )
            end
          end
          containment_reported = Set.new
          exact.to_a.combination(2) do |(left_identity, left),
                                        (right_identity, right)|
            next if left_identity == right_identity
            next unless roots_overlap_by_containment?(left, right)

            [ left, right ].each do |profile|
              conflicting << profile
              next unless containment_reported.add?(profile)

              issues << DiscoveryIssue.new(
                kind: "shared_profile_root",
                username: profile.username,
                uid: profile.uid,
                detail:
                  "one Hive profile root contains another installed-user " \
                  "profile root"
              )
            end
          end
          environment_conflicts.each do |profile|
            issues << DiscoveryIssue.new(
              kind: "profile_root_ambiguous",
              username: profile.username,
              uid: profile.uid,
              detail:
                "multiple environments assign different runtime roots to " \
                "the same config/state profile"
            )
          end

          exact.values.reject { |profile| conflicting.include?(profile) }
        end

        def profile_key(profile)
          roots = canonical_profile_roots(profile)
          [ profile.uid, roots.fetch(:config_home), roots.fetch(:state_home) ]
        end

        def canonical_profile_roots(profile)
          profile.root_bindings.to_h do |binding|
            [ binding.kind, @root_bindings.key(binding) ]
          end
        end

        def roots_overlap_by_containment?(left, right)
          left.root_bindings.any? do |left_binding|
            right.root_bindings.any? do |right_binding|
              left_path = left_binding.canonical_path
              right_path = right_binding.canonical_path
              strict_descendant?(left_path, right_path) ||
                strict_descendant?(right_path, left_path)
            end
          end
        end

        def strict_descendant?(path, ancestor)
          prefix =
            ancestor == File::SEPARATOR ? ancestor :
              "#{ancestor}#{File::SEPARATOR}"
          path.start_with?(prefix) && path != ancestor
        end

        def issue_for(account, kind, detail)
          DiscoveryIssue.new(
            kind: kind,
            username: account[:username],
            uid: account[:uid],
            detail: detail
          )
        end

        def account_field(account, name)
          return account.public_send(name) if account.respond_to?(name)

          account.fetch(name)
        end
      end

      # Rebinds the captured profile to both NSS lookup directions immediately
      # before any child is forked. The catalog is authoritative for discovery,
      # but a long-running package hook must not reuse a uid/name/home tuple
      # after account replacement or directory-service drift.
      class NssIdentity
        def initialize(
          query: NssQuery.new,
          by_uid: nil,
          by_name: nil,
          supplementary_groups: nil
        )
          if by_uid || by_name
            unless by_uid && by_name
              raise ArgumentError,
                    "both NSS identity lookup seams must be supplied"
            end
            @query = nil
            @by_uid = by_uid
            @by_name = by_name
            @supplementary_groups = supplementary_groups ||
              SupplementaryGroups.new(groups: -> { [] })
          else
            @query = query
          end
        end

        def call(profile, deadline: nil)
          if @query
            identity = @query.identity(
              profile.username, profile.uid, deadline: deadline
            )
            uid_entry = identity.by_uid
            name_entry = identity.by_name
            groups = identity.supplementary_gids
          else
            uid_entry = @by_uid.call(profile.uid)
            name_entry = @by_name.call(profile.username)
            groups = @supplementary_groups.call(
              profile.username, profile.gid
            )
          end
          unless exact?(uid_entry, profile) && exact?(name_entry, profile)
            raise Hive::ConfigError,
                  "installed-user NSS identity changed after discovery for " \
                  "uid #{profile.uid}"
          end
          unless groups == profile.supplementary_gids
            raise Hive::ConfigError,
                  "installed-user supplementary groups changed after " \
                  "discovery for uid #{profile.uid}"
          end

          true
        rescue ArgumentError, KeyError
          raise Hive::ConfigError,
                "installed-user NSS identity disappeared after discovery for " \
                "uid #{profile.uid}"
        end

        private

        def exact?(entry, profile)
          entry.name.to_s == profile.username &&
            Integer(entry.uid) == profile.uid &&
            Integer(entry.gid) == profile.gid &&
            File.expand_path(entry.dir.to_s) == profile.home
        rescue ArgumentError, TypeError
          false
        end
      end

      class ChildLauncher
        def initialize(
          identity_drop:,
          session: Process.method(:setsid),
          environment: ENV,
          stdout_reopen: STDOUT.method(:reopen),
          stderr_reopen: STDERR.method(:reopen),
          umask: File.method(:umask),
          chdir: Dir.method(:chdir),
          execer: Kernel.method(:exec),
          warning: Kernel.method(:warn),
          exit_process: Process.method(:exit!),
          root_bindings: ProfileRootBindings.new
        )
          @identity_drop = identity_drop
          @session = session
          @environment = environment
          @stdout_reopen = stdout_reopen
          @stderr_reopen = stderr_reopen
          @umask = umask
          @chdir = chdir
          @execer = execer
          @warning = warning
          @exit_process = exit_process
          @root_bindings = root_bindings
        end

        def call(profile, environment, argv, readers:, writers:)
          readers.each(&:close)
          @stdout_reopen.call(writers.fetch(:stdout))
          @stderr_reopen.call(writers.fetch(:stderr))
          writers.each_value(&:close)
          @session.call
          @identity_drop.call(profile)
          @root_bindings.verify!(profile)
          @environment.replace(environment)
          @umask.call(0o077)
          @chdir.call(profile.home)
          @execer.call(*argv, close_others: true)
        rescue StandardError => error
          @warning.call(
            "hive: cannot execute candidate migration as uid " \
            "#{profile.uid}: #{error.class}: #{error.message}"
          )
          @exit_process.call(126)
        end
      end

      class Executor
        MAX_CAPTURE_BYTES = 1024 * 1024
        DEFAULT_TIMEOUT_SEC = 900
        SAFE_PATHS = [
          File.dirname(RbConfig.ruby),
          "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
          "/usr/sbin", "/sbin"
        ].uniq.freeze

        def initialize(binary:, candidate: nil,
                       effective_uid: -> { Process.euid },
                       identity_drop: IdentityDrop.new, runner: nil,
                       identity_validator: NssIdentity.new,
                       child_launcher: nil,
                       directory: File.method(:directory?),
                       realpath: File.method(:realpath),
                       root_bindings: ProfileRootBindings.new,
                       process_kill: Process.method(:kill),
                       process_waitpid2: Process.method(:waitpid2),
                       force: true,
                       timeout_sec: DEFAULT_TIMEOUT_SEC,
                       monotonic_clock: lambda {
                         Process.clock_gettime(Process::CLOCK_MONOTONIC)
                       })
          @binary = File.expand_path(binary)
          @candidate = candidate ||
            CandidateIdentity.capture(@binary)
          @effective_uid = effective_uid
          @identity_validator = identity_validator
          @child_launcher = child_launcher ||
            ChildLauncher.new(
              identity_drop: identity_drop,
              root_bindings: root_bindings
            )
          @directory = directory
          @realpath = realpath
          @root_bindings = root_bindings
          @process_kill = process_kill
          @process_waitpid2 = process_waitpid2
          @force = force == true
          @runner = runner
          @timeout_sec = Float(timeout_sec)
          raise ArgumentError, "timeout_sec must be positive" unless
            @timeout_sec.positive?

          @monotonic_clock = monotonic_clock
        end

        def call(profile, deadline: nil)
          CandidateIdentity.verify!(@candidate)
          begin
            if !@runner && !@effective_uid.call.zero?
              raise Hive::ConfigError,
                    "install-wide JobStore migration requires root authority"
            end
            assert_profile_current!(profile, deadline: deadline)
            environment = child_environment(profile)
            if @runner
              return validate_payload!(
                @runner.call(profile, environment, argv), profile
              )
            end

            stdout, stderr, status = capture_as_user(
              profile, environment, deadline: deadline
            )
            unless status.success?
              detail =
                BoundedDiagnostic.call(stderr.empty? ? stdout : stderr)
              raise Hive::Error,
                    "candidate migration failed for uid #{profile.uid} " \
                    "(exit #{status.exitstatus}): #{detail}"
            end
            validate_payload!(JSON.parse(stdout), profile)
          ensure
            CandidateIdentity.verify!(@candidate)
          end
        rescue JSON::ParserError => error
          raise Hive::ConfigError,
                "candidate migration returned malformed JSON for uid " \
                "#{profile.uid}: #{error.message}"
        end

        private

        def argv
          args = [ @binary, "refactor-patrol-migrate-installed" ]
          args << "--resume" unless @force
          args.freeze
        end

        def assert_profile_current!(profile, deadline:)
          if @identity_validator.method(:call).parameters.any? do |kind, name|
               %i[key keyreq].include?(kind) && name == :deadline
             end
            @identity_validator.call(profile, deadline: deadline)
          else
            @identity_validator.call(profile)
          end
          unless @directory.call(profile.home) &&
                 @realpath.call(profile.home) == profile.real_home
            raise Hive::ConfigError,
                  "installed-user home changed after discovery for uid #{profile.uid}"
          end
          @root_bindings.verify!(profile)
        rescue SystemCallError => error
          raise Hive::ConfigError,
                "cannot revalidate installed-user home for uid " \
                "#{profile.uid}: #{error.message}"
        end

        def child_environment(profile)
          base = {
            "HOME" => profile.home,
            "USER" => profile.username,
            "LOGNAME" => profile.username,
            "PATH" => SAFE_PATHS.join(File::PATH_SEPARATOR),
            "LANG" => "C.UTF-8",
            "HIVE_INVOKED_BIN" => @binary,
            "HIVE_JOB_SCHEMA_MIGRATION_INTERNAL" => "1"
          }.merge(profile.environment)
          bindings = profile.root_bindings.to_h do |binding|
            [ binding.kind, binding.canonical_path ]
          end
          base[Hive::Paths::JOB_SCHEMA_CONFIG_HOME] =
            bindings.fetch(:config_home)
          base[Hive::Paths::JOB_SCHEMA_STATE_HOME] =
            bindings.fetch(:state_home)
          base.freeze
        end

        def capture_as_user(profile, environment, deadline: nil)
          pid = nil
          waited = false
          waiter = nil
          child_deadline = nil
          stdout_reader, stdout_writer = IO.pipe
          stderr_reader, stderr_writer = IO.pipe
          readers = [ stdout_reader, stderr_reader ]
          writers = { stdout: stdout_writer, stderr: stderr_writer }
          launcher = @child_launcher
          child = -> { launcher.call(profile, environment, argv, readers:, writers:) }
          pid = fork(&child)
          waiter = Thread.new do
            @process_waitpid2.call(pid)&.last
          rescue Errno::ECHILD
            nil
          end
          waiter.report_on_exception = false
          stdout_writer.close
          stderr_writer.close
          child_deadline = [
            @monotonic_clock.call + @timeout_sec,
            deadline
          ].compact.min
          stdout, stderr, status = read_and_wait_bounded(
            pid,
            { stdout: stdout_reader, stderr: stderr_reader },
            deadline: child_deadline,
            waiter: waiter
          )
          waited = true
          [ stdout, stderr, status ]
        ensure
          cleanup_child(
            pid, waiter: waiter, deadline: child_deadline
          ) unless
            waited || pid.nil?
          [ stdout_reader, stdout_writer, stderr_reader, stderr_writer ].compact.each do |io|
            close_stream(io)
          end
        end

        def read_and_wait_bounded(pid, streams, deadline:, waiter:)
          outputs = streams.to_h { |name, _io| [ name, +"" ] }
          captures = streams.to_h { |name, io| [ io, name ] }
          total = 0
          status = nil
          until status && captures.empty?
            remaining = deadline - @monotonic_clock.call
            if remaining <= 0
              kill_child(pid)
              raise Hive::ConfigError,
                    "candidate migration exceeded #{@timeout_sec} seconds"
            end
            unless captures.empty?
              ready = IO.select(
                captures.keys, nil, nil, [ remaining, 0.05 ].min
              )

              Array(ready&.first).each do |io|
                chunk = io.read_nonblock(16 * 1024, exception: false)
                if chunk.nil?
                  io.close
                  captures.delete(io)
                  next
                end
                next if chunk == :wait_readable

                total += chunk.bytesize
                if total > MAX_CAPTURE_BYTES
                  kill_child(pid)
                  raise Hive::ConfigError,
                        "candidate migration output exceeded the bounded capture"
                end
                outputs.fetch(captures.fetch(io)) << chunk
              end
            else
              IO.select(nil, nil, nil, [ remaining, 0.05 ].min)
            end
            unless status
              status = waiter.value if waiter.join(0)
            end
          end
          [
            outputs.fetch(:stdout, ""),
            outputs.fetch(:stderr, ""),
            status
          ]
        end

        def validate_payload!(payload, profile)
          user_profile = expected_user_profile(profile)
          validator =
            Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new(
              root: "/",
              user_profile: user_profile
            )
          unless validator.valid_payload?(
            payload,
            hive_version: @candidate.version,
            user_profile: user_profile
          )
            raise Hive::ConfigError,
                  "candidate migration returned an invalid user-profile receipt"
          end

          payload
        end

        def expected_user_profile(profile)
          roots = profile.root_bindings.to_h do |binding|
            [ binding.kind, binding.canonical_path ]
          end
          {
            "username" => profile.username,
            "uid" => profile.uid,
            "home" => profile.home,
            "config_home" => roots.fetch(:config_home),
            "state_home" => roots.fetch(:state_home)
          }.freeze
        end

        def kill_child(pid)
          ProcessGroup.kill(@process_kill, pid)
        end

        def cleanup_child(pid, waiter: nil, deadline: nil)
          begin
            kill_child(pid)
          rescue SystemCallError
            nil
          end
          if waiter
            remaining =
              deadline ? [ deadline - @monotonic_clock.call, 0 ].max : 0
            waiter.join(remaining)
          else
            @process_waitpid2.call(pid, Process::WNOHANG)
          end
          nil
        rescue Errno::ECHILD
          nil
        end

        def close_stream(io)
          io.close unless io.closed?
        rescue IOError
          nil
        end
      end

      class IdentityDrop
        def initialize(
          groups_setter: Process.method(:groups=),
          gid_drop: Process::GID.method(:change_privilege),
          uid_drop: Process::UID.method(:change_privilege),
          effective_uid: -> { Process.euid },
          effective_gid: -> { Process.egid },
          groups: -> { Process.groups }
        )
          @groups_setter = groups_setter
          @gid_drop = gid_drop
          @uid_drop = uid_drop
          @effective_uid = effective_uid
          @effective_gid = effective_gid
          @groups = groups
        end

        def call(profile)
          expected_groups = profile.supplementary_gids
          if !profile.uid.zero? && expected_groups.include?(0)
            raise Hive::ConfigError,
                  "candidate child identity includes root supplementary group"
          end
          @groups_setter.call(expected_groups)
          @gid_drop.call(profile.gid)
          @uid_drop.call(profile.uid)
          observed_groups = @groups.call.map { |gid| Integer(gid) }.uniq.sort
          unless @effective_uid.call == profile.uid &&
                 @effective_gid.call == profile.gid &&
                 observed_groups == expected_groups
            raise Hive::ConfigError,
                  "candidate child did not assume the complete identity for " \
                  "uid #{profile.uid}"
          end

          true
        end
      end

      class CandidateIdentity
        MAX_BYTES = 4 * 1024 * 1024

        def self.capture(
          path,
          realpath: File.method(:realpath),
          opener: File.method(:open),
          lstat: File.method(:lstat),
          trusted_uid: nil
        )
          resolved = realpath.call(path)
          unless File.const_defined?(:NOFOLLOW)
            raise Hive::ConfigError,
                  "install-wide migration candidate requires no-follow file support"
          end
          flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
          stat = nil
          after = nil
          bytes = nil
          opener.call(resolved, flags) do |file|
            stat = file.stat
            unless stat.file? && stat.size.positive? &&
                   (stat.mode & 0o111).positive? &&
                   stat.size <= MAX_BYTES &&
                   (trusted_uid.nil? || (
                     stat.uid == trusted_uid &&
                     (stat.mode & 0o022).zero? &&
                     stat.nlink == 1
                   ))
              raise Hive::ConfigError,
                    "install-wide migration candidate is not a bounded executable file"
            end
            bytes = file.read(MAX_BYTES + 1) || +""
            after = file.stat
          end
          path_after = lstat.call(resolved)
          unless stable?(stat, after, bytes.bytesize) &&
                 stable?(after, path_after, bytes.bytesize)
            raise Hive::ConfigError,
                  "install-wide migration candidate changed during capture"
          end

          Candidate.new(
            path: resolved,
            dev: after.dev,
            ino: after.ino,
            size: after.size,
            mode: after.mode,
            uid: after.uid,
            gid: after.gid,
            mtime: after.mtime,
            ctime: after.ctime,
            sha256: Digest::SHA256.hexdigest(bytes),
            version: Hive::VERSION
          ).freeze
        rescue SystemCallError => error
          raise Hive::ConfigError,
                "cannot capture install-wide migration candidate: " \
                "#{error.class}: #{error.message}"
        end

        def self.verify!(candidate)
          current = capture(candidate.path)
          unless current == candidate
            raise Hive::ConfigError,
                  "install-wide migration candidate changed after activation"
          end

          true
        end

        def self.stable?(before, after, bytesize)
          %i[dev ino size mode uid gid mtime ctime].all? do |field|
            before.public_send(field) == after.public_send(field)
          end && after.size == bytesize
        end
        private_class_method :stable?
      end
    end
  end
end
