require "digest"
require "fileutils"
require "json"
require "securerandom"
require "sequel"
require "time"
require "yaml"
require "hive/atomic_file"
require "hive/config"
require "hive/daemon/activation_lock"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/cutover_manifest"
require "hive/runtime_control_plane/maintenance"
require "hive/pid_file"
require "hive/task_meta"

module Hive
  module RuntimeControlPlane
    # One forward-only cutover. File-backed task/artifact authorities stay in
    # place; disposable runtime state is accepted only when it has no owner.
    class Cutover
      Result = Data.define(:phase, :cutover_id, :database_path, :exclusions)
      Target = Data.define(:home, :relative_path, :expected_type)
      TaskIdentity = Data.define(:folder, :id, :workflow)
      FENCE_BYTES = "HIVE_RUNTIME_RETIRED\nUse the active Hive launcher and run hive runtime status.\n".freeze
      ATTEMPT_RUNTIME_PATHS = %w[
        decision-indexes generation-locks log-state maintenance pending-finalization
        proof records routing-policies
      ].freeze
      TARGETS = [
        Target.new(:state, "dispatch_requests", :directory),
        Target.new(:state, "dispatch_results", :directory),
        *ATTEMPT_RUNTIME_PATHS.map { |path| Target.new(:state, "attempts/v4/#{path}", :directory) },
        Target.new(:state, "provider-health", :directory),
        Target.new(:state, "operational", :directory),
        Target.new(:state, ".task-counter.lock", :file),
        Target.new(:state, "task-counter.yml", :file),
        Target.new(:data, "usage.db", :file),
        Target.new(:data, "usage.db-wal", :file),
        Target.new(:data, "usage.db-shm", :file),
        Target.new(:data, "usage.db.patrol-discovery-allowances", :directory)
      ].freeze
      PROJECT_RUNTIME_FILES = %w[
        daemon/pr-merge-reconciliation.json
        daemon/pr-merge-reconciliation.json.lock
      ].freeze
      TASK_RUNTIME_FILES = %w[.lock .lock.tmp.guard].freeze
      MAX_FILE_BYTES = 512 * 1024 * 1024
      REQUIRED_USAGE_COLUMNS = %i[id agent started_at].freeze
      TOKEN_USAGE_COLUMNS = %i[
        id task_id attempt_id agent session_id model requested_backend requested_model
        actual_backend actual_model project_slug task_slug stage started_at ended_at
        input output cached cache_read cache_write reasoning cost input_available
        output_available cached_available cache_read_available cache_write_available
        reasoning_available cost_available task_generation source billing_route
        billing_evidence_source input_includes_cache_read input_includes_cache_write
        output_includes_reasoning
      ].freeze

      class Error < RuntimeControlPlane::Error; end
      class ConfirmationRequired < Error; end
      class ProjectError < Error; end

      def self.cutover(confirm:, exclusions: [], **options) =
        new(**options).run(confirm: confirm, exclusions: exclusions)
      def self.bootstrap(confirm:, **options) = new(**options).bootstrap(confirm: confirm)
      def self.resume(**options) = new(**options).resume

      def self.task_authority(projects)
        Array(projects).sort_by { |project| project.fetch("project_id") }.map do |project|
          root = File.expand_path(project.fetch("hive_state_path", project.fetch("path")))
          { "project_id" => project.fetch("project_id"), "name" => project.fetch("name"),
            "state_path" => root, "sha256" => tree_digest(root, scope: "stages") }
        end.freeze
      end

      def self.tree_digest(root, scope: nil)
        scan_root = scope ? File.join(root, scope) : root
        status = File.lstat(scan_root)
        raise Errno::ENOTDIR, scan_root unless status.directory? && !status.symlink?

        digest = Digest::SHA256.new
        pending = Dir.children(scan_root).sort.reverse.map { |name| File.join(scan_root, name) }
        until pending.empty?
          path = pending.pop
          relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
          next if relative.split(File::SEPARATOR).include?(".git")
          next if retired_task_path?(relative)

          entry = File.lstat(path)
          raise Error.new("task authority contains a symlink", code: :task_authority_unsafe) if entry.symlink?
          if entry.directory?
            Dir.children(path).sort.reverse_each { |name| pending << File.join(path, name) }
          elsif entry.file? && entry.nlink == 1 && entry.size <= MAX_FILE_BYTES
            digest << "f\0#{relative}\0#{entry.mode & 0o7777}\0#{entry.size}\0"
            File.open(path, "rb") { |file| digest << file.read(64 * 1024) until file.eof? }
          else
            raise Error.new("task authority contains an unsafe entry", code: :task_authority_unsafe)
          end
        end
        digest.hexdigest
      rescue SystemCallError => error
        raise Error.new("task authority is unavailable: #{error.message}", code: :task_authority_unavailable)
      end

      def self.retired_task_path?(relative)
        PROJECT_RUNTIME_FILES.include?(relative) || TASK_RUNTIME_FILES.include?(relative) ||
          relative.match?(%r{\Astages/[^/]+/[^/]+/\.lock(?:\.tmp\.guard)?\z})
      end

      def self.inspect_status(state_home:, database:)
        root = File.join(File.expand_path(state_home), ".runtime-cutover", "current")
        phase = CutoverManifest::PHASES.reverse.find do |name|
          File.exist?(File.join(root, "#{name}.json"))
        end
        document = CutoverManifest.new(path: File.join(root, "#{phase}.json")).load.fetch("document") if phase
        diagnosis = database.diagnostics
        if diagnosis.ok?
          unless %w[ready intended active].include?(phase)
            raise Error.new(
              "runtime database has no active cutover manifest and no resumable cutover manifest",
              code: :activation_manifest_missing
            )
          end
          identity = database.installation_identity
          unless identity && identity.fetch(:installation_id) == document.fetch("installation_id") &&
                 identity.fetch(:lineage_id) == document.fetch("lineage_id") &&
                 identity[:activation_epoch] == document.dig("evidence", "activation_epoch")
            raise Error.new("runtime database identity differs from active manifest", code: :activation_identity_mismatch)
          end
        end
        { "phase" => phase || "absent",
          "installation_id" => document && document.fetch("installation_id"),
          "next_action" => %w[ready intended].include?(phase) ? "hive runtime resume" : nil,
          "database" => Codec.normalize(diagnosis.to_h) }
      end

      attr_reader :services

      def initialize(state_home: Hive::Paths.state_home, data_home: Hive::Paths.data_home,
                     projects: Hive::Config.registered_projects, source_release: Hive::VERSION,
                     target_release: Hive::VERSION, services: nil, maintenance_gate: nil,
                     clock: -> { Time.now.utc }, uuid_generator: -> { SecureRandom.uuid }, fault: nil)
        @state_home = File.expand_path(state_home)
        @data_home = File.expand_path(data_home)
        @projects = Array(projects)
        @source_release = source_release.to_s
        @target_release = target_release.to_s
        @services = services || MaintenanceServices.new(state_home: @state_home)
        @gate = maintenance_gate || Hive::Daemon::ActivationLock.new(hive_home: @state_home)
        @clock = clock
        @uuid_generator = uuid_generator
        @fault = fault
      end

      def run(confirm:, exclusions: [])
        return finish_active_activation if current_phase == "active"
        return resume if current_phase
        confirmation! unless confirm
        perform(exclusions: exclusions, fresh: false)
      end

      def bootstrap(confirm:)
        return finish_active_activation if current_phase == "active"
        return resume if current_phase
        confirmation! unless confirm
        material = target_paths.select { |target| path_exists?(target.fetch(:live)) }
        unless material.empty?
          raise Error.new("legacy runtime state exists", code: :legacy_state_present,
                          action: "run hive migrate --all")
        end
        perform(exclusions: [], fresh: true)
      end

      def resume
        phase = current_phase
        return finish_active_activation if phase == "active"
        raise Error.new("no cutover is ready to resume", code: :resume_unavailable) unless phase

        document = load_phase(phase).fetch("document")
        @cutover_id = document.fetch("installation_id")
        @active_projects = active_projects_from(document)
        load_task_identities!(@active_projects)
        raise Error.new("task authority changed during cutover", code: :source_changed) unless
          document.fetch("task_authority") == self.class.task_authority(@active_projects)
        @services.stop!(cutover_id: cutover_id)
        @gate.synchronize do
          if %w[preparing ready].include?(current_phase)
            with_legacy_writer_guards(enabled: !document.dig("evidence", "fresh")) do
              if current_phase == "preparing"
                prepare_ready(
                  @active_projects, document.fetch("exclusions"), document.fetch("task_authority"),
                  document.dig("evidence", "fresh")
                )
              end
              publish_intent_from_ready if current_phase == "ready"
            end
          end
          activate_from_intent
        end
      end

      private

      def perform(exclusions:, fresh:)
        reject_existing_run!
        active, excluded = validate_projects(exclusions)
        @active_projects = active
        task_authority = self.class.task_authority(active)
        prepare_run!
        publish_phase("preparing", active, excluded, task_authority, "fresh" => fresh)
        fault!(:run_prepared)
        @services.stop!(cutover_id: cutover_id)
        fault!(:services_stopped)
        @gate.synchronize do
          with_legacy_writer_guards(enabled: !fresh) do
            prepare_ready(active, excluded, task_authority, fresh)
            publish_intent_from_ready
          end
          activate_from_intent
        end
      end

      def prepare_ready(active, excluded, task_authority, fresh)
        ensure_no_live_database!
        unless fresh
          assert_attempts_quiescent!
        end
        unless task_authority == self.class.task_authority(active)
          raise Error.new("registry or task authority changed during cutover", code: :source_changed)
        end
        epoch = activation_epoch
        activated_at = Codec.dump_time(@clock.call)
        evidence = {
          "usage_expected" => File.file?(legacy_usage_path), "fresh" => fresh,
          "activation_epoch" => epoch, "activated_at" => activated_at
        }
        publish_phase("ready", active, excluded, task_authority, evidence)
        fault!(:fleet_ready)
      end

      def publish_intent_from_ready
        return if manifest_present?("intended")
        ready = load_phase("ready").fetch("document")
        projects = active_projects_from(ready)
        unless ready.fetch("task_authority") == self.class.task_authority(projects)
          raise Error.new("registry or task authority changed during cutover", code: :source_changed)
        end
        evidence = ready.fetch("evidence").dup
        with_usage_snapshot(expected: evidence.delete("usage_expected")) do |usage|
          evidence["usage_snapshot"] = usage if usage
          build_database!(projects, evidence)
          fault!(:database_built)
          seal_and_fence! unless evidence.fetch("fresh")
          fault!(:sources_sealed)
        end
        install_database!(evidence)
        publish_phase("intended", active_projects_from(ready), ready.fetch("exclusions"),
                      ready.fetch("task_authority"), evidence)
        fault!(:activation_intent)
      end

      def activate_from_intent
        document = load_phase("intended").fetch("document")
        @cutover_id = document.fetch("installation_id")
        validate_live_database!(document)
        FileUtils.mkdir_p(Hive::Paths.runtime_payload_root(@state_home), mode: 0o700)
        fault!(:candidate_identity_published)
        @services.activate!
        fault!(:services_activated)
        publish_phase("active", active_projects_from(document), document.fetch("exclusions"),
                      document.fetch("task_authority"), document.fetch("evidence")) unless
          manifest_present?("active")
        fault!(:activation_published)
        result_for("active")
      end

      def finish_active_activation
        document = load_phase("active").fetch("document")
        @cutover_id = document.fetch("installation_id")
        validate_live_database!(document)
        @services.activate! unless @services.activated?
        result_for("active")
      end

      def validate_projects(exclusions)
        names = Array(exclusions).map(&:to_s).uniq.sort
        unknown = names - @projects.map { |project| project.fetch("name") }
        raise ProjectError.new("unknown exclusions: #{unknown.join(', ')}", code: :unknown_exclusion) unless unknown.empty?

        validate_project_identities!
        missing_projects = @projects.select do |project|
          !File.directory?(project.fetch("path")) || !File.directory?(project.fetch("hive_state_path"))
        end
        reachable_exclusions = names - missing_projects.map { |project| project.fetch("name") }
        unless reachable_exclusions.empty?
          raise ProjectError.new(
            "reachable projects must be deregistered, not excluded: #{reachable_exclusions.join(', ')}",
            code: :reachable_project_exclusion
          )
        end
        load_task_identities!(@projects - missing_projects)
        active = []
        excluded = []
        @projects.each do |project|
          missing = !File.directory?(project.fetch("path")) || !File.directory?(project.fetch("hive_state_path"))
          if names.include?(project.fetch("name"))
            excluded << { "name" => project.fetch("name"), "project_id" => project.fetch("project_id"),
                          "reason" => "missing" }
          elsif missing
            raise ProjectError.new("registered project #{project.fetch('name')} is missing", code: :project_missing)
          else
            active << project
          end
        end
        [ active.freeze, excluded.freeze ]
      end

      def validate_project_identities!
        @projects.each do |project|
          registration = project.fetch("registration_id").to_s
          valid_registration = Hive::Config::PROJECT_UUID.match?(registration) ||
            (registration.start_with?("legacy:") &&
             Hive::Config::PROJECT_UUID.match?(registration.delete_prefix("legacy:")))
          unless Hive::Config::PROJECT_UUID.match?(project.fetch("project_id").to_s) && valid_registration
            raise ProjectError.new("registered project identity is invalid", code: :invalid_project_identity)
          end
        end
        %w[project_id registration_id].each do |key|
          values = @projects.map { |project| project.fetch(key) }
          raise ProjectError.new("duplicate #{key}", code: :project_identity_collision) unless values.uniq == values
        end
        roots = @projects.map { |project| Hive::Config.canonical_registration_state_path(project.fetch("hive_state_path")) }
        raise ProjectError.new("duplicate Hive state root", code: :state_root_collision) unless roots.uniq == roots
      rescue KeyError, Hive::Error => error
        raise error if error.is_a?(ProjectError)
        raise ProjectError.new("registered project identity is invalid", code: :invalid_project_identity)
      end

      def load_task_identities!(projects)
        @task_metadata = projects.to_h do |project|
          pattern = File.join(project.fetch("hive_state_path"), "stages", "*", "*")
          tasks = Dir.glob(pattern).select { |folder| File.directory?(folder) }.sort.map do |folder|
            observed = Hive::TaskMeta.read_for_admission(folder)
            unless observed.ok?
              raise ProjectError.new(observed.error || "task metadata is missing",
                                     code: :project_invalid)
            end
            metadata = observed.data
            if metadata[:id].to_s.empty?
              raise ProjectError.new("task #{File.basename(folder)} has no durable id",
                                     code: :task_identity_missing)
            end
            TaskIdentity.new(folder, metadata.fetch(:id).to_s, (metadata[:workflow] || "coding").to_s)
          end
          [ project.fetch("project_id"), tasks ]
        end
        ids = @task_metadata.values.flatten.map(&:id)
        raise ProjectError.new("duplicate task id", code: :task_identity_collision) unless ids.uniq == ids
      end

      def build_database!(projects, evidence)
        return validate_live_database!(evidence) if File.file?(database_path)
        FileUtils.rm_f([ build_path, "#{build_path}-wal", "#{build_path}-shm" ])
        database = Database.new(path: build_path).migrate!
        timestamp = Codec.dump_time(@clock.call)
        database.transaction do |db|
          original = db[:installations].get(:installation_id)
          db[:installations].where(installation_id: original).update(
            installation_id: cutover_id, lineage_id: cutover_id, created_at: timestamp,
            activation_epoch: evidence.fetch("activation_epoch"),
            activated_at: evidence.fetch("activated_at")
          )
          projects.each do |project|
            db[:projects].insert(
              project_id: project.fetch("project_id"), installation_id: cutover_id,
              registration_id: project.fetch("registration_id"), name: project.fetch("name"),
              observed_path: File.expand_path(project.fetch("path")),
              state_root_path: File.expand_path(project.fetch("hive_state_path")),
              repository_identity_json: project["repository_identity"] && Codec.dump_json(project["repository_identity"]),
              active: 1, registered_at: project.fetch("registered_at", timestamp), last_observed_at: timestamp
            )
            insert_tasks(db, project, timestamp)
          end
          import_usage(db) if evidence["usage_snapshot"]
        end
        database.read { |db| db.run("PRAGMA wal_checkpoint(TRUNCATE)") }
        database.disconnect
        diagnosis = Database.new(path: build_path).diagnostics
        raise diagnosis.error unless diagnosis.ok?
        true
      rescue Sequel::Error => error
        raise Error.new("candidate import failed: #{error.message}", code: :candidate_import_failed)
      ensure
        database&.disconnect
      end

      def install_database!(evidence)
        return validate_live_database!(evidence) if File.file?(database_path)
        parent = File.dirname(database_path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        status = File.lstat(parent)
        unless status.directory? && !status.symlink? && status.uid == Process.euid
          raise Error.new("runtime database parent is unsafe", code: :database_custody_invalid)
        end
        File.chmod(0o700, parent)
        File.rename(build_path, database_path)
        Hive::AtomicFile.fsync_directory(parent)
        validate_live_database!(evidence)
      end

      def insert_tasks(db, project, timestamp)
        @task_metadata.fetch(project.fetch("project_id"), []).each do |task|
          db[:task_subjects].insert(
            task_id: task.id, project_id: project.fetch("project_id"),
            workflow_id: task.workflow, task_slug: File.basename(task.folder),
            observed_path: task.folder, source_fingerprint: "", generation: 0,
            created_at: timestamp, last_observed_at: timestamp
          )
        end
      end

      def import_usage(target)
        source = Sequel.connect(adapter: "sqlite", database: usage_snapshot_path, readonly: true,
                                max_connections: 1)
        validate_usage_database!(source)
        columns = source[:token_usage].columns
        target_columns = target[:token_usage].columns
        defaults = {
          input: 0, output: 0, cached: 0,
          input_available: 1, output_available: 1, cached_available: 1,
          cache_read_available: 0, cache_write_available: 0,
          reasoning_available: 0, cost_available: 0
        }
        source[:token_usage].order(:id).each do |record|
          target[:token_usage].insert(defaults.merge(record.slice(*columns)).slice(*target_columns))
        end
      rescue Sequel::Error, KeyError, TypeError => error
        raise Error.new("legacy usage import failed: #{error.message}", code: :usage_snapshot_invalid)
      ensure
        source&.disconnect
      end

      def assert_attempts_quiescent!
        root = File.join(@state_home, "attempts", "v4", "records")
        return unless File.directory?(root)
        Dir.glob(File.join(root, "**", "*.json")).sort.each do |path|
          status = File.lstat(path)
          unless status.file? && !status.symlink? && status.nlink == 1 && status.size <= MAX_FILE_BYTES
            invalid_legacy!("legacy runtime source is unsafe", path: path)
          end
          record = JSON.parse(File.binread(path))
          next if %w[lost terminal].include?(record["state"])
          live!("live attempt remains at #{path}", attempt_id: record["attempt_id"], state: record["state"])
        end
      rescue JSON::ParserError
        invalid_legacy!("legacy runtime JSON is malformed")
      end

      def with_legacy_writer_guards(enabled:)
        handles = []
        return yield unless enabled

        legacy_flock_paths.each { |path| handles << acquire_legacy_guard(path) }
        @task_metadata.values.flatten.each do |task|
          guard = target_paths.find { |target| target.fetch(:live) == File.join(task.folder, ".lock.tmp.guard") }
          next if guard && fence_installed?(guard)
          handles << acquire_legacy_guard(guard.fetch(:live))
          live!("legacy task owner is active", path: task.folder) if legacy_task_lock_live?(task.folder)
        end
        yield
      ensure
        handles.reverse_each do |handle|
          handle.flock(File::LOCK_UN)
          handle.close
        end
      end

      def legacy_flock_paths
        target_paths.filter_map do |target|
          path = target.fetch(:live)
          path if path.end_with?(".lock") && File.basename(path) != ".lock" && !fence_installed?(target)
        end
      end

      def acquire_legacy_guard(path)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        handle = File.open(path, flags, 0o600)
        entry = File.lstat(path)
        opened = handle.stat
        valid = entry.file? && !entry.symlink? && entry.nlink == 1 &&
          entry.uid == Process.euid && entry.dev == opened.dev && entry.ino == opened.ino
        invalid_legacy!("legacy writer lock is unsafe", path: path) unless valid
        live!("legacy writer lock is held", path: path) unless
          handle.flock(File::LOCK_EX | File::LOCK_NB)
        handle
      rescue Error
        handle&.close
        raise
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        handle&.close
        live!("legacy writer lock is held", path: path)
      rescue SystemCallError, IOError => error
        handle&.close
        invalid_legacy!("legacy writer lock is unsafe", path: path, error: error.message)
      end

      def legacy_task_lock_live?(folder)
        path = File.join(folder, ".lock")
        return false unless File.file?(path)
        raw = File.open(path, File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)) do |file|
          file.read(64 * 1024 + 1)
        end
        invalid_legacy!("legacy task lock is oversized", path: path) if raw.bytesize > 64 * 1024
        payload = YAML.safe_load(raw, permitted_classes: [ Time ])
        pid = payload.is_a?(Hash) && payload["pid"]
        return false unless pid.is_a?(Integer) && pid.positive? && Hive::PidFile.alive?(pid)

        recorded = payload["process_start_time"]
        current = Hive::Lock.process_start_time(pid)
        recorded.nil? || current.nil? || recorded == current
      rescue Errno::ENOENT, Psych::Exception
        false
      rescue SystemCallError, IOError => error
        invalid_legacy!("legacy task lock is unsafe", path: path, error: error.message)
      end

      def live!(message, details = {})
        raise Error.new(message, code: :live_runtime_owner, details: details,
                        action: "finish all legacy work and retry")
      end

      def invalid_legacy!(message, details = {})
        raise Error.new(message, code: :legacy_runtime_invalid, details: details)
      end

      def with_usage_snapshot(expected:)
        unless expected
          raise Error.new("legacy usage source appeared during cutover", code: :source_changed) if
            File.file?(legacy_usage_path)
          return yield(nil)
        end
        if fence_installed?(usage_target)
          begin
            return yield(usage_snapshot_evidence)
          rescue Sequel::Error, SystemCallError, IOError
            raise Error.new("sealed usage snapshot is corrupt", code: :sealed_source_corrupt)
          end
        end
        unless File.file?(legacy_usage_path)
          raise Error.new("legacy usage source is missing", code: :sealed_source_corrupt)
        end

        FileUtils.rm_f(usage_snapshot_path)
        source = Sequel.connect(adapter: "sqlite", database: legacy_usage_path,
                                max_connections: 1, timeout: BUSY_TIMEOUT_MS)
        validate_usage_database!(source)
        3.times do
          FileUtils.rm_f(usage_snapshot_path)
          source.run("VACUUM INTO #{source.literal(usage_snapshot_path)}")
          evidence = usage_snapshot_evidence
          snapshot = Sequel.connect(adapter: "sqlite", database: usage_snapshot_path,
                                    readonly: true, max_connections: 1)
          snapshot_digest = usage_content_digest(snapshot)
          snapshot.disconnect
          matched = false
          result = source.transaction(mode: :exclusive, rollback: :always) do
            next unless usage_content_digest(source) == snapshot_digest

            matched = true
            fault!(:usage_snapshotted)
            yield evidence
          end
          return result if matched
        end
        raise Error.new("legacy usage changed during snapshot", code: :source_changed)
      rescue Error
        raise
      rescue Sequel::Error, SystemCallError, IOError => error
        raise Error.new("legacy usage snapshot is invalid: #{error.message}", code: :usage_snapshot_invalid)
      ensure
        source&.disconnect
      end

      def usage_content_digest(database)
        columns = database[:token_usage].columns.sort
        digest = Digest::SHA256.new << Codec.dump_json(columns.map(&:to_s))
        database[:token_usage].select(*columns).order(:id).each do |row|
          digest << Codec.dump_json(row.transform_keys(&:to_s))
        end
        digest.hexdigest
      end

      def usage_snapshot_evidence
        snapshot = Sequel.connect(adapter: "sqlite", database: usage_snapshot_path,
                                  readonly: true, max_connections: 1)
        validate_usage_database!(snapshot)
        { "sha256" => Digest::SHA256.file(usage_snapshot_path).hexdigest,
          "bytes" => File.size(usage_snapshot_path), "rows" => snapshot[:token_usage].count }
      ensure
        snapshot&.disconnect
      end

      def validate_usage_database!(database)
        checks = database.fetch("PRAGMA quick_check").map { |row| row.values.first }
        columns = database.table_exists?(:token_usage) ? database[:token_usage].columns : []
        unless checks == [ "ok" ] && (REQUIRED_USAGE_COLUMNS - columns).empty? &&
               (columns - TOKEN_USAGE_COLUMNS).empty?
          raise Error.new("legacy usage schema is unsupported", code: :usage_snapshot_invalid)
        end
        true
      end

      def validate_usage_snapshot!(evidence)
        path = usage_snapshot_path
        return true if evidence.nil? && !path_exists?(path)
        unless evidence.is_a?(Hash) && evidence.keys.sort == %w[bytes rows sha256] &&
               evidence["bytes"].is_a?(Integer) && evidence["rows"].is_a?(Integer)
          raise Error.new("sealed usage evidence is invalid", code: :sealed_source_corrupt)
        end
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.nlink == 1 && status.size == evidence.fetch("bytes") &&
               Digest::SHA256.file(path).hexdigest == evidence.fetch("sha256")
          raise Error.new("sealed usage snapshot changed", code: :sealed_source_corrupt)
        end
        database = Sequel.connect(adapter: "sqlite", database: path, readonly: true, max_connections: 1)
        validate_usage_database!(database)
        raise Error.new("sealed usage row count changed", code: :sealed_source_corrupt) unless
          database[:token_usage].count == evidence.fetch("rows")
        true
      rescue Sequel::Error, SystemCallError, IOError
        raise Error.new("sealed usage snapshot is corrupt", code: :sealed_source_corrupt)
      ensure
        database&.disconnect
      end

      def seal_and_fence!
        validate_target_shapes!
        target_paths.each do |target|
          next if fence_installed?(target)
          path = target.fetch(:live)
          if path_exists?(path)
            target.fetch(:expected_type) == :file ? File.unlink(path) : FileUtils.rm_r(path)
          end
          install_fence(target.fetch(:live), target.fetch(:expected_type))
          fault!(:fence_installed)
        end
      end

      def validate_target_shapes!
        target_paths.each do |target|
          next if fence_installed?(target)
          path = target.fetch(:live)
          next unless path_exists?(path)

          status = File.lstat(path)
          valid = !status.symlink? && status.uid == Process.euid &&
            if target.fetch(:expected_type) == :file
              status.file? && status.nlink == 1
            else
              status.directory?
            end
          invalid_legacy!("legacy runtime target has an unexpected shape", path: path) unless valid
        end
      rescue SystemCallError => error
        invalid_legacy!("legacy runtime target is unavailable", error: error.message)
      end

      def fence_installed?(target)
        path = target.fetch(:live)
        if target.fetch(:expected_type) == :file
          status = File.lstat(path)
          status.directory? && !status.symlink? && status.uid == Process.euid &&
            safe_fence_file?(File.join(path, "RETIRED"))
        else
          safe_fence_file?(path)
        end
      rescue SystemCallError
        false
      end

      def safe_fence_file?(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          entry = File.lstat(path)
          opened = file.stat
          entry.file? && !entry.symlink? && entry.nlink == 1 && entry.uid == Process.euid &&
            entry.dev == opened.dev && entry.ino == opened.ino && file.read == FENCE_BYTES
        end
      rescue SystemCallError
        false
      end

      def install_fence(path, expected_type)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        if expected_type == :file
          FileUtils.mkdir_p(path, mode: 0o700)
          Hive::AtomicFile.write(File.join(path, "RETIRED"), FENCE_BYTES, mode: 0o600)
        else
          Hive::AtomicFile.write(path, FENCE_BYTES, mode: 0o600)
        end
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def validate_live_database!(document)
        document = document.fetch("evidence") if document.key?("evidence")
        database = Database.new(path: database_path)
        diagnosis = database.diagnostics
        raise diagnosis.error unless diagnosis.ok?
        identity = database.installation_identity
        unless identity.fetch(:installation_id) == cutover_id &&
               identity[:activation_epoch] == document.fetch("activation_epoch") &&
               identity[:activated_at] == document.fetch("activated_at")
          raise Error.new("runtime database identity differs from cutover", code: :candidate_invalid)
        end
        true
      ensure
        database&.disconnect
      end

      def publish_phase(phase, projects, exclusions, task_authority, evidence)
        return load_phase(phase) if manifest_present?(phase)
        manifest(phase).publish(CutoverManifest.build(
          phase: phase, installation_id: cutover_id, lineage_id: cutover_id,
          source_release: @source_release, target_release: @target_release,
          exclusions: exclusions, task_authority: task_authority,
          evidence: evidence.merge("projects" => projects.map { |project| project.fetch("project_id") })
        ))
      end

      def ensure_no_live_database!
        return unless File.exist?(database_path)
        diagnosis = Database.new(path: database_path).diagnostics
        return if diagnosis.status == :missing
        raise Error.new("runtime control plane already exists", code: :database_already_present)
      end

      def reject_existing_run!
        return unless File.exist?(current_root)
        return if current_phase == "active"
        if current_phase.nil?
          FileUtils.rm_rf(current_root)
          @cutover_id = nil
          return
        end
        raise Error.new("an incomplete cutover already exists", code: :cutover_incomplete)
      end

      def prepare_run!
        FileUtils.mkdir_p(current_root, mode: 0o700)
        preflight_filesystems!
        fault!(:filesystem_preflighted)
      end

      def preflight_filesystems!
        roots = target_paths.map do |target|
          path = File.dirname(target.fetch(:live))
          path = File.dirname(path) until File.directory?(path)
          path
        end
        roots << File.dirname(database_path)
        roots.uniq.each do |root|
          probe = File.join(root, ".hive-cutover-probe-#{cutover_id}")
          raise Error.new("filesystem probe is ambiguous", code: :storage_preflight_failed) if path_exists?(probe)
          Hive::AtomicFile.write(probe, "#{cutover_id}\n", mode: 0o600)
          raise Error.new("filesystem probe changed", code: :storage_preflight_failed) unless
            File.binread(probe) == "#{cutover_id}\n"
          File.unlink(probe)
        ensure
          FileUtils.rm_f(probe) if probe
        end
      rescue SystemCallError, IOError => error
        raise Error.new("cutover filesystem preflight failed: #{error.message}", code: :storage_preflight_failed)
      end

      def active_projects_from(document)
        ids = document.dig("evidence", "projects")
        projects = @projects.select { |project| ids.include?(project.fetch("project_id")) }
        raise ProjectError.new("registered project set changed", code: :source_changed) unless
          projects.map { |project| project.fetch("project_id") }.sort == ids.sort
        projects
      end

      def target_paths = global_target_paths + project_target_paths
      def usage_target = global_target_paths.find { |target| target.fetch(:live) == legacy_usage_path }
      def global_target_paths
        @global_target_paths ||= TARGETS.map do |target|
          home = target.home == :state ? @state_home : @data_home
          { home: target.home, relative_path: target.relative_path,
            expected_type: target.expected_type, live: File.join(home, target.relative_path) }
        end
      end

      def project_target_paths
        projects = @active_projects || @projects.select { |project| File.directory?(project["path"].to_s) }
        projects.flat_map do |project|
          root = File.expand_path(project.fetch("hive_state_path"))
          tasks = @task_metadata&.fetch(project.fetch("project_id"), [])&.map(&:folder) || []
          paths = PROJECT_RUNTIME_FILES.map { |relative| File.join(root, relative) } + tasks.flat_map do |task|
            TASK_RUNTIME_FILES.map { |name| File.join(task, name) }
          end
          paths.map do |path|
            { home: "project-#{project.fetch('project_id')}", relative_path: path,
              expected_type: :file, live: path }
          end
        end
      end

      def current_phase = CutoverManifest::PHASES.reverse.find { |phase| manifest_present?(phase) }
      def manifest(phase) = CutoverManifest.new(path: manifest_path(phase))
      def manifest_present?(phase) = path_exists?(manifest_path(phase))
      def load_phase(phase)
        envelope = manifest(phase).load
        raise Error.new("cutover phase checkpoint differs", code: :activation_manifest_mismatch) unless
          envelope.dig("document", "phase") == phase
        envelope
      end
      def result_for(phase)
        document = load_phase(phase).fetch("document")
        Result.new(phase, document.fetch("installation_id"), database_path, document.fetch("exclusions"))
      end
      def manifest_path(phase) = File.join(current_root, "#{phase}.json")
      def current_root = File.join(@state_home, ".runtime-cutover", "current")
      def usage_snapshot_path = File.join(current_root, "usage.snapshot.sqlite3")
      def legacy_usage_path = File.join(@data_home, "usage.db")
      def build_path = File.join(current_root, "build.sqlite3")
      def database_path = Hive::Paths.runtime_control_plane_path(@state_home)
      def cutover_id = @cutover_id ||= @uuid_generator.call
      def activation_epoch = Integer(@clock.call.utc.strftime("%Y%m%d%H%M%S"))
      def path_exists?(path) = File.exist?(path) || File.symlink?(path)
      def fault!(point) = @fault&.call(point)
      def confirmation!
        raise ConfirmationRequired.new("runtime cutover requires confirmation", code: :confirmation_required,
                                       action: "hive migrate --all --yes")
      end
    end
  end
end
