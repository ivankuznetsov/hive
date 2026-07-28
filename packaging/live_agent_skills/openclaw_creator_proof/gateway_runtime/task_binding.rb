module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class TaskBinding
      MAX_STAGES = 64
      MAX_TASKS = 512
      MAX_META_BYTES = 64 * 1024
      MAX_TOTAL_META_BYTES = 512 * 1024

      class Invalid < StandardError; end

      def initialize(workspace:, safe_slug:, task_key:, workflow:)
        @workspace = workspace
        @safe_slug = safe_slug
        @task_key = task_key
        @workflow = workflow
      end

      def created_slug(result_rows:, ordinal:)
        result = result_rows.find { |row| row["ordinal"] == 6 }
        return unless ordinal == 7 && result && result["created"] == true

        slug = result.fetch("slug")
        return unless @safe_slug.match?(slug)

        keyed = task_metadata.select {
          |_path, data| data["idempotency_key"] == @task_key
        }
        return unless keyed.length == 1

        path, data = keyed.fetch(0)
        return unless File.basename(File.dirname(path)) == slug &&
                      data["slug"] == slug &&
                      data["workflow"] == @workflow

        slug
      rescue Invalid, KeyError, Psych::Exception, SystemCallError
        nil
      end

      private

      def task_metadata
        workspace = strict_directory(@workspace)
        state = strict_directory(File.join(workspace, ".hive-state"))
        stages = strict_directory(File.join(state, "stages"))
        workspace_real = File.realpath(workspace)
        raise Invalid unless confined?(File.realpath(stages), workspace_real)

        task_count = 0
        total_bytes = 0
        bounded_children(stages, MAX_STAGES).flat_map do |stage_name|
          stage = strict_directory(File.join(stages, stage_name))
          bounded_children(stage, MAX_TASKS).filter_map do |task_name|
            task_count += 1
            raise Invalid if task_count > MAX_TASKS

            entry = File.join(stage, task_name)
            if task_name == ".gitkeep"
              raise Invalid unless strict_file?(entry)
              next
            end
            task = strict_directory(entry)
            meta = File.join(task, "meta.yml")
            bytes = bounded_file_bytes(meta)
            total_bytes += bytes.bytesize
            raise Invalid if total_bytes > MAX_TOTAL_META_BYTES
            raise Invalid unless confined?(File.realpath(meta), workspace_real)

            [ meta, YAML.safe_load(bytes, aliases: false) ].tap {
              |row| raise Invalid unless row.last.is_a?(Hash)
            }
          end
        end
      end

      def bounded_children(path, limit)
        Dir.children(path).sort.tap {
          |children| raise Invalid if children.length > limit
        }
      end

      def bounded_file_bytes(path)
        raise Invalid unless strict_file?(path)

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          raise Invalid unless file.stat.file? && file.stat.size <= MAX_META_BYTES

          file.read(MAX_META_BYTES + 1).tap {
            |bytes| raise Invalid if bytes.bytesize > MAX_META_BYTES
          }
        end
      end

      def strict_directory(path)
        stat = File.lstat(path)
        raise Invalid unless stat.directory? && !stat.symlink?

        path
      end

      def strict_file?(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      end

      def confined?(path, root)
        path.start_with?("#{root}/")
      end
    end
  end
end
