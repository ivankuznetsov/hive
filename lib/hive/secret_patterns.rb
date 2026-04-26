module Hive
  # Shared regex set for credential/secret detection. Used by both:
  # - lib/hive/stages/pr.rb's PR-body secret-scan (ADR-008)
  # - lib/hive/stages/review/fix_guardrail.rb's post-fix diff guardrail (ADR-020)
  #
  # New patterns must come with at least one test in
  # test/unit/secret_patterns_test.rb (or the consumer's tests).
  module SecretPatterns
    PATTERNS = {
      # AWS access key id (AKIA = long-term, ASIA = temporary session token)
      # and secret access key.
      aws_access_key:        /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
      aws_secret_access_key: %r{aws[_\- ]secret[_\- ]access[_\- ]key.{0,5}['"]?[A-Za-z0-9/+=]{40}['"]?}i,
      # GitHub tokens: ghp (PAT), ghs (server-to-server), gho (OAuth), ghu (user).
      github_token:          /gh[psou]_[A-Za-z0-9]{36,}/,
      # Generic api_key / api-key / apiKey followed by an assignment to a
      # long string. Quotes are optional so unquoted shell/YAML/env-style
      # assignments (`API_KEY=abcdef...`) also trip; the trailing
      # lookahead requires a token boundary so we don't run past the
      # secret into adjacent text.
      generic_api_key:       /\bapi[_\-]?key\b[\s:=]{0,3}['"]?[A-Za-z0-9_\-]{20,}['"]?(?=[\s,;]|$)/i,
      # PEM-encoded private keys.
      pem_private_key:       /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----/,
      # OpenAI / Anthropic / Stripe API keys (canonical prefixes).
      openai_api_key:        /\bsk-[A-Za-z0-9]{20,}/,
      anthropic_api_key:     /\bsk-ant-[A-Za-z0-9_\-]{20,}/,
      stripe_api_key:        /\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{20,}/,
      # Slack tokens.
      slack_token:           /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
      # JWT-shaped tokens (eyJ... three base64 segments).
      jwt:                   /\beyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b/
    }.freeze

    module_function

    # Scan `text` against every pattern. Returns an Array of
    # `{name:, snippet:}` matches. The snippet is truncated to 80
    # chars so callers can include it in error messages without
    # leaking very long secrets to logs.
    def scan(text)
      return [] if text.nil? || text.empty?

      matches = []
      PATTERNS.each do |name, regex|
        text.scan(regex) do |_capture|
          full = Regexp.last_match[0]
          matches << { name: name, snippet: full.length > 80 ? "#{full[0, 80]}…" : full }
        end
      end
      matches
    end
  end
end
