require "fileutils"
require "securerandom"
require "time"
require "yaml"
require "hive/dependencies"

module Hive
  module TaskMeta
    module_function

    FILENAME = "meta.yml".freeze
    WRITABLE_FIELDS = %i[
      id slug display_name depends_on workflow workflow_commit
      workflow_manifest_digest workflow_configuration_digest base_branch completed_at
    ].freeze

    class InvalidMetadata < StandardError; end

    AdmissionRead = Data.define(:status, :data, :error, :reason) do
      def ok?
        %i[ok absent].include?(status)
      end
    end

    def path(task_folder)
      File.join(task_folder, FILENAME)
    end

    def read(task_folder)
      raw = YAML.safe_load(File.read(path(task_folder))) || {}
      return empty unless raw.is_a?(Hash)

      data = {
        id: normalize_id(raw["id"] || raw[:id]),
        slug: normalize_string(raw["slug"] || raw[:slug]),
        display_name: normalize_string(raw["display_name"] || raw[:display_name]),
        depends_on: normalize_string(raw["depends_on"] || raw[:depends_on]),
        workflow: normalize_string(raw["workflow"] || raw[:workflow])
      }
      if raw.key?("base_branch") || raw.key?(:base_branch)
        data[:base_branch] = normalize_string(raw["base_branch"] || raw[:base_branch])
      end
      if raw.key?("workflow_commit") || raw.key?(:workflow_commit)
        data[:workflow_commit] = normalize_string(raw["workflow_commit"] || raw[:workflow_commit])
      end
      if raw.key?("workflow_manifest_digest") || raw.key?(:workflow_manifest_digest)
        data[:workflow_manifest_digest] = normalize_string(
          raw["workflow_manifest_digest"] || raw[:workflow_manifest_digest]
        )
      end
      if raw.key?("workflow_configuration_digest") || raw.key?(:workflow_configuration_digest)
        data[:workflow_configuration_digest] = normalize_string(
          raw["workflow_configuration_digest"] || raw[:workflow_configuration_digest]
        )
      end
      if key?(raw, "completed_at")
        data[:completed_at] = normalize_completed_at(
          fetch(raw, "completed_at"), label: path(task_folder), warn_on_invalid: true
        )
      end
      data
    rescue Errno::ENOENT
      # No meta.yml (pre-`hive new` / legacy folders) — a normal, expected
      # absence, not corruption. Return empty silently.
      empty
    rescue Psych::Exception, SystemCallError, IOError => e
      # A YAML/permission/encoding error here silently drops `depends_on`
      # (read by the resolver as "no dependency" (blocked:false) — the daemon
      # could dispatch a dependent ahead of its prerequisite) and the
      # `workflow` selector (read as "use the project default"). Narrow the
      # rescue (matching Worktree.read_pointer) and log so the dropped fields
      # are observable instead of failing the gate open in silence.
      warn "hive: task_meta: failed to read #{path(task_folder)} " \
           "(#{e.class}: #{e.message}); treating meta as empty " \
           "(depends_on, workflow, base_branch dropped; managed provenance dropped; completed_at dropped)"
      empty
    end

    def read_for_admission(task_folder)
      source = File.read(path(task_folder))
      %w[depends_on base_branch].each do |field|
        if Hive::Dependencies.duplicate_top_level_key?(source, field)
          return AdmissionRead.new(
            status: :invalid,
            data: empty,
            error: "#{path(task_folder)} contains duplicate #{field} declarations",
            reason: :metadata_invalid
          )
        end
      end
      raw = YAML.safe_load(source)
      unless raw.nil? || raw.is_a?(Hash)
        return AdmissionRead.new(
          status: :invalid,
          data: empty,
          error: "#{path(task_folder)} must contain a mapping",
          reason: :metadata_invalid
        )
      end

      raw ||= {}
      data = normalized_data(raw)
      if key?(raw, "depends_on")
        begin
          data[:depends_on] = Hive::Dependencies.parse_reference(fetch(raw, "depends_on")).to_s
        rescue Hive::Dependencies::InvalidReference => e
          return AdmissionRead.new(
            status: :invalid,
            data: data,
            error: "#{path(task_folder)} depends_on is invalid: #{e.message}",
            reason: :reference_invalid
          )
        end
      end

      AdmissionRead.new(status: :ok, data: data, error: nil, reason: nil)
    rescue Errno::ENOENT
      AdmissionRead.new(status: :absent, data: empty, error: nil, reason: nil)
    rescue Psych::Exception => e
      AdmissionRead.new(
        status: :unreadable,
        data: empty,
        error: "could not parse #{path(task_folder)}: #{e.class}: #{e.message}",
        reason: :metadata_unreadable
      )
    rescue SystemCallError, IOError => e
      AdmissionRead.new(
        status: :unreadable,
        data: empty,
        error: "could not read #{path(task_folder)}: #{e.class}: #{e.message}",
        reason: :metadata_unreadable
      )
    end

    def write(task_folder, id:, slug:, display_name:, depends_on: nil, workflow: nil, base_branch: nil,
              workflow_commit: nil, workflow_manifest_digest: nil, workflow_configuration_digest: nil,
              completed_at: nil)
      FileUtils.mkdir_p(task_folder)
      normalized_depends_on = normalize_string(depends_on)
      normalized_workflow = normalize_string(workflow)
      normalized_base_branch = normalize_string(base_branch)
      normalized_commit = normalize_string(workflow_commit)
      normalized_digest = normalize_string(workflow_manifest_digest)
      normalized_configuration_digest = normalize_string(workflow_configuration_digest)
      normalized_completed_at = normalize_completed_at(completed_at, label: "completed_at", strict: true)
      if normalized_commit.nil? != normalized_digest.nil?
        raise ArgumentError, "workflow_commit and workflow_manifest_digest must be written together"
      end
      if normalized_configuration_digest && normalized_commit.nil?
        raise ArgumentError, "workflow_configuration_digest requires immutable workflow provenance"
      end
      data = {
        "id" => normalize_id(id),
        "slug" => normalize_string(slug),
        "display_name" => normalize_string(display_name)
      }
      data["depends_on"] = normalized_depends_on if normalized_depends_on
      data["workflow"] = normalized_workflow if normalized_workflow
      data["base_branch"] = normalized_base_branch if normalized_base_branch
      data["workflow_commit"] = normalized_commit if normalized_commit
      data["workflow_manifest_digest"] = normalized_digest if normalized_digest
      data["workflow_configuration_digest"] = normalized_configuration_digest if normalized_configuration_digest
      data["completed_at"] = normalized_completed_at if normalized_completed_at
      tmp = File.join(task_folder, ".#{FILENAME}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(tmp, data.to_yaml)
      File.rename(tmp, path(task_folder))
      result = data.transform_keys(&:to_sym).merge(
        depends_on: normalized_depends_on, workflow: normalized_workflow
      )
      result[:base_branch] = normalized_base_branch if normalized_base_branch
      if normalized_commit
        result[:workflow_commit] = normalized_commit
        result[:workflow_manifest_digest] = normalized_digest
        result[:workflow_configuration_digest] = normalized_configuration_digest if normalized_configuration_digest
      end
      result[:completed_at] = normalized_completed_at if normalized_completed_at
      result
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def update_display_name(task_folder, name)
      rewrite(task_folder, display_name: name)
    end

    # Set the task id while preserving every other meta field. Used by the
    # daemon's id backfiller to assign an id to a task created outside
    # `hive new` (hand-made folder, `mv`-ed in) whose meta has none.
    def update_id(task_folder, id)
      rewrite(task_folder, id: id)
    end

    # First-writer-wins completion clock. The stable guard serializes metadata
    # rewrites without using the task's process lock, so callers that already
    # hold that lock (run/approve/backfill) can safely call this helper.
    def write_completed_at_once(task_folder, value = Time.now.utc)
      with_rewrite_lock(task_folder) do
        current = read_for_update!(task_folder)
        return current[:completed_at] if current[:completed_at]

        completed_at = normalize_completed_at(value, label: "completed_at", strict: true)
        updated = current.merge(completed_at: completed_at)
        updated[:slug] ||= File.basename(task_folder)
        write(task_folder, **updated.slice(*WRITABLE_FIELDS))
        completed_at
      end
    end

    def rewrite(task_folder, changes)
      with_rewrite_lock(task_folder) do
        current = read_for_update!(task_folder)
        updated = current.merge(changes)
        updated[:slug] ||= File.basename(task_folder)
        write(task_folder, **updated.slice(*WRITABLE_FIELDS))
      end
    end

    Snapshot = Data.define(:exists, :bytes)

    def snapshot(task_folder)
      Snapshot.new(exists: true, bytes: File.binread(path(task_folder)))
    rescue Errno::ENOENT
      Snapshot.new(exists: false, bytes: nil)
    end

    def restore(task_folder, snapshot)
      if snapshot.exists
        FileUtils.mkdir_p(task_folder)
        write_raw_atomic(task_folder, snapshot.bytes)
      else
        File.delete(path(task_folder)) if File.exist?(path(task_folder))
      end
    end

    def empty
      { id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }
    end

    def read_for_update!(task_folder)
      validate_stored_completed_at!(task_folder)
      result = read_for_admission(task_folder)
      return result.data if result.ok?

      raise InvalidMetadata, "refusing to rewrite invalid task metadata: #{result.error}"
    end

    def normalized_data(raw)
      data = {
        id: normalize_id(fetch(raw, "id")),
        slug: normalize_string(fetch(raw, "slug")),
        display_name: normalize_string(fetch(raw, "display_name")),
        depends_on: normalize_string(fetch(raw, "depends_on")),
        workflow: normalize_string(fetch(raw, "workflow")),
        base_branch: normalize_string(fetch(raw, "base_branch")),
        workflow_commit: normalize_string(fetch(raw, "workflow_commit")),
        workflow_manifest_digest: normalize_string(fetch(raw, "workflow_manifest_digest")),
        workflow_configuration_digest: normalize_string(fetch(raw, "workflow_configuration_digest"))
      }
      if key?(raw, "completed_at")
        data[:completed_at] = normalize_completed_at(fetch(raw, "completed_at"), label: "completed_at")
      end
      data
    end

    def key?(hash, key)
      hash.key?(key) || hash.key?(key.to_sym)
    end

    def fetch(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_sym]
    end

    def normalize_id(value)
      return value if value.is_a?(Integer)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_string(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def normalize_completed_at(value, label:, strict: false, warn_on_invalid: false)
      return nil if value.nil?

      parsed =
        if value.is_a?(Time)
          value
        elsif value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
          Time.iso8601(value)
        end
      return parsed.utc.iso8601 if parsed

      raise ArgumentError, "#{label} must be a UTC ISO 8601 timestamp" if strict
      warn "hive: task_meta: invalid completed_at in #{label}; keeping task visible" if warn_on_invalid
      nil
    rescue ArgumentError
      raise ArgumentError, "#{label} must be a UTC ISO 8601 timestamp" if strict

      warn "hive: task_meta: invalid completed_at in #{label}; keeping task visible" if warn_on_invalid
      nil
    end

    def validate_stored_completed_at!(task_folder)
      raw = YAML.safe_load(File.read(path(task_folder))) || {}
      return unless raw.is_a?(Hash) && key?(raw, "completed_at")

      normalize_completed_at(
        fetch(raw, "completed_at"), label: path(task_folder), strict: true
      )
    rescue Errno::ENOENT
      nil
    rescue Psych::Exception, SystemCallError, IOError
      # read_for_admission below owns the existing typed error normalization
      # for malformed/unreadable metadata; this preflight only adds the
      # completed_at-specific validation arm.
      nil
    rescue ArgumentError => e
      raise InvalidMetadata, "refusing to rewrite invalid task metadata: #{e.message}"
    end

    def with_rewrite_lock(task_folder)
      FileUtils.mkdir_p(task_folder)
      guard_path = File.join(task_folder, ".#{FILENAME}.tmp.guard")
      File.open(guard_path, File::RDWR | File::CREAT, 0o644) do |guard|
        guard.flock(File::LOCK_EX)
        yield
      end
    end

    def write_raw_atomic(task_folder, bytes)
      tmp = File.join(task_folder, ".#{FILENAME}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.binwrite(tmp, bytes)
      File.rename(tmp, path(task_folder))
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
