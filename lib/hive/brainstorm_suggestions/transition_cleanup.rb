# frozen_string_literal: true

require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_suggestions/store"
require "hive/markers"

module Hive
  module BrainstormSuggestions
    module TransitionCleanup
      module_function

      def call_under_lock(task_root)
        root = File.expand_path(task_root.to_s)
        path = File.join(root, "brainstorm.md")
        if File.file?(path) && !File.symlink?(path)
          Hive::Markers.with_markers_lock(path, create: false, timeout: 5) do
            body = File.binread(path, Envelope::MAX_SCAN_BYTES + 1)
            raise InvalidState, "brainstorm state exceeds cleanup scan bound" if
              body.bytesize > Envelope::MAX_SCAN_BYTES

            stripped = Envelope.strip(body).text
            Hive::Markers.write_atomic(path, stripped) unless stripped == body
          end
        end
        Store.new(root).delete!
        true
      end
    end
  end
end
