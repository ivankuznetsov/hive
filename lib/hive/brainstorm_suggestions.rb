# frozen_string_literal: true

module Hive
  # Repository-aware brainstorm suggestions are advisory state. Nothing in
  # this namespace writes an operator answer or advances a workflow stage.
  module BrainstormSuggestions
    SCHEMA = "hive-brainstorm-suggestions"
    SCHEMA_VERSION = 1
    STORE_FILENAME = "brainstorm-suggestions.json"

    STATES = %w[
      loading fresh stale no_safe_suggestion unavailable failed
    ].freeze
    RETRYABLE_STATES = %w[failed unavailable no_safe_suggestion].freeze
    SOURCE_CLASSES = %w[
      request repository project_wiki main_wiki settled_answers
    ].freeze

    MAX_STORE_BYTES = 256 * 1024
    MAX_TEXT_CHARACTERS = 1_000
    MAX_TEXT_LINES = 12
    MAX_RATIONALE_CHARACTERS = 320
    MAX_SAFE_REASON_CHARACTERS = 240

    class Error < Hive::Error; end
    class InvalidState < Error; end
    class UnsafePath < Error; end
  end
end

require "hive/brainstorm_suggestions/binding"
require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_suggestions/store"
