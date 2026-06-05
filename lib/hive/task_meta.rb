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
        display_name: normalize_string(raw["display_name"] || raw[:display_name])
      }
    rescue StandardError
      empty
    end

    def write(task_folder, id:, slug:, display_name:)
      FileUtils.mkdir_p(task_folder)
      data = {
        "id" => normalize_id(id),
        "slug" => normalize_string(slug),
        "display_name" => normalize_string(display_name)
      }
      tmp = File.join(task_folder, ".#{FILENAME}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(tmp, data.to_yaml)
      File.rename(tmp, path(task_folder))
      data.transform_keys(&:to_sym)
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
        display_name: name
      )
    end

    def empty
      { id: nil, slug: nil, display_name: nil }
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
