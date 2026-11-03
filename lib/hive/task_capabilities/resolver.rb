require "hive/task_capabilities/approval"
require "hive/task_capabilities/admission"
require "hive/config"
require "hive/workflow_package/configuration"

module Hive
  module TaskCapabilities
    # Preview and capture use this deterministic resolver; task reads use Store.
    class Resolver
      Resolution = Data.define(:plan, :approvals, :preview)
      INPUT_KEYS = %i[selections qa_waiver_reason qa_waiver_checks approval_references task_text task_labels repository_paths changed_paths].freeze
      NOTICE = "New coding tasks now pin optional capabilities. UI needs an installed compatible named skill and executor. Security needs an operator-written exact-route approval and enforceable local scope. QA defaults On: configure a real behavior check, or record a separate human QA waiver with reason and affected checks for every task. There is no standing project waiver. See wiki/modules/task_capabilities.md for prerequisites.".freeze
      attr_reader :catalog, :policy, :configuration_digest

      def initialize(workflow:, cfg:, project_root: nil, source: {}, configuration_digest: nil)
        @workflow = workflow
        @cfg = Hive::WorkflowPackage::CanonicalJSON.normalize(cfg)
        @project_root = project_root
        @source = source
        settings = @cfg.fetch("task_capabilities", {})
        @catalog = Catalog.new(workflow: workflow, definitions: settings.fetch("catalog", []))
        @policy = Policy.new(settings.fetch("policy", {}), catalog: catalog, approvals: settings.fetch("approvals", {}))
        @configuration_digest = configuration_digest || digest(@cfg)
      end

      def preview(selections: [], qa_waiver_reason: nil, qa_waiver_checks: [], approval_references: [], task_text: "", task_labels: [], repository_paths: [], changed_paths: [])
        unless task_text.is_a?(String) && [ task_labels, repository_paths, changed_paths ].all? { |values| values.is_a?(Array) && values.all? { |value| value.is_a?(String) } }
          invalid!("capability signals require task text and arrays of labels or paths")
        end
        explicit = pairs(selections, choices: true)
        references = pairs(approval_references)
        validate_waiver!(explicit, qa_waiver_reason, qa_waiver_checks)
        references.each { |id, reference| invalid!("unknown approval reference #{reference.inspect} for #{id}") unless policy.approvals.key?(reference) }
        inputs = catalog.definitions.to_h { |definition| [ definition.id, explicit.fetch(definition.id, "automatic") ] }
        matches = policy.matches(task_text: task_text, task_labels: task_labels, repository_paths: repository_paths, changed_paths: changed_paths)
        choices = {}
        blockers = []
        recommendations = []
        catalog.definitions.each do |definition|
          id = definition.id
          input = inputs.fetch(id)
          signals = matches.select { |match| match.fetch("capability") == id }.flat_map { |match| match.fetch("signals") }
          automatic = id == "qa" || (id != "security" && (policy.required?(id) || !signals.empty?))
          effective = input == "automatic" ? (automatic ? "on" : "off") : input
          provenance = input != "automatic" ? "explicit" : (policy.required?(id) && id != "security" ? "hard-policy" : (!signals.empty? && id != "security" ? "policy-signal" : "default"))
          choices[id] = { "input" => input, "effective" => effective, "source" => provenance,
                          "reason" => selection_reason(id, input, effective, provenance), "signals" => signals,
                          "state" => policy.required?(id) && effective == "off" ? "blocked" : (id == "qa" && effective == "off" ? "waived" : "pending") }
          recommendations << { "id" => id, "reason" => "UI guidance is recommended; select an installed compatible skill to use it", "signals" => signals } if id == "ui" && effective == "off" && input == "automatic"
          block(blockers, id, "policy_conflict", "#{id} is required by project policy; change the selection or ask the project owner to reconcile policy") if policy.required?(id) && effective == "off"
        end
        references.each do |id, reference|
          unless choices.fetch(id).fetch("effective") == "on" && policy.approvals.fetch(reference).fetch("capability") == id
            invalid!("approval #{reference.inspect} must authorize the same selected capability #{id.inspect}")
          end
        end
        selected = choices.select { |_id, choice| choice.fetch("effective") == "on" }.keys
        ordered = composition(selected, blockers)
        bindings = ordered.map { |definition, stage| binding(definition, stage, references, blockers, automatic: inputs.fetch(definition.id) == "automatic") }
        waivers = []
        if inputs["qa"] == "off"
          checks = planned_checks(catalog.fetch("qa"))
          ids = checks.map { |check| check.fetch("id") }
          unless qa_waiver_checks == [ "all" ] || (ids - qa_waiver_checks).empty? && (qa_waiver_checks - ids).empty? && !ids.empty?
            invalid!("QA Off must acknowledge all planned affected checks (#{ids.join(', ')}), or use all")
          end
          if policy.required?("qa")
            choices.fetch("qa")["requested_waiver"] = { "reason" => Hive::SecretPatterns.redact(qa_waiver_reason), "checks" => qa_waiver_checks }
          else
            waivers << { "capability" => "qa", "reason" => Hive::SecretPatterns.redact(qa_waiver_reason), "checks" => qa_waiver_checks, "state" => "waived", "source" => "task-creator" }
          end
        end
        result = Plan.redact({ "configuration_digest" => configuration_digest, "catalog_digest" => catalog.digest,
          "inputs" => inputs, "choices" => choices, "bindings" => bindings, "waivers" => waivers,
          "recommendations" => recommendations, "blockers" => blockers,
          "approval_references" => references, "policy" => policy.to_h,
          "input_digest" => digest({ "selections" => selections, "qa_waiver_reason" => qa_waiver_reason,
            "qa_waiver_checks" => qa_waiver_checks, "approval_references" => approval_references,
            "task_text" => task_text, "task_labels" => task_labels,
            "repository_paths" => repository_paths, "changed_paths" => changed_paths }) })
        result["preview_digest"] = digest(result)
        Definition.deep_freeze(result)
      end

      def self.operator_authorization?(inputs)
        inputs[:qa_waiver_reason] || !Array(inputs[:approval_references]).empty? ||
          Array(inputs[:selections]).any? { |value| %w[qa=off security=on].include?(value) }
      end

      def resolve(task_identity:, expected_preview: nil, **inputs)
        Admission.authorize_operator! if self.class.operator_authorization?(inputs)
        preview = preview(**inputs)
        if expected_preview && expected_preview != preview.fetch("preview_digest")
          raise Admission::Error.new("capability selections or configuration changed; refresh the preview before creating the task", reason: "task_capability_stale_preview")
        end
        approvals = preview.fetch("approval_references").map do |_id, reference|
          Approval.new(reference: reference, envelope: policy.approvals.fetch(reference)).blob(task_identity: task_identity)
        end
        data = Plan.minimal(task_identity: task_identity, catalog: catalog, source: @source.merge("selection_input_digest" => preview.fetch("input_digest")), policy: policy.to_h, configuration_digest: configuration_digest).to_h.merge(
          preview.slice("inputs", "choices", "bindings", "waivers", "recommendations", "blockers"),
          "approvals" => approvals.map { |value| { "digest" => digest(value) } }
        )
        Resolution.new(plan: Plan.new(data), approvals: approvals, preview: preview)
      end

      private

      def digest(value) = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(value))
      def invalid!(message) = raise(Admission::Error.new(message, reason: "task_capability_invalid_selection"))

      def pairs(value, choices: false)
        invalid!("capability inputs must be repeatable ID=VALUE strings") unless value.is_a?(Array)
        value.each_with_object({}) do |entry, result|
          invalid!("capability input must be ID=VALUE") unless entry.is_a?(String) && entry.count("=") == 1
          id, input = entry.split("=", 2)
          invalid!("unknown capability #{id.inspect}") unless catalog.definitions.any? { |definition| definition.id == id }
          invalid!("duplicate capability input #{id.inspect}") if result.key?(id)
          invalid!("#{id} must be automatic, on or off") if choices && !%w[automatic on off].include?(input)
          invalid!("empty capability approval reference") if input.nil? || input.empty?
          result[id] = input
        end
      end

      def validate_waiver!(explicit, reason, checks)
        invalid!("QA waiver checks must be a unique array of check IDs or all") unless checks.is_a?(Array) && checks.all? { |id| id.is_a?(String) && Definition::ID.match?(id) } && checks.uniq == checks && (!checks.include?("all") || checks == [ "all" ])
        if explicit["qa"] == "off"
          invalid!("QA Off requires a nonempty waiver reason and affected check IDs (or all)") unless reason.is_a?(String) && !reason.strip.empty? && !checks.empty?
        elsif reason || !checks.empty?
          invalid!("QA waiver details require explicit qa=off")
        end
      end

      def selection_reason(id, input, effective, provenance)
        return "explicit task creator selection: #{input}" if input != "automatic"
        return "security Automatic never executes; explicit On and exact approval are required" if id == "security"
        return "project hard policy requires #{id}" if provenance == "hard-policy"
        return "project UI selection policy matched recorded signals" if provenance == "policy-signal"
        effective == "on" ? "QA defaults On and requires behavior verification" : "available on explicit selection"
      end

      def block(blockers, id, reason, message, phase: "dispatch")
        entry = { "capability" => id, "reason" => "task_capability_#{reason}", "message" => message, "phase" => phase }
        blockers << entry unless blockers.include?(entry)
      end

      def composition(selected, blockers)
        @workflow.stages.flat_map do |stage|
          catalog.ordered(selected, stage: stage.name).map { |definition| [ definition, stage.name ] }
        end
      rescue Hive::ConfigError => error
        block(blockers, "composition", "blocked", error.message)
        []
      end

      def planned_checks(definition)
        return definition.checks unless definition.id == "qa" && definition.checks.empty?
        checks = []
        command = @cfg.dig("review", "ci", "command")
        checks << { "id" => "ci", "kind" => "behavior", "claim" => "configured repository behavior checks", "command" => command, "provider" => "ci", "depends_on" => [] } if command.is_a?(String) && !command.strip.empty?
        checks << { "id" => "browser", "kind" => "behavior", "claim" => "configured browser behavior checks", "provider" => "browser", "depends_on" => [] } if @cfg.dig("review", "browser_test", "enabled") == true
        checks
      end

      def binding(definition, stage, references, blockers, automatic:)
        data = definition.to_h
        result = data.merge("stage" => stage, "definition_digest" => definition.fingerprint, "checks" => planned_checks(definition))
        if definition.id == "security" || references.key?(definition.id)
          reference = references[definition.id]
          if !reference
            block(blockers, definition.id, "approval_required", "security On requires an operator-written exact-route approval; supply --capability-approval security=REFERENCE")
          else
            approval = Approval.new(reference: reference, envelope: policy.approvals.fetch(reference))
            request = approval.envelope.merge(data.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").reject { |key, value| key == "targets" && value.empty? })
            request["capability"] = definition.id
            unless approval.covers?(request)
              block(blockers, definition.id, "approval_scope", "security binding exceeds its approved actor, tools, targets, budget or timeout; obtain an exact covering operator approval")
            end
            result = result.merge(request.reject { |key, _| key == "capability" }, "approval_reference" => reference)
            if !route_available?(result.fetch("actor"))
              block(blockers, definition.id, "route_unavailable", "approved security route is unavailable; restore the approved route, or archive/cancel the task without finalization", phase: "finalization")
            end
          end
        end
        if definition.kind == "guidance"
          pin_guidance(definition, result, blockers, automatic: automatic)
        elsif result.fetch("checks").empty? || (definition.id == "qa" && result.fetch("checks").none? { |check| check["kind"] == "behavior" })
          block(blockers, definition.id, "verification_unavailable", "#{definition.id} has no usable behavior verification plan; configure real checks#{definition.id == 'qa' ? ' or record a separate operator QA exception with qa=off, a reason and all affected checks' : ''}")
        else
          result.fetch("checks").each do |check|
            usable = check["command"].is_a?(String) && !check["command"].strip.empty? || check["provider"] == "browser" && @cfg.dig("review", "browser_test", "enabled") == true || result["actor"]
            block(blockers, definition.id, "verification_unavailable", "#{definition.id}/#{check['id']} runner unavailable; configure its command or an enforceable actor route") unless usable
          end
        end
        if result["actor"]
          result["actor_fingerprint"] = Hive::WorkflowPackage::Configuration.profile_fingerprint(
            Hive::AgentProfiles.lookup(result.fetch("actor").fetch("profile"), cfg: @cfg))
        end
        result
      end

      def pin_guidance(definition, result, blockers, automatic:)
        stage = @workflow.stage_named(result.fetch("stage"))
        unless Admission.guidance_stage_supported?(@workflow, stage.name)
          block(blockers, definition.id, "blocked", "selected guidance #{definition.id} has no execution attachment at #{stage.name}; bind it to plan or execute")
        end
        resource = { "execute" => "execute_implementation", "review" => "review_ci" }.fetch(stage.name, stage.name)
        inherited_permissions = stage.permissions || Hive::Config.permission_spec(@cfg, stage.name)
        inherited_budget = @cfg.dig("budget_usd", resource) || stage.budget_usd || Hive::Config::DEFAULTS.dig("budget_usd", resource)
        inherited_timeout = @cfg.dig("timeout_sec", resource) || stage.timeout_sec || Hive::Config::DEFAULTS.dig("timeout_sec", resource)
        result["permissions"] ||= inherited_permissions
        result["budget_usd"] ||= inherited_budget
        result["timeout_sec"] ||= inherited_timeout
        if automatic && definition.id == "ui" &&
            (result["budget_usd"] > inherited_budget || result["timeout_sec"] > inherited_timeout ||
             !guidance_scope_within?(result["permissions"], inherited_permissions))
          block(blockers, definition.id, "policy_conflict", "automatic UI selection exceeds existing stage authority or resource bounds; explicitly accept a permitted execution-plan selection")
        end
        if definition.id == "ui" || result["skill"]
          result["skill_identity"] = Admission.skill_identity(result, project_root: @project_root, cfg: @cfg)
        elsif result["actor"] && definition.instruction_path
          result["instruction_content"] = File.binread(definition.instruction_path)
        else
          block(blockers, definition.id, "blocked", "selected guidance #{definition.id} requires an exact actor and installed skill or pinned instruction")
        end
        if result["actor"] && !route_available?(result.fetch("actor"))
          block(blockers, definition.id, "blocked", "selected #{definition.id} executor is unavailable; restore its exact configured route or change the execution plan")
        end
      rescue Admission::Error => error
        block(blockers, result.fetch("id"), "missing_skill", error.message)
      end

      def guidance_scope_within?(requested, inherited)
        if bounded_scope?(requested) && bounded_scope?(inherited)
          return Approval.permissions_within?(requested, inherited)
        end
        baseline = guidance_scope(inherited)
        return true if baseline.fetch(:preset) == "yolo"
        candidate = guidance_scope(requested)
        return false if candidate.fetch(:preset) == "yolo"
        return false if baseline.fetch(:bounded) && !candidate.fetch(:bounded) && (candidate.fetch(:tools) & %w[Bash WebFetch]).any?
        candidate.fetch(:tools).all? do |rule|
          baseline.fetch(:tools).include?(rule) || baseline.fetch(:tools).include?(Hive::PermissionScope.tool_name(rule))
        end && directories_within?(candidate.fetch(:dirs), baseline.fetch(:dirs))
      rescue Hive::ConfigError
        false
      end

      def bounded_scope?(spec) = spec.is_a?(Hash) && !spec.key?("preset")

      def guidance_scope(spec)
        if bounded_scope?(spec)
          Hive::WorkflowPackage::RuntimePolicy.validate_spec!(spec)
          return { preset: nil, bounded: true, tools: spec.fetch("tools", []) - spec.fetch("deny", []), dirs: spec.fetch("directories", []) }
        end
        scope, parsed = Hive::PermissionScope.resolve_managed_spec(spec, task_folder: "/", stage: "capability automatic selection")
        tools = parsed["tools"] || scope.allowed_tools || []
        { preset: parsed.fetch("preset"), bounded: false, tools: tools.map(&:strip), dirs: parsed.fetch("dirs", []) }
      end

      def directories_within?(requested, inherited)
        normalize = lambda do |path|
          absolute = File.absolute_path?(path) || path.start_with?("~")
          [ absolute, absolute ? File.expand_path(path) : Pathname.new(path).cleanpath.to_s ]
        end
        allowed = inherited.map(&normalize)
        requested.all? do |raw|
          absolute, path = normalize.call(raw)
          (!absolute && path != ".." && !path.start_with?("../")) ||
            allowed.any? { |kind, root| kind == absolute && (path == root || path.start_with?(root + File::SEPARATOR)) }
        end
      end

      def route_available?(actor)
        binary = Hive::AgentProfiles.lookup(actor.fetch("profile"), cfg: @cfg).bin
        binary.include?(File::SEPARATOR) ? File.executable?(binary) : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |directory| File.executable?(File.join(directory, binary)) }
      end
    end
  end
end
