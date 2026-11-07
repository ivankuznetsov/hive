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
  end
end
