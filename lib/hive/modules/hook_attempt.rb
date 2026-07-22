require "digest"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    # Immutable admission identity for one module hook and occurrence. It has
    # the shape consumed by Attempts::Dispatcher, while carrying an explicit
    # module-hook subject in attempt schema v3.
    HookAttempt = Data.define(
      :task_id, :project, :task_slug, :intended_stage, :task_locator,
      :progress_token, :task_generation, :ownership_generation,
      :task_input_epoch, :subject, :argv, :execution_snapshot, :run_id
    ) do
      def self.build(project:, project_id:, module_name:, hook:, selection:,
                     configuration:, event:)
        generation = selection.fetch("active")
        config_digest = generation.fetch("configuration_digest")
        grant_digest = ::Digest::SHA256.hexdigest(canonical(configuration.grants))
        occurrence_id = event.fetch("event_id")
        subject = {
          "kind" => "module_hook", "project_id" => project_id.to_s,
          "module" => module_name.to_s, "hook" => hook.fetch("id"),
          "event_id" => event.fetch("event_id"),
          "occurrence_id" => occurrence_id,
          "event_name" => event.fetch("event_name"),
          "module_generation" => generation.fetch("source_commit"),
          "configuration_digest" => config_digest,
          "grant_digest" => grant_digest
        }
        task_generation = ::Digest::SHA256.hexdigest(
          [ "hive-module-hook-v1", canonical(subject) ].join("\0")
        )
        target = hook.fetch("target")
        argv = [
          "hive", "__module-hook", module_name.to_s, hook.fetch("id"),
          "--project", project.to_s,
          "--event-id", event.fetch("event_id"), "--target-kind", target.fetch("kind"),
          "--target", target.fetch("id"), "--generation", generation.fetch("source_commit"),
          "--configuration-digest", config_digest, "--run-id", task_generation
        ]
        run_id = task_generation
        new(
          task_id: nil, project: project.to_s,
          task_slug: "module-#{module_name}-#{hook.fetch('id')}-#{occurrence_id[0, 12]}",
          intended_stage: "module-hook", task_locator: "module:#{module_name}/#{hook.fetch('id')}",
          progress_token: occurrence_id, task_generation: task_generation,
          ownership_generation: "#{selection.fetch('epoch')}:#{generation.fetch('source_commit')}",
          task_input_epoch: selection.fetch("epoch"), subject: subject.freeze,
          argv: argv.freeze,
          execution_snapshot: {
            "descriptor" => hook,
            "configuration" => configuration.to_h,
            "grants" => configuration.grants
          }.freeze,
          run_id: run_id
        )
      end

      def retry(retry_charge)
        charge = Integer(retry_charge)
        raise ArgumentError, "module retry charge must be positive" unless charge.positive?
        generation = ::Digest::SHA256.hexdigest(
          [ "hive-module-hook-retry-v1", run_id, charge ].join("\0")
        )
        self.class.new(
          task_id: task_id, project: project,
          task_slug: "#{task_slug}-retry-#{charge}", intended_stage: intended_stage,
          task_locator: task_locator, progress_token: progress_token,
          task_generation: generation, ownership_generation: ownership_generation,
          task_input_epoch: task_input_epoch, subject: subject, argv: argv,
          execution_snapshot: execution_snapshot, run_id: run_id
        )
      end

      def self.canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end
      private_class_method :canonical
    end
  end
end
