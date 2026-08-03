module HiveLiveAgentProof
  module WorkflowCreator
    module TextSafety
      class Error < StandardError; end
      MAX_INPUT_BYTES, MAX_OUTPUT_BYTES, MAX_SECRET_BYTES, MAX_EXACT_SECRETS = 4_096, 4_096, 4_096, 64
      REDACTED = "[REDACTED]".freeze
      PATTERNS = [
        [ "pattern:anthropic".freeze, /sk-ant-[A-Za-z0-9_-]{12,}/.freeze ],
        [ "pattern:openai".freeze, /sk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{20,}/.freeze ],
        [ "pattern:github-token".freeze, /gh[opsu]_[A-Za-z0-9]{20,}/.freeze ],
        [ "pattern:github-pat".freeze, /github_pat_[A-Za-z0-9_]{20,}/.freeze ],
        [ "pattern:private-key".freeze, /
          -----BEGIN[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP)[ ])?PRIVATE[ ]KEY(?:[ ]BLOCK)?-----
          [\s\S]{0,4096}?(?:-----END[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP)[ ])?PRIVATE[ ]KEY(?:[ ]BLOCK)?-----|\z)/x.freeze ]
      ].each(&:freeze).freeze
      EXACT_FINDINGS = Array.new(MAX_EXACT_SECRETS) { |index| "exact-secret:#{index}".freeze }.freeze
      REDACTION_TRANSITIONS = [ "".freeze, REDACTED, "".freeze, "".freeze ].freeze
      UNSAFE_PATH = %r{\A\z|\A(?:/|[A-Za-z]:|[~-])|[\x00-\x1F\x7F]|\\|//|/\z|(?:\A|/)\.{1,2}(?:/|\z)}.freeze
      OBJECT_FREEZE, CLASS_ALLOCATE, PROC_CALL, STRING_INITIALIZE =
        Values::OBJECT_FREEZE, Values::CLASS_ALLOCATE, Values::PROC_CALL, Values::STRING_INITIALIZE
      REGEXP_LAST_MATCH, METHOD_CALL = Regexp.method(:last_match).freeze, Method.instance_method(:call).freeze
      MATCH_BEGIN, MATCH_END = %i[bytebegin byteend].map { MatchData.instance_method(_1).freeze }
      STRING_BYTESIZE, STRING_APPEND, STRING_BYTESLICE, STRING_SCRUB, STRING_MATCH, STRING_BYTEINDEX, STRING_SCAN, STRING_BINARY =
        Values::STRING_BYTESIZE, Values::STRING_APPEND, *%i[byteslice scrub match? byteindex scan b].map { String.instance_method(_1).freeze }
      ARRAY_INITIALIZE, ARRAY_EACH, ARRAY_LENGTH, ARRAY_PUSH, ARRAY_GET, ARRAY_SET =
        %i[initialize each length << [] []=].map { Array.instance_method(_1).freeze }
      INTEGER_ADD, INTEGER_SUBTRACT, INTEGER_MULTIPLY, INTEGER_GREATER, INTEGER_TIMES, INTEGER_BETWEEN, INTEGER_CLAMP =
        %i[+ - * > times between? clamp].map { Integer.instance_method(_1).freeze }
      MARK_RANGE = lambda do |marks, first, last|
        ARRAY_SET.bind_call(marks, first, INTEGER_ADD.bind_call(ARRAY_GET.bind_call(marks, first), 1))
        ARRAY_SET.bind_call(marks, last, INTEGER_SUBTRACT.bind_call(ARRAY_GET.bind_call(marks, last), 1))
      end.freeze
      SECRET_SCAN = lambda do |value, secrets|
        raise Error if INTEGER_GREATER.bind_call(STRING_BYTESIZE.bind_call(value), MAX_INPUT_BYTES)
        raise Error if INTEGER_GREATER.bind_call(ARRAY_LENGTH.bind_call(secrets), MAX_EXACT_SECRETS)
        marks = ARRAY_INITIALIZE.bind_call(CLASS_ALLOCATE.bind_call(Array), INTEGER_ADD.bind_call(STRING_BYTESIZE.bind_call(value), 1), 0)
        findings, bytes = [], STRING_BINARY.bind_call(value)
        INTEGER_TIMES.bind_call(ARRAY_LENGTH.bind_call(secrets)) do |index|
          secret = ARRAY_GET.bind_call(secrets, index)
          size, needle = STRING_BYTESIZE.bind_call(secret), STRING_BINARY.bind_call(secret)
          raise Error unless INTEGER_BETWEEN.bind_call(size, 1, MAX_SECRET_BYTES)
          offset = STRING_BYTEINDEX.bind_call(bytes, needle, 0)
          ARRAY_PUSH.bind_call(findings, ARRAY_GET.bind_call(EXACT_FINDINGS, index)) if offset
          while offset
            PROC_CALL.bind_call(MARK_RANGE, marks, offset, INTEGER_ADD.bind_call(offset, size))
            offset = STRING_BYTEINDEX.bind_call(bytes, needle, INTEGER_ADD.bind_call(offset, 1))
          end
        end
        ARRAY_EACH.bind_call(PATTERNS) do |label, pattern|
          found = false
          STRING_SCAN.bind_call(value, pattern) do
            match = METHOD_CALL.bind_call(REGEXP_LAST_MATCH)
            PROC_CALL.bind_call(MARK_RANGE, marks, MATCH_BEGIN.bind_call(match, 0), MATCH_END.bind_call(match, 0))
            found = true
          end
          ARRAY_PUSH.bind_call(findings, label) if found
        end
        [ OBJECT_FREEZE.bind_call(findings), marks ]
      end.freeze
      class << self
        def text(value, limit: MAX_OUTPUT_BYTES)
          raise Error if INTEGER_GREATER.bind_call(STRING_BYTESIZE.bind_call(value), MAX_INPUT_BYTES)
          bounded = INTEGER_CLAMP.bind_call(limit, 0, MAX_OUTPUT_BYTES)
          OBJECT_FREEZE.bind_call(STRING_SCRUB.bind_call(STRING_BYTESLICE.bind_call(value, 0, bounded), ""))
        end
        def safe_relative_path?(value)
          INTEGER_GREATER.bind_call(STRING_BYTESIZE.bind_call(value), MAX_INPUT_BYTES) ?
            false : !STRING_MATCH.bind_call(value, UNSAFE_PATH)
        end
        def secret_findings(value, exact_secrets:) = ARRAY_GET.bind_call(PROC_CALL.bind_call(SECRET_SCAN, value, exact_secrets), 0)
        def redact(value, exact_secrets:, limit: MAX_OUTPUT_BYTES)
          marks = ARRAY_GET.bind_call(PROC_CALL.bind_call(SECRET_SCAN, value, exact_secrets), 1)
          output = STRING_INITIALIZE.bind_call(CLASS_ALLOCATE.bind_call(String), encoding: Values::UTF8)
          active = inside = 0
          INTEGER_TIMES.bind_call(STRING_BYTESIZE.bind_call(value)) do |index|
            active = INTEGER_ADD.bind_call(active, ARRAY_GET.bind_call(marks, index))
            masked = INTEGER_CLAMP.bind_call(active, 0, 1)
            transition = INTEGER_ADD.bind_call(INTEGER_MULTIPLY.bind_call(inside, 2), masked)
            STRING_APPEND.bind_call(output, ARRAY_GET.bind_call(REDACTION_TRANSITIONS, transition))
            STRING_APPEND.bind_call(output, STRING_BYTESLICE.bind_call(value, index,
                                                                       INTEGER_SUBTRACT.bind_call(1, masked)))
            inside = masked
          end
          text(STRING_BYTESLICE.bind_call(output, 0, MAX_INPUT_BYTES), limit: limit)
        end
      end
      Error.freeze
    end
  end
end
