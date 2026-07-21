require "pathname"
require "set"
require "hive/permission_scope"
require "hive/workflow_package/registry_manifest"

module Hive
  module WorkflowPackage
    # Pure projection of exact Hive actor policies into Honeycomb's coarse,
    # conservative manifest disclosure. This mirrors the v1 registry contract
    # without executing descriptor content or consulting a checkout.
    module PermissionProjection
      READ_TOOLS = %w[Glob Grep LS Read].freeze
      WRITE_TOOLS = %w[Edit MultiEdit NotebookEdit Write].freeze
      NETWORK_TOOLS = %w[WebFetch WebSearch].freeze
      KNOWN_TOOLS = (READ_TOOLS + WRITE_TOOLS + NETWORK_TOOLS + [ "Bash" ]).freeze
      UNSUPPORTED_FILE_RULES = Hive::PermissionScope::UNMATCHED_FILE_RULE_REPLACEMENTS.freeze
      RISK_ORDER = { "low" => 0, "moderate" => 1, "high" => 2 }.freeze
      PROJECT_ROOT_DIR = "../../../..".freeze

      module_function

      def derive!(descriptor)
        unless descriptor.is_a?(Hash) && descriptor["stages"].is_a?(Array)
          fail!("workflow descriptor must contain a stages array")
        end
        union = empty_union
        descriptor["stages"].each_with_index do |stage, index|
          fail!("workflow stage #{index + 1} must be a map") unless stage.is_a?(Hash)
          merge_actor!(union, stage, "stage #{index + 1}") if %w[agent council].include?(stage["kind"])
          Array(stage["reviewers"]).each_with_index do |actor, reviewer_index|
            merge_actor!(union, actor, "stage #{index + 1} reviewer #{reviewer_index + 1}")
          end
          revise = stage.dig("council", "revise")
          merge_actor!(union, revise, "stage #{index + 1} revise") if revise
        end
        finalize(union)
      end

      def merge_actor!(union, actor, label)
        fail!("#{label} must be a map") unless actor.is_a?(Hash)
        fail!("#{label} must declare permissions") unless actor.key?("permissions")
        contribution = normalize_scope!(actor["permissions"], label)
        union[:risk] = contribution[:risk] if RISK_ORDER.fetch(contribution[:risk]) > RISK_ORDER.fetch(union[:risk])
        %i[capabilities network_hosts filesystem_read filesystem_write secrets].each do |key|
          union[key].merge(contribution.fetch(key))
        end
      end

      def normalize_scope!(spec, label)
        normalized = case spec
        when String then { "preset" => spec }
        when Hash
          fail!("#{label} permission keys must be strings") unless spec.keys.all?(String)
          spec
        else
          fail!("#{label} permissions must be an explicit preset or map")
        end
        preset = normalized["preset"]
        fail!("#{label} permission preset is unsupported") unless %w[yolo read-only scoped].include?(preset)
        allowed = preset == "scoped" ? %w[preset tools dirs bash] : [ "preset" ]
        fail!("#{label} permissions contain unknown fields") unless (normalized.keys - allowed).empty?

        case preset
        when "yolo" then unbounded
        when "read-only" then bounded_read
        when "scoped" then normalize_scoped!(normalized, label)
        end
      end

      def normalize_scoped!(spec, label)
        if spec.key?("tools") == spec.key?("bash")
          fail!("#{label} scoped permissions require exactly one of tools or bash")
        end
        dirs = normalize_dirs!(spec.fetch("dirs", []), label)
        if spec.key?("bash")
          fail!("#{label} bash must be boolean") unless [ true, false ].include?(spec["bash"])
          return spec["bash"] ? unbounded : bounded_read(dirs)
        end
        tools = spec["tools"]
        unless tools.is_a?(Array) && !tools.empty? && tools.all? { |tool| tool.is_a?(String) && !tool.empty? }
          fail!("#{label} scoped tools must be a non-empty string array")
        end
        rules = tools.map { |rule| normalize_tool_rule!(rule, label) }
        return unbounded if rules.any? { |rule| rule.fetch(:tool) == "Bash" }

        contribution = empty_union.merge(label: label)
        rules.each do |rule|
          tool = rule.fetch(:tool)
          path = rule[:path]
          if path && tool == "Read"
            contribution[:capabilities] << "filesystem-read"
            contribution[:filesystem_read] << path
          elsif path && tool == "Edit"
            contribution[:risk] = "moderate"
            contribution[:capabilities] << "filesystem-write"
            contribution[:filesystem_write] << path
          elsif READ_TOOLS.include?(tool)
            contribution[:capabilities] << "filesystem-read"
            contribution[:filesystem_read].merge([ "task", *dirs ])
          elsif WRITE_TOOLS.include?(tool)
            contribution[:risk] = "moderate"
            contribution[:capabilities] << "filesystem-write"
            contribution[:filesystem_write].merge([ "task", *dirs ])
          elsif NETWORK_TOOLS.include?(tool)
            contribution[:risk] = "high"
            contribution[:capabilities] << "network"
            contribution[:network_hosts] << "*"
          end
        end
        contribution
      end

      def normalize_tool_rule!(value, label)
        match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(value)
        fail!("#{label} contains a malformed tool rule") unless match
        tool = match[:tool]
        fail!("#{label} contains an unsupported permission-bearing tool") unless KNOWN_TOOLS.include?(tool)
        path = match[:specifier]
        if path && UNSUPPORTED_FILE_RULES.key?(tool)
          fail!("#{label} uses an unenforced #{tool}(path) rule; use #{UNSUPPORTED_FILE_RULES.fetch(tool)}(path)")
        end
        path = normalize_scope_path(path) if path
        fail!("#{label} contains a non-portable tool path") if match[:specifier] && path.nil?
        { tool: tool, path: path }
      end

      def normalize_dirs!(dirs, label)
        fail!("#{label} dirs must be an array") unless dirs.is_a?(Array)
        dirs.map do |path|
          normalized = normalize_scope_path(path)
          fail!("#{label} contains a non-portable directory") unless normalized
          normalized
        end.sort.uniq
      end

      def normalize_scope_path(value)
        return unless value.is_a?(String) && !value.empty? && value == value.strip
        return if value.include?("\0") || value.include?("\\") || Pathname.new(value).absolute?
        return if value.start_with?("~") || value.match?(/\A[A-Za-z]:\//)
        return "repository" if value == PROJECT_ROOT_DIR
        if value.start_with?("#{PROJECT_ROOT_DIR}/")
          relative = value.delete_prefix("#{PROJECT_ROOT_DIR}/")
          return if unsafe_segments?(relative)
          return "repository/#{relative}"
        end
        return if value.split("/").include?("..")
        clean = Pathname.new(value).cleanpath.to_s
        return if clean != value && !value.start_with?("./")
        clean == "." ? "task" : "task/#{clean.delete_prefix('./')}"
      end

      def unsafe_segments?(value)
        segments = value.split("/")
        segments.empty? || segments.any? { |segment| segment.empty? || %w[. ..].include?(segment) } ||
          Pathname.new(value).cleanpath.to_s != value
      end

      def bounded_read(extra = [])
        empty_union.merge(
          risk: "low", capabilities: Set["filesystem-read"],
          filesystem_read: Set.new(%w[repository task] + extra)
        )
      end

      def unbounded
        {
          risk: "high", capabilities: Set.new(RegistryManifest::CAPABILITIES),
          network_hosts: Set["*"], filesystem_read: Set["*"],
          filesystem_write: Set["*"], secrets: Set["*"]
        }
      end

      def empty_union
        {
          risk: "low", capabilities: Set.new, network_hosts: Set.new,
          filesystem_read: Set.new, filesystem_write: Set.new, secrets: Set.new
        }
      end

      def finalize(union)
        {
          "risk" => union.fetch(:risk),
          "capabilities" => canonical_set(union.fetch(:capabilities)),
          "network_hosts" => canonical_set(union.fetch(:network_hosts)),
          "filesystem_read" => canonical_set(union.fetch(:filesystem_read)),
          "filesystem_write" => canonical_set(union.fetch(:filesystem_write)),
          "secrets" => canonical_set(union.fetch(:secrets))
        }.freeze
      end

      def canonical_set(values) = values.include?("*") ? [ "*" ] : values.to_a.sort.freeze

      def fail!(message) = raise(Hive::ConfigError, "workflow permission projection failed: #{message}")
    end
  end
end
