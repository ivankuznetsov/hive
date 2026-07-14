module Hive
  # Shared regex set for credential/secret detection. Used by:
  # - PR-body/comment secret scans in OpenPr, Finalize, and GithubPublisher
  # - lib/hive/stages/review/fix_guardrail.rb's post-fix diff guardrail (ADR-020)
  # - lib/hive/honeycomb/preflight.rb's packaged-file secret gate and redacted
  #   dependency diagnostics (and manifest.rb's RULE_SET_VERSION stamp)
  #
  # New patterns must come with at least one test in
  # test/unit/secret_patterns_test.rb (or the consumer's tests).
  module SecretPatterns
    RULE_SET_VERSION = 1
    REMEDIATION = "Remove the secret from the package and reference it through runtime secret configuration instead.".freeze

    Rule = Data.define(:id, :regex, :remediation)
    SafeFinding = Data.define(:rule_id, :file, :line, :remediation)

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
      # PEM-encoded private keys. Block form (/m flag) so the regex
      # spans the full BEGIN ... END envelope including the base64
      # body. The previous header-only regex left the key body in
      # redacted output — see PR #84 review finding #3.
      pem_private_key:       /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----.*?-----END (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----/m,
      # Truncated-PEM fallback. Status diagnostic tails are cut at a
      # fixed byte budget (DIAGNOSTIC_DETAIL_MAX = 4000) so most leaks
      # appear as BEGIN + partial body with no matching END. The
      # block-form pattern above fails on these; this fallback redacts
      # BEGIN through up to 4000 trailing bytes so the partial body is
      # not surfaced. Ordering matters: the full-block pattern runs
      # first via PATTERNS-iteration so complete PEMs are replaced
      # before this fallback can see them. Resolves issue #88.
      pem_private_key_header: /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----[\s\S]{0,4000}/,
      # `password=`, `passwd=`, `PASSWORD=` style assignments. Same
      # token-boundary shape as generic_api_key so unquoted shell/env
      # values trip without running past the secret.
      password_assignment:   /\b(?:password|passwd|pwd)\b[\s:=]{0,3}['"]?[^\s'"]{6,}['"]?(?=[\s,;]|$)/i,
      # HTTP Authorization headers with Bearer / Basic / Token scheme.
      # Catches the header value regardless of surrounding format
      # (curl output, header dumps, framework log lines).
      bearer_token:          /\bauthorization\s*[:=]\s*['"]?(?:Bearer|Basic|Token)\s+[A-Za-z0-9._\-+\/=]{8,}['"]?/i,
      # Session-like Cookie / Set-Cookie values. Matches a key
      # containing `session` / `sessionid` / `sid` / `auth` followed
      # by a non-trivial value.
      session_cookie:        /(?:Set-)?Cookie:\s*[^;\s]*(?:session(?:id)?|sid|auth)[^;=\s]*=[^;\s]{8,}/i,
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

    def rules
      @rules ||= PATTERNS.map do |id, regex|
        Rule.new(id: id, regex: regex, remediation: REMEDIATION)
      end.freeze
    end

    # Location-aware scan for diagnostics that must never include matched
    # credential bytes. Unlike `scan`, this intentionally has no snippet
    # field and is safe to render in public submission output.
    def safe_scan(text, file:)
      normalized = utf8(text)
      return [] if normalized.empty?

      rules.flat_map do |rule|
        normalized.to_enum(:scan, rule.regex).map do
          match = Regexp.last_match
          SafeFinding.new(
            rule_id: rule.id.to_s,
            file: file.to_s,
            line: normalized[0...match.begin(0)].count("\n") + 1,
            remediation: rule.remediation
          )
        end
      end.sort_by { |finding| [ finding.file, finding.line, finding.rule_id ] }.freeze
    end

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

    # Replace every PATTERNS match in `text` with a `[REDACTED:<name>]`
    # placeholder. Shared helper so consumers (TaskAction#diagnostic,
    # DiagnosisAgent#artifact_body, etc.) cannot diverge on which
    # patterns they apply. Returns a new string; `text` is not mutated.
    # Binary input is coerced to UTF-8 with invalid bytes replaced so
    # gsub against UTF-8 regexes never raises Encoding::CompatibilityError.
    def redact(text)
      return "" if text.nil?

      output = utf8(text)
      PATTERNS.each do |name, regex|
        output.gsub!(regex, "[REDACTED:#{name}]")
      end
      output
    end

    def utf8(text)
      output = text.to_s.dup
      output.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    end
    private_class_method :utf8
  end
end
