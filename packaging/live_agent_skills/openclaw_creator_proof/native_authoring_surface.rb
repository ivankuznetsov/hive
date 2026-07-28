require "digest"
require "fileutils"
require "pathname"

module HiveLiveAgentProof
  module OpenClawCreatorProof
    class NativeAuthoringSurface
      ENTRY_LIMIT = 10_000
      DIRECTORY_LIMIT = 2_000
      DEPTH_LIMIT = 20
      BYTE_LIMIT = 128 * 1024 * 1024
      MUTATION_LIMIT = 2_000

      attr_reader :receipt_path

      def initialize(workspace:, receipt_path:)
        @workspace = File.realpath(workspace)
        @receipt_path = File.expand_path(receipt_path)
        @observations = []
        persist!
      end

      def observe(label)
        before = snapshot
        result = yield
        after = snapshot
        mutations = mutation_records(before, after)
        @observations << {
          "label" => label.to_s,
          "status" => "observed",
          "mutations" => mutations
        }
        persist!
        result
      rescue Failure
        raise
      rescue StandardError => e
        fail_effect!("cannot observe native authoring effects: #{e.message}")
      end

      private

      def snapshot
        entries = {}
        directories = 0
        bytes = 0
        queue = Dir.children(@workspace).sort
        until queue.empty?
          relative = queue.shift
          path = File.join(@workspace, relative)
          depth = Pathname.new(relative).each_filename.count
          fail_effect!("effect observation depth exceeded") if depth > DEPTH_LIMIT
          stat = File.lstat(path)
          record = { "type" => nil, "mode" => stat.mode & 0o7777 }
          if stat.directory? && !stat.symlink?
            directories += 1
            record["type"] = "directory"
            children = Dir.children(path).sort.map { |name| File.join(relative, name) }
            queue = children + queue
          elsif stat.file? && !stat.symlink?
            bytes += stat.size
            record.merge!(
              "type" => "file",
              "size" => stat.size,
              "sha256" => Digest::SHA256.file(path).hexdigest
            )
          else
            fail_effect!("effect observation found a link or special entry: #{relative}")
          end
          entries[relative] = record
          fail_effect!("effect observation entry budget exceeded") if
            entries.length > ENTRY_LIMIT
          fail_effect!("effect observation directory budget exceeded") if
            directories > DIRECTORY_LIMIT
          fail_effect!("effect observation byte budget exceeded") if bytes > BYTE_LIMIT
        end
        entries
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => e
        fail_effect!("cannot snapshot authoring workspace: #{e.message}")
      end

      def mutation_records(before, after)
        paths = (before.keys | after.keys).sort
        records = paths.filter_map do |path|
          previous = before[path]
          current = after[path]
          next if previous == current

          {
            "path" => path,
            "operation" =>
              if previous.nil?
                "created"
              elsif current.nil?
                "removed"
              else
                "modified"
              end,
            "before" => previous,
            "after" => current,
            "scope" => "workspace"
          }
        end
        fail_effect!("effect mutation receipt budget exceeded") if records.length > MUTATION_LIMIT

        records
      end

      def persist!
        payload = {
          "schema" => "hive-live-agent-effect-observation",
          "schema_version" => 1,
          "workspace" => @workspace,
          "status" => "observed",
          "observations" => @observations
        }
        HiveLiveAgentProof.write_json(@receipt_path, payload)
      end

      def fail_effect!(detail)
        raise Failure.new(
          phase: "effects",
          reason: "effect_observation_failed",
          detail: detail
        )
      end
    end
  end
end
