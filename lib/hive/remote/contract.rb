# frozen_string_literal: true

module Hive
  module Remote
    # Shared wire limits and identifier grammars; safe to load in a client.
    module Contract
      MAX_RESPONSE_BYTES = 2 * 1024 * 1024
      MAX_MUTATION_BYTES = 256 * 1024
      MAX_LOG_BYTES = 256 * 1024
      MAX_CONTENT_BYTES = 512 * 1024
      SCOPES = %w[read create act answer].freeze
      PROJECT_NAME = /\A[A-Za-z0-9_.-]{1,128}\z/
      TASK_ID = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
      WORKFLOW_ID = /\A[a-z0-9][a-z0-9-]*\z/
      STAGE = /\A[0-9]+-[a-z][a-z0-9-]*\z/
      GENERATION = /\A[0-9a-f]{64}\z/
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
    end
  end
end
