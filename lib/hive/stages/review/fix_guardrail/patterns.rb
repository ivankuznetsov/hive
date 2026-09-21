require "hive/secret_scanner"

module Hive
  module Stages
    module Review
      module FixGuardrail
        # Pattern set for the post-fix diff guardrail (ADR-020). Each
        # pattern names a high-risk class of change a fix agent should
        # not make autonomously. A match in the new commits' diff trips
        # the guardrail; the runner sets REVIEW_WAITING reason=fix_guardrail
        # and writes reviews/fix-guardrail-NN.md so the user inspects
        # before the loop continues.
        #
        # Override per-project via review.fix.guardrail.patterns_override:
        #   patterns_override:
        #     ci_workflow_edit: false   # disable
        #     custom_no_pdb:                      # add custom
        #       regex: '\bimport pdb\b'
        #       severity: high
        #       targets: code            # `code` (any added line) or `file_path` (any path match)
        module Patterns
          # Each pattern descriptor:
          #   :detector    — which scan engine owns this pattern:
          #                    :regex           — spec[:regex] matched against the target text
          #                    :secret_patterns — dispatched to Hive::SecretScanner.scan;
          #                                       no spec[:regex] participates in matching
          #   :regex       — Regexp matched against either added lines (code) or file paths (file_path)
          #   :severity    — :high | :medium | :nit (used to group findings in fix-guardrail-NN.md)
          #   :targets     — :code | :file_path (which side of the diff to scan)
          #   :description — single-line explanation surfaced in the finding
          DEFAULTS = {
            shell_pipe_to_interpreter: {
              detector: :regex,
              regex: /(?:\bcurl\b|\bwget\b)[^|\n]*\|\s*(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\b/,
              severity: :high,
              targets: :code,
              description: "shell-pipe-to-interpreter: a curl/wget pipe into sh/bash/python/ruby/node executes attacker-controlled code if the URL ever serves something else."
            },
            ci_workflow_edit: {
              detector: :regex,
              regex: %r{\A(?:\.github/workflows/|\.gitlab-ci\.ya?ml\z|\.circleci/config\.ya?ml\z|Jenkinsfile\z|bitbucket-pipelines\.ya?ml\z|\.azure-pipelines\.ya?ml\z|\.travis\.ya?ml\z)},
              severity: :high,
              targets: :file_path,
              description: "CI workflow edit: changes to CI/CD config files affect every future deploy. Auto-fixing them is a privilege escalation in the deploy pipeline."
            },
            secrets_pattern_match: {
              # Explicit non-regex strategy: scan dispatches on this
              # detector key and hands each added line to
              # Hive::SecretScanner.scan instead of spec[:regex].
              detector: :secret_patterns,
              regex: nil,
              severity: :high,
              targets: :code,
              description: "secret material added in a fix commit (AWS/GitHub/PEM/OpenAI/etc.). Auto-fix should never write a credential."
            },
            dotenv_edit: {
              # `(?:\A|/)` so nested matches in monorepos / Rails apps
              # also trip — apps/web/.env, config/credentials.yml.enc,
              # packages/api/.npmrc — not just repo-root .env.
              #
              # Template suffixes (.env.example / .env.sample /
              # .env.template / .env.dist / .env.tmpl /
              # .env.default[s]) are deliberately EXCLUDED from the
              # match: those files are by-design committed to the repo
              # as templates with no real credentials (12-factor, Rails,
              # Next.js, Laravel convention). Real per-env files
              # (.env, .env.local, .env.production, .env.test,
              # .env.staging, .env.development) still trip. Projects
              # that genuinely keep secrets in .env.example can re-add
              # strict matching via review.fix.guardrail.patterns_override.
              detector: :regex,
              regex: %r{
                (?:\A|/)(?:
                  \.env\z
                  | \.env\.(?!(?:example|sample|template|dist|tmpl|defaults?)\z).+\z
                  | secrets\.ya?ml\z
                  | credentials\.ya?ml(?:\.enc)?\z
                  | \.npmrc\z
                  | \.pypirc\z
                )
              }x,
              severity: :high,
              targets: :file_path,
              description: ".env / secrets file edit: env/secret files often contain credentials and per-environment overrides; auto-fix shouldn't touch them."
            },
            permission_change: {
              detector: :regex,
              # Catch any executable / setuid / setgid / world-writable bit
              # in the trailing octal triple (1, 3, 5, or 7 → exec bit set):
              # 100755, 100777, 104755 (setuid), 102755 (setgid), …
              regex: /\A(?:old mode|new mode|deleted file mode|new file mode) 10[0-9][0-9][0-9][1357]$/,
              severity: :medium,
              targets: :raw_diff_header,
              description: "executable / setuid / setgid bit added: a fix that flips file mode to an executable or privileged mode may be granting execution rights to a script the user didn't expect."
            }
          }.freeze
        end
      end
    end
  end
end
