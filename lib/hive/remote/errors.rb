# frozen_string_literal: true

require "hive/errors"

module Hive
  module Remote
    class Error < Hive::Error
      attr_reader :code, :status

      def initialize(code:, status:, message:)
        @code = code.to_s
        @status = Integer(status)
        super(message)
      end
    end

    # Only checks that guarantee no command was submitted use this error.
    class AdmissionRefused < Error
      def deterministic_non_application? = true
    end
  end
end
