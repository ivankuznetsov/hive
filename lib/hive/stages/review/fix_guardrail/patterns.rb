require "hive/secret_patterns"

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
        #     dependency_lockfile_change: false   # disable
        #     custom_no_pdb:                      # add custom
        #       regex: '\bimport pdb\b'
        #       severity: high
        #       targets: code            # `code` (any added line) or `file_path` (any path match)
        module Patterns
          # Each pattern descriptor:
          #   :regex       — Regexp matched against either added lines (code) or file paths (file_path)
          #   :severity    — :high | :medium | :nit (used to group findings in fix-guardrail-NN.md)
          #   :targets     — :code | :file_path (which side of the diff to scan)
          #   :description — single-line explanation surfaced in the finding
          DEFAULTS = {
            shell_pipe_to_interpreter: {
              regex: /(?:\bcurl\b|\bwget\b)[^|\n]*\|\s*(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\b/,
              severity: :high,
              targets: :code,
              description: "shell-pipe-to-interpreter: a curl/wget pipe into sh/bash/python/ruby/node executes attacker-controlled code if the URL ever serves something else."
            },
            ci_workflow_edit: {
              regex: %r{\A(?:\.github/workflows/|\.gitlab-ci\.ya?ml\z|\.circleci/config\.ya?ml\z|Jenkinsfile\z|bitbucket-pipelines\.ya?ml\z|\.azure-pipelines\.ya?ml\z|\.travis\.ya?ml\z)},
              severity: :high,
              targets: :file_path,
              description: "CI workflow edit: changes to CI/CD config files affect every future deploy. Auto-fixing them is a privilege escalation in the deploy pipeline."
            },
            secrets_pattern_match: {
              # Special-cased: this dispatches to Hive::SecretPatterns.
              # FixGuardrail.scan handles it as a separate path.
              regex: nil,
              severity: :high,
              targets: :code,
              description: "secret material added in a fix commit (AWS/GitHub/PEM/OpenAI/etc.). Auto-fix should never write a credential."
            },
            dotenv_edit: {
              # `(?:\A|/)` so nested matches in monorepos / Rails apps
              # also trip — apps/web/.env, config/credentials.yml.enc,
              # packages/api/.npmrc — not just repo-root .env.
              regex: %r{(?:\A|/)(?:\.env(?:\..+)?\z|secrets\.ya?ml\z|credentials\.ya?ml(?:\.enc)?\z|\.npmrc\z|\.pypirc\z)},
              severity: :high,
              targets: :file_path,
              description: ".env / secrets file edit: env/secret files often contain credentials and per-environment overrides; auto-fix shouldn't touch them."
            },
            dependency_lockfile_change: {
              # `(?:\A|/)` so monorepo lockfiles match too —
              # packages/y/package-lock.json, services/api/Gemfile.lock,
              # apps/web/yarn.lock — not just repo-root.
              regex: %r{(?:\A|/)(?:Gemfile\.lock|package-lock\.json|pnpm-lock\.ya?ml|yarn\.lock|Cargo\.lock|go\.sum|poetry\.lock|Pipfile\.lock|composer\.lock|uv\.lock)\z},
              severity: :medium,
              targets: :file_path,
              description: "lockfile churn during a fix pass: verify the change is an intended bump, not an accidental downgrade or arbitrary version drift."
            },
            permission_change: {
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
