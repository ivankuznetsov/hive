require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/github_publication"
require "hive/git_ops"
require "hive/patrol_fix/publication_receipt"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/runner"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/worktree_snapshot"
require "hive/patrol_fix/worktree_receipt"
require "hive/worktree"

module Hive
  module Stages
    module PatrolFix
      # Deterministic Patrol Fix publication. Review is the semantic gate;
      # this stage only revalidates its exact local authority and delegates
      # replay-safe branch/PR effects to the lower-level controller.
      module Publish
        module_function

        DIAGNOSTIC_FILENAME = "patrol-fix-publication-diagnostic.json".freeze
        MAX_BODY_BYTES = 24 * 1024

        def run!(task, cfg = {}, git_gateway: nil, github_gateway: nil,
                 worktree_root: nil, controller: nil, cleanup: nil)
          store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
          if (existing = current_publication(store, task.folder))
            Hive::PatrolFix::PublicationReceipt.validate_payload!(existing.fetch("payload"))
            write_pr_metadata!(task.folder, existing.fetch("payload"))
            cleanup_after_receipt(
              task, cleanup, worktree_root, existing.fetch("payload")
            )
            return complete(existing)
          end

          git_gateway ||= default_git_gateway(cfg)
          github_gateway ||= Hive::GithubPublication::GithubGateway.new(cfg: cfg)
          request = publication_request(
            task, cfg, git_gateway: git_gateway, worktree_root: worktree_root
          )
          controller ||= Hive::GithubPublication::Controller.new(
            state_path: publication_state_path(task, request.generation),
            git_gateway: git_gateway, github_gateway: github_gateway
          )
          revalidate = lambda do |_phase|
            current = publication_request(
              task, cfg, git_gateway: git_gateway, worktree_root: worktree_root
            )
            current.to_h == request.to_h
          end
          publication = controller.publish!(request, revalidate: revalidate)

          # The lower-level controller revalidates at its final observation,
          # and the stage repeats that exact check immediately before local
          # completion authority becomes durable.
          final = publication_request(
            task, cfg, git_gateway: git_gateway, worktree_root: worktree_root
          )
          unless final.to_h == request.to_h
            raise Hive::GithubPublication::Blocked.new(
              "stale_authority", "publication authority changed before the canonical receipt"
            )
          end
          receipt = Hive::PatrolFix::PublicationReceipt.build(
            task: { "slug" => request.task, "generation" => request.generation },
            evidence_revision: {
              "generation" => request.generation,
              "digest" => request.evidence_digest
            },
            publication: publication
          )
          write_pr_metadata!(task.folder, receipt.fetch("payload"))
          receipt = store.append!(receipt)
          unless current_publication(store, task.folder) == receipt
            raise Hive::GithubPublication::Blocked.new(
              "stale_authority", "publication receipt is not current after durable append"
            )
          end
          cleanup_after_receipt(
            task, cleanup, worktree_root, receipt.fetch("payload")
          )
          complete(receipt)
        end

        def publication_request(task, cfg = {}, git_gateway:, worktree_root: nil)
          snapshot = exact_snapshot!(
            task, cfg, git_gateway: git_gateway, worktree_root: worktree_root
          )
          Hive::GithubPublication::Request.new(
            task: task.slug,
            generation: snapshot.fetch("manifest").dig("task", "generation"),
            evidence_digest: snapshot.fetch("manifest").dig("evidence_revision", "digest"),
            review_receipt_id: snapshot.fetch("review").fetch("receipt_id"),
            worktree_path: snapshot.fetch("owner").fetch("worktree"),
            host: snapshot.fetch("repository_identity").fetch("host"),
            repository: snapshot.fetch("repository_identity").fetch("repository"),
            base_branch: snapshot.fetch("base_branch"),
            creation_base_oid: snapshot.fetch("owner").fetch("base_revision"),
            branch: snapshot.fetch("owner").fetch("branch"),
            head_oid: snapshot.fetch("head_revision"),
            diff_digest: snapshot.fetch("diff_digest"),
            title: title_for(task, snapshot.fetch("manifest")),
            body: body_for(snapshot), diff: snapshot.fetch("diff"),
            draft: cfg.dig("patrol", "draft_prs") != false
          )
        rescue ArgumentError, Hive::GhError
          raise Hive::GithubPublication::Blocked.new(
            "invalid_publication_identity", "publication identity is invalid"
          )
        end

        def publication_state_path(task, generation)
          File.join(
            task.hive_state_path, "patrol-fix", "publications", task.slug,
            "generation-#{generation}.json"
          )
        end

        def exact_snapshot!(task, cfg, git_gateway:, worktree_root:)
          manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
          store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
          receipts = store.read_all
          review = receipts.find do |row|
            current?(row, manifest) && row["kind"] == "decision" &&
              row["stage"] == "review" && row.dig("payload", "route") == "publish"
          end
          raise Hive::StageError, "publish requires an exact current review approval" unless review
          fix = receipts.find { |row| row["receipt_id"] == review.dig("payload", "fix_receipt_id") }
          validation = receipts.find do |row|
            row["receipt_id"] == review.dig("payload", "validation_receipt_id")
          end
          unless fix&.fetch("kind", nil) == "fix" && fix.fetch("stage") == "fix" &&
                 validation&.fetch("kind", nil) == "validation" && validation.fetch("stage") == "validate"
            raise Hive::StageError, "publish approval references unavailable fix or validation evidence"
          end
          expected_head = review.dig("payload", "head_revision")
          expected_diff = review.dig("payload", "diff_digest")
          unless fix.dig("payload", "head_revision") == expected_head &&
                 validation.dig("payload", "worktree_head") == expected_head &&
                 fix.dig("payload", "diff_digest") == expected_diff
            raise Hive::StageError, "publish approval does not bind one exact validated patch"
          end

          worktree = Hive::PatrolFix::WorktreeSnapshot.capture(
            task: task, manifest: manifest, fix: fix, validation: validation,
            worktree_root: worktree_root, phase: :publish
          )
          owner = worktree.fetch("owner")
          head = worktree.fetch("head_revision")
          digest = worktree.fetch("diff_digest")
          repository_identity = git_gateway.repository_identity(
            worktree_path: owner.fetch("worktree")
          )
          unless repository_identity.is_a?(Hash) &&
                 repository_identity.keys.sort == %w[host repository]
            raise Hive::StageError, "publication repository identity is unavailable"
          end
          base_branch = cfg["default_branch"].to_s
          base_branch = Hive::GitOps.new(task.project_root).detect_default_branch if base_branch.empty?
          {
            "manifest" => manifest, "review" => review, "fix" => fix,
            "validation" => validation, "owner" => owner,
            "head_revision" => head, "diff_digest" => digest,
            "diff" => worktree.fetch("diff"), "repository_identity" => repository_identity,
            "base_branch" => base_branch
          }
        end
        private_class_method :exact_snapshot!

        def title_for(task, _manifest)
          "Fix Patrol finding: #{task.slug}"
        end
        private_class_method :title_for

        def body_for(snapshot)
          manifest = snapshot.fetch("manifest")
          review = snapshot.fetch("review")
          validation = snapshot.fetch("validation")
          sources = manifest.fetch("sources").map do |source|
            "- #{source.fetch('engine')}: #{source.fetch('identity')}"
          end
          evidence = manifest.fetch("sources").flat_map { |source| source.fetch("evidence") }
          validation_rows = Array(validation.dig("payload", "commands")).map do |row|
            "- #{row.fetch('identity')}: exit #{row.fetch('exit_status')}"
          end
          body = <<~MD
            ## Patrol Fix

            This pull request repairs one finding tracked by Hive's Patrol Fix workflow.

            ### Sources

            #{sources.join("\n")}

            ### Finding evidence

            #{evidence.map { |value| "- #{value}" }.join("\n")}

            ### Independent review

            #{review.dig("payload", "rationale")}

            #{Array(review.dig("payload", "evidence")).map { |value| "- #{value}" }.join("\n")}

            ### Validation

            Verdict: #{validation.dig("payload", "verdict")}
            #{validation_rows.join("\n")}
          MD
          bounded_utf8(body, MAX_BODY_BYTES)
        end
        private_class_method :body_for

        def bounded_utf8(value, limit)
          text = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
          return text if text.bytesize <= limit

          text.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub("?")
        end
        private_class_method :bounded_utf8

        def current_publication(store, folder)
          manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
          store.read_all.find do |row|
            current?(row, manifest) && row["kind"] == "publication" && row["stage"] == "publish"
          end
        end
        private_class_method :current_publication

        def current?(receipt, manifest)
          receipt.fetch("task") == manifest.fetch("task") &&
            receipt.fetch("evidence_revision") == manifest.fetch("evidence_revision")
        end
        private_class_method :current?

        def current_owner(task, worktree_root, payload)
          manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
          owner = Hive::PatrolFix::WorktreeReceipt.new(
            task_folder: task.folder, project_root: task.project_root,
            slug: task.slug, worktree_root: worktree_root
          ).read
          generation = manifest.dig("task", "generation")
          expected_path = Hive::Worktree.new(
            task.project_root, "#{task.slug}-patrol-fix-g#{generation}",
            worktree_root: worktree_root
          ).path
          expected = [
            generation, manifest.dig("evidence_revision", "digest"),
            payload.fetch("creation_base_revision"), payload.fetch("branch"),
            expected_path
          ]
          actual = owner.values_at(
            "generation", "evidence_digest", "base_revision", "branch", "worktree"
          )
          unless actual == expected
            raise Hive::StageError, "publication cleanup custody is stale"
          end
          owner
        end
        private_class_method :current_owner

        def cleanup_after_receipt(task, cleanup, worktree_root, payload)
          owner = current_owner(task, worktree_root, payload)
          cleaner = cleanup || lambda do |current_task, current_owner|
            Hive::AgentGitGate.remove_materialization(
              repository_path: current_task.project_root,
              destination: current_owner.fetch("worktree"),
              destination_root: File.dirname(current_owner.fetch("worktree"))
            )
          end
          cleaner.call(task, owner)
        rescue StandardError
          diagnostic = {
            "schema" => "hive-patrol-fix-publication-diagnostic",
            "schema_version" => 1, "code" => "cleanup_failed",
            "summary" => "The pull request is durable; controller-owned worktree cleanup failed.",
            "recorded_at" => Time.now.utc.iso8601(6)
          }
          begin
            Hive::AtomicFile.write(
              File.join(task.folder, DIAGNOSTIC_FILENAME),
              JSON.generate(diagnostic.sort.to_h) + "\n", mode: 0o600
            )
          rescue StandardError
            # Publication authority is already durable. Even diagnostic
            # storage failure cannot make the stage non-terminal.
            nil
          end
        end
        private_class_method :cleanup_after_receipt

        def write_pr_metadata!(folder, payload)
          body = <<~MD
            ---
            pr_url: #{payload.fetch("url")}
            pr_number: #{payload.fetch("number")}
            head_oid: #{payload.fetch("head_revision")}
            publication_id: #{payload.fetch("publication_id")}
            hosted_state: #{payload.fetch("state")}
            ---

            ## Summary
            Exact Patrol Fix publication recorded by Hive.
          MD
          Hive::AtomicFile.write(File.join(folder, "pr.md"), body, mode: 0o600)
        end
        private_class_method :write_pr_metadata!

        def default_git_gateway(cfg)
          Hive::GithubPublication::GitGateway.new(
            cfg: cfg,
            allow_local_transport: cfg.dig("agent_git_gate", "allow_local_transport") == true
          )
        end
        private_class_method :default_git_gateway

        def complete(receipt)
          {
            status: :complete, commit: "patrol-fix pull request published",
            receipt: receipt, pr_url: receipt.dig("payload", "url")
          }
        end
        private_class_method :complete
      end
    end
  end
end

Hive::PatrolFix::Runner.register("publish", Hive::Stages::PatrolFix::Publish.method(:run!))
