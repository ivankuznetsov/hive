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
    # the intended set. `read-only` denies the static READ_ONLY_DISALLOWED
    # set; `scoped` derives its deny list from READ_ONLY_DISALLOWED with the
    # granted tools subtracted out (see scoped_scope) so its two lists never
    # overlap — Claude's deny rules win, so a tool in both would be denied
    # despite being granted. Do not use plan mode here; it changes agent
    # behavior.
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

    # Accepted keys per preset, enforced by validate_keys!. `scoped`'s key
    # set is ALSO referenced by validate_scoped!, which enforces the
    # semantics of those keys (types, the tools-XOR-bash rule, the
    # needs-tools-or-bash requirement). Keep the two declarations in sync: a
    # key added here without a matching validate_scoped! rule (or vice versa)
    # would silently drift — one would accept it while the other ignores it.
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

      # The single validated construction site. Both factories (build_scope
      # for the yolo/read-only presets, scoped_scope for scoped) route
      # through here, so the core invariants are enforced at construction
      # rather than only inside those factories — a future third
      # construction site can't silently reintroduce a deny-wins-over-grant
      # overlap (the bug fixed in b6a0c72b) or a yolo scope that carries tool
      # lists. The result is frozen so the validated state can't be mutated
      # after the fact.
      def self.build(preset:, permission_mode:, allowed_tools:, disallowed_tools:, add_dirs_extra:)
        validate_invariants!(preset, permission_mode, allowed_tools, disallowed_tools, add_dirs_extra)
        new(
          preset: preset,
          permission_mode: permission_mode,
          allowed_tools: allowed_tools,
          disallowed_tools: disallowed_tools,
          add_dirs_extra: add_dirs_extra
        ).freeze
      end

      def self.validate_invariants!(preset, permission_mode, allowed_tools, disallowed_tools, add_dirs_extra)
        unless add_dirs_extra.is_a?(Array)
          raise ArgumentError, "add_dirs_extra must be an Array, got #{add_dirs_extra.inspect}"
        end

        if preset == YOLO
          # yolo is the no-scoping preset: Claude receives no tool lists.
          unless permission_mode == "bypassPermissions" && allowed_tools.nil? && disallowed_tools.nil?
            raise ArgumentError,
                  "yolo scope must carry bypassPermissions and nil tool lists; got " \
                  "mode=#{permission_mode.inspect} allowed=#{allowed_tools.inspect} " \
                  "disallowed=#{disallowed_tools.inspect}"
          end
          return
        end

        raise ArgumentError, "non-yolo scope #{preset.inspect} requires a permission_mode" if permission_mode.nil?

        # Claude's deny rules win over allow rules, so the lists MUST be
        # disjoint or a granted tool would be silently denied.
        overlap = Array(allowed_tools) & Array(disallowed_tools)
        return if overlap.empty?

        raise ArgumentError,
              "scope #{preset.inspect} would both grant and deny #{overlap.inspect}; " \
              "deny rules win, so the allow and deny lists must be disjoint"
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
      when YOLO, "read-only"
        # Both presets are pure pass-throughs of their PRESETS entry, so the
        # preset name itself selects the data — no need to restate it twice.
        build_scope(parsed.fetch("preset"))
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

    # Enforce the `scoped` preset's shape. The SET of accepted keys is
    # declared in MAP_KEYS["scoped"] (and checked by validate_keys!); this
    # method enforces their SEMANTICS — types, the tools-XOR-bash rule, and
    # the "scoped requires tools: or bash:" requirement. Keep both in sync
    # (see MAP_KEYS).
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
      Scope.build(
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
      Scope.build(
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

    # `tools` arrived via parse_spec → validate_scoped! → validate_tools! on
    # the resolve path, so entries are already non-blank Strings; this only
    # strips surrounding whitespace. It does NOT dedup or reject
    # blank-after-strip — that is deferred to tool_csv (the emit chokepoint),
    # which drops blanks and collapses duplicates. A direct caller that
    # bypasses validate_tools! gets those unguarded entries.
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
