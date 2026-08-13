require "hive/artifacts/outcome_evidence/document"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Compatibility reader only. A document returned here remains displayable
      # but is deliberately never an accepted outcome-evidence attempt.
      class LegacyCaptureReader
        MAX_BYTES = Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES

        def initialize(task_folder)
          @path = File.join(task_folder, "media", "capture-manifest.json")
        end

        def read
          source = read_regular
          return nil unless source

          preview = JSON.parse(
            source, object_class: Document::StrictHash, allow_duplicate_key: true
          )
          version = Integer(preview["schema_version"], exception: false)
          return nil unless [ 1, 2 ].include?(version)

          Document.parse(
            source, schema: "hive-artifact-capture", version: version,
            label: "legacy capture manifest"
          )
        rescue StoreError, JSON::ParserError, SystemCallError
          nil
        end

        private

        def read_regular
          File.open(@path, File::RDONLY | File::NOFOLLOW) do |file|
            return nil unless file.stat.file?

            value = file.read(MAX_BYTES + 1)
            return nil if value.bytesize > MAX_BYTES

            value
          end
        rescue Errno::ENOENT, Errno::ELOOP
          nil
        end
      end
    end
  end
end
