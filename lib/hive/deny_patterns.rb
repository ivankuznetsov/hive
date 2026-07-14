module Hive
  # Canonical, versioned rules for publish-time behaviors that require an
  # explicit shell capability declaration and registry review.
  module DenyPatterns
    RULE_SET_VERSION = 2

    Rule = Data.define(
      :id,
      :severity,
      :capability,
      :description,
      :remediation,
      :regex
    )
    Finding = Data.define(:rule_id, :file, :line, :severity, :capability, :remediation)

    RULES = [
      Rule.new(
        id: :shell_download_to_interpreter,
        severity: "high",
        capability: "Bash",
        description: "Downloads remote content and executes it through an interpreter.",
        remediation: "Download to a pinned file, verify its digest, and execute it only in an explicitly justified Bash context.",
        # Four shapes. `\\\r?\n` line continuations are treated as whitespace and
        # an optional absolute path (e.g. /bin/) is allowed before the
        # interpreter so `curl x | \\<newline>bash` and `curl x | /bin/bash`
        # no longer evade the rule.
        #   (1) download piped straight to an interpreter, tolerating
        #       sudo/env/command/flag/VAR= wrappers:
        #       `curl x.sh | sudo bash`, `wget -qO- x.sh | sudo -E sh`.
        #   (2) command/process substitution of a download inside an interpreter
        #       or eval/source: `bash <(curl …)`, `eval "$(curl …)"`,
        #       `sh -c "`wget …`"`.
        #   (3) download piped to `tee FILE` then chained with `&&`/`;`/`|`
        #       into a shell — the tee-to-disk variant of shape (1).
        #   (4) download redirected to a file that a shell then executes by name:
        #       `curl x.sh -o /tmp/x; sh /tmp/x`, `wget x.sh > x && bash x`.
        regex: %r{
          (?:\bcurl\b|\bwget\b)[^|\n]*\|(?:\s|\\\r?\n)*
            (?:(?:sudo|env|command|-\S+|\S+=\S+)(?:\s|\\\r?\n)+)*
            (?:[\w./-]*/)?(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\b
          |
          \b(?:sh|bash|zsh|fish|python\d?|ruby|node|perl|eval|source)\b[^\n]*(?:<\(|\$\(|`)\s*(?:sudo\s+)?(?:curl|wget)\b
          |
          (?:\bcurl\b|\bwget\b)[^|\n]*\|\s*(?:sudo\s+)?tee\b[^\n]*?(?:&&|\|\||;|\|)\s*(?:(?:sudo|env|command)\s+)*(?:[\w./-]*/)?(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\b
          |
          (?:\bcurl\b|\bwget\b)[^\n]*?(?:>|-o|--output)[\s=]+([^\s;&|]+)[^\n]*?(?:;|&&|&)[^\n]*?(?:(?:sudo|env|command)\s+)*(?:[\w./-]*/)?(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\s+\S*?\1
        }ix
      ),
      Rule.new(
        id: :credential_path_access,
        severity: "high",
        capability: "Bash",
        # Verbs cover both reads (cat/less/…) and copy/exfil (cp/scp/rsync) of a
        # credential store, so the description reflects access rather than reads.
        description: "Reads or copies a local credential store (SSH keys, cloud/registry credentials).",
        remediation: "Remove direct credential-file access and use the runtime's secret or authenticated tool integration.",
        # Home-relative (~, $HOME) and absolute (/home/<user>, /root, /Users/<user>)
        # prefixes both count; stores extend beyond .ssh/.aws to gnupg, docker,
        # kube, and the netrc/npmrc/pypirc credential files.
        regex: %r{
          \b(?:cat|less|more|head|tail|sed|awk|cp|scp|rsync|find|ls)\b[^\n]*
          (?:~|\$HOME|\$\{HOME\}|/home/[^/\s]+|/root|/Users/[^/\s]+)/
          (?:\.ssh|\.aws|\.gnupg|\.docker|\.kube|\.config/(?:gh|gcloud)|\.netrc|\.npmrc|\.pypirc)
          (?:/|\b)
        }ix
      ),
      Rule.new(
        id: :outbound_data_transfer,
        severity: "high",
        capability: "Bash",
        description: "Uploads a local file or standard input to a network endpoint.",
        remediation: "Remove the upload or use a declared, reviewable integration that constrains the destination and data.",
        # Space- and equals-form flags both count (`--upload-file f`,
        # `--upload-file=f`, `--data-binary=@f`), the `-d@f` attached short form
        # is caught via its unambiguous `@`, and wget's `--post-file`/`--body-file`
        # uploads are covered alongside curl.
        regex: %r{
          \bcurl\b[^\n]*
            (?:
              --data(?:-binary|-raw|-urlencode)?[\s=]+@(?:-|\S+)
              | -d[\s=]*@(?:-|\S+)
              | --upload-file[\s=]+\S+
              | -T[\s=]+\S+
            )
          |
          \bwget\b[^\n]*(?:--post-file|--body-file)[\s=]+\S+
        }ix
      )
    ].freeze

    module_function

    def rules
      RULES
    end

    def rule(id)
      RULES.find { |candidate| candidate.id == id.to_sym } ||
        raise(KeyError, "unknown deny rule: #{id}")
    end

    def scan(text, file:)
      normalized = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      return [] if normalized.empty?

      RULES.flat_map do |descriptor|
        normalized.to_enum(:scan, descriptor.regex).map do
          match = Regexp.last_match
          Finding.new(
            rule_id: descriptor.id.to_s,
            file: file.to_s,
            line: normalized[0...match.begin(0)].count("\n") + 1,
            severity: descriptor.severity,
            capability: descriptor.capability,
            remediation: descriptor.remediation
          )
        end
      end.sort_by { |finding| [ finding.file, finding.line, finding.rule_id ] }.freeze
    end
  end
end
