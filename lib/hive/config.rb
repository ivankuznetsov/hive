require "yaml"
require "fileutils"
require "securerandom"
require "hive/agent_profiles"
require "hive/babysitter/interval"
require "hive/paths"

module Hive
  module Config
    DEFAULTS = {
      "hive_state_path" => ".hive-state",
      "worktree_root" => nil,
      "default_branch" => nil,
      "project_name" => nil,
      "claude" => {
        "mode" => "tmux",
        "permission_mode" => "bypassPermissions"
      },
      # Budget and timeout caps are GENEROUS sanity caps for runaway agents,
      # not cost targets. Most tasks finish well within them; a stuck loop
      # still gets cut off. Bumped ~5x from the original conservative values
      # in plan 2026-05-04-001 (per ADR-023). The deprecated `execute_review`
      # key was dropped here — 6-review owns reviewer budgets per ADR-014, so
      # nothing reads it. Existing project configs that still set it survive
      # via deep-merge but the key is no longer rendered for fresh projects.
      "budget_usd" => {
        "brainstorm" => 50,
        "plan" => 100,
        "execute_implementation" => 500,
        "open_pr" => 50,
        "artifacts" => 100,
        "finalize" => 50,
        "review_ci" => 100,
        "review_triage" => 75,
        "review_fix" => 500,
        "review_browser" => 100,
        "patrol" => 100
      },
      "timeout_sec" => {
        "brainstorm" => 1800,
        "plan" => 3600,
        "execute_implementation" => 14400,
        "open_pr" => 1800,
        "artifacts" => 3600,
        "finalize" => 1800,
        "review_ci" => 3600,
        "review_triage" => 1800,
        "review_fix" => 14400,
        "review_browser" => 3600,
        "patrol" => 3600
      },
      # Stage-level agent for single-agent stages. The review
      # stage has its own per-role agent fields under "review.{ci,triage,
      # fix,browser_test}.agent". Runtime fallback in stage code stays
      # `cfg.dig("<stage>", "agent") || "claude"` so legacy configs without
      # these keys keep behaving as today (ADR-023). The recommended-default
      # for execute is `codex` only at the rendered-template level, not in
      # DEFAULTS itself, to avoid silently flipping the implementer for old
      # projects on next load.
      # The `skill` field per stage names the slash-command the agent
      # is told to invoke inside its prompt. Per-project overrides via
      # `<stage>.skill` in config.yml pick a different skill without
      # touching templates/. When the field is absent, stage runners use
      # `stage_skill` below so agent-specific defaults can follow each
      # CLI's installed skill names.
      "brainstorm" => {
        "agent" => "claude",
        "skill" => "/compound-engineering:ce-brainstorm",
        "runtime" => "headless"
      },
      "plan" => {
        "agent" => "claude",
        "skill_by_agent" => {
          "claude" => "/plan",
          "codex" => "/llm-wiki:wiki-plan",
          "pi" => "/llm-wiki:wiki-plan",
          "default" => "/llm-wiki:wiki-plan"
        }
      },
      "execute" => { "agent" => "claude" },
      "open_pr" => { "agent" => "claude" },
      "artifacts" => { "agent" => "claude" },
      "finalize" => { "agent" => "claude" },
      # Per-CLI agent profiles. Each project may override `bin`,
      # `env_override`, or `min_version` to pin to a different binary or
      # version. Adding a new top-level profile is not yet supported here
      # — register custom profiles in Ruby via Hive::AgentProfiles.register.
      "agents" => {
        "claude" => {
          "bin" => "claude",
          "env_override" => "HIVE_CLAUDE_BIN",
          "min_version" => "2.1.118"
        },
        "codex" => {
          "bin" => "codex",
          "env_override" => "HIVE_CODEX_BIN",
          "min_version" => "0.125.0"
        },
        "pi" => {
          "bin" => "pi",
          "env_override" => "HIVE_PI_BIN",
          "min_version" => "0.70.2"
        }
      },
      # Configuration for the 6-review stage's autonomous loop. Each role
      # (ci, reviewers, triage, fix, browser_test) takes an `agent` profile
      # name (must resolve via Hive::AgentProfiles.lookup) and an optional
      # `prompt_template` path under templates/.
      #
      # `reviewers` is an Array; the deep-merge rule REPLACES it wholesale
      # when a project sets it (the alternative — per-element merge — has
      # ambiguous semantics for ordered lists). Hive's recommended set ships
      # in templates/project_config.yml.erb (live, not commented), so a
      # fresh `hive init` produces a populated config.
      "review" => {
        "ci" => {
          "command" => nil,
          "max_attempts" => 3,
          "agent" => "claude",
          "prompt_template" => "ci_fix_prompt.md.erb"
        },
        "reviewers" => [],
        "triage" => {
          "enabled" => true,
          "agent" => "claude",
          "bias" => "courageous",
          "prompt_template" => nil,
          "custom_prompt" => nil
        },
        "fix" => {
          "agent" => "claude",
          "prompt_template" => "fix_prompt.md.erb",
          "auto_commit" => {
            "sign_policy" => "inherit",
            "scope_check" => {
              "enabled" => true,
              "allowed_paths" => [
                "app/**",
                "app/**/*",
                "lib/**",
                "lib/**/*",
                "src/**",
                "src/**/*",
                "test/**",
                "test/**/*",
                "tests/**",
                "tests/**/*",
                "spec/**",
                "spec/**/*",
                "docs/**",
                "docs/**/*",
                "wiki/**",
                "wiki/**/*",
                "README",
                "README.*",
                "CHANGELOG",
                "CHANGELOG.*",
                "LICENSE",
                "LICENSE.*",
                "Gemfile",
                "*.gemspec",
                "Rakefile",
                "Makefile",
                "package.json",
                "pyproject.toml",
                "requirements.txt",
                "requirements-*.txt",
                "go.mod",
                "Cargo.toml",
                "composer.json",
                "mix.exs"
              ],
              "denied_paths" => [
                ".git/**",
                ".git/**/*",
                "bin/**",
                "bin/**/*",
                "config/**",
                "config/**/*",
                ".github/**",
                ".github/**/*",
                ".gitlab-ci.yml",
                ".gitlab-ci.yaml",
                ".circleci/**",
                ".circleci/**/*",
                "Jenkinsfile",
                "bitbucket-pipelines.yml",
                "bitbucket-pipelines.yaml",
                ".azure-pipelines.yml",
                ".azure-pipelines.yaml",
                ".travis.yml",
                ".env",
                ".env.*",
                "**/.env",
                "**/.env.*",
                "**/secrets.yml",
                "**/secrets.yaml",
                "**/credentials.yml",
                "**/credentials.yaml",
                "**/credentials.yml.enc",
                "**/credentials.yaml.enc",
                "**/.npmrc",
                "**/.pypirc",
                "Gemfile.lock",
                "package-lock.json",
                "pnpm-lock.yaml",
                "pnpm-lock.yml",
                "yarn.lock",
                "Cargo.lock",
                "go.sum",
                "poetry.lock",
                "Pipfile.lock",
                "composer.lock",
                "uv.lock",
                "**/Gemfile.lock",
                "**/package-lock.json",
                "**/pnpm-lock.yaml",
                "**/pnpm-lock.yml",
                "**/yarn.lock",
                "**/Cargo.lock",
                "**/go.sum",
                "**/poetry.lock",
                "**/Pipfile.lock",
                "**/composer.lock",
                "**/uv.lock"
              ]
            }
          }
        },
        "browser_test" => {
          "enabled" => false,
          "agent" => "claude",
          "prompt_template" => "browser_test_prompt.md.erb",
          "max_attempts" => 2
        },
        "github_publish" => {
          "enabled" => true,
          "max_attempts" => 2
        },
        "max_passes" => 2,
        # Outer wall-clock budget for the whole reviewers phase. Sized to
        # fit a couple of claude-tmux reviewers each running up to their
        # per-reviewer `timeout_sec` (default 7200s / 2h) — a deep code
        # review legitimately takes 1-2h. Each reviewer is bounded by its
        # own timeout, NOT by an even split of this budget, so this only
        # needs to cover the sum (raise it if you run more reviewers).
        "max_wall_clock_sec" => 14_400
      },
      # Hive daemon settings (ADR-024). The daemon polls
      # `hive status --json`, dispatches workflow verbs on tasks the
      # classifier marks safe, and stops only at human-input gates.
      #
      # Per-project `daemon.enabled` is rendered into a project's
      # `.hive-state/config.yml` by `hive init` (TTY prompt, default Y).
      # The `Config::DEFAULTS["daemon"]["enabled"]` value is the LEGACY
      # FALLBACK for projects whose YAML doesn't carry the `daemon:`
      # key at all — same "do not silently flip legacy projects"
      # pattern ADR-023 used for stage agents. Default `false` here
      # means existing projects need an explicit one-line config edit
      # before the daemon will touch them.
      "daemon" => {
        "enabled" => false,
        "autostart" => false,
        "poll_interval_sec" => 30,
        "fast_poll_sec" => 1,
        "edit_debounce_sec" => 30,
        "pr_merge_poll_interval_sec" => 300,
        "max_concurrent_runs" => 3,
        "max_concurrent_per_project" => 3,
        "max_runs_per_day_per_project" => 50,
        "transient_retry_backoff_sec" => 60,
        "shutdown_grace_sec" => 600,
        # R-02: per-child wall-clock timeout for daemon-spawned `hive`
        # children. `child_timeout_sec` is the default cap (0 disables —
        # children run unbounded, the historical behaviour). Operators can
        # set a project/global cap when they want the daemon to reap genuinely
        # wedged children. `child_verb_timeouts` overrides the default per hive verb
        # (e.g. {"review" => 10800}). `child_kill_grace_sec` is the
        # SIGTERM→SIGKILL escalation window — a MINIMUM, not a precise
        # timer: timeouts are enforced once per `poll_interval_sec` tick, so
        # the actual SIGKILL can land up to one poll interval late, and
        # `child_kill_grace_sec: 0` does NOT mean immediate KILL (it means
        # "KILL on the next tick after TERM"). (#266)
        "child_timeout_sec" => 0,
        "child_kill_grace_sec" => 30,
        "child_verb_timeouts" => {},
        "log_max_bytes" => 10_485_760,
        "log_max_files" => 5
      },
      # Update flow (plan 2026-05-27-002). The daemon checks the latest
      # release on a throttled cadence and, on the install.sh channel,
      # auto-updates when idle; brew/AUR get a nudge. Both knobs default
      # ON during the dev period — `check: false` disables the probe
      # entirely; `auto: false` keeps checks/nudges but never self-updates.
      "update" => {
        "check" => true,
        "auto" => true
      },
      # Experimental PR babysitter. This is intentionally separate
      # from the pipeline daemon: it polls open GitHub PRs and asks a
      # development agent to keep them mergeable.
      "babysitter" => {
        "enabled" => false,
        "interval" => "10m",
        "max_concurrent_prs" => 2,
        "labels_ignore" => %w[wip do-not-merge draft],
        "dry_run" => false,
        "budget_minutes" => 30,
        "budget_usd" => 50
      },
      # Repository patrol is opt-in per managed project. When enabled,
      # the daemon schedules `hive patrol PROJECT` scans that map
      # semantic code slices, review them with an agent, attempt fixes
      # in isolated worktrees, validate configured commands, and surface
      # successful fixes only as GitHub PRs.
      "patrol" => {
        "enabled" => false,
        "trigger" => "continuous",
        "poll_interval_sec" => 600,
        "agent" => "claude",
        "min_confidence_to_fix" => "medium",
        "max_findings_per_feature" => 10,
        "max_prs_per_cycle" => 3,
        # Open ready (non-draft) PRs by default so the babysitter — which
        # skips draft PRs — picks them up. Set `draft_prs: true` per project
        # to revert to draft PRs that need a manual "ready" toggle first.
        "draft_prs" => false,
        "include" => [],
        "exclude" => [ "node_modules", "dist", "build", "vendor", ".git" ],
        "commands" => {
          "format" => nil,
          "lint" => nil,
          "typecheck" => nil,
          "test" => nil
        },
        "review" => {
          "max_context_files" => 24,
          "max_owned_files" => 12
        }
      },
      # Global Telegram bot settings. The bot is an operator surface
      # across every registered project, so runtime code loads these
      # from the global config via load_global_bot. The token lives
      # only in HIVE_TELEGRAM_BOT_TOKEN and is never persisted.
      "bot" => {
        "enabled" => false,
        "chat_id_allowlist" => [],
        "poll_interval_sec" => 30,
        "long_poll_timeout_sec" => 25,
        # alert_state_file is intentionally omitted from DEFAULTS — the
        # path is state_home-derived and resolved at runtime by
        # `global_bot_defaults` / `Config.load` so a HIVE_HOME / XDG
        # override propagates correctly. A hardcoded developer-specific
        # path here would be misleading for direct DEFAULTS readers.
        "recovery_reminder_window_sec" => 28_800,
        "recovery_grace_sec" => 60,
        "conversation_ttl_sec" => 3600,
        "idea_attachment_max_bytes" => 20 * 1024 * 1024,
        "idea_attachment_max_count" => 10,
        "idea_draft_ttl_sec" => 900,
        "codex_budget_usd" => 1,
        "codex_timeout_sec" => 120,
        "shutdown_grace_sec" => 60,
        "pid_file" => "~/Dev/hive/.bot.pid",
        "log_file" => "~/Dev/hive/logs/bot.log",
        "log_max_bytes" => 10_485_760,
        "log_max_files" => 5,
        "last_seen_state_file" => "~/Dev/hive/.bot.last_seen_update_id"
      },
      # Stage-level invariants enforced by `Hive::Stages::Base.with_stage_events`.
      # `ensure_clean_on_exit` (default true) makes worktree-owning stages
      # — `4-execute`, `6-review`, `8-finalize` — fail loudly when they
      # leave residue at stage exit. Residue that passes
      # `review.fix.auto_commit.scope_check` is auto-committed as
      # `chore(<stage>): commit residual worktree changes`; out-of-scope
      # residue surfaces as `:error reason=ensure_clean_on_exit_failed`.
      # Set to `false` to opt the entire invariant out (not recommended
      # outside legacy projects).
      "stages" => {
        "ensure_clean_on_exit" => true
      },
      # Auto-rebase pre-step for `hive run` (plan
      # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md).
      # Detects drift behind origin/<default_branch>, fetches, attempts
      # rebase, dispatches the project's execute-stage agent to resolve
      # conflicts. Fail-soft: any failure aborts the rebase and the
      # stage runner proceeds against the (stale) base. The hardcoded
      # max-conflict-resolutions cap (5) lives on
      # `Hive::Rebase::MAX_CONFLICT_RESOLUTIONS`, not config — projects
      # with persistently high-conflict branches should investigate the
      # underlying drift, not raise the cap.
      "rebase" => {
        "enabled" => true,
        "conflict_resolution_timeout_sec" => 2700
      }
    }.freeze

    # Roles that take an `agent` profile-name field. Used by validation to
    # check each role's value resolves to a registered AgentProfile.
    ROLE_AGENT_PATHS = [
      %w[brainstorm agent],
      %w[plan agent],
      %w[execute agent],
      %w[open_pr agent],
      %w[artifacts agent],
      %w[finalize agent],
      %w[review ci agent],
      %w[review triage agent],
      %w[review fix agent],
      %w[review browser_test agent]
    ].freeze

    # `/plan` was Hive's original wiki-first planning alias. It remains the
    # Claude default because Claude supports user-level slash commands. Codex
    # and Pi receive llm-wiki's canonical skill name unless a project chooses
    # a non-legacy override.
    LEGACY_WIKI_PLAN_ALIAS = "/plan"
    CLAUDE_MODES = %w[headless tmux].freeze
    CLAUDE_PERMISSION_MODES = %w[acceptEdits auto bypassPermissions default dontAsk plan].freeze
    AUTO_COMMIT_SIGN_POLICIES = %w[inherit bypass fail].freeze
    EXPLICIT_CLAUDE_MODE_KEY = :__hive_explicit_claude_mode
    EXPLICIT_BRAINSTORM_RUNTIME_KEY = :__hive_explicit_brainstorm_runtime

    module_function

    def hive_home
      Hive::Paths.config_home
    end

    def global_config_path
      File.join(hive_home, "config.yml")
    end

    def hive_state_dir(project_root, hive_state_name = ".hive-state")
      File.join(project_root, hive_state_name)
    end

    def load(project_root)
      project_root = File.expand_path(project_root)
      candidate = File.join(project_root, ".hive-state", "config.yml")
      data = if File.exist?(candidate)
               parsed = YAML.safe_load(File.read(candidate)) || {}
               raise ConfigError, "config.yml at #{candidate} must be a hash" unless parsed.is_a?(Hash)

               parsed
      else
               {}
      end
      merged = merge_defaults(data).merge("project_root" => project_root)
      merged[EXPLICIT_CLAUDE_MODE_KEY] = nested_key?(data, "claude", "mode")
      merged[EXPLICIT_BRAINSTORM_RUNTIME_KEY] = nested_key?(data, "brainstorm", "runtime")
      inject_bot_runtime_path_defaults!(merged)
      validate!(merged, candidate)
      merged
    end

    # DEFAULTS["bot"] intentionally omits state_home-derived path keys
    # so direct readers cannot get a stale developer-specific path. We
    # fill those in here after merge so the consumer-facing cfg always
    # carries the same path that `global_bot_defaults` would resolve.
    def inject_bot_runtime_path_defaults!(cfg)
      # Skip when "bot" is not a Hash — `validate!` runs next and turns
      # the malformed scalar into a proper ConfigError. Injecting first
      # would crash with IndexError on String#[]= and lose that signal.
      bot = cfg["bot"]
      return unless bot.is_a?(Hash)

      bot["alert_state_file"] ||= File.join(Hive::Paths.state_home, ".bot.alert_state.json")
    end

    def claude_mode(cfg)
      raw = cfg.dig("claude", "mode")
      raw = DEFAULTS.dig("claude", "mode") if raw.nil?
      case raw
      when "tmux" then :tmux
      when "headless" then :headless
      else
        raise ConfigError, "claude.mode must be one of #{CLAUDE_MODES.inspect}; got #{raw.inspect}"
      end
    end

    def claude_permission_mode(cfg)
      raw = cfg.dig("claude", "permission_mode")
      raw = DEFAULTS.dig("claude", "permission_mode") if raw.nil?
      return raw if CLAUDE_PERMISSION_MODES.include?(raw)

      raise ConfigError,
            "claude.permission_mode must be one of #{CLAUDE_PERMISSION_MODES.inspect}; got #{raw.inspect}"
    end

    def nested_key?(hash, *path)
      cursor = hash
      path.each do |key|
        return false unless cursor.is_a?(Hash)
        return false unless cursor.key?(key)

        cursor = cursor[key]
      end
      true
    end

    # Only `Config.load` knows whether the user actually wrote
    # `claude.mode` in config.yml; merge_defaults inserts the
    # DEFAULTS value so the merged cfg always carries a non-nil
    # `claude.mode`. After load, the EXPLICIT_CLAUDE_MODE_KEY flag is
    # the single source of truth. Callers that synthesise a cfg
    # in-process (tests, daemon helpers) must set the flag themselves;
    # the default below is `false` so an unset flag is treated as
    # "default kicked in", not "user wrote it".
    def explicit_claude_mode?(cfg)
      cfg[EXPLICIT_CLAUDE_MODE_KEY] == true
    end

    # Pairs with `explicit_claude_mode?` but kept on the legacy
    # explicit-via-cfg.dig fallback intentionally: synthesised cfgs
    # under tests / daemon helpers that carry `brainstorm.runtime`
    # without going through `Config.load` still need to opt into the
    # one-release legacy 2-brainstorm branch. The DEFAULTS path does
    # NOT seed `brainstorm.runtime`, so the dig-based fallback is
    # unambiguous here — distinct from claude.mode, which IS seeded
    # by DEFAULTS and needs the strict flag.
    def explicit_brainstorm_runtime?(cfg)
      return cfg[EXPLICIT_BRAINSTORM_RUNTIME_KEY] unless cfg[EXPLICIT_BRAINSTORM_RUNTIME_KEY].nil?

      cfg.dig("brainstorm", "runtime") != nil
    end

    def stage_skill(cfg, stage)
      stage_cfg = cfg.fetch(stage, {})
      agent_name = (stage_cfg["agent"] || DEFAULTS.dig(stage, "agent") || "claude").to_s
      configured_skill = stage_cfg["skill"]

      return configured_skill if configured_skill && !legacy_wiki_plan_alias_for_non_claude?(stage, agent_name, configured_skill)

      skills_by_agent = {}
      default_skills_by_agent = DEFAULTS.dig(stage, "skill_by_agent")
      skills_by_agent.merge!(default_skills_by_agent) if default_skills_by_agent.is_a?(Hash)
      configured_skills_by_agent = stage_cfg["skill_by_agent"]
      skills_by_agent.merge!(configured_skills_by_agent) if configured_skills_by_agent.is_a?(Hash)

      if !skills_by_agent.empty?
        skills_by_agent[agent_name] || skills_by_agent["default"] || configured_skill
      else
        configured_skill || DEFAULTS.dig(stage, "skill")
      end
    end

    def legacy_wiki_plan_alias_for_non_claude?(stage, agent_name, skill)
      stage == "plan" &&
        agent_name != "claude" &&
        skill.to_s == LEGACY_WIKI_PLAN_ALIAS
    end

    # Surface a misconfigured HIVE_HOME loudly on READ paths only.
    # When ENV["HIVE_HOME"] is explicitly set to a path that doesn't exist
    # (e.g., a user typo), `registered_projects` returning [] silently hid
    # the typo and made `hive status --json | jq .ok` falsely report `true`
    # under nonexistent-HIVE_HOME smoke runs. Fire only when explicitly set
    # AND missing — leave the default unset path lazy-creatable by
    # `register_project` (which does its own mkdir_p), and accept the
    # legitimate "directory exists but config.yml not yet written" first-run
    # state.
    def validate_hive_home!
      env = ENV["HIVE_HOME"]
      return if env.nil? || env.empty?
      return if File.directory?(env)

      raise ConfigError, "HIVE_HOME is set to a path that does not exist: #{env}"
    end

    def registered_projects
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      return [] unless File.exist?(path)

      data = load_global_config(path)
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      # Tolerate hand-edit accidents: a non-Hash row, a row missing
      # `name`, or a row whose `path` isn't a String would previously
      # raise here and brick every command (status / forget / prune /
      # the TUI) until the operator hand-fixed config.yml. Treat such
      # rows as invisible at the loader level so the rest of the
      # surface stays usable; `hive prune` operates on the raw entries
      # below the loader and is the cleanup verb for this case.
      Array(data["registered_projects"]).each_with_object([]) do |entry, out|
        next unless valid_registry_entry?(entry)

        abs_path = File.expand_path(entry["path"])
        out << {
          "name" => entry["name"],
          "path" => abs_path,
          "hive_state_path" => entry["hive_state_path"] || File.join(abs_path, ".hive-state")
        }
      end
    end

    # Shape gate shared by the loader and `prune`'s predicate so the
    # two surfaces agree on what counts as a valid registry row.
    # Without this, the loader would silently skip a corrupted entry
    # while prune would also fail to drop it (its old predicate only
    # matched `!File.directory?` on rows that already had a String
    # path), and the entry would persist forever.
    def valid_registry_entry?(entry)
      entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["path"].is_a?(String)
    end

    # YAML.safe_load can raise more than `Psych::SyntaxError`:
    # `Psych::DisallowedClass` (e.g. `!ruby/object:Object` in a hand-edited
    # config) and `Psych::AliasesNotEnabled` (anchor + alias) are also
    # "operator wrote bad YAML" cases that used to leak as InternalError
    # (exit 70) despite the documented exit 78 contract. Rescue
    # `Psych::Exception` so every malformed-YAML shape funnels through the
    # same `error_kind: "config"` envelope the TUI's narrow rescue catches.
    #
    # EACCES specifically is the most user-facing of the IO group:
    # `chmod 000` on the global config file (or running as a different
    # user) used to surface as `internal error: Errno::EACCES: ...`
    # at exit 70. The root cause is configuration access, not a Hive
    # bug — exit 78 is the right shape.
    def load_global_config(path)
      YAML.safe_load(File.read(path)) || {}
    rescue Psych::Exception => e
      raise ConfigError, "global config at #{path} is not valid YAML: #{e.message}"
    rescue Errno::EACCES, Errno::EISDIR => e
      raise ConfigError, "global config at #{path} is not readable: #{e.message}"
    end

    GLOBAL_CONFIG_WRITE_ERRORS = [
      Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::ENOSPC, Errno::EXDEV,
      Errno::EDQUOT, Errno::ENOMEM, Errno::EIO, Errno::ENOENT, Errno::EISDIR,
      Errno::ENOTDIR, Errno::EEXIST, Errno::ELOOP, Errno::ENAMETOOLONG
    ].freeze

    # Locked read-modify-write helper for the XDG global config.yml. The
    # sibling lock file serializes writers across File.rename, unlike
    # locking config.yml itself whose inode changes on every atomic
    # replace.
    def update_global_config!
      Hive::Paths.ensure_migrated!
      FileUtils.mkdir_p(hive_home)
      with_global_config_lock do
        path = global_config_path
        data = File.exist?(path) ? load_global_config(path) : {}
        raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

        result = yield data
        write_global_config_atomic!(data)
        result
      end
    end

    # Atomic + filesystem-error-aware writer for the XDG global config.yml.
    # Direct callers get the same lock discipline as read-modify-write helpers;
    # methods that already hold the lock call write_global_config_atomic!
    # directly to keep the whole mutation in one critical section.
    def write_global_config!(data)
      Hive::Paths.ensure_migrated!
      FileUtils.mkdir_p(hive_home)
      with_global_config_lock { write_global_config_atomic!(data) }
    end

    def with_global_config_lock
      lock_path = "#{global_config_path}.lock"
      lock = begin
        File.open(lock_path, File::RDWR | File::CREAT, 0o600)
      rescue *GLOBAL_CONFIG_WRITE_ERRORS => e
        raise ConfigError, "global config at #{global_config_path} could not be locked: #{e.message}"
      end

      begin
        lock.flock(File::LOCK_EX)
      rescue *GLOBAL_CONFIG_WRITE_ERRORS => e
        lock.close
        raise ConfigError, "global config at #{global_config_path} could not be locked: #{e.message}"
      end

      begin
        yield
      ensure
        lock.close
      end
    end

    def write_global_config_atomic!(data)
      path = global_config_path
      dir = File.dirname(path)
      mode = File.exist?(path) ? File.stat(path).mode & 0o7777 : 0o644
      tmp = File.join(dir, ".#{File.basename(path)}.tmp.#{Process.pid}.#{::SecureRandom.hex(4)}")
      renamed = false

      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, mode, encoding: "UTF-8") do |f|
        f.chmod(mode)
        f.write(data.to_yaml)
        f.flush
        f.fsync
      end
      File.rename(tmp, path)
      renamed = true
      fsync_parent_dir(dir)
      data
    rescue *GLOBAL_CONFIG_WRITE_ERRORS => e
      raise ConfigError, "global config at #{path} could not be written: #{e.message}"
    ensure
      if !renamed && tmp && File.exist?(tmp)
        begin
          File.delete(tmp)
        rescue StandardError
          # Best-effort cleanup must not mask the original write error.
        end
      end
    end

    def fsync_parent_dir(dir)
      File.open(dir, File::RDONLY) { |f| f.fsync }
    rescue Errno::EINVAL, NotImplementedError
      # Filesystem does not support fsync on directories.
    end

    def find_project(name)
      registered_projects.find { |p| p["name"] == name }
    end

    # Load and validate the global `daemon` block from
    # the global config.yml under `Hive::Paths.config_home`. Returns the merged Hash (operator
    # overrides on top of `Config::DEFAULTS["daemon"]`). Used by
    # `hive daemon start` / `reload` so operator knobs in the global
    # config (max_concurrent_runs, poll_interval_sec, log_*, etc.)
    # actually take effect at runtime.
    #
    # Returns the bare DEFAULTS["daemon"] when no global config is
    # present (first-run scenario, no projects registered yet).
    def load_global_daemon
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      data = File.exist?(path) ? load_global_config(path) : {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      override = data["daemon"] || {}
      unless override.is_a?(Hash)
        raise ConfigError,
              "daemon in #{describe_source(path)} must be a Hash; got #{override.class}"
      end

      merged = deep_merge(deep_dup(DEFAULTS["daemon"]), override)
      # Re-use the existing validator by wrapping the daemon block in a
      # cfg-shaped hash. validate_daemon! is idempotent and operates on
      # cfg["daemon"].
      validate_daemon!({ "daemon" => merged }, path)
      merged
    end

    # Load the global `update` block (auto/check) from the XDG config
    # path, merged over DEFAULTS["update"]. Used by `hive daemon start`
    # so an operator's opt-out actually takes effect at runtime. Returns
    # the bare defaults when no global config exists.
    def load_global_update
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      data = File.exist?(path) ? load_global_config(path) : {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      override = data["update"] || {}
      unless override.is_a?(Hash)
        raise ConfigError,
              "update in #{describe_source(path)} must be a Hash; got #{override.class}"
      end

      merged = deep_merge(deep_dup(DEFAULTS["update"]), override)
      validate_update!(merged, path)
      merged
    end

    def validate_update!(merged, path)
      %w[check auto].each do |key|
        value = merged[key]
        next if [ true, false ].include?(value)

        raise ConfigError,
              "update.#{key} in #{describe_source(path)} must be true or false; got #{value.inspect}"
      end
    end

    # Load and validate the global `bot` block from the XDG config path.
    # `require_runtime: true` is used by `hive bot start` so the opt-in
    # credentials fail loudly there without making read-only commands like
    # `hive status` require a Telegram token.
    def load_global_bot(require_runtime: false)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      data = File.exist?(path) ? load_global_config(path) : {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      override = data["bot"] || {}
      unless override.is_a?(Hash)
        raise ConfigError,
              "bot in #{describe_source(path)} must be a Hash; got #{override.class}"
      end

      merged = deep_merge(global_bot_defaults, override)
      validate_bot_config!({ "bot" => merged }, path)
      validate_bot_runtime!(merged, path) if require_runtime
      merged
    end

    def telegram_bot_token!
      token = ENV["HIVE_TELEGRAM_BOT_TOKEN"].to_s
      return token unless token.strip.empty?

      raise ConfigError, "HIVE_TELEGRAM_BOT_TOKEN must be set to start hive bot"
    end

    def global_bot_defaults
      defaults = deep_dup(DEFAULTS["bot"])
      defaults["pid_file"] = File.join(Hive::Paths.state_home, ".bot.pid")
      defaults["log_file"] = File.join(Hive::Paths.state_home, "logs", "bot.log")
      defaults["alert_state_file"] = File.join(Hive::Paths.state_home, ".bot.alert_state.json")
      defaults["last_seen_state_file"] = File.join(Hive::Paths.state_home, ".bot.last_seen_update_id")
      defaults
    end

    def register_project(name:, path:)
      entry = nil
      update_global_config! do |data|
        data["registered_projects"] = Array(data["registered_projects"])
        abs_path = File.expand_path(path)
        hive_state_path = File.join(abs_path, ".hive-state")
        entry = { "name" => name, "path" => abs_path, "hive_state_path" => hive_state_path }
        real_path = realpath_or_nil(abs_path)
        entry["real_path"] = real_path if real_path
        existing = data["registered_projects"].find { |p| p.is_a?(Hash) && p["name"] == name }
        if existing
          existing.replace(entry)
        else
          data["registered_projects"] << entry
        end
      end
      entry
    end

    # Inverse of register_project: remove the entry whose name matches.
    # Returns the removed Hash entry, or nil if no entry matched. Does
    # not touch the project's `.hive-state` directory on disk — the
    # registry and the on-disk state are independent, and a deregister
    # may target a project whose path is gone (the common case) or one
    # the user simply no longer wants tracked.
    #
    # Validates $HIVE_HOME first so a typoed env var surfaces as
    # ConfigError (exit 78) rather than masquerading as `unknown_project`
    # / exit 64 — without this, an operator with a bad HIVE_HOME saw
    # "no entry named foo" and would chase a non-existent registry typo
    # instead of fixing the env var.
    #
    # Index-based delete (not Array#- subtraction): two registry rows
    # with the same name and content are equal under `Hash#==`, so
    # `entries - [removed]` would clear BOTH. delete_at on the matched
    # index removes exactly the row the operator named.
    def unregister_project(name:)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      return nil unless File.exist?(global_config_path)

      removed = nil
      with_global_config_lock do
        if File.exist?(global_config_path)
          data = load_global_config(global_config_path)
          raise ConfigError, "global config at #{global_config_path} must be a hash" unless data.is_a?(Hash)

          # Stringify both sides of the name match. CLI passes argv as a
          # String; hand-edited registry entries can carry an Integer
          # "name" (e.g. `name: 42` in YAML), which would never match
          # `Integer == "42"` and silently exit `unknown_project`.
          key = name.to_s
          entries = Array(data["registered_projects"])
          idx = entries.index { |p| p.is_a?(Hash) && p["name"].to_s == key }
          if idx
            removed = entries[idx]
            remaining = entries.dup
            remaining.delete_at(idx)
            data["registered_projects"] = remaining
            write_global_config_atomic!(data)
          end
        end
      end
      removed
    end

    # Drop every registry entry whose `path` no longer points at a
    # directory on disk, whose stored realpath no longer matches the
    # current target, OR whose row shape is invalid (non-Hash / missing
    # / non-String name or path). Used by `hive prune` and the TUI stale-
    # project drop key. The filesystem check is `File.directory?` (not
    # `exist?`) so a stray leftover file at the registered path does not
    # masquerade as live. Pass `dry_run: true` to compute the would-be-
    # removed list without rewriting global_config_path.
    #
    # Returns a Hash:
    #   {
    #     removed: Array<Hash>,    # entries dropped (or that would be)
    #     kept_count: Integer      # entries remaining after the drop
    #   }
    #
    # Computing kept_count from the in-memory `entries` array (rather
    # than re-reading via `registered_projects.size`) closes the
    # consistency window where a concurrent register/forget between the
    # two reads produced inconsistent counts.
    def prune_missing_projects!(dry_run: false)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      return { removed: [], kept_count: 0 } unless File.exist?(global_config_path)

      result = { removed: [], kept_count: 0 }
      with_global_config_lock do
        if File.exist?(global_config_path)
          data = load_global_config(global_config_path)
          raise ConfigError, "global config at #{global_config_path} must be a hash" unless data.is_a?(Hash)

          entries = Array(data["registered_projects"])
          removed, kept = entries.partition { |entry| droppable_registry_entry?(entry) }
          result = { removed: removed, kept_count: kept.size }
          if removed.any? && !dry_run
            data["registered_projects"] = kept
            write_global_config_atomic!(data)
          end
        end
      end
      result
    end

    # Predicate for prune: drops invalid rows, rows whose path is
    # gone, AND rows whose stored realpath no longer matches the current
    # path target. The shape branch and the filesystem branches are all
    # true for "this row should not be in the registry", so corrupted
    # rows surface in the prune output and removed_count exactly like
    # missing-path rows.
    #
    # `File.expand_path` mirrors `registered_projects` (which expands
    # before exposing the row to the rest of the surface). Without it,
    # a hand-edited row like `path: ~/project` would be dropped as stale
    # because `File.directory?` does not expand `~`.
    def droppable_registry_entry?(entry)
      return true unless valid_registry_entry?(entry)

      path = File.expand_path(entry["path"])
      return true unless File.directory?(path)

      registered_real_path = registry_real_path(entry)
      return false unless registered_real_path

      current_real_path = realpath_or_nil(path)
      current_real_path.nil? || current_real_path != registered_real_path
    end

    def registry_real_path(entry)
      value = entry["real_path"]
      return nil unless value.is_a?(String) && !value.empty?

      expanded = File.expand_path(value)
      expanded == value ? expanded : nil
    rescue ArgumentError
      nil
    end

    def realpath_or_nil(path)
      File.realpath(path)
    rescue SystemCallError, ArgumentError
      nil
    end

    # Recursive deep-merge: descends into nested Hashes so a partial
    # override like `review: { ci: { command: "bin/ci" } }` keeps every
    # other default at `review.ci.*` and at every other `review.*` key
    # intact. Arrays replace wholesale (no per-element merge) — this is
    # the explicit semantic for ordered lists like `review.reviewers`,
    # where per-element merge would have ambiguous semantics, and it
    # generalises to any Array-typed setting. Scalars override directly.
    #
    # Closes doc-review F3 (P0): the previous implementation was a
    # single-level Hash#merge that would wipe sibling keys whenever a
    # user override touched a 3+-deep nested path.
    def merge_defaults(data)
      deep_merge(deep_dup(DEFAULTS), data)
    end

    def deep_merge(base, override)
      return override unless base.is_a?(Hash) && override.is_a?(Hash)

      out = {}
      base.each { |k, v| out[k] = v }
      override.each do |k, v|
        out[k] = base.key?(k) ? deep_merge(base[k], v) : v
      end
      out
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end

    # Validate the merged config. Raises Hive::ConfigError on any issue
    # so callers see a single error class for "config is bad" regardless
    # of which field is at fault. Validation runs after merge so a
    # default value cannot be the cause of a failure — only user input
    # ever fails validation.
    def validate!(cfg, source_path)
      validate_hash_shaped_keys!(cfg, source_path)
      validate_stage_skill_by_agent!(cfg, source_path)
      validate_reviewers!(cfg, source_path)
      validate_review_fix_auto_commit!(cfg, source_path)
      validate_role_agent_names!(cfg, source_path)
      validate_claude_mode!(cfg, source_path)
      validate_claude_permission_mode!(cfg, source_path)
      validate_brainstorm_runtime!(cfg, source_path)
      validate_review_attempts!(cfg, source_path)
      validate_daemon!(cfg, source_path)
      validate_babysitter!(cfg, source_path)
      validate_patrol!(cfg, source_path)
      validate_bot_config!(cfg, source_path)
      validate_rebase!(cfg, source_path)
    end

    # Top-level keys that MUST be Hashes when present. A scalar override
    # (e.g. YAML `brainstorm: claude` instead of `brainstorm: { agent: claude }`)
    # would otherwise survive deep_merge — `deep_merge(default_hash, "claude")`
    # returns the override unchanged, since override is not a Hash — and
    # crash later as TypeError/NoMethodError when stage code calls
    # `cfg.dig("brainstorm", "agent")`. Surface the shape mismatch loudly at
    # load time with a typed ConfigError instead.
    HASH_SHAPED_KEYS = %w[
      brainstorm
      claude
      plan
      execute
      open_pr
      artifacts
      finalize
      budget_usd
      timeout_sec
      review
      agents
      daemon
      babysitter
      patrol
      bot
      rebase
    ].freeze

    def validate_hash_shaped_keys!(cfg, source_path)
      HASH_SHAPED_KEYS.each do |key|
        next unless cfg.key?(key)

        value = cfg[key]
        next if value.is_a?(Hash)

        raise ConfigError,
              "#{key} in #{describe_source(source_path)} must be a Hash; " \
              "got #{value.inspect} (#{value.class}). Either remove the key " \
              "(defaults will apply) or supply `#{key}: { ... }` with the right shape."
      end
    end

    def validate_stage_skill_by_agent!(cfg, source_path)
      %w[brainstorm plan].each do |stage|
        value = cfg.dig(stage, "skill_by_agent")
        next if value.nil?

        unless value.is_a?(Hash)
          raise ConfigError,
                "#{stage}.skill_by_agent in #{describe_source(source_path)} must be a Hash; " \
                "got #{value.inspect} (#{value.class})"
        end

        value.each do |agent, skill|
          unless skill.is_a?(String) || skill.is_a?(Symbol)
            raise ConfigError,
                  "#{stage}.skill_by_agent.#{agent} in #{describe_source(source_path)} must be a String; " \
                  "got #{skill.inspect} (#{skill.class})"
          end
        end
      end
    end

    # Numeric review-loop knobs that must be positive integers.
    #
    # Path        | Why must be ≥ 1
    # ------------|----------------
    # review.ci.max_attempts            | 0 → CiFix runs once and bails before spawning fix
    # review.browser_test.max_attempts  | 0 → BrowserTest writes browser-blocked.md without spawning
    # review.max_passes                 | 0 → pass loop exits before Phase 2 runs
    # review.max_wall_clock_sec         | 0 → wall_clock_exceeded? trips on first check
    POSITIVE_INTEGER_KEYS = [
      [ %w[review ci max_attempts], "review.ci.max_attempts" ],
      [ %w[review browser_test max_attempts], "review.browser_test.max_attempts" ],
      [ %w[review max_passes], "review.max_passes" ],
      [ %w[review max_wall_clock_sec], "review.max_wall_clock_sec" ]
    ].freeze

    def validate_review_attempts!(cfg, source_path)
      POSITIVE_INTEGER_KEYS.each do |path, label|
        value = cfg.dig(*path)
        next if value.nil?

        unless value.is_a?(Integer) && value.positive?
          raise ConfigError,
                "#{label} in #{describe_source(source_path)} must be a positive integer (>= 1); " \
                "got #{value.inspect} (#{value.class})"
        end
      end
    end

    def review_fix_auto_commit_config(cfg, source_path)
      fix = cfg.dig("review", "fix")
      return nil if fix.nil?

      unless fix.is_a?(Hash)
        raise ConfigError,
              "review.fix in #{describe_source(source_path)} must be a Hash; got #{fix.inspect} (#{fix.class})"
      end

      auto_commit = fix["auto_commit"]
      return nil if auto_commit.nil?

      unless auto_commit.is_a?(Hash)
        raise ConfigError,
              "review.fix.auto_commit in #{describe_source(source_path)} must be a Hash; " \
              "got #{auto_commit.inspect} (#{auto_commit.class}). To disable the fallback scope check, " \
              "set review.fix.auto_commit.scope_check.enabled to false."
      end

      auto_commit
    end

    def validate_review_fix_auto_commit_scope!(cfg, source_path)
      auto_commit = review_fix_auto_commit_config(cfg, source_path)
      return if auto_commit.nil?

      validate_review_fix_auto_commit_scope_config!(auto_commit["scope_check"], source_path)
    end

    def validate_review_fix_auto_commit_scope_config!(scope, source_path)
      return if scope.nil?

      unless scope.is_a?(Hash)
        raise ConfigError,
              "review.fix.auto_commit.scope_check in #{describe_source(source_path)} must be a Hash; " \
              "got #{scope.inspect} (#{scope.class})"
      end

      enabled = scope["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "review.fix.auto_commit.scope_check.enabled in #{describe_source(source_path)} " \
              "must be true or false; got #{enabled.inspect} (#{enabled.class})"
      end

      %w[allowed_paths denied_paths].each do |key|
        label = "review.fix.auto_commit.scope_check.#{key}"
        if scope.key?(key) && scope[key].nil?
          raise ConfigError,
                "#{label} in #{describe_source(source_path)} must be an Array of path globs; got NilClass"
        end

        validate_path_glob_list!(scope[key], label, source_path)
      end
    end

    def validate_path_glob_list!(value, label, source_path)
      return if value.nil?

      unless value.is_a?(Array)
        raise ConfigError,
              "#{label} in #{describe_source(source_path)} must be an Array of path globs; got #{value.class}"
      end

      value.each_with_index do |entry, idx|
        unless entry.is_a?(String) && !entry.strip.empty?
          raise ConfigError,
                "#{label}[#{idx}] in #{describe_source(source_path)} must be a non-empty String"
        end

        normalized = entry.tr("\\", "/")
        if entry.match?(%r{\A[A-Za-z]:[\\/]}) || normalized.start_with?("/") || normalized.include?("\0") ||
           normalized.split("/").any? { |part| part.empty? || part == "." || part == ".." }
          raise ConfigError,
                "#{label}[#{idx}] in #{describe_source(source_path)} must be a relative path glob without traversal or null bytes"
        end
      end
    end

    def validate_reviewers!(cfg, source_path)
      reviewers = cfg.dig("review", "reviewers")
      # Defaults provide []; the only path to nil is a YAML user typing
      # `reviewers:` with no value. Fail loudly instead of silently
      # accepting (downstream code would NoMethodError on .each).
      if reviewers.nil?
        raise ConfigError,
              "review.reviewers in #{describe_source(source_path)} is nil; " \
              "either remove the key (defaults provide []) or supply an Array of reviewer entries"
      end

      unless reviewers.is_a?(Array)
        raise ConfigError,
              "review.reviewers in #{describe_source(source_path)} must be an Array of reviewer entries; got #{reviewers.class}"
      end

      seen_names = {}
      seen_basenames = {}
      reviewers.each_with_index do |entry, idx|
        unless entry.is_a?(Hash)
          raise ConfigError,
                "review.reviewers[#{idx}] in #{describe_source(source_path)} must be a Hash; got #{entry.class}"
        end

        # Required fields: presence + non-empty. Missing or blank values
        # would otherwise NoMethodError or yield broken filenames mid-spawn
        # (closes ce-code-review AC-6). Mirrors the framing used by the
        # output_basename / agent checks below.
        %w[name skill prompt_template].each do |field|
          value = entry[field]
          missing = value.nil? || (value.is_a?(String) && value.strip.empty?)
          next unless missing

          raise ConfigError,
                "review.reviewers[#{idx}].#{field} in #{describe_source(source_path)} is missing"
        end

        name = entry["name"]
        if name && (prev = seen_names[name])
          raise ConfigError,
                "review.reviewers in #{describe_source(source_path)} has duplicate name #{name.inspect} " \
                "at indices [#{prev}, #{idx}]"
        end
        seen_names[name] = idx if name

        # output_basename uniqueness — empty / whitespace-only strings are
        # treated as absent (would yield `reviews/-01.md` which is broken,
        # so reject them explicitly rather than letting the uniqueness
        # check silently allow two empty values to collide on disk).
        basename = entry["output_basename"]
        normalized_basename = basename.is_a?(String) ? basename.strip : basename
        if basename.is_a?(String) && normalized_basename.empty?
          raise ConfigError,
                "review.reviewers[#{idx}].output_basename in #{describe_source(source_path)} must not be empty " \
                "(would produce reviews/-NN.md filenames)"
        end

        # ce-review round-3 P1 #2 — reject path-traversal characters in
        # output_basename. The basename interpolates directly into
        # `reviews/<basename>-NN.md`; without this check, a value like
        # `../escape` produces `reviews/../escape-NN.md`. The retry-
        # loop cleanup in lib/hive/reviewers/agent.rb calls
        # `File.delete(output_path)` on that resolved path, which could
        # then delete files outside the task's `reviews/` directory.
        # Reject `/`, `\`, ASCII NUL, and the path-segment tokens `.`
        # and `..`. After rejection, the basename is guaranteed to be a
        # single safe filename component.
        if normalized_basename.is_a?(String)
          if normalized_basename =~ %r{[/\\\0]} ||
             normalized_basename == "." ||
             normalized_basename == ".."
            raise ConfigError,
                  "review.reviewers[#{idx}].output_basename #{basename.inspect} in #{describe_source(source_path)} " \
                  "must be a single filename component without path separators (/, \\, null) " \
                  "and may not be '.' or '..'"
          end
        end

        if normalized_basename && (prev = seen_basenames[normalized_basename])
          raise ConfigError,
                "review.reviewers in #{describe_source(source_path)} has duplicate output_basename #{basename.inspect} " \
                "at indices [#{prev}, #{idx}] (would cause concurrent file-write collisions)"
        end
        seen_basenames[normalized_basename] = idx if normalized_basename

        # ce-review P2 #6 — reject an output_basename whose per-pass
        # file (`<basename>-NN.md`) would collide with the orchestrator's
        # reserved-prefix namespace (`escalations-`, `ci-blocked`,
        # `browser-`, `fix-guardrail-`, `fix-success-`, `errors-`).
        # Without this check, a reviewer configured with
        # `output_basename: "errors"` silently has its per-pass file
        # classified as orchestrator-owned by `reviewer_file?`, hidden
        # from triage's `discover_reviewer_files`, and overwritten by
        # the U2 errors sink when other reviewers fail in the same pass.
        if normalized_basename
          require "hive/stages/review"
          probe = "#{normalized_basename}-99.md"
          if !Hive::Stages::Review.reviewer_file?(probe)
            reserved = Hive::Stages::Review::ORCHESTRATOR_OWNED_PREFIXES
                       .map { |p| p.chomp("-") }
                       .join(", ")
            raise ConfigError,
                  "review.reviewers[#{idx}].output_basename #{basename.inspect} in #{describe_source(source_path)} " \
                  "starts with a reserved orchestrator-owned prefix; choose a different name " \
                  "(reserved prefixes: #{reserved})"
          end
        end

        # ce-review P3 #8 — validate optional `max_attempts` at config
        # load time. The adapter falls back to the default on coercion
        # failure (defensive), but a load-time error catches typos
        # before the loop spawns its first reviewer.
        if entry.key?("max_attempts")
          max = entry["max_attempts"]
          unless max.is_a?(Integer) && max.positive?
            raise ConfigError,
                  "review.reviewers[#{idx}].max_attempts in #{describe_source(source_path)} " \
                  "must be a positive Integer; got #{max.inspect}"
          end
        end

        validate_agent_name!(
          entry["agent"],
          "review.reviewers[#{idx}].agent",
          source_path
        )
      end
    end

    def validate_review_fix_auto_commit!(cfg, source_path)
      auto_commit = review_fix_auto_commit_config(cfg, source_path)
      return if auto_commit.nil?

      validate_review_fix_auto_commit_scope_config!(auto_commit["scope_check"], source_path)
      validate_review_fix_auto_commit_sign_policy!(auto_commit, source_path)
    end

    def validate_review_fix_auto_commit_sign_policy!(auto_commit, source_path)
      policy = auto_commit["sign_policy"]
      return if policy.nil?

      unless policy.is_a?(String) && AUTO_COMMIT_SIGN_POLICIES.include?(policy)
        raise ConfigError,
              "review.fix.auto_commit.sign_policy in #{describe_source(source_path)} " \
              "must be one of #{AUTO_COMMIT_SIGN_POLICIES.inspect}; got #{policy.inspect} (#{policy.class})"
      end
    end

    def review_fix_auto_commit_sign_policy(cfg)
      policy = cfg.dig("review", "fix", "auto_commit", "sign_policy")
      policy || DEFAULTS.dig("review", "fix", "auto_commit", "sign_policy")
    end

    def validate_role_agent_names!(cfg, source_path)
      ROLE_AGENT_PATHS.each do |path|
        agent = cfg.dig(*path)
        validate_agent_name!(agent, path.join("."), source_path)
      end
    end

    BRAINSTORM_RUNTIMES = %w[headless tmux_interactive].freeze

    def validate_claude_mode!(cfg, source_path)
      mode = cfg.dig("claude", "mode")
      return if CLAUDE_MODES.include?(mode)

      raise ConfigError,
            "claude.mode in #{describe_source(source_path)} must be one of " \
            "#{CLAUDE_MODES.inspect}; got #{mode.inspect} (#{mode.class})"
    end

    def validate_claude_permission_mode!(cfg, source_path)
      permission_mode = cfg.dig("claude", "permission_mode")
      return if CLAUDE_PERMISSION_MODES.include?(permission_mode)

      raise ConfigError,
            "claude.permission_mode in #{describe_source(source_path)} must be one of " \
            "#{CLAUDE_PERMISSION_MODES.inspect}; got #{permission_mode.inspect} (#{permission_mode.class})"
    end

    def validate_brainstorm_runtime!(cfg, source_path)
      runtime = cfg.dig("brainstorm", "runtime")
      return if runtime.nil?
      return if BRAINSTORM_RUNTIMES.include?(runtime)

      raise ConfigError,
            "brainstorm.runtime in #{describe_source(source_path)} must be one of " \
            "#{BRAINSTORM_RUNTIMES.inspect}; got #{runtime.inspect} (#{runtime.class})"
    end

    # Shared check used by both validate_reviewers! and
    # validate_role_agent_names!: ensure `agent_name` resolves via
    # Hive::AgentProfiles.lookup. Nil values pass through (the field is
    # optional). Each error message lists the registered profile names so
    # an agent reading the failure output learns the valid set.
    def validate_agent_name!(agent_name, label, source_path)
      return if agent_name.nil?

      # AgentProfiles.registered?(name) calls `name.to_sym`, which crashes
      # on Integer / Hash / Array / Boolean with NoMethodError. Guard with
      # a String check first so a user typo like `execute: { agent: 42 }`
      # surfaces as a typed ConfigError instead of an opaque NoMethodError.
      unless agent_name.is_a?(String) || agent_name.is_a?(Symbol)
        raise ConfigError,
              "#{label} in #{describe_source(source_path)} must be a String " \
              "(an agent profile name like \"claude\" or \"codex\"); " \
              "got #{agent_name.inspect} (#{agent_name.class})"
      end

      return if Hive::AgentProfiles.registered?(agent_name)

      raise ConfigError,
            "#{label} #{agent_name.inspect} in #{describe_source(source_path)} " \
            "is not a registered AgentProfile (registered: #{Hive::AgentProfiles.registered_names.inspect})"
    end

    # Stable description of where a config came from, for error messages.
    # When the candidate file does not exist (defaults-only path), point
    # the user at the right path with an explicit "(defaults; no file
    # present)" note instead of pointing them at a phantom file.
    def describe_source(path)
      return path if File.exist?(path)

      "#{path} (defaults; no file present)"
    end

    # Numeric daemon knobs that must be positive integers. Lower bounds
    # encode behavioural floors:
    #   poll_interval_sec >= 5         — anything tighter starves CPU on
    #                                    `hive status` subprocesses
    #   fast_poll_sec >= 1             — cheap reap/stat cadence between
    #                                    full status polls
    #   edit_debounce_sec >= 0         — 0 means "no debounce, dispatch
    #                                    on first mtime move"; valid choice
    #   pr_merge_poll_interval_sec >= 60 — `gh pr view` is rate-limited
    #                                      under heavy load
    #   max_concurrent_*  >= 1         — caps below 1 disable dispatch
    #   max_runs_per_day_per_project >= 1
    #   transient_retry_backoff_sec >= 1
    #   shutdown_grace_sec >= 0        — 0 means "no grace, immediate
    #                                    SIGTERM on stop"; valid choice
    #   log_max_bytes >= 1024          — anything smaller breaks Logger
    #   log_max_files >= 1
    DAEMON_NUMERIC_BOUNDS = [
      [ "poll_interval_sec", 5 ],
      [ "fast_poll_sec", 1 ],
      [ "edit_debounce_sec", 0 ],
      [ "pr_merge_poll_interval_sec", 60 ],
      [ "max_concurrent_runs", 1 ],
      [ "max_concurrent_per_project", 1 ],
      [ "max_runs_per_day_per_project", 1 ],
      [ "transient_retry_backoff_sec", 1 ],
      [ "shutdown_grace_sec", 0 ],
      # child_timeout_sec >= 0  — 0 disables the per-child wall-clock cap
      # child_kill_grace_sec >= 0 — 0 means "SIGKILL on the next timeout tick after TERM"
      [ "child_timeout_sec", 0 ],
      [ "child_kill_grace_sec", 0 ],
      [ "log_max_bytes", 1024 ],
      [ "log_max_files", 1 ]
    ].freeze

    def validate_daemon!(cfg, source_path)
      daemon = cfg["daemon"]
      return if daemon.nil?

      enabled = daemon["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "daemon.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      autostart = daemon["autostart"]
      unless autostart.nil? || autostart == true || autostart == false
        raise ConfigError,
              "daemon.autostart in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{autostart.inspect} (#{autostart.class})"
      end

      DAEMON_NUMERIC_BOUNDS.each do |key, min|
        value = daemon[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min
          raise ConfigError,
                "daemon.#{key} in #{describe_source(source_path)} must be an integer " \
                ">= #{min}; got #{value.inspect} (#{value.class})"
        end
      end

      validate_daemon_verb_timeouts!(daemon, source_path)
    end

    # R-02: `daemon.child_verb_timeouts` is an optional map of hive verb
    # (String) → timeout seconds (Integer >= 0). 0 disables the cap for
    # that verb. Reject anything else loudly so a typo'd YAML knob fails
    # at load instead of silently never timing out.
    def validate_daemon_verb_timeouts!(daemon, source_path)
      overrides = daemon["child_verb_timeouts"]
      return if overrides.nil?

      unless overrides.is_a?(Hash)
        raise ConfigError,
              "daemon.child_verb_timeouts in #{describe_source(source_path)} must be a Hash " \
              "of verb => seconds; got #{overrides.class}"
      end

      overrides.each do |verb, secs|
        unless secs.is_a?(Integer) && secs >= 0
          raise ConfigError,
                "daemon.child_verb_timeouts[#{verb.inspect}] in #{describe_source(source_path)} " \
                "must be an integer >= 0; got #{secs.inspect} (#{secs.class})"
        end
      end
    end

    def validate_babysitter!(cfg, source_path)
      babysitter = cfg["babysitter"]
      return if babysitter.nil?

      %w[enabled dry_run].each do |key|
        value = babysitter[key]
        next if value.nil? || value == true || value == false

        raise ConfigError,
              "babysitter.#{key} in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{value.inspect} (#{value.class})"
      end

      interval = babysitter["interval"]
      unless interval.nil?
        # Validate via Interval.parse so a zero/negative interval (0, "0m")
        # is rejected at load time. The bare format check accepted them and
        # they only blew up later inside the dispatcher tick, turning a
        # malformed config into a daemon-loop crash instead of a load-time
        # ConfigError.
        begin
          Hive::Babysitter::Interval.parse(interval)
        rescue ConfigError => e
          raise ConfigError, "#{e.message} (in #{describe_source(source_path)})"
        end
      end

      {
        "max_concurrent_prs" => babysitter["max_concurrent_prs"],
        "budget_minutes" => babysitter["budget_minutes"],
        "budget_usd" => babysitter["budget_usd"]
      }.each do |key, value|
        next if value.nil?
        next if value.is_a?(Integer) && value >= 1

        raise ConfigError,
              "babysitter.#{key} in #{describe_source(source_path)} must be an integer >= 1; " \
              "got #{value.inspect} (#{value.class})"
      end

      labels = babysitter["labels_ignore"]
      unless labels.is_a?(Array) && labels.all? { |entry| entry.is_a?(String) }
        raise ConfigError,
              "babysitter.labels_ignore in #{describe_source(source_path)} must be an Array of Strings; " \
              "got #{labels.inspect} (#{labels.class})"
      end
    end

    PATROL_TRIGGERS = %w[new_commits timer continuous].freeze
    PATROL_CONFIDENCE_LEVELS = %w[low medium high].freeze
    PATROL_NUMERIC_BOUNDS = [
      [ "poll_interval_sec", 60 ],
      [ "max_findings_per_feature", 1 ],
      [ "max_prs_per_cycle", 1 ]
    ].freeze

    def validate_patrol!(cfg, source_path)
      patrol = cfg["patrol"]
      return if patrol.nil?

      enabled = patrol["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "patrol.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      draft_prs = patrol["draft_prs"]
      unless draft_prs.nil? || draft_prs == true || draft_prs == false
        raise ConfigError,
              "patrol.draft_prs in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{draft_prs.inspect} (#{draft_prs.class})"
      end

      trigger = patrol["trigger"]
      unless PATROL_TRIGGERS.include?(trigger)
        raise ConfigError,
              "patrol.trigger in #{describe_source(source_path)} must be one of " \
              "#{PATROL_TRIGGERS.inspect}; got #{trigger.inspect} (#{trigger.class})"
      end

      confidence = patrol["min_confidence_to_fix"]
      unless PATROL_CONFIDENCE_LEVELS.include?(confidence)
        raise ConfigError,
              "patrol.min_confidence_to_fix in #{describe_source(source_path)} must be one of " \
              "#{PATROL_CONFIDENCE_LEVELS.inspect}; got #{confidence.inspect} (#{confidence.class})"
      end

      PATROL_NUMERIC_BOUNDS.each do |key, min|
        value = patrol[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min
          raise ConfigError,
                "patrol.#{key} in #{describe_source(source_path)} must be an integer " \
                ">= #{min}; got #{value.inspect} (#{value.class})"
        end
      end

      validate_agent_name!(patrol["agent"], "patrol.agent", source_path)
      validate_path_glob_list!(patrol["include"], "patrol.include", source_path)
      validate_path_glob_list!(patrol["exclude"], "patrol.exclude", source_path)
      validate_patrol_commands!(patrol, source_path)
      validate_patrol_review!(patrol, source_path)
    end

    def validate_patrol_commands!(patrol, source_path)
      commands = patrol["commands"]
      unless commands.is_a?(Hash)
        raise ConfigError,
              "patrol.commands in #{describe_source(source_path)} must be a Hash; " \
              "got #{commands.inspect} (#{commands.class})"
      end

      %w[format lint typecheck test].each do |key|
        value = commands[key]
        next if value.nil?
        next if value.is_a?(String) && !value.strip.empty?

        raise ConfigError,
              "patrol.commands.#{key} in #{describe_source(source_path)} must be null or a non-empty String; " \
              "got #{value.inspect} (#{value.class})"
      end
    end

    def validate_patrol_review!(patrol, source_path)
      review = patrol["review"]
      return if review.nil?

      unless review.is_a?(Hash)
        raise ConfigError,
              "patrol.review in #{describe_source(source_path)} must be a Hash; " \
              "got #{review.inspect} (#{review.class})"
      end

      { "max_context_files" => 0, "max_owned_files" => 1 }.each do |key, min|
        value = review[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min
          raise ConfigError,
                "patrol.review.#{key} in #{describe_source(source_path)} must be an integer " \
                ">= #{min}; got #{value.inspect} (#{value.class})"
        end
      end
    end

    BOT_NUMERIC_BOUNDS = [
      [ "poll_interval_sec", 5, nil ],
      [ "long_poll_timeout_sec", 5, 50 ],
      [ "recovery_reminder_window_sec", 3600, 604_800 ],
      [ "recovery_grace_sec", 0, 3600 ],
      [ "conversation_ttl_sec", 60, nil ],
      [ "idea_attachment_max_bytes", 1, 20 * 1024 * 1024 ],
      [ "idea_attachment_max_count", 1, 10 ],
      [ "idea_draft_ttl_sec", 60, nil ],
      [ "codex_budget_usd", 0, nil ],
      [ "codex_timeout_sec", 10, nil ],
      [ "shutdown_grace_sec", 0, nil ],
      [ "log_max_bytes", 1024, nil ],
      [ "log_max_files", 1, nil ]
    ].freeze

    BOT_PATH_KEYS = %w[
      pid_file
      log_file
      alert_state_file
      last_seen_state_file
    ].freeze

    def validate_bot_config!(cfg, source_path)
      bot = cfg["bot"]
      return if bot.nil?

      enabled = bot["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "bot.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      validate_bot_allowlist!(bot, source_path)
      warn_deprecated_bot_dedupe!(bot, source_path)
      validate_bot_numbers!(bot, source_path)
      validate_bot_paths!(bot, source_path)
    end

    def validate_bot_runtime!(bot, source_path)
      telegram_bot_token!
      allowlist = bot["chat_id_allowlist"]
      return if allowlist.is_a?(Array) && !allowlist.empty?

      raise ConfigError,
            "bot.chat_id_allowlist in #{describe_source(source_path)} must contain at least one chat_id " \
            "before hive bot can start"
    end

    def validate_bot_allowlist!(bot, source_path)
      allowlist = bot["chat_id_allowlist"]
      unless allowlist.is_a?(Array)
        raise ConfigError,
              "bot.chat_id_allowlist in #{describe_source(source_path)} must be an Array of Integers; " \
              "got #{allowlist.inspect} (#{allowlist.class})"
      end

      allowlist.each_with_index do |entry, idx|
        next if entry.is_a?(Integer)

        raise ConfigError,
              "bot.chat_id_allowlist[#{idx}] in #{describe_source(source_path)} must be an Integer; " \
              "got #{entry.inspect} (#{entry.class})"
      end
    end

    def validate_bot_numbers!(bot, source_path)
      BOT_NUMERIC_BOUNDS.each do |key, min, max|
        value = bot[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min && (max.nil? || value <= max)
          bound = max ? "between #{min} and #{max}" : ">= #{min}"
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must be an integer #{bound}; " \
                "got #{value.inspect} (#{value.class})"
        end
      end
    end

    # Single source of truth for deprecated bot keys. Each entry names the
    # config key, its replacement, and the DEFAULTS path used to suppress
    # warnings when the user has not actually set anything (or has set the
    # historical default). Both the load-time `warn` path and the supervisor's
    # structured :deprecated_config event iterate this list.
    DEPRECATED_BOT_KEYS = [
      {
        key: "notification_dedupe_window_sec",
        replacement: "bot.alert_state_file and bot.recovery_reminder_window_sec"
      }
    ].freeze

    def warn_deprecated_bot_dedupe!(bot, source_path)
      # deprecated_bot_keys already returns the fully-qualified key
      # ("bot.<name>"), so the warn line does not add its own prefix.
      deprecated_bot_keys(bot).each do |entry|
        warn "hive: #{entry[:key]} in #{describe_source(source_path)} is deprecated; " \
             "alert lifecycle now uses #{entry[:replacement]}"
      end
    end

    # Returns deprecated bot keys whose value differs from default so callers
    # (e.g. the bot supervisor) can emit structured :deprecated_config events.
    def deprecated_bot_keys(bot)
      return [] unless bot.is_a?(Hash)

      DEPRECATED_BOT_KEYS.each_with_object([]) do |entry, out|
        value = bot[entry[:key]]
        default = DEFAULTS.dig("bot", entry[:key])
        next if value.nil? || value == default

        out << { key: "bot.#{entry[:key]}", replacement: entry[:replacement] }
      end
    end

    def validate_bot_paths!(bot, source_path)
      BOT_PATH_KEYS.each do |key|
        value = bot[key]
        next if value.nil?

        unless value.is_a?(String) && !value.strip.empty?
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must be a non-empty String path; " \
                "got #{value.inspect} (#{value.class})"
        end
        if unsafe_path_segment?(value)
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must not contain '..' path segments; " \
                "got #{value.inspect}"
        end
        bot[key] = File.expand_path(value)
      end
    end

    def unsafe_path_segment?(value)
      File.expand_path(value).split(File::SEPARATOR).include?("..") ||
        value.split(/[\\\/]/).include?("..")
    end

    # Validate `rebase:` block from auto-rebase plan
    # (docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md U5).
    # Two keys today: `enabled` (boolean) and `conflict_resolution_timeout_sec`
    # (integer >= 60 — lower bound prevents operationally-useless tiny
    # timeouts that would mark every conflict-resolution as failed).
    def validate_rebase!(cfg, source_path)
      rebase = cfg["rebase"]
      return if rebase.nil?

      enabled = rebase["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "rebase.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      timeout = rebase["conflict_resolution_timeout_sec"]
      return if timeout.nil?

      unless timeout.is_a?(Integer) && timeout >= 60
        raise ConfigError,
              "rebase.conflict_resolution_timeout_sec in #{describe_source(source_path)} " \
              "must be an integer >= 60; got #{timeout.inspect} (#{timeout.class})"
      end
    end
  end
end
