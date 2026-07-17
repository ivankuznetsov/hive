module Hive
  module Patrol
    Feature = Struct.new(
      :id, :kind, :entrypoints, :owned_files, :context_files, :tests,
      keyword_init: true
    ) do
      def documentation?
        kind.to_s == "documentation"
      end

      def to_h
        {
          "id" => id,
          "kind" => kind,
          "entrypoints" => Array(entrypoints),
          "owned_files" => Array(owned_files),
          "context_files" => Array(context_files),
          "tests" => Array(tests)
        }
      end

      def self.from_h(hash)
        new(
          id: hash.fetch("id"),
          kind: hash.fetch("kind"),
          entrypoints: Array(hash["entrypoints"]),
          owned_files: Array(hash["owned_files"]),
          context_files: Array(hash["context_files"]),
          tests: Array(hash["tests"])
        )
      end
    end
  end
end
