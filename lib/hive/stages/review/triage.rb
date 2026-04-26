require "digest"
require "fileutils"
require "hive/agent_profiles"
require "hive/protected_files"
require "hive/reviewers/synthetic_task"
require "hive/stages/base"

module Hive
  module Stages
    module Review
      # Auto-triage step of the 5-review autonomous loop. Reads every
      # `reviews/<*>-<pass>.md` for the current pass, hands them to a
      # triage agent (configured via review.triage.agent), and expects
      # the agent to:
      #   1. Edit each reviewer file in place to add `[x]` on auto-fix
      #      items and append `<!-- triage: <reason> -->` on the same
      #      line.
      #   2. Write `reviews/escalations-<pass>.md` listing only the
      #      still-`[ ]` items grouped by source-reviewer.
      #
      # Bias preset is selected via review.triage.bias (`courageous`
      # default; `safetyist` opt-in). A project may override the entire
      # prompt by setting review.triage.custom_prompt to a path under
      # <.hive-state>/templates/. Path-escape attempts raise
      # Hive::ConfigError.
      #
      # ADR-013-style protected-files SHA-256 check wraps the spawn:
      # plan.md, worktree.yml, and task.md must NOT be modified by the
      # triage agent. Tampering yields a :triage_tampered error result;
      # the U9 runner converts that to a REVIEW_ERROR marker.
      module Triage
        Result = Data.define(:status, :escalations_path, :error_message, :tampered_files)

        # Files the triage agent must NOT modify. The reviewer files
        # are deliberately NOT in this list — triage's job is to edit
        # them in place. The escalations file is new and SHA-irrelevant.
        PROTECTED_FILES = Hive::ProtectedFiles::ORCHESTRATOR_OWNED

        BIAS_PRESETS = {
          "courageous" => "triage_courageous.md.erb",
          "safetyist" => "triage_safetyist.md.erb"
        }.freeze

        module_function

        def run!(cfg:, ctx:)
          escalations = escalations_path(ctx)
          reviewer_files = discover_reviewer_files(ctx)

          if reviewer_files.empty?
            FileUtils.mkdir_p(File.dirname(escalations))
            File.write(escalations, empty_escalations_body(ctx.pass))
            return Result.new(
              status: :ok,
              escalations_path: escalations,
              error_message: nil,
              tampered_files: []
            )
          end

          template_name = resolve_template(cfg, ctx)
          profile_name = cfg.dig("review", "triage", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(profile_name)

          prompt = render_prompt(
            template_name: template_name,
            ctx: ctx,
            cfg: cfg,
            reviewer_files: reviewer_files,
            escalations_path: escalations
          )

          before = Hive::ProtectedFiles.snapshot(ctx.task_folder, PROTECTED_FILES)
          spawn_result = Hive::Stages::Base.spawn_agent(
            synthetic_task(ctx),
            prompt: prompt,
            add_dirs: [ ctx.task_folder ],
            cwd: ctx.worktree_path,
            max_budget_usd: cfg.dig("budget_usd", "review_triage") || 15,
            timeout_sec: cfg.dig("timeout_sec", "review_triage") || 300,
            log_label: "review-triage-pass#{format('%02d', ctx.pass)}",
            profile: profile,
            expected_output: escalations,
            status_mode: :output_file_exists
          )
          after = Hive::ProtectedFiles.snapshot(ctx.task_folder, PROTECTED_FILES)

          tampered = Hive::ProtectedFiles.diff(before, after)
          if tampered.any?
            return Result.new(
              status: :tampered,
              escalations_path: escalations,
              error_message: "triage agent modified protected files: #{tampered.join(', ')}",
              tampered_files: tampered
            )
          end

          if spawn_result[:status] == :ok
            Result.new(
              status: :ok,
              escalations_path: escalations,
              error_message: nil,
              tampered_files: []
            )
          else
            Result.new(
              status: :error,
              escalations_path: escalations,
              error_message: spawn_result[:error_message] || "triage agent failed (#{spawn_result[:status]})",
              tampered_files: []
            )
          end
        end

        # Test helper: list of files the protected-SHA check covers, in
        # discovery order. Exposed so tests can trigger the tampering
        # path deterministically.
        def protected_paths(ctx)
          PROTECTED_FILES.map { |name| File.join(ctx.task_folder, name) }
        end

        def escalations_path(ctx)
          File.join(
            ctx.task_folder,
            "reviews",
            "escalations-#{format('%02d', ctx.pass)}.md"
          )
        end

        def discover_reviewer_files(ctx)
          glob = File.join(
            ctx.task_folder,
            "reviews",
            "*-#{format('%02d', ctx.pass)}.md"
          )
          Dir[glob]
            .select { |f| Hive::Stages::Review.reviewer_file?(File.basename(f)) }
            .sort
        end

        def resolve_template(cfg, ctx)
          custom = cfg.dig("review", "triage", "custom_prompt")
          return resolve_custom_template(custom, ctx) if custom

          bias = (cfg.dig("review", "triage", "bias") || "courageous").to_s
          template = BIAS_PRESETS[bias]
          unless template
            raise Hive::ConfigError,
                  "review.triage.bias #{bias.inspect} is not a known preset " \
                  "(known: #{BIAS_PRESETS.keys.inspect})"
          end
          template
        end

        # Custom triage prompt path: resolved via the shared
        # Hive::Stages::Base.resolve_template_path guard so every
        # consumer of a user-supplied template name (review.fix,
        # review.ci, review.browser_test, per-reviewer) shares one
        # path-escape policy.
        def resolve_custom_template(custom, ctx)
          state_dir = ctx_state_dir(ctx)
          # `custom` here is always a user-supplied path. Force the
          # custom-template branch by joining a leading `./` so the
          # resolver doesn't fall into the built-in branch when the
          # user supplies a bare basename.
          name = custom.include?("/") ? custom : "./#{custom}"
          Hive::Stages::Base.resolve_template_path(name, hive_state_dir: state_dir)
        rescue Hive::ConfigError => e
          # Surface the original `review.triage.custom_prompt …` framing
          # callers (and tests) match on.
          raise Hive::ConfigError, e.message.sub("prompt_template", "review.triage.custom_prompt")
        end

        # Delegates to the shared helper so every review-stage consumer
        # of resolve_template_path agrees on which directory counts as
        # the templates root.
        def ctx_state_dir(ctx)
          Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
        end

        def render_prompt(template_name:, ctx:, cfg:, reviewer_files:, escalations_path:)
          # Custom prompt path is an absolute path (from resolve_custom_template);
          # bias preset is a basename relative to templates/. Distinguish the
          # two and load the right ERB.
          custom = cfg.dig("review", "triage", "custom_prompt")
          erb_source =
            if custom
              File.read(template_name)
            else
              path = File.expand_path("../../../../templates/#{template_name}", __dir__)
              File.read(path)
            end

          tag = Hive::Stages::Base.user_supplied_tag
          bindings = Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(ctx.worktree_path),
            worktree_path: ctx.worktree_path,
            task_folder: ctx.task_folder,
            pass: ctx.pass,
            reviewer_files: reviewer_files,
            reviewer_contents: build_reviewer_contents_block(reviewer_files, tag),
            escalations_path: escalations_path,
            user_supplied_tag: tag
          )
          require "erb"
          ERB.new(erb_source, trim_mode: "-").result(bindings.binding_for_erb)
        end

        # Build a single concatenated string with each reviewer file
        # wrapped in its own <user_supplied content_type="reviewer_md">
        # block. The agent receives every file's verbatim content but
        # closing tags inside any individual file cannot escape the
        # wrapper because the per-spawn nonce is unguessable (ADR-019).
        def build_reviewer_contents_block(reviewer_files, tag)
          out = +""
          reviewer_files.each do |path|
            content =
              begin
                File.read(path)
              rescue Errno::ENOENT, IOError, SystemCallError => e
                # A reviewer file disappearing mid-triage (TOCTOU race
                # with the user, broken symlink, perms flipped) must not
                # abort the whole triage — substitute an explanatory
                # placeholder so the agent still sees the structure of
                # the wrapper and can mark the file `[ ]` for human
                # review.
                "(reviewer file unreadable: #{e.message})"
              end
            out << "\n## #{File.basename(path)}\n\n"
            out << "<#{tag} content_type=\"reviewer_md\" path=\"#{path}\">\n"
            out << content
            out << "\n</#{tag}>\n"
          end
          out
        end

        def empty_escalations_body(pass)
          <<~MD
            # Escalations for pass #{format('%02d', pass)}

            _No reviewer findings produced for this pass. Triage skipped._
          MD
        end

        # Triage shares the synthetic-task pattern with every other
        # 5-review sub-spawn; delegate to the shared helper (M-04).
        def synthetic_task(ctx)
          Hive::Reviewers.synthetic_task_for(ctx)
        end
      end
    end
  end
end
