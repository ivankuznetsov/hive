require "fileutils"
require "securerandom"
require "yaml"
require "hive/dependencies"

module Hive
  module TaskMeta
    module_function

    FILENAME = "meta.yml".freeze

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

      {
        id: normalize_id(raw["id"] || raw[:id]),
        slug: normalize_string(raw["slug"] || raw[:slug]),
        display_name: normalize_string(raw["display_name"] || raw[:display_name]),
        depends_on: normalize_string(raw["depends_on"] || raw[:depends_on]),
        workflow: normalize_string(raw["workflow"] || raw[:workflow])
      }
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
           "(#{e.class}: #{e.message}); treating meta as empty (depends_on, workflow dropped)"
      empty
    end

    def read_for_admission(task_folder)
      source = File.read(path(task_folder))
      if Hive::Dependencies.duplicate_top_level_key?(source, "depends_on")
        return AdmissionRead.new(
          status: :invalid,
          data: empty,
          error: "#{path(task_folder)} contains duplicate depends_on declarations",
          reason: :metadata_invalid
        )
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

    def write(task_folder, id:, slug:, display_name:, depends_on: nil, workflow: nil)
      FileUtils.mkdir_p(task_folder)
      normalized_depends_on = normalize_string(depends_on)
      normalized_workflow = normalize_string(workflow)
      data = {
        "id" => normalize_id(id),
        "slug" => normalize_string(slug),
        "display_name" => normalize_string(display_name)
      }
      data["depends_on"] = normalized_depends_on if normalized_depends_on
      data["workflow"] = normalized_workflow if normalized_workflow
      tmp = File.join(task_folder, ".#{FILENAME}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(tmp, data.to_yaml)
      File.rename(tmp, path(task_folder))
      data.transform_keys(&:to_sym).merge(depends_on: normalized_depends_on, workflow: normalized_workflow)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def update_display_name(task_folder, name)
      current = read_for_update!(task_folder)
      slug = current[:slug] || File.basename(task_folder)
      write(
        task_folder,
        id: current[:id],
        slug: slug,
        display_name: name,
        depends_on: current[:depends_on],
        workflow: current[:workflow]
      )
    end

    # Set the task id while preserving every other meta field. Used by the
    # daemon's id backfiller to assign an id to a task created outside
    # `hive new` (hand-made folder, `mv`-ed in) whose meta has none.
    def update_id(task_folder, id)
      current = read_for_update!(task_folder)
      slug = current[:slug] || File.basename(task_folder)
      write(
        task_folder,
        id: id,
        slug: slug,
        display_name: current[:display_name],
        depends_on: current[:depends_on],
        # Preserve the workflow selector — without it, the daemon's id
        # backfiller would silently drop a non-coding `workflow:` and revert
        # the task to the project default (mirrors update_display_name).
        workflow: current[:workflow]
      )
    end

    def empty
      { id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }
    end

    def read_for_update!(task_folder)
      result = read_for_admission(task_folder)
      return result.data if result.ok?

      raise InvalidMetadata, "refusing to rewrite invalid task metadata: #{result.error}"
    end

    def normalized_data(raw)
      {
        id: normalize_id(fetch(raw, "id")),
        slug: normalize_string(fetch(raw, "slug")),
        display_name: normalize_string(fetch(raw, "display_name")),
        depends_on: normalize_string(fetch(raw, "depends_on")),
        workflow: normalize_string(fetch(raw, "workflow"))
      }
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
  end
end
