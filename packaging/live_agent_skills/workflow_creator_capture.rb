# frozen_string_literal: true

require "digest"
require_relative "workflow_creator"

module HiveLiveAgentProof
  module WorkflowCreator
    class Capture
      class Error < StandardError; end

      STREAMS = %i[stdout stderr].freeze
      MAX_LIMIT_BYTES = 1_048_576
      MAX_TAIL_BYTES = 4_096
      SCAN_SLICE_BYTES = 2_048
      REDACTED = "[REDACTED]".freeze
      NO_SECRETS = [].freeze

      def initialize(limit_bytes:, tail_bytes: MAX_TAIL_BYTES, exact_secrets: [])
        @limit = integer_in!(limit_bytes, 1..MAX_LIMIT_BYTES, "capture limit")
        @tail_limit = integer_in!(tail_bytes, 1..MAX_TAIL_BYTES, "capture tail limit")
        @exact_secrets = Values.capture(exact_secrets).value
        unless @exact_secrets.instance_of?(Array) && @exact_secrets.length <= 64 && @exact_secrets.all? do |secret|
          secret.instance_of?(String) && !secret.empty? && secret.bytesize <= MAX_TAIL_BYTES
        end
          raise Error, "capture exact secrets are invalid"
        end
        @states = STREAMS.to_h do |stream|
          [ stream, { bytes: 0, digest: Digest::SHA256.new, truncated: false,
                      window: +"".b, findings: [] } ]
        end
        @finished = false
      rescue Values::Error
        raise Error, "capture exact secrets are invalid"
      end

      def write(stream, chunk)
        raise Error, "capture is already finished" if @finished
        state = @states[stream]
        raise Error, "capture stream is invalid" unless state
        raise Error, "capture chunk is invalid" unless chunk.instance_of?(String)

        bytes = chunk.b
        remaining = @limit - state.fetch(:bytes)
        admitted = bytes.byteslice(0, remaining) || "".b
        state.fetch(:digest).update(admitted)
        state[:bytes] += admitted.bytesize
        state[:truncated] ||= bytes.bytesize > remaining
        scan(state, bytes)
        self
      end

      def finish
        return @result if @finished

        @finished = true
        findings = STREAMS.flat_map do |stream|
          @states.fetch(stream).fetch(:findings).map { |finding| "#{stream}:#{finding}" }
        end
        result = { "limit_bytes" => @limit }
        STREAMS.each do |stream|
          state = @states.fetch(stream)
          result["#{stream}_bytes"] = state.fetch(:bytes)
          result["#{stream}_sha256"] = state.fetch(:digest).hexdigest
          result["#{stream}_truncated"] = state.fetch(:truncated)
        end
        result["secret_scan"] = {
          "status" => findings.empty? ? "passed" : "failed",
          "scanner" => Vocabulary.fetch("scanner"), "findings" => findings.freeze
        }.freeze
        result["tails"] = STREAMS.to_h { |stream| [ stream.to_s, tail(@states.fetch(stream)) ] }.freeze
        @result = result.freeze
      end

      private

      def integer_in!(value, range, label)
        integer = Integer(value)
        raise Error, "#{label} is invalid" unless range.cover?(integer)

        integer
      rescue ArgumentError, TypeError
        raise Error, "#{label} is invalid"
      end

      def scan(state, bytes)
        offset = 0
        while offset < bytes.bytesize
          slice = bytes.byteslice(offset, SCAN_SLICE_BYTES)
          state.fetch(:window) << slice
          @exact_secrets.each_with_index do |secret, index|
            state.fetch(:findings) << "exact-secret:#{index}" if state.fetch(:window).include?(secret.b)
          end
          overflow = state.fetch(:window).bytesize - MAX_TAIL_BYTES
          state[:window] = state.fetch(:window).byteslice(overflow, MAX_TAIL_BYTES) if overflow.positive?
          owned = state.fetch(:window).dup.force_encoding(Encoding::UTF_8).scrub("").freeze
          state.fetch(:findings).concat(TextSafety.secret_findings(owned, exact_secrets: NO_SECRETS))
          state.fetch(:findings).uniq!
          offset += slice.bytesize
        end
      rescue TextSafety::Error
        raise Error, "capture secret scan failed closed"
      end

      def tail(state)
        return REDACTED if state.fetch(:findings).any?

        window = state.fetch(:window)
        offset = [ window.bytesize - @tail_limit, 0 ].max
        raw = window.byteslice(offset, @tail_limit) || "".b
        raw.force_encoding(Encoding::UTF_8).scrub("").freeze
      end
    end
  end
end
