require "digest"
require "etc"
require "json"
require "rbconfig"
require "set"
require "time"
require "hive"
require "hive/invoked_binary"
require "hive/refactor_patrol/registered_project_migration_status"
require "hive/secret_patterns"

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

      Profile = Data.define(
        :username, :uid, :gid, :home, :real_home, :environment, :source
      )
      Candidate = Data.define(
        :path, :dev, :ino, :size, :mode, :uid, :gid, :mtime, :ctime,
        :sha256, :version
      )
      DiscoveryIssue = Data.define(:kind, :username, :uid, :detail)
      Snapshot = Data.define(
        :profiles, :issues, :closed, :inventory_path, :inventory_digest
      )

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
      end

      attr_reader :last_payload

      def initialize(
        catalog: Catalog.new,
        executor: nil,
        binary_path: Hive::InvokedBinary.method(:path),
        candidate: nil,
        clock: -> { Time.now.utc },
        effective_uid: -> { Process.euid }
      )
        @catalog = catalog
        @executor = executor
        @binary_path = binary_path
        @candidate = candidate
        @clock = clock
        @effective_uid = effective_uid
        @last_payload = nil
      end

      def call(now: nil, force: true)
        unless @effective_uid.call.zero?
          raise Hive::ConfigError,
                "install-wide JobStore migration requires root authority"
        end

        time = utc(now || @clock.call)
        snapshot = @catalog.snapshot
        candidate = @candidate || CandidateIdentity.capture(candidate_binary)
        executor = @executor ||
          Executor.new(
            binary: candidate.path,
            candidate: candidate,
            force: force
          )
        profiles = snapshot.profiles.map do |profile|
          migrate_profile(profile, executor)
        end.freeze
        issues = snapshot.issues.map do |issue|
          {
            "kind" => issue.kind,
            "username" => issue.username,
            "uid" => issue.uid,
            "detail" => bounded(issue.detail)
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
        @last_payload = {
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

      private

      def candidate_binary
        path = @binary_path.call
        unless path && File.file?(path) && File.executable?(path)
          raise Hive::UnavailableError,
                "install-wide JobStore migration candidate binary is unavailable"
        end

        File.expand_path(path)
      end

      def migrate_profile(profile, executor)
        payload = executor.call(profile)
        projects = Array(payload["projects"])
        retryable = projects.any? { |project| project["retryable"] == true }
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
          "error" => bounded("#{error.class}: #{error.message}")
        }
      end

      def profile_digest(profile)
        Digest::SHA256.hexdigest(JSON.generate(
          "uid" => profile.uid,
          "home" => profile.home,
          "real_home" => profile.real_home,
          "environment" => profile.environment.sort.to_h
        ))
      end

      def bounded(value)
        Hive::SecretPatterns.redact(value.to_s)
          .byteslice(0, MAX_ERROR_BYTES).to_s.scrub("")
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
                 absolute_path?(entry["home"]) &&
                 entry["environment"].is_a?(Hash) &&
                 (entry["environment"].keys - ENV_KEYS).empty?
            raise Hive::ConfigError,
                  "installed-user inventory contains a malformed profile"
          end
          environment = entry["environment"].each_with_object({}) do |(key, value), result|
            unless value.is_a?(String) && absolute_path?(value)
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

        def absolute_path?(value)
          value.is_a?(String) &&
            !value.empty? &&
            value.each_byte.none? { |byte| byte < 0x20 || byte == 0x7f } &&
            File.absolute_path(value) == value
        end
      end

      class Catalog
        DEFAULT_EVIDENCE = %w[
          .config/hive/config.yml
          .hive-state/registry.yml
          Dev/hive/config.yml
        ].freeze

        def initialize(
          accounts: lambda {
            entries = []
            Etc.passwd { |entry| entries << entry }
            entries
          },
          inventory: Inventory.new,
          directory: File.method(:directory?),
          file: File.method(:file?),
          realpath: File.method(:realpath)
        )
          @accounts = accounts
          @inventory = inventory
          @directory = directory
          @file = file
          @realpath = realpath
        end

        def snapshot
          accounts, account_issues = indexed_accounts
          inventory = @inventory.read
          issues = inventory.issues.dup.concat(account_issues)
          profiles = default_profiles(accounts, issues)
          inventory.profiles.each do |entry|
            profile = inventory_profile(entry, accounts, issues)
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

        def indexed_accounts
          issues = []
          result = {}
          ambiguous = {}
          Array(@accounts.call).each do |account|
            username = account_field(account, :name).to_s
            uid = Integer(account_field(account, :uid))
            gid = Integer(account_field(account, :gid))
            home = account_field(account, :dir).to_s
            next if username.empty? || home.empty?
            next if uid.negative? || gid.negative?
            next unless absolute_path?(home)

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
        end

        def default_profiles(accounts, issues)
          accounts.values.filter_map do |account|
            next unless @directory.call(account.fetch(:home))
            next unless DEFAULT_EVIDENCE.any? do |relative|
              @file.call(File.join(account.fetch(:home), relative))
            end

            build_profile(account, environment: {}, source: "default-home")
          rescue SystemCallError => error
            issues << issue_for(
              account, "default_home_unavailable",
              "#{error.class}: #{error.message}"
            )
            nil
          end
        end

        def inventory_profile(entry, accounts, issues)
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
            source: "root-inventory"
          )
        rescue SystemCallError => error
          issues << issue_for(
            account || entry, "inventory_home_unavailable",
            "#{error.class}: #{error.message}"
          )
          nil
        end

        def build_profile(account, environment:, source:)
          home = account.fetch(:home)
          raise Errno::ENOENT, home unless @directory.call(home)

          real_home = @realpath.call(home)
          Profile.new(
            username: account.fetch(:username),
            uid: account.fetch(:uid),
            gid: account.fetch(:gid),
            home: home,
            real_home: real_home,
            environment: environment.freeze,
            source: source
          ).freeze
        end

        def reject_ambiguous_roots(profiles, issues)
          exact = {}
          conflicting = Set.new
          roots = Hash.new { |hash, key| hash[key] = [] }
          profiles.each do |profile|
            key = profile_key(profile)
            if exact.key?(key)
              prior = exact.fetch(key)
              if prior.environment != profile.environment
                conflicting << prior
                conflicting << profile
              end
              next
            end
            exact[key] = profile
            canonical_profile_roots(profile).each do |kind, path|
              roots[[ kind, path ]] << profile
            end
          end
          roots.each do |(kind, path), members|
            next unless members.map(&:uid).uniq.length > 1

            members.each do |profile|
              conflicting << profile
              issues << DiscoveryIssue.new(
                kind: "shared_profile_root",
                username: profile.username,
                uid: profile.uid,
                detail:
                  "#{kind} root #{path} is assigned to multiple OS users"
              )
            end
          end
          conflicting.each do |profile|
            next if issues.any? do |issue|
              issue.kind == "profile_root_ambiguous" &&
                issue.uid == profile.uid &&
                issue.username == profile.username
            end

            matching = profiles.select do |candidate|
              candidate.uid == profile.uid &&
                profile_key(candidate) == profile_key(profile)
            end
            next unless matching.map(&:environment).uniq.length > 1

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
          ProfileRoots.resolve(profile).transform_values do |path|
            @realpath.call(path)
          rescue SystemCallError
            path
          end
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

        def absolute_path?(value)
          value.each_byte.none? { |byte| byte < 0x20 || byte == 0x7f } &&
            File.absolute_path(value) == value
        end
      end

      # Rebinds the captured profile to both NSS lookup directions immediately
      # before any child is forked. The catalog is authoritative for discovery,
      # but a long-running package hook must not reuse a uid/name/home tuple
      # after account replacement or directory-service drift.
      class NssIdentity
        def initialize(
          by_uid: Etc.method(:getpwuid),
          by_name: Etc.method(:getpwnam)
        )
          @by_uid = by_uid
          @by_name = by_name
        end

        def call(profile)
          uid_entry = @by_uid.call(profile.uid)
          name_entry = @by_name.call(profile.username)
          unless exact?(uid_entry, profile) && exact?(name_entry, profile)
            raise Hive::ConfigError,
                  "installed-user NSS identity changed after discovery for " \
                  "uid #{profile.uid}"
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
          exit_process: Process.method(:exit!)
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
        end

        def call(profile, environment, argv, readers:, writers:)
          readers.each(&:close)
          @stdout_reopen.call(writers.fetch(:stdout))
          @stderr_reopen.call(writers.fetch(:stderr))
          writers.each_value(&:close)
          @session.call
          @identity_drop.call(profile)
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
                       process_kill: Process.method(:kill),
                       process_wait: Process.method(:wait),
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
            ChildLauncher.new(identity_drop: identity_drop)
          @directory = directory
          @realpath = realpath
          @process_kill = process_kill
          @process_wait = process_wait
          @force = force == true
          @runner = runner
          @timeout_sec = Float(timeout_sec)
          raise ArgumentError, "timeout_sec must be positive" unless
            @timeout_sec.positive?

          @monotonic_clock = monotonic_clock
        end

        def call(profile)
          CandidateIdentity.verify!(@candidate)
          begin
            assert_profile_current!(profile)
            environment = child_environment(profile)
            if @runner
              return validate_payload!(
                @runner.call(profile, environment, argv), profile
              )
            end

            unless @effective_uid.call.zero?
              raise Hive::ConfigError,
                    "install-wide JobStore migration requires root authority"
            end

            stdout, stderr, status = capture_as_user(profile, environment)
            unless status.success?
              detail = bounded(stderr.empty? ? stdout : stderr)
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

        def assert_profile_current!(profile)
          @identity_validator.call(profile)
          unless @directory.call(profile.home) &&
                 @realpath.call(profile.home) == profile.real_home
            raise Hive::ConfigError,
                  "installed-user home changed after discovery for uid #{profile.uid}"
          end
        rescue SystemCallError => error
          raise Hive::ConfigError,
                "cannot revalidate installed-user home for uid " \
                "#{profile.uid}: #{error.message}"
        end

        def child_environment(profile)
          {
            "HOME" => profile.home,
            "USER" => profile.username,
            "LOGNAME" => profile.username,
            "PATH" => SAFE_PATHS.join(File::PATH_SEPARATOR),
            "LANG" => "C.UTF-8",
            "HIVE_INVOKED_BIN" => @binary,
            "HIVE_JOB_SCHEMA_MIGRATION_INTERNAL" => "1"
          }.merge(profile.environment).freeze
        end

        def capture_as_user(profile, environment)
          pid = nil
          waited = false
          stdout_reader, stdout_writer = IO.pipe
          stderr_reader, stderr_writer = IO.pipe
          readers = [ stdout_reader, stderr_reader ]
          writers = { stdout: stdout_writer, stderr: stderr_writer }
          launcher = @child_launcher
          child = -> { launcher.call(profile, environment, argv, readers:, writers:) }
          pid = fork(&child)
          stdout_writer.close
          stderr_writer.close
          deadline = @monotonic_clock.call + @timeout_sec
          stdout, stderr = read_bounded(
            pid,
            { stdout: stdout_reader, stderr: stderr_reader },
            deadline: deadline
          )
          _child, status = Process.wait2(pid)
          waited = true
          [ stdout, stderr, status ]
        ensure
          cleanup_child(pid) unless waited || pid.nil?
          [ stdout_reader, stdout_writer, stderr_reader, stderr_writer ].compact.each do |io|
            close_stream(io)
          end
        end

        def read_bounded(pid, streams, deadline:)
          outputs = streams.to_h { |name, _io| [ name, +"" ] }
          captures = streams.to_h { |name, io| [ io, name ] }
          total = 0
          until captures.empty?
            remaining = deadline - @monotonic_clock.call
            if remaining <= 0
              kill_child(pid)
              raise Hive::ConfigError,
                    "candidate migration exceeded #{@timeout_sec} seconds"
            end
            ready = IO.select(captures.keys, nil, nil, [ remaining, 0.25 ].min)
            next unless ready

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
          end
          [ outputs.fetch(:stdout, ""), outputs.fetch(:stderr, "") ]
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
          roots = ProfileRoots.resolve(profile)
          {
            "username" => profile.username,
            "uid" => profile.uid,
            "home" => profile.home,
            "config_home" => roots.fetch(:config_home),
            "state_home" => roots.fetch(:state_home)
          }.freeze
        end

        def kill_child(pid)
          @process_kill.call("KILL", -pid)
        rescue Errno::ESRCH
          begin
            @process_kill.call("KILL", pid)
          rescue Errno::ESRCH
            nil
          end
        end

        def cleanup_child(pid)
          begin
            kill_child(pid)
          rescue SystemCallError
            nil
          end
          begin
            @process_wait.call(pid)
          rescue Errno::ECHILD
            nil
          end
        end

        def close_stream(io)
          io.close unless io.closed?
        rescue IOError
          nil
        end

        def bounded(value)
          Hive::SecretPatterns.redact(value.to_s)
            .byteslice(0, MAX_ERROR_BYTES).to_s.scrub("")
        end
      end

      class IdentityDrop
        def initialize(
          initgroups: Process.method(:initgroups),
          gid_drop: Process::GID.method(:change_privilege),
          uid_drop: Process::UID.method(:change_privilege),
          effective_uid: -> { Process.euid },
          effective_gid: -> { Process.egid },
          groups: -> { Process.groups }
        )
          @initgroups = initgroups
          @gid_drop = gid_drop
          @uid_drop = uid_drop
          @effective_uid = effective_uid
          @effective_gid = effective_gid
          @groups = groups
        end

        def call(profile)
          @initgroups.call(profile.username, profile.gid)
          @gid_drop.call(profile.gid)
          @uid_drop.call(profile.uid)
          root_group_retained =
            !profile.gid.zero? && @groups.call.include?(0)
          unless @effective_uid.call == profile.uid &&
                 @effective_gid.call == profile.gid &&
                 !root_group_retained
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
          lstat: File.method(:lstat)
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
                   stat.size <= MAX_BYTES
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
