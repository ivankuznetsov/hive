module Hive
  module PermissionScope
    # The "no scoping" preset name. Extracted so the comparisons in
    # `resolve`, `Scope#yolo?`, and `Config::DEFAULTS["permissions"]` all
    # reference one symbol instead of restating the bare "yolo" literal.
    YOLO = "yolo".freeze

    # read-only is intentionally narrow: local file inspection only.
    # Network and MCP tools are not included in allowed_tools; mutating
    # and shell tools are also denied explicitly for clearer Claude errors.
    # `scoped` derives its OWN deny list from this set minus whatever it
    # grants (see scoped_scope): Claude's deny rules win over allow rules,
    # so a tool may never appear in both lists or it would be denied
    # despite being granted.
    READ_ONLY_ALLOWED = %w[Read LS Grep Glob].freeze
    READ_ONLY_DISALLOWED = %w[Write Edit MultiEdit NotebookEdit Bash].freeze

    # Non-yolo scopes rely on allowedTools/disallowedTools to pre-approve
    # the intended set. The disallow list is always READ_ONLY_DISALLOWED
    # with the granted tools subtracted out, so it never overlaps (and thus
    # never silently overrides) the allow list. Do not use plan mode here;
    # it changes agent behavior.
    NON_PROMPTING_PERMISSION_MODE = "default".freeze

    PRESETS = {
      "yolo" => {
        permission_mode: "bypassPermissions",
        allowed_tools: nil,
        disallowed_tools: nil
      },
      "read-only" => {
        permission_mode: NON_PROMPTING_PERMISSION_MODE,
        allowed_tools: READ_ONLY_ALLOWED,
        disallowed_tools: READ_ONLY_DISALLOWED
      },
      "scoped" => {
        permission_mode: NON_PROMPTING_PERMISSION_MODE
      }
    }.freeze

    MAP_KEYS = {
      "yolo" => %w[preset],
      "read-only" => %w[preset],
      "scoped" => %w[preset tools dirs bash]
    }.freeze

    # Nullability is asymmetric by design: under `yolo`, `allowed_tools`
    # and `disallowed_tools` are both nil (Claude receives no tool lists),
    # while `add_dirs_extra` is always an Array (empty when no `dirs:` were
    # requested) so callers can splat it unconditionally.
    Scope = Struct.new(
      :preset,
      :permission_mode,
      :allowed_tools,
      :disallowed_tools,
      :add_dirs_extra,
      keyword_init: true
    ) do
      def yolo?
        preset == YOLO
      end
    end

    module_function

    def validate!(spec, stage: nil)
      parse_spec(spec, stage: stage)
      true
    end

    def resolve(spec, task_folder:, profile:, stage: nil)
      parsed = parse_spec(spec, stage: stage)
      profile_name = profile && profile.name
      if parsed.fetch("preset") != YOLO && profile_name != :claude
        raise Hive::ConfigError,
              "stage #{stage || '(unknown)'} requests permissions #{parsed.fetch('preset').inspect} " \
              "but runner #{profile_name.inspect} cannot enforce tool scoping (claude only)"
      end

      case parsed.fetch("preset")
      when YOLO
        build_scope(YOLO)
      when "read-only"
        build_scope("read-only")
      when "scoped"
        scoped_scope(parsed, task_folder: task_folder, stage: stage)
      end
    end

    # Build the `--allowedTools` / `--disallowedTools` CSV. Blank entries
    # are dropped and duplicates are collapsed (first occurrence wins) so a
    # user `tools: [Read, Read]` list — or any other accidental repeat —
    # can't reach Claude's argv twice. Order is preserved: it is the single
    # chokepoint for both tool lists, and a stable, deduped order keeps the
    # emitted argv byte-identical across runs for golden-arg tests.
    def tool_csv(tools)
      values = Array(tools).compact.map(&:to_s).reject(&:empty?).uniq
      return nil if values.empty?

      values.join(",")
    end

    def parse_spec(spec, stage:)
      normalized = normalize_spec(spec, stage: stage)
      preset = normalized.fetch("preset")
      unless PRESETS.key?(preset)
        raise invalid_spec(stage, spec, "unknown preset #{preset.inspect}; expected one of #{PRESETS.keys.inspect}")
      end

      validate_keys!(normalized, preset, stage: stage, original: spec)
      validate_scoped!(normalized, stage: stage, original: spec) if preset == "scoped"
      normalized
    end

    def normalize_spec(spec, stage:)
      case spec
      when nil
        # A present-but-blank `permissions:` (YAML key with no value → nil)
        # reaches here ONLY from a stage- or project-level scope the operator
        # explicitly declared (Config.permission_spec returns the YOLO default
        # for a fully-absent key, never nil). Treating it as yolo would
        # silently grant full permissions to someone who typed `permissions:`
        # intending to scope — the exact fail-open footgun this feature
        # guards against. Fail closed instead.
        raise invalid_spec(
          stage,
          spec,
          "permissions: is present but blank — an empty permissions block is rejected to " \
          "avoid silently granting full (yolo) access; remove the key to use the default, " \
          "or set an explicit preset (yolo/read-only/scoped)"
        )
      when String, Symbol
        name = spec.to_s
        raise invalid_spec(stage, spec, "preset cannot be blank") if name.strip.empty?

        { "preset" => name }
      when Hash
        stringify_keys(spec, stage: stage)
      else
        raise invalid_spec(stage, spec, "must be a preset string or a map with preset:")
      end
    end

    def stringify_keys(hash, stage:)
      hash.each_with_object({}) do |(key, value), out|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise invalid_spec(stage, hash, "contains non-string key #{key.inspect}")
        end

        out[key.to_s] = value
      end.tap do |out|
        unless out.key?("preset")
          raise invalid_spec(stage, hash, "map must include preset:")
        end
        unless out["preset"].is_a?(String) || out["preset"].is_a?(Symbol)
          raise invalid_spec(stage, hash, "preset must be a string")
        end

        out["preset"] = out["preset"].to_s
      end
    end

    def validate_keys!(normalized, preset, stage:, original:)
      allowed = MAP_KEYS.fetch(preset)
      unknown = normalized.keys - allowed
      return if unknown.empty?

      raise invalid_spec(stage, original, "unknown key(s) #{unknown.inspect} for #{preset.inspect}")
    end

    def validate_scoped!(normalized, stage:, original:)
      if normalized.key?("tools") && normalized.key?("bash")
        raise invalid_spec(stage, original, "bash: cannot be combined with tools:; express Bash via tools:")
      end

      validate_tools!(normalized["tools"], stage: stage, original: original) if normalized.key?("tools")
      validate_dirs!(normalized["dirs"], stage: stage, original: original) if normalized.key?("dirs")
      validate_bash!(normalized["bash"], stage: stage, original: original) if normalized.key?("bash")

      return if normalized.key?("tools") || normalized.key?("bash")

      raise invalid_spec(stage, original, "scoped requires tools: or bash:")
    end

    def validate_tools!(tools, stage:, original:)
      unless tools.is_a?(Array) && tools.any?
        raise invalid_spec(stage, original, "tools: must be a non-empty Array")
      end

      tools.each_with_index do |tool, idx|
        next if (tool.is_a?(String) || tool.is_a?(Symbol)) && !tool.to_s.strip.empty?

        raise invalid_spec(stage, original, "tools[#{idx}] must be a non-empty String")
      end
    end

    def validate_dirs!(dirs, stage:, original:)
      unless dirs.is_a?(Array)
        raise invalid_spec(stage, original, "dirs: must be an Array")
      end

      dirs.each_with_index do |dir, idx|
        next if (dir.is_a?(String) || dir.is_a?(Symbol)) && !dir.to_s.strip.empty? && !dir.to_s.include?("\0")

        raise invalid_spec(stage, original, "dirs[#{idx}] must be a non-empty String without null bytes")
      end
    end

    def validate_bash!(bash, stage:, original:)
      return if bash == true || bash == false

      raise invalid_spec(stage, original, "bash: must be true or false")
    end

    def build_scope(preset, add_dirs_extra: [])
      data = PRESETS.fetch(preset)
      Scope.new(
        preset: preset,
        permission_mode: data.fetch(:permission_mode),
        allowed_tools: data[:allowed_tools]&.dup,
        disallowed_tools: data[:disallowed_tools]&.dup,
        add_dirs_extra: add_dirs_extra
      )
    end

    def scoped_scope(spec, task_folder:, stage:)
      allowed = if spec.key?("tools")
        normalize_tools(spec.fetch("tools"))
      else
        tools = READ_ONLY_ALLOWED.dup
        tools << "Bash" if spec["bash"] == true
        tools
      end
      Scope.new(
        preset: "scoped",
        permission_mode: NON_PROMPTING_PERMISSION_MODE,
        allowed_tools: allowed,
        # Subtract the granted tools so the deny list never overlaps the
        # allow list. Claude's deny rules take precedence over allow rules,
        # so emitting a granted tool (e.g. Write/Edit/Bash) in BOTH lists
        # would deny it despite the explicit `tools:`/`bash:` grant —
        # silently breaking `scoped`'s entire purpose.
        disallowed_tools: READ_ONLY_DISALLOWED - allowed,
        add_dirs_extra: resolve_dirs(spec["dirs"], task_folder: task_folder, stage: stage)
      )
    end

    def normalize_tools(tools)
      tools.map { |tool| tool.to_s.strip }
    end

    def resolve_dirs(dirs, task_folder:, stage:)
      # `dirs` arrived via parse_spec, which already ran validate_scoped! →
      # validate_dirs! on the resolve path, so no re-validation here.
      Array(dirs).map do |dir|
        raw = dir.to_s
        File.absolute_path?(raw) ? File.expand_path(raw) : File.expand_path(raw, task_folder)
      end
    end

    def invalid_spec(stage, value, detail)
      label = stage ? "stage #{stage} permissions" : "permissions"
      Hive::ConfigError.new("#{label} #{value.inspect} is invalid: #{detail}")
    end
  end
end
