module AgentCliRuntime
  module Redactor
    PATTERNS = {
      github_token: /\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[psou]_[A-Za-z0-9]{36,})\b/,
      openai_api_key: /\bsk-[A-Za-z0-9]{20,}/,
      anthropic_api_key: /\bsk-ant-[A-Za-z0-9_-]{20,}/,
      generic_api_key:
        /\bapi[_-]?key\b['"]?[\s:=]{0,3}['"]?[A-Za-z0-9_-]{20,}['"]?(?=[\s,;}\]]|$)/i,
      password:
        /\b(?:password|passwd|pwd)\b['"]?[\s:=]{0,3}['"]?[^\s'"]{6,}['"]?(?=[\s,;}\]]|$)/i,
      authorization:
        /\bauthorization\s*[:=]\s*['"]?(?:Bearer|Basic|Token)\s+[A-Za-z0-9._+\/=-]{8,}['"]?/i,
      private_key:
        /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----.*?-----END (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----/m,
      private_key_header:
        /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----[\s\S]*\z/,
      jwt: /\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/
    }.freeze

    module_function

    def redact(value)
      output = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
      PATTERNS.each do |name, pattern|
        output.gsub!(pattern, "[REDACTED:#{name}]")
      end
      output
    end

    def diagnostic(value, bytes: AgentCliRuntime::DIAGNOSTIC_BYTES)
      message = value.respond_to?(:message) ? value.message : value.to_s
      redacted = redact(message)
      return nil if redacted.empty?
      return redacted.freeze if redacted.bytesize <= bytes

      redacted.byteslice(0, bytes).to_s
              .force_encoding(Encoding::UTF_8)
              .scrub("?")
              .freeze
    end
  end
end
