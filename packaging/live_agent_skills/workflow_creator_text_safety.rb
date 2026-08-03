module HiveLiveAgentProof
  module WorkflowCreator
    module TextSafety
      class Error < StandardError; end
      MAX_INPUT_BYTES, MAX_OUTPUT_BYTES, MAX_SECRET_BYTES, MAX_EXACT_SECRETS = 4_096, 4_096, 4_096, 64
      REDACTED = "[REDACTED]".freeze
      PATTERNS = [
        [ "pattern:anthropic".freeze, /sk-ant-[A-Za-z0-9_-]{12,}/.freeze ], [ "pattern:openai".freeze, /sk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{20,}/.freeze ],
        [ "pattern:github-token".freeze, /gh[opsu]_[A-Za-z0-9]{20,}/.freeze ], [ "pattern:github-pat".freeze, /github_pat_[A-Za-z0-9_]{20,}/.freeze ],
        [ "pattern:private-key".freeze, /-----BEGIN[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)[ ])?PRIVATE[ ]KEY(?:[ ]BLOCK)?-----[\s\S]{0,4096}?(?:-----END[ ](?:(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)[ ])?PRIVATE[ ]KEY(?:[ ]BLOCK)?-----|\z)/x.freeze ]
      ].each(&:freeze).freeze
      EXACT_FINDINGS = Array.new(MAX_EXACT_SECRETS) { |index| "exact-secret:#{index}".freeze }.freeze
      REDACTION_TRANSITIONS = [ "".freeze, REDACTED, "".freeze, "".freeze ].freeze
      UNSAFE_PATH = %r{\A\z|\A(?:/|[A-Za-z]:|[~-])|[\x00-\x1F\x7F]|\\|//|/\z|(?:\A|/)\.{1,2}(?:/|\z)}.freeze
      SEAL = Values.const_get(:SEAL, false)
      OBJECT_EQUAL, OBJECT_FREEZE, PROC_CALL = Values::OBJECT_EQUAL, Values::OBJECT_FREEZE, Values::PROC_CALL
      REGEXP_LAST_MATCH = SEAL.call(Regexp.method(:last_match), :call)
      MATCH_BEGIN, MATCH_END = %i[bytebegin byteend].map { SEAL.call(MatchData.instance_method(_1), :bind_call) }
      STRING_BYTESIZE, STRING_APPEND, STRING_BYTESLICE, STRING_SCRUB, STRING_MATCH, STRING_BYTEINDEX, STRING_SCAN, STRING_BINARY, HASH_FETCH, HASH_SET = [ Values::STRING_BYTESIZE, Values::STRING_APPEND, *%i[byteslice scrub match? byteindex scan b].map { SEAL.call(String.instance_method(_1), :bind_call) }, *%i[fetch []=].map { SEAL.call(Hash.instance_method(_1), :bind_call) } ]
      ARRAY_EACH, ARRAY_LENGTH, ARRAY_PUSH, ARRAY_GET, ARRAY_SET, ARRAY_MULTIPLY = %i[each length << [] []= *].map { SEAL.call(Array.instance_method(_1), :bind_call) }
      INTEGER_ADD, INTEGER_SUBTRACT, INTEGER_MULTIPLY, INTEGER_GREATER, INTEGER_ZERO, INTEGER_COMPARE, INTEGER_TIMES = %i[+ - * > zero? <=> times].map { SEAL.call(Integer.instance_method(_1), :bind_call) }
      LOWER_MASK, UPPER_MASK = [ 0, 0, 1 ].freeze, [ 0, 1, 0 ].freeze
      MARK_RANGE = lambda do |marks, first, last|
        ARRAY_SET.__invoke__(marks, first, INTEGER_ADD.__invoke__(ARRAY_GET.__invoke__(marks, first), 1))
        ARRAY_SET.__invoke__(marks, last, INTEGER_SUBTRACT.__invoke__(ARRAY_GET.__invoke__(marks, last), 1))
      end.freeze
      ERROR_BOUNDARY = SEAL.call(lambda do |&projection|
        PROC_CALL.__invoke__(projection)
      rescue Error, EncodingError, TypeError, ArgumentError then raise Error, "workflow-creator text cannot be projected", cause: nil
      end, :call)
      SECRET_SCAN = lambda do |value, secrets|
        raise Error if INTEGER_GREATER.__invoke__(STRING_BYTESIZE.__invoke__(value), MAX_INPUT_BYTES)
        raise Error if INTEGER_GREATER.__invoke__(ARRAY_LENGTH.__invoke__(secrets), MAX_EXACT_SECRETS)
        marks = ARRAY_MULTIPLY.__invoke__([ 0 ], INTEGER_ADD.__invoke__(STRING_BYTESIZE.__invoke__(value), 1))
        findings, bytes, matches = [], STRING_BINARY.__invoke__(value), {}
        INTEGER_TIMES.__invoke__(ARRAY_LENGTH.__invoke__(secrets)) do |index|
          secret = ARRAY_GET.__invoke__(secrets, index)
          size, needle = STRING_BYTESIZE.__invoke__(secret), STRING_BINARY.__invoke__(secret)
          raise Error if INTEGER_ZERO.__invoke__(size)
          raise Error if INTEGER_GREATER.__invoke__(size, MAX_SECRET_BYTES)
          offset = HASH_FETCH.__invoke__(matches, needle) do
            first = offset = STRING_BYTEINDEX.__invoke__(bytes, needle, 0)
            while offset
              PROC_CALL.__invoke__(MARK_RANGE, marks, offset, INTEGER_ADD.__invoke__(offset, size))
              offset = STRING_BYTEINDEX.__invoke__(bytes, needle, INTEGER_ADD.__invoke__(offset, 1))
            end
            HASH_SET.__invoke__(matches, needle, first)
          end
          ARRAY_PUSH.__invoke__(findings, ARRAY_GET.__invoke__(EXACT_FINDINGS, index)) if offset
        end
        ARRAY_EACH.__invoke__(PATTERNS) do |label, pattern|
          found = false
          STRING_SCAN.__invoke__(value, pattern) do
            match = REGEXP_LAST_MATCH.__invoke__
            PROC_CALL.__invoke__(MARK_RANGE, marks, MATCH_BEGIN.__invoke__(match, 0), MATCH_END.__invoke__(match, 0))
            found = true
          end
          ARRAY_PUSH.__invoke__(findings, label) if found
        end
        [ OBJECT_FREEZE.__invoke__(findings), marks ]
      end.freeze
      class << self
        def text(value, limit: MAX_OUTPUT_BYTES) = ERROR_BOUNDARY.__invoke__ do
          raise Error if INTEGER_GREATER.__invoke__(STRING_BYTESIZE.__invoke__(value), MAX_INPUT_BYTES)
          bounded = INTEGER_ADD.__invoke__(limit, INTEGER_MULTIPLY.__invoke__(INTEGER_SUBTRACT.__invoke__(0, limit), ARRAY_GET.__invoke__(LOWER_MASK, INTEGER_COMPARE.__invoke__(limit, 0))))
          bounded = INTEGER_SUBTRACT.__invoke__(bounded, INTEGER_MULTIPLY.__invoke__(INTEGER_SUBTRACT.__invoke__(bounded, MAX_OUTPUT_BYTES), ARRAY_GET.__invoke__(UPPER_MASK, INTEGER_COMPARE.__invoke__(bounded, MAX_OUTPUT_BYTES))))
          OBJECT_FREEZE.__invoke__(STRING_SCRUB.__invoke__(STRING_BYTESLICE.__invoke__(value, 0, bounded), ""))
        end
        def safe_relative_path?(value) = ERROR_BOUNDARY.__invoke__ { INTEGER_GREATER.__invoke__(STRING_BYTESIZE.__invoke__(value), MAX_INPUT_BYTES) ? false : OBJECT_EQUAL.__invoke__(STRING_MATCH.__invoke__(value, UNSAFE_PATH), false) }
        def secret_findings(value, exact_secrets:) = ERROR_BOUNDARY.__invoke__ { ARRAY_GET.__invoke__(PROC_CALL.__invoke__(SECRET_SCAN, value, exact_secrets), 0) }
        def redact(value, exact_secrets:, limit: MAX_OUTPUT_BYTES) = ERROR_BOUNDARY.__invoke__ do
          marks = ARRAY_GET.__invoke__(PROC_CALL.__invoke__(SECRET_SCAN, value, exact_secrets), 1)
          output = STRING_BYTESLICE.__invoke__("", 0, 0)
          active = inside = 0
          INTEGER_TIMES.__invoke__(STRING_BYTESIZE.__invoke__(value)) do |index|
            active = INTEGER_ADD.__invoke__(active, ARRAY_GET.__invoke__(marks, index))
            masked = ARRAY_GET.__invoke__(UPPER_MASK, INTEGER_COMPARE.__invoke__(active, 0))
            transition = INTEGER_ADD.__invoke__(INTEGER_MULTIPLY.__invoke__(inside, 2), masked)
            STRING_APPEND.__invoke__(STRING_APPEND.__invoke__(output, ARRAY_GET.__invoke__(REDACTION_TRANSITIONS, transition)),
                                     STRING_BYTESLICE.__invoke__(value, index, INTEGER_SUBTRACT.__invoke__(1, masked)))
            inside = masked
          end
          text(STRING_BYTESLICE.__invoke__(output, 0, MAX_INPUT_BYTES), limit: limit)
        end
      end
      private_constant :SEAL
      [ Error, self ].each { |object| OBJECT_FREEZE.__invoke__(object) }
    end
  end
end
