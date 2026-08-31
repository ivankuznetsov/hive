require "digest"

module Hive
  # Shared regex set for credential/secret detection. Used by both:
  # - PR-body/comment secret scans in OpenPr, Finalize, and GithubPublisher
  # - lib/hive/stages/review/fix_guardrail.rb's post-fix diff guardrail (ADR-020)
  #
  # New patterns must come with at least one test in
  # test/unit/secret_patterns_test.rb (or the consumer's tests).
  module SecretPatterns
    POLICY_VERSION = 1
    PASSWORD_ASSIGNMENT_PREFIX = /\A.*?\b(?:[A-Za-z][A-Za-z0-9]*_)*(?:password|passwd|pwd)\b['"]?\s*[:=]\s*/i
    DYNAMIC_PASSWORD_LOOKUP = /\A
      (?=[^\r\n]*(?:\[|\())
      [A-Za-z_$][A-Za-z0-9_$]*
      (?:
        \.[A-Za-z_$][A-Za-z0-9_$]*
        | \[[^\]\r\n]+\]
        | \([^\)\r\n]*\)
      )+
    \z/x
    RUBY_SOURCE_PATH = /(?:\A|\/)(?:[^\/]+\.(?:rb|rake)|Rakefile)\z/.freeze
    RUBY_PASSWORD_REFERENCE = /\A(?:
      [@$]{0,2}[A-Za-z_][A-Za-z0-9_]*
      | :[A-Za-z_][A-Za-z0-9_]*[!?=]?
      | \([@$]{0,2}[A-Za-z_][A-Za-z0-9_]*\)
    )\z/x

    PATTERNS = {
      # AWS access key id (AKIA = long-term, ASIA = temporary session token)
      # and secret access key.
      aws_access_key:        /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
      aws_secret_access_key: %r{aws[_\- ]secret[_\- ]access[_\- ]key.{0,5}['"]?[A-Za-z0-9/+=]{40}['"]?}i,
      # Current fine-grained GitHub PATs use the longer `github_pat_` prefix.
      github_fine_grained_pat: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
      # Legacy GitHub tokens: ghp (PAT), ghs (server-to-server), gho (OAuth), ghu (user).
      github_token:          /gh[psou]_[A-Za-z0-9]{36,}/,
      # Generic api_key / api-key / apiKey followed by an assignment to a
      # long string. Quotes are optional so unquoted shell/YAML/env-style
      # assignments (`API_KEY=abcdef...`) also trip; the trailing
      # lookahead requires a token boundary so we don't run past the
      # secret into adjacent text.
      generic_api_key:       /\bapi[_\-]?key\b['"]?[\s:=]{0,3}['"]?[A-Za-z0-9_\-]{20,}['"]?(?=[\s,;}\]]|$)/i,
      # PEM-encoded private keys. Block form (/m flag) so the regex
      # spans the full BEGIN ... END envelope including the base64
      # body. The previous header-only regex left the key body in
      # redacted output — see PR #84 review finding #3.
      pem_private_key:       /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----.*?-----END (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----/m,
      # Truncated-PEM fallback. Status diagnostic tails are cut at a
      # fixed byte budget (DIAGNOSTIC_DETAIL_MAX = 4000) so most leaks
      # appear as BEGIN + partial body with no matching END. The
      # block-form pattern above fails on these; this fallback redacts
      # BEGIN through the end of the diagnostic so a long partial body is
      # not surfaced. Ordering matters: the full-block pattern runs
      # first via PATTERNS-iteration so complete PEMs are replaced
      # before this fallback can see them. Resolves issue #88.
      pem_private_key_header: /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----[\s\S]*\z/,
      # `password=`, `passwd=`, `PASSWORD=` style assignments. Require
      # the assignment delimiter so prose such as "password resets" is
      # not mistaken for a credential.
      # Include conventional prefixes (`DB_PASSWORD`, `ADMIN_PASSWORD`) so a
      # dotted unquoted credential cannot hide behind the variable name.
      # A whole shell variable reference is not itself secret material. Exempt
      # only `$NAME` / `${NAME}` (optionally quoted); mixed reference-plus-
      # literal values remain fail-closed.
      password_assignment:   /\b(?:[A-Za-z][A-Za-z0-9]*_)*(?:password|passwd|pwd)\b['"]?\s*[:=]\s*(?!['"]?\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)['"]?(?=[\s,;}\]]|$))['"]?[^\s'"]{6,}['"]?(?=[\s,;}\]]|$)/i,
      password_sql:          /\bPASSWORD\s+['"][^\s'"]{6,}['"]/i,
      password_xml:          /<password>\s*[^<\s]{6,}\s*<\/password>/i,
      password_cli:          /--password\s+['"]?[^\s'"]{6,}['"]?(?=\s|$)/i,
      # HTTP Authorization headers with Bearer / Basic / Token scheme.
      # Catches the header value regardless of surrounding format
      # (curl output, header dumps, framework log lines).
      bearer_token:          /\bauthorization\s*[:=]\s*['"]?(?:Bearer|Basic|Token)\s+[A-Za-z0-9._\-+\/=]{8,}['"]?/i,
      # Session-like Cookie / Set-Cookie values. Matches a key
      # containing `session` / `sessionid` / `sid` / `auth` followed
      # by a non-trivial value.
      session_cookie:        /(?:Set-)?Cookie:\s*[^;\s]*(?:session(?:id)?|sid|auth)[^;=\s]*=[^;\s]{8,}/i,
      # OpenAI / Anthropic / Stripe API keys (canonical prefixes).
      openai_api_key:        /\bsk-(?!ant-)[A-Za-z0-9_-]{20,}/,
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

      text = normalized_utf8(text)
      matches = []
      PATTERNS.each do |name, regex|
        text.scan(regex) do |_capture|
          full = Regexp.last_match[0]
          matches << {
            name: name,
            snippet: full.length > 80 ? "#{full[0, 80]}…" : full,
            sha256: Digest::SHA256.hexdigest(full)
          }
        end
      end
      matches
    end

    def match?(text)
      return false if text.nil? || text.empty?

      PATTERNS.each_value.any? { |regex| regex.match?(text) }
    end

    # Git diffs need source-aware classification that raw logs and prose do
    # not. Scan only paths and added lines, then ignore password-shaped bytes
    # when the right-hand side is provably a runtime reference. The ordinary
    # scan/match?/redact API stays conservative.
    def match_diff?(diff)
      return false if diff.nil? || diff.empty?

      current_path = nil
      in_hunk = false
      saw_file = false

      normalized_utf8(diff).each_line do |raw_line|
        line = raw_line.chomp! || raw_line
        if line.start_with?("diff --git ")
          saw_file = true
          current_path = nil
          in_hunk = false
          return true if match?(line)
          next
        end

        if (path_match = line.match(%r{\A\+\+\+ [bciow]/(.+)\z}))
          current_path = path_match[1]
          return true if match?(current_path)
          next
        end
        if line == "+++ /dev/null"
          current_path = nil
          next
        end
        if line.start_with?("+++ ")
          current_path = nil
          return true if match?(line)
          next
        end
        if line.start_with?("@@ ")
          in_hunk = true
          next
        end
        unless in_hunk
          return true if match?(line)
          next
        end

        if line.start_with?("+") && !line.start_with?("+++")
          added = line[1..]
          return true if source_line_match?(path: current_path, line: added)
        elsif line.start_with?("-") || line.start_with?(" ") ||
              line == "\\ No newline at end of file"
          next
        else
          in_hunk = false
          return true if match?(line)
        end
      end

      # Controller requests normally carry a native Git patch. Preserve the
      # old fail-closed behavior for synthetic or malformed diff bytes.
      !saw_file && match?(diff)
    end

    def runtime_password_reference?(path:, line:, hit:)
      return false unless hit[:name] == :password_assignment

      snippet = hit[:snippet].to_s
      rhs = snippet.sub(PASSWORD_ASSIGNMENT_PREFIX, "")
      return false if rhs == snippet || rhs.start_with?("'", '"')
      candidates = [ rhs ]
      candidates << rhs[0...-1] if rhs.end_with?(",", ";", ")", "}")
      reference = candidates.any? do |candidate|
        DYNAMIC_PASSWORD_LOOKUP.match?(candidate) ||
          (RUBY_SOURCE_PATH.match?(path.to_s) && RUBY_PASSWORD_REFERENCE.match?(candidate))
      end
      return false unless reference

      return true if candidates.length > 1

      offset = line.to_s.index(snippet)
      return false unless offset

      tail = line.to_s[(offset + snippet.length)..].to_s.lstrip
      tail.empty? || tail.start_with?(",", ")", "}", ";", "#") ||
        (RUBY_SOURCE_PATH.match?(path.to_s) && tail.match?(/\Ado(?:\s|\z)/))
    end

    # Replace every PATTERNS match in `text` with a `[REDACTED:<name>]`
    # placeholder. Shared helper so consumers (TaskAction#diagnostic,
    # DiagnosisAgent#artifact_body, etc.) cannot diverge on which
    # patterns they apply. Returns a new string; `text` is not mutated.
    # Binary input is coerced to UTF-8 with invalid bytes replaced so
    # gsub against UTF-8 regexes never raises Encoding::CompatibilityError.
    def redact(text)
      return "" if text.nil?

      output = normalized_utf8(text)
      PATTERNS.each do |name, regex|
        output.gsub!(regex, "[REDACTED:#{name}]")
      end
      output
    end

    def normalized_utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
    end

    def source_line_match?(path:, line:)
      PATTERNS.each do |name, regex|
        line.scan(regex) do
          return true unless name == :password_assignment

          full = Regexp.last_match[0]
          snippet = full.length > 80 ? "#{full[0, 80]}…" : full
          hit = { name: name, snippet: snippet }
          return true unless runtime_password_reference?(path: path, line: line, hit: hit)
        end
      end
      false
    end
    private_class_method :normalized_utf8, :source_line_match?
  end
end
