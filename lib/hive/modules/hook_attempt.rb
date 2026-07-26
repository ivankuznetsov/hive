require "digest"
require "hive/modules/target_executor"
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
                     configuration:, event:, package_root: nil)
        generation = selection.fetch("active")
        config_digest = generation.fetch("configuration_digest")
        source_commit = generation.fetch("source_commit")
        unless configuration.digest == config_digest &&
               configuration.generation.fetch("name") == module_name.to_s &&
               configuration.generation.fetch("source_commit") == source_commit
          raise Hive::ConfigError, "module hook configuration identity does not match selection"
        end
        subject = subject_for(
          project_id: project_id, module_name: module_name, hook: hook,
          module_generation: source_commit, configuration: configuration, event: event
        )
        task_generation = run_id_for(subject)
        occurrence_id = event.fetch("event_id")
        target = hook.fetch("target")
        argv = argv_for(
          project: project, module_name: module_name, hook_id: hook.fetch("id"),
          event_id: event.fetch("event_id"), target: target,
          module_generation: source_commit, configuration_digest: config_digest,
          run_id: task_generation
        )
        run_id = task_generation
        ownership_generation = "#{selection.fetch('epoch')}:#{source_commit}"
        task_input_epoch = selection.fetch("epoch")
        target_snapshot = Hive::Modules::TargetExecutor.capture_snapshot(
          target: target, configuration: configuration, package_root: package_root
        )
        new(
          task_id: nil, project: project.to_s,
          task_slug: "module-#{module_name}-#{hook.fetch('id')}-#{occurrence_id[0, 12]}",
          intended_stage: "module-hook", task_locator: "module:#{module_name}/#{hook.fetch('id')}",
          progress_token: occurrence_id, task_generation: task_generation,
          ownership_generation: ownership_generation,
          task_input_epoch: task_input_epoch, subject: subject.freeze,
          argv: argv.freeze,
          execution_snapshot: {
            "schema_version" => 1, "subject" => subject,
            "descriptor" => hook, "target" => target_snapshot,
            "configuration" => configuration.to_h,
            "grants" => configuration.grants,
            "ownership_generation" => ownership_generation,
            "task_input_epoch" => task_input_epoch
          }.freeze,
          run_id: run_id
        )
      end

      def self.subject_for(project_id:, module_name:, hook:, module_generation:,
                           configuration:, event:)
        {
          "kind" => "module_hook", "project_id" => project_id.to_s,
          "module" => module_name.to_s, "hook" => hook.fetch("id"),
          "event_id" => event.fetch("event_id"),
          "occurrence_id" => event.fetch("event_id"),
          "event_name" => event.fetch("event_name"),
          "module_generation" => module_generation.to_s,
          "configuration_digest" => configuration.digest,
          "grant_digest" => ::Digest::SHA256.hexdigest(canonical(configuration.grants))
        }
      end

      def self.argv_for(project:, module_name:, hook_id:, event_id:, target:,
                        module_generation:, configuration_digest:, run_id:)
        [
          "hive", "__module-hook", module_name.to_s, hook_id.to_s,
          "--project", project.to_s, "--event-id", event_id.to_s,
          "--target-kind", target.fetch("kind"), "--target", target.fetch("id"),
          "--generation", module_generation.to_s,
          "--configuration-digest", configuration_digest.to_s, "--run-id", run_id.to_s
        ]
      end

      def self.run_id_for(subject)
        ::Digest::SHA256.hexdigest(
          [ "hive-module-hook-v1", canonical(subject) ].join("\0")
        )
      end

      def self.validate_execution_snapshot!(snapshot)
        expected = %w[
          configuration descriptor grants ownership_generation schema_version
          subject target task_input_epoch
        ]
        valid = snapshot.is_a?(Hash) && snapshot.keys.sort == expected &&
          snapshot["schema_version"] == 1 &&
          %w[configuration descriptor grants subject target].all? { |key| snapshot[key].is_a?(Hash) } &&
          snapshot["ownership_generation"].is_a?(String) &&
          snapshot["task_input_epoch"].is_a?(Integer) && snapshot["task_input_epoch"] >= 0
        raise Hive::ConfigError, "module hook execution snapshot is malformed" unless valid

        subject = snapshot.fetch("subject")
        subject_keys = %w[
          configuration_digest event_id event_name grant_digest hook kind module
          module_generation occurrence_id project_id
        ]
        target = snapshot.fetch("target")
        descriptor = snapshot.fetch("descriptor")
        target_keys = case target.fetch("kind", nil)
        when "entrypoint" then %w[id kind]
        when "command" then %w[argv id kind]
        when "workflow" then %w[descriptor files id kind]
        else []
        end
        valid = subject.keys.sort == subject_keys && subject["kind"] == "module_hook" &&
          subject_keys.grep_v("kind").all? { |key| subject[key].is_a?(String) && !subject[key].empty? } &&
          %w[configuration_digest grant_digest].all? { |key| /\A[0-9a-f]{64}\z/.match?(subject[key]) } &&
          %w[entrypoint workflow command].include?(target["kind"]) &&
          target["id"].is_a?(String) && !target["id"].empty? &&
          target.keys.sort == target_keys &&
          descriptor["id"] == subject["hook"] && descriptor["target"] == target.slice("kind", "id") &&
          snapshot["ownership_generation"] ==
            "#{snapshot.fetch('task_input_epoch')}:#{subject.fetch('module_generation')}" &&
          !snapshot.fetch("configuration").empty? && !snapshot.fetch("grants").empty?
        raise Hive::ConfigError, "module hook execution snapshot is malformed" unless valid

        true
      rescue KeyError, TypeError
        raise Hive::ConfigError, "module hook execution snapshot is malformed"
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
