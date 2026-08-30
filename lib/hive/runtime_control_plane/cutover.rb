require "digest"
require "fileutils"
require "json"
require "securerandom"
require "sequel"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/daemon/activation_lock"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/cutover_manifest"
require "hive/runtime_control_plane/maintenance"
require "hive/task_meta"

module Hive
  module RuntimeControlPlane
    # One forward-only cutover. File-backed task/artifact authorities stay in
    # place; disposable runtime state is accepted only when it has no owner.
    class Cutover
      Result = Data.define(:phase, :cutover_id, :database_path, :exclusions)
      Target = Data.define(:home, :relative_path, :expected_type)
      TaskIdentity = Data.define(:folder, :id, :workflow)
      PHASES = %w[ready intended active].freeze
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
            "state_path" => root, "sha256" => tree_digest(root) }
        end.freeze
      end

      def self.tree_digest(root)
        status = File.lstat(root)
        raise Errno::ENOTDIR, root unless status.directory? && !status.symlink?

        digest = Digest::SHA256.new
        pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
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
        %w[daemon/pr-merge-reconciliation.json daemon/pr-merge-reconciliation.json.lock].include?(relative) ||
          %w[.lock .lock.tmp.guard].include?(relative) ||
          relative.match?(%r{\Astages/[^/]+/[^/]+/\.lock(?:\.tmp\.guard)?\z})
      end

      def self.inspect_status(state_home:, database:)
        root = File.join(File.expand_path(state_home), ".runtime-cutover", "current")
        phase = PHASES.reverse.find { |name| File.exist?(File.join(root, "#{name}.json")) }
        document = CutoverManifest.new(path: File.join(root, "#{phase}.json")).load.fetch("document") if phase
        diagnosis = database.diagnostics
        if diagnosis.ok?
          raise Error.new("runtime database has no active cutover manifest", code: :activation_manifest_missing) unless
            phase == "active"
          identity = database.installation_identity
          unless identity && identity.fetch(:installation_id) == document.fetch("installation_id") &&
                 identity.fetch(:lineage_id) == document.fetch("lineage_id") &&
                 identity[:activation_epoch] == document.dig("evidence", "activation_epoch")
            raise Error.new("runtime database identity differs from active manifest", code: :activation_identity_mismatch)
          end
        end
        { "schema" => "hive-runtime-cutover-status", "phase" => phase || "absent",
          "installation_id" => document && document.fetch("installation_id"), "database" => diagnosis.to_h }
      ensure
        database.disconnect if diagnosis&.ok?
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
        return result_for("active") if current_phase == "active"
        return resume if current_phase
        confirmation! unless confirm
        perform(exclusions: exclusions, fresh: false)
      end

      def bootstrap(confirm:)
        return result_for("active") if current_phase == "active"
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
        return result_for("active") if phase == "active"
        raise Error.new("no cutover is ready to resume", code: :resume_unavailable) unless phase

        document = load_phase(phase).fetch("document")
        @cutover_id = document.fetch("installation_id")
        @active_projects = active_projects_from(document)
        load_task_identities!(@active_projects)
        raise Error.new("task authority changed during cutover", code: :source_changed) unless
          document.fetch("task_authority") == self.class.task_authority(@active_projects)
        @services.stop!(cutover_id: cutover_id)
        @gate.synchronize do
          publish_intent_from_ready if current_phase == "ready"
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
        fault!(:run_prepared)
        @services.stop!(cutover_id: cutover_id)
        @gate.synchronize do
          prepare_ready(active, excluded, task_authority, fresh)
          publish_intent_from_ready
          activate_from_intent
        end
      end

      def prepare_ready(active, excluded, task_authority, fresh)
        ensure_no_live_database!
        unless fresh
          assert_attempts_quiescent!
          assert_locks_quiescent!
        end
        FileUtils.rm_f(usage_snapshot_path)
        usage = create_usage_snapshot! if File.file?(File.join(@data_home, "usage.db"))
        unless task_authority == self.class.task_authority(active)
          raise Error.new("registry or task authority changed during cutover", code: :source_changed)
        end
        epoch = activation_epoch
        activated_at = Codec.dump_time(@clock.call)
        evidence = {
          "usage_snapshot" => usage, "fresh" => fresh,
          "activation_epoch" => epoch, "activated_at" => activated_at
        }
        publish_phase("ready", active, excluded, task_authority, evidence)
        fault!(:fleet_ready)
      end

      def publish_intent_from_ready
        return if manifest_present?("intended")
        ready = load_phase("ready").fetch("document")
        validate_usage_snapshot!(ready.dig("evidence", "usage_snapshot"))
        seal_and_fence! unless ready.dig("evidence", "fresh")
        fault!(:sources_sealed)
        install_database!(active_projects_from(ready), ready.fetch("evidence"))
        fault!(:database_built)
        publish_phase("intended", active_projects_from(ready), ready.fetch("exclusions"),
                      ready.fetch("task_authority"), ready.fetch("evidence"))
        fault!(:activation_intent)
      end

      def activate_from_intent
        document = load_phase("intended").fetch("document")
        @cutover_id = document.fetch("installation_id")
        validate_live_database!(document)
        FileUtils.mkdir_p(Hive::Paths.runtime_payload_root(@state_home), mode: 0o700)
        fault!(:candidate_identity_published)
        @services.activate! if @services.respond_to?(:activate!)
        publish_phase("active", active_projects_from(document), document.fetch("exclusions"),
                      document.fetch("task_authority"), document.fetch("evidence")) unless
          manifest_present?("active")
        result_for("active")
      end

      def validate_projects(exclusions)
        names = Array(exclusions).map(&:to_s).uniq.sort
        unknown = names - @projects.map { |project| project.fetch("name") }
        raise ProjectError.new("unknown exclusions: #{unknown.join(', ')}", code: :unknown_exclusion) unless unknown.empty?

        validate_project_identities!
        load_task_identities!(@projects.reject { |project| names.include?(project.fetch("name")) })
        active = []
        excluded = []
        @projects.each do |project|
          missing = !File.directory?(project.fetch("path")) || !File.directory?(project.fetch("hive_state_path"))
          if names.include?(project.fetch("name"))
            excluded << { "name" => project.fetch("name"), "project_id" => project.fetch("project_id"),
                          "reason" => missing ? "missing" : "operator_excluded" }
          elsif missing
            raise ProjectError.new("registered project #{project.fetch('name')} is missing", code: :project_missing)
          else
            active << project
          end
        end
        [ active.freeze, excluded.freeze ]
      end

      def validate_project_identities!
        uuid = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
        @projects.each do |project|
          registration = project.fetch("registration_id").to_s
          valid_registration = uuid.match?(registration) ||
            (registration.start_with?("legacy:") && uuid.match?(registration.delete_prefix("legacy:")))
          unless uuid.match?(project.fetch("project_id").to_s) && valid_registration
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

      def install_database!(projects, evidence)
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
        FileUtils.mkdir_p(File.dirname(database_path), mode: 0o700)
        File.rename(build_path, database_path)
        Hive::AtomicFile.fsync_directory(File.dirname(database_path))
        validate_live_database!(evidence)
      rescue Sequel::Error => error
        raise Error.new("candidate import failed: #{error.message}", code: :candidate_import_failed)
      ensure
        database&.disconnect
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

      def assert_locks_quiescent!
        target_paths.select { |target| target.fetch(:relative_path).end_with?(".lock") }.each do |target|
          path = target.fetch(:live)
          next unless File.file?(path)
          File.open(path, File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)) do |lock|
            live!("legacy writer lock is held", path: path) unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            lock.flock(File::LOCK_UN)
          end
        end
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        live!("legacy writer lock is held")
      end

      def live!(message, details = {})
        raise Error.new(message, code: :live_runtime_owner, details: details,
                        action: "finish all legacy work and retry")
      end

      def invalid_legacy!(message, details = {})
        raise Error.new(message, code: :legacy_runtime_invalid, details: details)
      end

      def create_usage_snapshot!
        destination = usage_snapshot_path
        source = Sequel.connect(adapter: "sqlite", database: File.join(@data_home, "usage.db"),
                                readonly: true, max_connections: 1)
        validate_usage_database!(source)
        source.run("VACUUM INTO #{source.literal(destination)}")
        snapshot = Sequel.connect(adapter: "sqlite", database: destination, readonly: true, max_connections: 1)
        validate_usage_database!(snapshot)
        { "sha256" => Digest::SHA256.file(destination).hexdigest, "bytes" => File.size(destination),
          "rows" => snapshot[:token_usage].count }
      rescue Sequel::Error, SystemCallError => error
        raise Error.new("legacy usage snapshot is invalid: #{error.message}", code: :usage_snapshot_invalid)
      ensure
        snapshot&.disconnect
        source&.disconnect
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
      rescue Sequel::Error
        raise Error.new("sealed usage snapshot is corrupt", code: :sealed_source_corrupt)
      ensure
        database&.disconnect
      end

      def seal_and_fence!
        target_paths.each do |target|
          next if fence_installed?(target)
          FileUtils.rm_rf(target.fetch(:live))
          install_fence(target.fetch(:live), target.fetch(:expected_type))
          fault!(:fence_installed)
        end
      end

      def fence_installed?(target)
        path = target.fetch(:live)
        if target.fetch(:expected_type) == :file
          File.directory?(path) && File.binread(File.join(path, "RETIRED")) == FENCE_BYTES
        else
          File.file?(path) && File.binread(path) == FENCE_BYTES
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

      def current_phase = PHASES.reverse.find { |phase| manifest_present?(phase) }
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
