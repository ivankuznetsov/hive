# frozen_string_literal: true

require_relative "workflow_creator_values"
module HiveLiveAgentProof
  module WorkflowCreator
    module TextSafety
      # Exact frozen plain shapes are an internal Values ownership contract, not origin authentication.
      class Error < StandardError; end
      PROJECT_FAILURE = Error.new("workflow-creator text cannot be projected")
      failure_protocol = %i[backtrace cause exception initialize_clone initialize_copy message set_backtrace to_s]
      failure_protocol.each { |name| PROJECT_FAILURE.singleton_class.alias_method(name, name) }
      PROJECT_FAILURE.freeze
      INVOKE = :__workflow_creator_text_safety_invoke__
      MAX_BYTES = 4_096
      MAX_EXACT_SECRETS = 64
      def self.seal(operation)
        singleton = operation.singleton_class
        singleton.alias_method(INVOKE, :bind_call)
        singleton.__send__(:private, INVOKE)
        singleton.alias_method(:send, :__send__)
        operation.freeze
      end
      OBJECT_CLASS = seal(Object.instance_method(:class))
      OBJECT_CLONE = seal(Object.instance_method(:clone))
      OBJECT_EQUAL = seal(BasicObject.instance_method(:equal?))
      OBJECT_FREEZE = seal(Object.instance_method(:freeze))
      OBJECT_FROZEN = seal(Object.instance_method(:frozen?))
      RAISE = seal(Kernel.instance_method(:raise))
      MODULE_CASE = seal(Module.instance_method(:===))
      ARRAY_EACH = seal(Array.instance_method(:each))
      ARRAY_GET = seal(Array.instance_method(:[]))
      ARRAY_INDEX = seal(Array.instance_method(:index))
      ARRAY_LENGTH = seal(Array.instance_method(:length))
      ARRAY_MULTIPLY = seal(Array.instance_method(:*))
      ARRAY_PUSH = seal(Array.instance_method(:<<))
      ARRAY_SET = seal(Array.instance_method(:[]=))
      STRING_APPEND = seal(String.instance_method(:<<))
      STRING_BINARY = seal(String.instance_method(:b))
      STRING_BYTEINDEX = seal(String.instance_method(:byteindex))
      STRING_BYTESIZE = seal(String.instance_method(:bytesize))
      STRING_BYTESLICE = seal(String.instance_method(:byteslice))
      STRING_ENCODING = seal(String.instance_method(:encoding))
      STRING_EQUAL = seal(String.instance_method(:==))
      STRING_SCRUB = seal(String.instance_method(:scrub))
      STRING_VALID = seal(String.instance_method(:valid_encoding?))
      REGEXP_MATCH = seal(Regexp.instance_method(:match))
      MATCH_BEGIN = seal(MatchData.instance_method(:begin))
      MATCH_BYTEBEGIN = seal(MatchData.instance_method(:bytebegin))
      MATCH_BYTEEND = seal(MatchData.instance_method(:byteend))
      INTEGER_ADD = seal(Integer.instance_method(:+))
      INTEGER_GREATER = seal(Integer.instance_method(:>))
      INTEGER_TIMES = seal(Integer.instance_method(:times))
      FAILURE_BASE = StandardError
      UTF8 = Encoding::UTF_8
      UNSAFE_PATH = %r{\A\z|\A(?:/|[A-Za-z]:|[~-])|[\x00-\x1F\x7F]|\\|//|/\z|(?:\A|/)\.{1,2}(?:/|\z)}.freeze
      PATTERNS = [
        [ "pattern:anthropic", /sk-ant-[A-Za-z0-9_-]{12,}/.freeze ],
        [ "pattern:openai", /sk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{20,}/.freeze ],
        [ "pattern:github-token", /gh[opsu]_[A-Za-z0-9]{20,}/.freeze ],
        [ "pattern:github-pat", /github_pat_[A-Za-z0-9_]{20,}/.freeze ],
        [
          "pattern:private-key",
          /-----BEGIN[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)[ ])?PRIVATE[ ]KEY(?:[ ]BLOCK)?-----
           [\s\S]{0,4096}?(?:-----END[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)[ ])?
           PRIVATE[ ]KEY(?:[ ]BLOCK)?-----|\z)/x.freeze
        ]
      ]
      OBJECT_FREEZE.send(INVOKE, PATTERNS.each { |entry| OBJECT_FREEZE.send(INVOKE, entry) })
      EXACT_FINDINGS = Array.new(MAX_EXACT_SECRETS) { |index| "exact-secret:#{index}".freeze }.freeze
      FAILURE_MATCHER = Module.new do
        def self.===(error) = MODULE_CASE.send(INVOKE, FAILURE_BASE, error)
      end.freeze
      def self.text(value, limit: MAX_BYTES)
        project do
          owned_string!(value)
          fail_projection! if INTEGER_GREATER.send(INVOKE, STRING_BYTESIZE.send(INVOKE, value), MAX_BYTES)
          fail_projection! unless OBJECT_EQUAL.send(INVOKE, OBJECT_CLASS.send(INVOKE, limit), Integer)
          bounded = INTEGER_GREATER.send(INVOKE, 0, limit) ? 0 : limit
          bounded = MAX_BYTES if INTEGER_GREATER.send(INVOKE, bounded, MAX_BYTES)
          OBJECT_FREEZE.send(INVOKE, STRING_SCRUB.send(INVOKE, STRING_BYTESLICE.send(INVOKE, value, 0, bounded), ""))
        end
      end
      def self.safe_relative_path?(value)
        project do
          owned_string!(value)
          oversized = INTEGER_GREATER.send(INVOKE, STRING_BYTESIZE.send(INVOKE, value), MAX_BYTES)
          oversized ? false : !REGEXP_MATCH.send(INVOKE, UNSAFE_PATH, value)
        end
      end
      def self.secret_findings(value, exact_secrets:)
        project { ARRAY_GET.send(INVOKE, scan(value, exact_secrets), 0) }
      end
      def self.redact(value, exact_secrets:, limit: MAX_BYTES)
        project do
          _findings, marks = scan(value, exact_secrets)
          output = STRING_BYTESLICE.send(INVOKE, "", 0, 0)
          active = 0
          inside = false
          INTEGER_TIMES.send(INVOKE, STRING_BYTESIZE.send(INVOKE, value)) do |index|
            active = INTEGER_ADD.send(INVOKE, active, ARRAY_GET.send(INVOKE, marks, index))
            if INTEGER_GREATER.send(INVOKE, active, 0)
              unless inside
                STRING_APPEND.send(INVOKE, output, "[REDACTED]")
                inside = true
              end
            else
              inside = false
              STRING_APPEND.send(INVOKE, output, STRING_BYTESLICE.send(INVOKE, value, index, 1))
            end
          end
          clipped = STRING_SCRUB.send(INVOKE, STRING_BYTESLICE.send(INVOKE, output, 0, MAX_BYTES), "")
          OBJECT_FREEZE.send(INVOKE, clipped)
          text(clipped, limit: limit)
        end
      end
      def self.project
        yield
      rescue FAILURE_MATCHER
        fail_projection!
      end
      def self.fail_projection!
        failure = OBJECT_CLONE.send(INVOKE, PROJECT_FAILURE, freeze: false)
        RAISE.send(INVOKE, self, failure, cause: nil)
      end
      def self.owned_string!(value)
        fail_projection! unless OBJECT_EQUAL.send(INVOKE, OBJECT_CLASS.send(INVOKE, value), String)
        fail_projection! unless OBJECT_FROZEN.send(INVOKE, value)
        fail_projection! unless OBJECT_EQUAL.send(INVOKE, STRING_ENCODING.send(INVOKE, value), UTF8)
        fail_projection! unless STRING_VALID.send(INVOKE, value)
      end
      def self.scan(value, exact_secrets)
        owned_string!(value)
        fail_projection! if INTEGER_GREATER.send(INVOKE, STRING_BYTESIZE.send(INVOKE, value), MAX_BYTES)
        fail_projection! unless OBJECT_EQUAL.send(INVOKE, OBJECT_CLASS.send(INVOKE, exact_secrets), Array)
        fail_projection! unless OBJECT_FROZEN.send(INVOKE, exact_secrets)
        fail_projection! if INTEGER_GREATER.send(INVOKE, ARRAY_LENGTH.send(INVOKE, exact_secrets), MAX_EXACT_SECRETS)
        marks = ARRAY_MULTIPLY.send(INVOKE, [ 0 ], INTEGER_ADD.send(INVOKE, STRING_BYTESIZE.send(INVOKE, value), 1))
        findings = scan_exact!(STRING_BINARY.send(INVOKE, value), exact_secrets, marks)
        scan_patterns!(value, findings, marks)
        [ OBJECT_FREEZE.send(INVOKE, findings), marks ]
      end
      def self.scan_patterns!(value, findings, marks)
        ARRAY_EACH.send(INVOKE, PATTERNS) do |label, pattern|
          found = false
          position = 0
          while (match = REGEXP_MATCH.send(INVOKE, pattern, value, position))
            found = true
            mark_range!(marks, MATCH_BYTEBEGIN.send(INVOKE, match, 0), MATCH_BYTEEND.send(INVOKE, match, 0))
            position = INTEGER_ADD.send(INVOKE, MATCH_BEGIN.send(INVOKE, match, 0), 1)
          end
          ARRAY_PUSH.send(INVOKE, findings, label) if found
        end
      end
      def self.scan_exact!(value, exact_secrets, marks)
        findings = []
        seen = []
        INTEGER_TIMES.send(INVOKE, ARRAY_LENGTH.send(INVOKE, exact_secrets)) do |index|
          secret = ARRAY_GET.send(INVOKE, exact_secrets, index)
          owned_string!(secret)
          size = STRING_BYTESIZE.send(INVOKE, secret)
          fail_projection! unless INTEGER_GREATER.send(INVOKE, size, 0)
          fail_projection! if INTEGER_GREATER.send(INVOKE, size, MAX_BYTES)
          found = find_exact!(value, STRING_BINARY.send(INVOKE, secret), size, marks, seen)
          ARRAY_PUSH.send(INVOKE, findings, ARRAY_GET.send(INVOKE, EXACT_FINDINGS, index)) if found
        end
        findings
      end
      def self.find_exact!(value, secret, size, marks, seen)
        seen_index = ARRAY_INDEX.send(INVOKE, seen) do |entry|
          STRING_EQUAL.send(INVOKE, ARRAY_GET.send(INVOKE, entry, 0), secret)
        end
        return ARRAY_GET.send(INVOKE, ARRAY_GET.send(INVOKE, seen, seen_index), 1) if seen_index
        found = false
        offset = STRING_BYTEINDEX.send(INVOKE, value, secret, 0)
        while offset
          found = true
          mark_range!(marks, offset, INTEGER_ADD.send(INVOKE, offset, size))
          offset = STRING_BYTEINDEX.send(INVOKE, value, secret, INTEGER_ADD.send(INVOKE, offset, 1))
        end
        ARRAY_PUSH.send(INVOKE, seen, [ secret, found ])
        found
      end
      def self.mark_range!(marks, first, last)
        ARRAY_SET.send(INVOKE, marks, first, INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, marks, first), 1))
        ARRAY_SET.send(INVOKE, marks, last, INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, marks, last), -1))
      end
      private_class_method :seal, :project, :fail_projection!, :owned_string!, :scan, :scan_patterns!, :scan_exact!,
                           :find_exact!, :mark_range!
      private_constant :PROJECT_FAILURE, :INVOKE, :MAX_BYTES, :MAX_EXACT_SECRETS,
                       :OBJECT_CLASS, :OBJECT_CLONE, :OBJECT_EQUAL, :OBJECT_FREEZE,
                       :OBJECT_FROZEN, :RAISE, :MODULE_CASE, :ARRAY_EACH, :ARRAY_GET, :ARRAY_INDEX, :ARRAY_LENGTH,
                       :ARRAY_MULTIPLY, :ARRAY_PUSH, :ARRAY_SET, :STRING_APPEND, :STRING_BYTEINDEX, :STRING_BYTESIZE,
                       :STRING_BYTESLICE, :STRING_ENCODING, :STRING_EQUAL, :STRING_SCRUB, :STRING_VALID, :REGEXP_MATCH,
                       :STRING_BINARY, :MATCH_BEGIN, :MATCH_BYTEBEGIN, :MATCH_BYTEEND, :INTEGER_ADD, :INTEGER_GREATER,
                       :INTEGER_TIMES, :FAILURE_BASE, :UTF8, :UNSAFE_PATH, :PATTERNS, :EXACT_FINDINGS, :FAILURE_MATCHER
      OBJECT_FREEZE.send(INVOKE, Error)
      OBJECT_FREEZE.send(INVOKE, self)
    end
  end
end
