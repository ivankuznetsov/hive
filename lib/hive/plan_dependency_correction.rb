require "digest"
require "json"
require "securerandom"
require "shellwords"
require "time"
require "hive/atomic_file"
require "hive/task_meta"

module Hive
  # Controller-owned durable state for bounded plan-dependency correction.
  #
  # Records per-invocation initial-plan correction reservation/exhaustion,
  # per-review revision correction reservation/exhaustion, and controller
  # diagnostics for previously cleared invalid plans. Written under task
  # custody BEFORE spawning any correction so a crash, restart, poll, or mtime
  # change conservatively leaves the single correction allowance spent.
  #
  # Intentionally lightweight so Hive::Recovery (loaded early) can read its
  # closed reason constant and predicates without loading plan-review runtime.
  module PlanDependencyCorrection
    SCHEMA = "hive-plan-dependency-correction".freeze
    SCHEMA_VERSION = 1
    FILENAME = "plan-dependency-correction.json".freeze
    EXHAUSTED_REASON = "plan_dependency_correction_exhausted".freeze
    MAX_JSON_BYTES = 256 * 1024

    module_function

    def path(task_folder)
      File.join(task_folder.to_s, FILENAME)
    end

    def marker_exhausted?(attrs)
      return false unless attrs.respond_to?(:[])

      (attrs["reason"] || attrs[:reason]).to_s == EXHAUSTED_REASON
    end

    def plan_review_exhausted?(plan_review)
      return false unless plan_review.is_a?(Hash)
      return false unless plan_review["state"].to_s == "blocked"

      Array(plan_review["blockers"]).any? do |blocker|
        blocker.is_a?(Hash) && blocker["reason"].to_s == EXHAUSTED_REASON
      end
    end

    def exhausted_row?(marker_attrs: nil, plan_review: nil)
      marker_exhausted?(marker_attrs) || plan_review_exhausted?(plan_review)
    end

    def remediation(attrs = {})
      message = attrs.respond_to?(:[]) ? (attrs["message"] || attrs[:message]).to_s.strip : ""
      return message unless message.empty?

      "plan dependency automatic correction was exhausted; repair depends_on in plan.md " \
        "using full task slugs and rerun with `hive plan <slug> --project <project> --from 3-plan`"
    end

    def repair_command(task)
      project = resolved_project_name(task)
      parts = [ "hive", "plan", task.slug.to_s ]
      parts.concat([ "--project", project ]) if project && !project.empty?
      parts.concat([ "--from", "3-plan" ]) # coding-scoped: root plan repair command targets the coding 3-plan stage
      parts.shelljoin
    end

    def resolved_project_name(task)
      if task.respond_to?(:project_root) && !task.project_root.to_s.empty?
        expanded = File.expand_path(task.project_root.to_s)
        registered = Array(Hive::Config.registered_projects).find do |entry|
          entry.is_a?(Hash) && entry["path"] && File.expand_path(entry["path"].to_s) == expanded
        end
        return registered["name"].to_s if registered && !registered["name"].to_s.empty?
      end
      if task.respond_to?(:project_name) && !task.project_name.to_s.empty?
        return task.project_name.to_s
      end
      return File.basename(task.project_root.to_s) if task.respond_to?(:project_root) && !task.project_root.to_s.empty?

      nil
    rescue StandardError
      task.respond_to?(:project_name) ? task.project_name.to_s : nil
    end
    private_class_method :resolved_project_name

    def exhausted_message(task:, validation:)
      detail = if validation
        "#{validation.reason_code}: #{validation.offending_ref}; #{validation.safe_correction}"
      else
        "plan.md depends_on remained invalid after automatic correction"
      end
      "plan dependency correction exhausted (#{detail}); Hive will not retry automatically. " \
        "Repair with `#{repair_command(task)}`."
    end

    def exhausted_action(task:, validation:)
      "repair invalid depends_on (#{validation&.offending_ref || 'plan.md'}) and rerun with `#{repair_command(task)}`"
    end

    def read(task_folder)
      file = path(task_folder)
      stat = File.lstat(file)
      return corrupt_state unless stat.file? && !stat.symlink?

      bytes = File.binread(file, MAX_JSON_BYTES + 1)
      return corrupt_state if bytes.bytesize > MAX_JSON_BYTES

      data = JSON.parse(bytes)
      return corrupt_state unless data.is_a?(Hash) && data["schema"] == SCHEMA &&
                                  data["schema_version"] == SCHEMA_VERSION

      data
    rescue Errno::ENOENT
      empty_state
    rescue JSON::ParserError, SystemCallError, IOError
      corrupt_state
    end

    def empty_state
      {
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "initial" => nil,
        "revisions" => {},
        "cleared_plan_diagnostic" => nil
      }
    end

    def corrupt_state
      empty_state.merge("corrupt" => true)
    end

    def start_explicit_invocation!(task_folder, observation:, existing_diagnostic: nil,
                                   clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      state = empty_state if state["corrupt"]
      invocation_id = "inv-#{SecureRandom.hex(16)}"
      state["initial"] = {
        "invocation_id" => invocation_id,
        "explicit_repair" => true,
        "input_digest" => existing_diagnostic&.plan_digest,
        "correction_used" => false,
        "exhausted" => false,
        "diagnostic" => serialize_diagnostic(existing_diagnostic),
        "updated_at" => clock.call.utc.iso8601(6)
      }
      state["cleared_plan_diagnostic"] = nil
      write_state!(task_folder, state, observation: observation)
      invocation_id
    end

    def initial_exhausted?(task_folder)
      state = read(task_folder)
      return true if state["corrupt"]

      state.dig("initial", "exhausted") == true
    end

    # Reserve the single automatic correction allowance for an initial plan
    # invocation BEFORE spawning the correction attempt. Returns false if the
    # allowance is already spent or exhausted, preventing retries/restarts/
    # crashes from granting extra spawns.
    def reserve_initial_correction!(task_folder, observation:, invocation_id:,
                                    input_digest:, diagnostic:, clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      return false if state["corrupt"]

      initial = state["initial"]
      if initial.is_a?(Hash)
        return false if initial["exhausted"] == true
        return false if initial["correction_used"] == true
      end

      state["initial"] = {
        "invocation_id" => invocation_id.to_s,
        "explicit_repair" => initial.is_a?(Hash) ? initial["explicit_repair"] == true : false,
        "input_digest" => input_digest,
        "correction_used" => true,
        "exhausted" => false,
        "diagnostic" => serialize_diagnostic(diagnostic),
        "updated_at" => clock.call.utc.iso8601(6)
      }
      write_state!(task_folder, state, observation: observation)
      true
    end

    def mark_initial_exhausted!(task_folder, observation:, invocation_id:,
                                input_digest:, diagnostic:, clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      state = empty_state if state["corrupt"]
      existing = state["initial"].is_a?(Hash) ? state["initial"] : {}
      state["initial"] = existing.merge(
        "invocation_id" => (existing["invocation_id"] || invocation_id).to_s,
        "input_digest" => input_digest,
        "correction_used" => true,
        "exhausted" => true,
        "diagnostic" => serialize_diagnostic(diagnostic),
        "updated_at" => clock.call.utc.iso8601(6)
      )
      write_state!(task_folder, state, observation: observation)
      state["initial"]
    end

    def clear_initial_resolved!(task_folder, observation:, invocation_id:,
                                clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      return unless File.exist?(path(task_folder))

      state = read(task_folder)
      return if state["corrupt"]

      state["initial"] = {
        "invocation_id" => invocation_id.to_s,
        "explicit_repair" => false,
        "input_digest" => nil,
        "correction_used" => false,
        "exhausted" => false,
        "diagnostic" => nil,
        "updated_at" => clock.call.utc.iso8601(6)
      }
      state["cleared_plan_diagnostic"] = nil
      write_state!(task_folder, state, observation: observation)
    end

    def record_cleared_plan_diagnostic!(task_folder, observation:, plan_digest:,
                                        diagnostic:, clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      state = empty_state if state["corrupt"]
      state["cleared_plan_diagnostic"] = {
        "plan_digest" => plan_digest,
        "diagnostic" => serialize_diagnostic(diagnostic),
        "recorded_at" => clock.call.utc.iso8601(6)
      }
      write_state!(task_folder, state, observation: observation)
      state["cleared_plan_diagnostic"]
    end

    def revision_state(task_folder, scope_key:)
      state = read(task_folder)
      return { "corrupt" => true, "correction_used" => true, "exhausted" => true } if state["corrupt"]

      revisions = state["revisions"]
      revisions.is_a?(Hash) ? revisions[scope_key.to_s] : nil
    end

    def reserve_revision_correction!(task_folder, observation:, review_id:, scope_key:,
                                     input_digest:, diagnostic:, clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      return false if state["corrupt"]

      revisions = state["revisions"].is_a?(Hash) ? state["revisions"].dup : {}
      existing = revisions[scope_key.to_s]
      if existing.is_a?(Hash) && (existing["correction_used"] == true || existing["exhausted"] == true)
        return false
      end

      revisions[scope_key.to_s] = {
        "review_id" => review_id.to_s,
        "scope_key" => scope_key.to_s,
        "input_digest" => input_digest,
        "correction_used" => true,
        "exhausted" => false,
        "diagnostic" => serialize_diagnostic(diagnostic),
        "updated_at" => clock.call.utc.iso8601(6)
      }
      state["revisions"] = revisions
      write_state!(task_folder, state, observation: observation)
      true
    end

    def mark_revision_exhausted!(task_folder, observation:, review_id:, scope_key:,
                                 input_digest:, diagnostic:, clock: -> { Time.now.utc })
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      state = read(task_folder)
      state = empty_state if state["corrupt"]
      revisions = state["revisions"].is_a?(Hash) ? state["revisions"].dup : {}
      revisions[scope_key.to_s] = {
        "review_id" => review_id.to_s,
        "scope_key" => scope_key.to_s,
        "input_digest" => input_digest,
        "correction_used" => true,
        "exhausted" => true,
        "diagnostic" => serialize_diagnostic(diagnostic),
        "updated_at" => clock.call.utc.iso8601(6)
      }
      state["revisions"] = revisions
      write_state!(task_folder, state, observation: observation)
      revisions[scope_key.to_s]
    end

    def format_prompt_diagnostic(validation)
      return "" unless validation

      data = validation.respond_to?(:to_h) ? validation.to_h : validation
      return "" unless data.is_a?(Hash)

      lines = []
      lines << "Reason: #{data['reason_code']}" if data["reason_code"]
      lines << "Offending declaration: #{data['offending_ref']}" if data["offending_ref"]
      unless data["current_depends_on"].nil?
        lines << "Current authoritative meta.yml depends_on: #{JSON.generate(data['current_depends_on'])}"
      end
      issues = Array(data["issues"])
      unless issues.empty?
        lines << "Issues:"
        issues.each do |issue|
          idx = issue["index"].nil? ? "declaration" : "index #{issue['index']}"
          suggestion = issue["suggestion"] ? " (optional suggestion, verify before using: #{issue['suggestion']})" : ""
          lines << "- [#{idx}] #{issue['display_value']}: #{issue['message']}#{suggestion}"
        end
      end
      lines << "Required correction: #{data['safe_correction']}" if data["safe_correction"]
      lines << "Rules: Use full task slugs (never task-code shorthand like C4, F2, F3), numeric IDs, or <project>:<full-slug>. Do not edit meta.yml."
      lines.join("\n")
    end

    def serialize_diagnostic(diagnostic)
      return nil if diagnostic.nil?

      diagnostic.respond_to?(:to_h) ? diagnostic.to_h : diagnostic
    end
    private_class_method :serialize_diagnostic

    def write_state!(task_folder, state, observation: nil)
      Hive::TaskMeta.validate_observation!(task_folder, observation) if observation
      file = path(task_folder)
      Hive::AtomicFile.write(file, "#{JSON.pretty_generate(state)}\n", mode: 0o600)
      File.chmod(0o600, file)
      Hive::AtomicFile.fsync_directory(task_folder)
    end
    private_class_method :write_state!
  end
end
