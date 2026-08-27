require "digest"
require "json"
require "hive/agent_git_gate"
require "hive/artifact_firewall"
require "hive/claude_launcher"
require "hive/dependencies"
require "hive/dependency_snapshot"
require "hive/github_publication"
require "hive/git_ops"
require "hive/markers"
require "hive/stages/base"
require "hive/task"
require "hive/worktree"

module Hive
  module Stages
    # Coding-workflow adapter for the shared GitHub publication controller.
    # The agent authors bounded title/body bytes only; it has no publication
    # role. GithubPublication owns inventory, branch push, PR creation,
    # adoption, and replay state for the exact request.
    module OpenPr
      module_function

      AUTHORING_FILE = "pr-draft.json".freeze
      PUBLICATION_STATE_FILE = "github-publication.json".freeze
      MAX_AUTHORING_BYTES = Hive::GithubPublication::MAX_TITLE_BYTES +
                            Hive::GithubPublication::MAX_BODY_BYTES + 1_024
      Authoring = Data.define(:title, :body)

      def run!(task, cfg, git_gateway: nil, github_gateway: nil, controller: nil)
        pointer = Hive::Stages::Base.worktree_pointer_or_exit(task)
        authoring = if File.exist?(authoring_path(task))
          read_authoring(authoring_path(task))
        else
          identity, profile, launch_arguments = publication_agent(task, cfg)
          authoring_for(task, cfg, pointer, identity, profile, launch_arguments)
        end
        return authoring if authoring.is_a?(Hash)

        git_gateway ||= default_git_gateway(cfg)
        request = publication_request(
          task, cfg, pointer, authoring, git_gateway: git_gateway
        )
        controller ||= Hive::GithubPublication::Controller.new(
          state_path: File.join(task.folder, PUBLICATION_STATE_FILE),
          git_gateway: git_gateway,
          github_gateway: github_gateway || Hive::GithubPublication::GithubGateway.new(cfg: cfg)
        )
        revalidate = lambda do |_phase|
          current_authoring = read_authoring(authoring_path(task))
          current = publication_request(
            task, cfg, pointer, current_authoring, git_gateway: git_gateway
          )
          current.to_h == request.to_h
        end
        publication = controller.publish!(request, revalidate: revalidate)
        complete_publication(task, publication)
      rescue Hive::GithubPublication::Blocked => e
        Hive::Markers.set(
          task.state_file, :error,
          reason: "github_publication_#{e.code}", detail: e.message.to_s[0, 200]
        )
        { commit: "open_pr_#{e.code}", status: :error }
      rescue Hive::StageError, Hive::AgentGitGate::Error, JSON::ParserError => e
        Hive::Markers.set(
          task.state_file, :error,
          reason: "open_pr_invalid_authoring", detail: e.message.to_s[0, 200]
        )
        { commit: "open_pr_invalid_authoring", status: :error }
      end

      def publication_agent(task, cfg)
        identity = Hive::Stages::Base.implementation_stage_identity(task, cfg, "open_pr")
        profile = if identity
          Hive::AgentProfiles.lookup(identity.provider, cfg: cfg)
        else
          Hive::Stages::Base.stage_profile(cfg, "open_pr")
        end
        launch_arguments = Hive::Stages::Base.implementation_launch_arguments(identity, profile)
        [ identity, profile, launch_arguments ]
      end

      def authoring_for(task, cfg, pointer, identity, profile, launch_arguments)
        path = authoring_path(task)
        return read_authoring(path) if File.exist?(path)

        prompt = render_prompt(
          task, pointer.fetch("path"), pointer.fetch("branch", task.slug),
          authoring_path: path,
          base_branch: publication_base_branch(task, cfg, pointer)
        )
        custody_manifest = Hive::ArtifactFirewall::Manifest.new(
          root: task.folder,
          protected_anchors: Hive::ArtifactFirewall::ORCHESTRATOR_OWNED,
          permitted_writable_roots: [ task.folder ]
        )
        agent_custody = Hive::ArtifactFirewall::AgentCustody.new(custody_manifest)
        spawn_result = spawn_open_pr_agent(
          task, cfg, prompt, profile, task.folder,
          identity: identity, launch_arguments: launch_arguments,
          agent_custody: agent_custody, expected_output: path
        )
        custody_report = agent_custody.report
        if !custody_report && spawn_result.is_a?(Hash) && spawn_result[:status] == :ok
          return authoring_error(task, "open_pr_custody_missing")
        end
        if custody_report&.tampered?
          Hive::Markers.set(
            task.state_file, :error,
            reason: "open_pr_tampered",
            files: custody_report.tampered_labels.join(","),
            restored: custody_report.restored?,
            restore_error: custody_report.restore_diagnostic.to_s[0, 200]
          )
          return { commit: "open_pr_tampered", status: :error }
        end

        Hive::Stages::Base.record_deferred_agent_observation(
          task, cfg, "open_pr", spawn_result
        )
        unless spawn_result.is_a?(Hash) && spawn_result[:status] == :ok
          return authoring_error(
            task, "open_pr_authoring_failed", spawn_result&.fetch(:error_message, nil)
          )
        end
        read_authoring(path)
      end

      def authoring_error(task, reason, detail = nil)
        Hive::Markers.set(
          task.state_file, :error,
          **{ reason: reason, detail: detail.to_s[0, 200] }.reject { |_key, value| value.empty? }
        )
        { commit: reason, status: :error }
      end

      def spawn_open_pr_agent(task, cfg, prompt, profile, cwd,
                              identity: nil, launch_arguments: nil,
                              agent_custody: nil, expected_output: nil)
        launch_arguments ||=
          Hive::Stages::Base.implementation_launch_arguments(identity, profile)
        expected_output ||= authoring_path(task)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "open_pr", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: cwd,
          max_budget_usd: cfg.dig("budget_usd", "open_pr") || 50,
          timeout_sec: cfg.dig("timeout_sec", "open_pr") || 1800,
          log_label: "open-pr-author",
          profile: profile,
          implementation_stage: "open_pr",
          agent_custody: agent_custody,
          expected_output: expected_output,
          status_mode: :output_file_exists,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          **launch_arguments
        }
        if Hive::AgentSupport.supports?(profile, :Interactive)
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task, cfg, **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("5-open-pr", task) # coding-scoped: stable tmux label
          )
        else
          Hive::Stages::Base.spawn_agent(
            task, **kwargs, cfg: cfg,
            defer_implementation_observation: true
          )
        end
      end

      def render_prompt(task, worktree_path, branch, authoring_path:, base_branch:)
        Hive::Stages::Base.render(
          "open_pr_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: worktree_path,
            authoring_path: authoring_path,
            slug: task.slug,
            branch: branch,
            base_branch: base_branch,
            plan_text: read_optional(task, "plan.md"),
            execute_output_text: read_optional(task, "task.md"),
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def publication_request(task, cfg, pointer, authoring, git_gateway:)
        path = pointer.fetch("path")
        branch = pointer.fetch("branch", task.slug)
        base_branch = publication_base_branch(task, cfg, pointer)
        base_oid = pointer.fetch("base_oid").to_s.downcase
        head_oid = git_read!(path, :head_oid).stdout.strip.downcase
        current_branch = git_read!(path, :current_branch).stdout.strip
        raise Hive::StageError, "publication worktree branch changed" unless current_branch == branch
        raise Hive::StageError, "publication worktree is dirty" unless git_read!(path, :status).stdout.empty?
        unless git_read!(path, :ancestor, base_oid: base_oid, head_oid: head_oid, allow_false: true).success?
          raise Hive::StageError, "publication head is not descended from its recorded base"
        end
        count = Integer(
          git_read!(path, :commit_count, base_oid: base_oid, head_oid: head_oid).stdout.strip,
          10
        )
        raise Hive::StageError, "publication has no commits beyond its recorded base" unless count.positive?
        diff = git_read!(
          path, :diff, base_oid: base_oid, head_oid: head_oid,
          max_stdout_bytes: Hive::GithubPublication::MAX_DIFF_BYTES
        ).stdout
        repository = git_gateway.repository_identity(worktree_path: path)
        Hive::GithubPublication::Request.new(
          worktree_path: path,
          host: repository.fetch("host"),
          repository: repository.fetch("repository"),
          base_branch: base_branch,
          creation_base_oid: base_oid,
          branch: branch,
          head_oid: head_oid,
          diff_digest: Digest::SHA256.hexdigest(diff),
          title: authoring.title,
          body: authoring.body,
          diff: diff,
          draft: true
        )
      rescue KeyError, ArgumentError, TypeError => e
        raise Hive::StageError, "publication identity is invalid: #{e.message}"
      end

      def git_read!(path, operation, allow_false: false, **options)
        result = Hive::AgentGitGate.read(path, operation, **options)
        return result if result.success? || (allow_false && result.exitstatus == 1 && !result.overflow)

        detail = result.stderr.to_s.strip
        detail = result.overflow ? "output exceeded its safe bound" : "git exited #{result.exitstatus}" if detail.empty?
        raise Hive::StageError, "publication Git read failed: #{operation}: #{detail}"
      end

      def publication_base_branch(task, cfg, pointer)
        dependency_pr_base_branch(task, cfg) || pointer["base_branch"] ||
          cfg["default_branch"] || Hive::GitOps.new(task.project_root).default_branch
      end

      def dependency_pr_base_branch(task, cfg)
        default_branch = cfg["default_branch"] || Hive::GitOps.new(task.project_root).default_branch
        base_branch = Hive::DependencySnapshot.stacked_base(task, default_branch)
        return unless base_branch

        Hive::Worktree.origin_branch_exists?(task.project_root, base_branch) ? base_branch : nil
      end

      def default_git_gateway(cfg)
        Hive::GithubPublication::GitGateway.new(
          cfg: cfg,
          allow_local_transport: cfg.dig("agent_git_gate", "allow_local_transport") == true
        )
      end

      def read_authoring(path)
        source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          stat = file.stat
          raise Hive::StageError, "#{AUTHORING_FILE} must be a regular file" unless stat.file?
          raise Hive::StageError, "#{AUTHORING_FILE} is empty" if stat.size.zero?
          raise Hive::StageError, "#{AUTHORING_FILE} exceeds #{MAX_AUTHORING_BYTES} bytes" if stat.size > MAX_AUTHORING_BYTES

          file.read(MAX_AUTHORING_BYTES + 1)
        end
        source.force_encoding(Encoding::UTF_8)
        raise Hive::StageError, "#{AUTHORING_FILE} must be valid UTF-8" unless source.valid_encoding?

        document = JSON.parse(source)
        unless document.is_a?(Hash) && document.keys.sort == %w[body title] &&
               document.values.all? { |value| value.is_a?(String) }
          raise Hive::StageError, "#{AUTHORING_FILE} must contain only string title and body fields"
        end
        if document.fetch("body").match?(Hive::Markers::MARKER_RE) ||
           document.fetch("body").match?(/<!--\s*hive-publication:/i)
          raise Hive::StageError, "#{AUTHORING_FILE} contains a reserved controller marker"
        end
        Authoring.new(title: document.fetch("title"), body: document.fetch("body"))
      rescue Errno::ENOENT
        raise Hive::StageError, "#{AUTHORING_FILE} is missing"
      rescue Errno::ELOOP
        raise Hive::StageError, "#{AUTHORING_FILE} must be a regular file, not a symlink"
      rescue SystemCallError, IOError => e
        raise Hive::StageError, "#{AUTHORING_FILE} is unreadable: #{e.class}: #{e.message}"
      end

      def complete_publication(task, publication)
        hosted_state = publication.fetch("hosted_state")
        if hosted_state == "closed"
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_closed")
          return { commit: "open_pr_closed", status: :error }
        end

        write_pr_md(task, publication)
        if hosted_state == "merged"
          write_merged_downstream_markers(task)
          write_merged_summary(task, publication)
        end
        Hive::Markers.set(
          task.state_file, :complete,
          pr_url: publication.fetch("url"),
          is_draft: (hosted_state == "draft").to_s,
          merged: (hosted_state == "merged").to_s,
          publication_id: publication.fetch("publication_id")
        )
        record_pr_observation(task, publication, hosted_state)
        {
          commit: hosted_state == "merged" ? "open_pr_already_merged" : "pr_opened_draft",
          status: :complete
        }
      end

      def write_pr_md(task, publication)
        body = <<~MD
          ---
          pr_url: #{publication.fetch("url")}
          pr_number: #{publication.fetch("number")}
          head_oid: #{publication.fetch("head_oid")}
          publication_id: #{publication.fetch("publication_id")}
          hosted_state: #{publication.fetch("hosted_state")}
          ---

          ## Summary
          Exact draft pull request published by Hive.

          ## Linked task
          #{task.folder}
        MD
        File.write(task.state_file, body)
      end

      def record_pr_observation(task, publication, state)
        context = Hive::Attempts::Context.current
        return false unless context

        number = publication.fetch("number")
        Hive::Stages::Base.record_task_activity(
          task, kind: state == "merged" ? "merge_observed" : "pr_observed",
          operation_id: "publication:#{context.attempt_id}:#{state}:#{number}",
          correlation_id: "publication:#{number}",
          reason: "pull request #{state}", source: "open_pr",
          payload: {
            "pr_number" => number, "pr_state" => state,
            "commit_oid" => publication.fetch("head_oid")
          }
        )
      end

      def write_merged_downstream_markers(task)
        review_state_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("review"))
        File.write(review_state_file, <<~MD)
          # Review skipped — PR merged before open-pr finished

          <!-- REVIEW_COMPLETE pass=0 browser=skipped merged=true -->
        MD
        artifact_state_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("artifacts"))
        File.write(artifact_state_file, <<~MD)
          # Artifacts skipped — PR merged before open-pr finished

          <!-- COMPLETE merged=true -->
        MD
      end

      def write_merged_summary(task, publication)
        File.write(File.join(task.folder, "summary.md"), <<~MD)
          ## Summary
          PR ##{publication.fetch("number")} was already merged before Hive finished the open-pr stage.

          PR: #{publication.fetch("url")}

          ## Review
          Hive recovered the exact controller-owned publication after observing its merged state.

          ## Open Escalations
          None.
        MD
      end

      def authoring_path(task)
        File.join(task.folder, AUTHORING_FILE)
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end
    end
  end
end
