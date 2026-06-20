require "fileutils"
require "securerandom"
require "yaml"

module Hive
  module TaskMeta
    module_function

    FILENAME = "meta.yml".freeze

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
      current = read(task_folder)
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
      current = read(task_folder)
      slug = current[:slug] || File.basename(task_folder)
      write(
        task_folder,
        id: id,
        slug: slug,
        display_name: current[:display_name],
        depends_on: current[:depends_on]
      )
    end

    def empty
      { id: nil, slug: nil, display_name: nil, depends_on: nil, workflow: nil }
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
