require "digest"
require "hive/honeycomb/lockfile"

module Hive
  module Honeycomb
    Inspection = Data.define(:name, :root, :state, :modified, :missing, :extra, :type_changed) do
      def clean? = state == "clean"
      def integrity_known? = %w[clean dirty extra_file missing].include?(state)
    end

    class Installation
      attr_reader :workflows_dir

      def initialize(workflows_dir)
        @workflows_dir = File.expand_path(workflows_dir)
      end

      def inspect(entry)
        root = File.join(workflows_dir, entry.name)
        return Inspection.new(name: entry.name, root: root, state: "missing", modified: [],
                              missing: entry.files.keys, extra: [], type_changed: []) unless path_exists?(root)

        root_stat = File.lstat(root)
        unless root_stat.directory?
          return Inspection.new(name: entry.name, root: root, state: "dirty", modified: [], missing: [],
                                extra: [], type_changed: [ "." ])
        end

        modified = []
        missing = []
        type_changed = []
        actual_files, actual_special = disk_inventory(root)
        entry.files.each do |path, expected_hash|
          if actual_special.any? { |special| path == special || path.start_with?("#{special}/") }
            type_changed << path
            next
          end
          target = File.join(root, path)
          stat = File.lstat(target)
          unless stat.file?
            type_changed << path
            next
          end
          modified << path unless ::Digest::SHA256.file(target).hexdigest == expected_hash
        rescue Errno::ENOENT
          missing << path
        end

        extra = actual_files - entry.files.keys
        type_changed |= actual_special & entry.files.keys
        state = if extra.any?
          "extra_file"
        elsif modified.any? || missing.any? || type_changed.any?
          "dirty"
        else
          "clean"
        end
        Inspection.new(
          name: entry.name, root: root, state: state,
          modified: modified.sort.freeze, missing: missing.sort.freeze,
          extra: extra.sort.freeze, type_changed: type_changed.sort.freeze
        )
      end

      def unmanaged_collisions(name)
        [ File.join(workflows_dir, "#{name}.yml"), File.join(workflows_dir, name) ].select do |path|
          path_exists?(path)
        end
      end

      def canonical_managed_root?(name)
        File.file?(File.join(workflows_dir, name, "workflow.yml"))
      end

      private

      def disk_inventory(root)
        files = []
        special = []
        walk = lambda do |dir, prefix|
          Dir.children(dir).sort.each do |name|
            target = File.join(dir, name)
            relative = prefix.empty? ? name : "#{prefix}/#{name}"
            stat = File.lstat(target)
            if stat.directory?
              walk.call(target, relative)
            elsif stat.file?
              files << relative
            else
              special << relative
            end
          end
        end
        walk.call(root, "")
        [ files, special ]
      rescue Errno::ENOENT
        [ files, special ]
      end

      def path_exists?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end
    end
  end
end
