require "find"
require "hive/workflow_package/safe_file"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class PackageReader
        FileEntry = Data.define(:path, :bytes, :text)
        ReadEvent = Data.define(
          :rule_id, :severity, :path, :line, :column, :message, :review, :evidence
        )
        PackageSnapshot = Data.define(:files, :events)

        private_constant :FileEntry, :ReadEvent, :PackageSnapshot

        def initialize(root, limits:)
          @root = root
          @limits = limits
        end

        def read
          entries = []
          events = []
          total = 0
          Find.find(@root) do |path|
            next if path == @root

            relative = path.delete_prefix("#{@root}/")
            stat = File.lstat(path)
            if stat.symlink? || (!stat.directory? && !stat.file?)
              events << event(
                "policy.invalid-file", :error, relative, nil, nil,
                "package contains a linked or special file"
              )
              Find.prune if stat.directory?
              next
            end
            next if stat.directory?

            if entries.length >= @limits.fetch("max_files")
              events << event(
                "policy.file-limit", :error, relative, nil, nil,
                "package file count exceeds lint policy"
              )
              break
            end
            if stat.size > @limits.fetch("max_file_bytes")
              events << event(
                "policy.file-limit", :error, relative, nil, nil,
                "package file exceeds lint byte limit"
              )
              next
            end

            bytes, current = SafeFile.read(
              path, max_bytes: @limits.fetch("max_file_bytes"),
              error_class: UnsafeYAML, message: "package file changed while being scanned"
            )
            unless current.dev == stat.dev && current.ino == stat.ino &&
                   current.size == bytes.bytesize
              events << event(
                "policy.invalid-file", :error, relative, nil, nil,
                "package file changed while being scanned"
              )
              next
            end

            total += bytes.bytesize
            if total > @limits.fetch("max_total_bytes")
              events << event(
                "policy.total-limit", :error, relative, nil, nil,
                "package total bytes exceed lint policy"
              )
              break
            end

            text, decoding_events = decode_text(bytes, relative)
            events.concat(decoding_events)
            entries << FileEntry.new(
              path: relative.freeze, bytes: bytes.freeze, text: text&.freeze
            ).freeze
          end
          snapshot(entries.sort_by(&:path), events)
        rescue SystemCallError, IOError, UnsafeYAML
          events ||= []
          events << event(
            "policy.invalid-file", :error, "", nil, nil,
            "package files could not be read safely"
          )
          snapshot([], events)
        end

        private

        def decode_text(bytes, path)
          return [ nil, [] ] if bytes.include?("\0")

          text = bytes.dup.force_encoding(Encoding::UTF_8)
          return [ text, [] ] if text.valid_encoding?

          [
            nil,
            [
              event(
                "policy.invalid-encoding", :error, path, nil, nil,
                "text input is not valid UTF-8"
              )
            ]
          ]
        end

        def event(rule_id, severity, path, line, column, message,
                  review: false, evidence: nil)
          ReadEvent.new(
            rule_id: rule_id.freeze, severity: severity, path: path.to_s.freeze,
            line: line, column: column, message: message.freeze,
            review: review, evidence: evidence&.freeze
          ).freeze
        end

        def snapshot(files, events)
          PackageSnapshot.new(files: files.freeze, events: events.freeze).freeze
        end
      end
    end
  end
end
