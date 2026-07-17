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
    FILE_EDIT_TOOLS = %w[Write Edit MultiEdit NotebookEdit].freeze
    UNMATCHED_FILE_RULE_REPLACEMENTS = {
      "Write" => "Edit",
      "MultiEdit" => "Edit",
      "NotebookEdit" => "Edit",
      "LS" => "Read",
      "Grep" => "Read",
      "Glob" => "Read"
    }.freeze

    # Claude permission rules are either a bare tool name or one path/command
    # specifier in parentheses (for example `Edit(./docs/**)`). Hive keeps the
    # accepted form deliberately whitespace/comma-free because tool_csv emits
    # one comma-separated argv value.
    TOOL_RULE_PATTERN = /\A(?<tool>[A-Za-z][A-Za-z0-9_.:*-]*)(?:\((?<specifier>[^(),\s\x00]+)\))?\z/

    # The read-only permission mode. "default" (not plan mode, which would
    # change agent behavior) combines with the explicit mutating/shell deny
    # list while preserving ordinary read behavior.
    NON_PROMPTING_PERMISSION_MODE = "default".freeze

    # Path-qualified allow rules need a default-deny fallback: without it, an
    # out-of-scope edit would become an interactive prompt and strand a
    # headless stage. `dontAsk` executes matching allow rules and rejects any
    # remaining permission request non-interactively.
    SCOPED_PERMISSION_MODE = "dontAsk".freeze

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
        permission_mode: SCOPED_PERMISSION_MODE
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
      # lists. `Struct.new` exposes a public `new`; it is made private below
      # (private_class_method :new) so `build` is the ONLY way to construct a
      # Scope and the invariants can't be bypassed. The result — and its
      # tool/dir member arrays — is frozen so the validated state (including
      # the disjoint allow/deny lists) can't be mutated in place after the
      # fact to reintroduce an overlap.
      def self.build(preset:, permission_mode:, allowed_tools:, disallowed_tools:, add_dirs_extra:)
        validate_invariants!(preset, permission_mode, allowed_tools, disallowed_tools, add_dirs_extra)
        new(
          preset: preset,
          permission_mode: permission_mode,
          allowed_tools: allowed_tools&.freeze,
          disallowed_tools: disallowed_tools&.freeze,
          add_dirs_extra: add_dirs_extra.freeze
        ).freeze
      end
      private_class_method :new

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

        # A non-yolo scope MUST grant at least one tool. tool_csv emits no
        # --allowedTools flag for an empty list, so an empty allowed_tools
        # would silently grant nothing (defense-in-depth: validate_tools!
        # already requires a non-empty tools: list upstream).
        if Array(allowed_tools).empty?
          raise ArgumentError,
                "non-yolo scope #{preset.inspect} requires a non-empty allowed_tools list; " \
                "an empty list would emit no --allowedTools and silently grant nothing"
        end

        # Claude's deny rules win over allow rules, so the lists MUST be
        # disjoint or a granted tool would be silently denied.
        overlap = Array(allowed_tools) & Array(disallowed_tools)
        unless overlap.empty?
          raise ArgumentError,
                "scope #{preset.inspect} would both grant and deny #{overlap.inspect}; " \
                "deny rules win, so the allow and deny lists must be disjoint"
        end

        granted_names = Array(allowed_tools).flat_map { |rule| PermissionScope.granted_tool_names(rule) }
        denied_names = Array(disallowed_tools).filter_map { |rule| PermissionScope.tool_name(rule) }
        semantic_overlap = granted_names & denied_names
        return if semantic_overlap.empty?

        raise ArgumentError,
              "scope #{preset.inspect} would grant and deny tools #{semantic_overlap.inspect}; " \
              "deny rules win, so a path-qualified Edit allow cannot retain a file-edit deny"
      end
    end

    module_function

    def validate!(spec, stage: nil)
      parsed = parse_spec(spec, stage: stage)
      # Push the parse-time check TOWARD resolve so a `scoped` block's `dirs:`
      # that can never resolve (an unknown `~user`, e.g. `~nouser/x`, raises
      # ArgumentError in resolve_dirs) is rejected at LOAD/parse time, not only
      # when the stage runs and stamps an attributed :error marker. A relative
      # dir needs a task folder to fully resolve, but only `~user`/type errors
      # raise — and those don't depend on the task folder — so a placeholder root
      # surfaces them. (The non-`claude` profile mismatch can't be checked here,
      # since the profile is a run-time choice; resolve still fails closed on it.)
      if parsed.fetch("preset") == "scoped"
        normalize_tools(parsed["tools"], task_folder: "/", stage: stage) if parsed.key?("tools")
        resolve_dirs(parsed["dirs"], task_folder: "/", stage: stage) if parsed.key?("dirs")
      end
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

    # Build the `--allowedTools` / `--disallowedTools` CSV from a tool list.
    #
    # Param contract — accepts CSV String | Array | nil. Two historical
    # representations both feed Claude's `allowed_tools:`/`disallowed_tools:`
    # params and converge here: the `*_ALLOWED_TOOLS` constants
    # (ClaudeLauncher) are pre-joined CSV Strings, while
    # PermissionScope::Scope#allowed_tools is an Array. Both work because
    # `Array("Read,LS") → ["Read,LS"] → "Read,LS"` is idempotent on an
    # already-joined CSV String and an Array round-trips normally. Caveat: a
    # CSV String is treated as ONE element, so duplicates/blanks INSIDE it are
    # not split out — only Array entries are deduped/blank-dropped. Prefer
    # passing Arrays.
    #
    # Blank entries are dropped and duplicates are collapsed (first
    # occurrence wins) so a user `tools: [Read, Read]` list — or any other
    # accidental repeat — can't reach Claude's argv twice. Order is preserved:
    # it is the single chokepoint for both tool lists, and a stable, deduped
    # order keeps the emitted argv byte-identical across runs for golden-arg
    # tests.
    def tool_csv(tools)
      values = Array(tools).compact.map(&:to_s).reject(&:empty?).uniq
      return nil if values.empty?

      values.join(",")
    end

    def tool_name(rule)
      TOOL_RULE_PATTERN.match(rule.to_s)&.[](:tool)
    end

    def granted_tool_names(rule)
      match = TOOL_RULE_PATTERN.match(rule.to_s)
      return [] unless match
      return FILE_EDIT_TOOLS if match[:tool] == "Edit" && match[:specifier]

      [ match[:tool] ]
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
        unless (tool.is_a?(String) || tool.is_a?(Symbol)) && !tool.to_s.strip.empty?
          raise invalid_spec(stage, original, "tools[#{idx}] must be a non-empty String")
        end

        # A tool entry is ONE element to the allow/deny disjointness
        # invariant, but Claude splits a comma-bearing value (`"Read,Write"`)
        # into several tools and never matches a whitespace-mangled name —
        # either way silently re-denying the tool the operator meant to grant,
        # with no operator-visible error. A NUL additionally crashes
        # Process.spawn (mirrors validate_dirs!'s null-byte guard). Real
        # Claude tool names carry none of these, so reject them. (Surrounding
        # whitespace is checked post-strip, matching normalize_tools, which
        # strips it on the resolve path.)
        stripped = tool.to_s.strip
        if stripped.match?(/[,\s]/) || stripped.include?("\0")
          raise invalid_spec(stage, original,
                             "tools[#{idx}] #{tool.inspect} must be a single tool name " \
                             "without commas, whitespace, or null bytes")
        end
        match = TOOL_RULE_PATTERN.match(stripped)
        unless match
          raise invalid_spec(stage, original,
                             "tools[#{idx}] #{tool.inspect} is a malformed permission rule; " \
                             "expected Tool or Tool(non-empty-specifier)")
        end
        if match[:specifier] && (replacement = UNMATCHED_FILE_RULE_REPLACEMENTS[match[:tool]])
          raise invalid_spec(stage, original,
                             "tools[#{idx}] #{tool.inspect} is unsupported; Claude does not enforce " \
                             "#{match[:tool]}(path), use #{replacement}(path) instead")
        end
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

    def build_scope(preset)
      data = PRESETS.fetch(preset)
      Scope.build(
        preset: preset,
        permission_mode: data.fetch(:permission_mode),
        allowed_tools: data[:allowed_tools]&.dup,
        disallowed_tools: data[:disallowed_tools]&.dup,
        # yolo/read-only presets never carry `dirs:`, so the extra add-dir
        # list is always empty here (scoped is the only preset that resolves
        # dirs, via scoped_scope).
        add_dirs_extra: []
      )
    end

    def scoped_scope(spec, task_folder:, stage:)
      allowed = if spec.key?("tools")
        normalize_tools(spec.fetch("tools"), task_folder: task_folder, stage: stage)
      else
        tools = READ_ONLY_ALLOWED.dup
        tools << "Bash" if spec["bash"] == true
        tools
      end
      granted_names = allowed.flat_map { |rule| granted_tool_names(rule) }.uniq
      Scope.build(
        preset: "scoped",
        permission_mode: SCOPED_PERMISSION_MODE,
        allowed_tools: allowed,
        # Subtract the granted tools so the deny list never overlaps the
        # allow list. Claude's deny rules take precedence over allow rules,
        # so emitting a granted tool (e.g. Write/Edit/Bash) in BOTH lists
        # would deny it despite the explicit `tools:`/`bash:` grant —
        # silently breaking `scoped`'s entire purpose.
        disallowed_tools: READ_ONLY_DISALLOWED.reject do |denied|
          granted_names.include?(denied)
        end,
        add_dirs_extra: resolve_dirs(spec["dirs"], task_folder: task_folder, stage: stage)
      )
    end

    # `tools` arrived via parse_spec → validate_scoped! → validate_tools! on
    # the resolve path. Bare rules pass through after trimming. Read/Edit path
    # rules are descriptor-portable and task-relative, so resolve them to the
    # double-slash absolute syntax Claude's permission matcher requires.
    def normalize_tools(tools, task_folder:, stage:)
      tools.map do |tool|
        rule = tool.to_s.strip
        match = TOOL_RULE_PATTERN.match(rule)
        next rule unless match && match[:specifier] && %w[Read Edit].include?(match[:tool])

        path = match[:specifier]
        expanded = File.absolute_path?(path) ? File.expand_path(path) : File.expand_path(path, task_folder)
        "#{match[:tool]}(#{claude_absolute_permission_path(expanded)})"
      rescue ArgumentError, TypeError => e
        raise invalid_spec(stage, rule, "tool path could not be resolved (#{e.message})")
      end
    end

    # Claude normalizes Windows paths to POSIX drive syntax before matching
    # permission rules (`C:\\Users` -> `/c/Users`). CLI absolute rules add one
    # more leading slash, so emit `//c/Users` on Windows and `//tmp/...` on
    # Unix. File.expand_path normally returns forward slashes on Windows, but
    # `tr` also keeps overridden/custom Ruby path implementations safe.
    def claude_absolute_permission_path(path)
      normalized = path.tr("\\", "/")
      normalized = normalized.sub(/\A([A-Za-z]):/) { "/#{Regexp.last_match(1).downcase}" }
      "//#{normalized.sub(%r{\A/+}, "")}"
    end

    def resolve_dirs(dirs, task_folder:, stage:)
      # `dirs` arrived via parse_spec, which already ran validate_scoped! →
      # validate_dirs! on the resolve path (non-blank, null-byte-free
      # Strings), so no re-validation here — but File.expand_path still
      # raises ArgumentError on an un-expandable `~user` (e.g. "~nouser/x")
      # and TypeError on a non-String. Re-raise those as a typed
      # Hive::ConfigError so the U10-4 fail-closed contract holds:
      # stage_permission_scope_or_mark! / Review.run! rescue ConfigError and
      # stamp an attributed :error marker instead of letting a bare crash
      # strand the stage's AGENT_WORKING / REVIEW_WORKING marker (a hang).
      Array(dirs).map do |dir|
        raw = dir.to_s
        File.absolute_path?(raw) ? File.expand_path(raw) : File.expand_path(raw, task_folder)
      rescue ArgumentError, TypeError => e
        raise invalid_spec(stage, raw, "dirs entry could not be resolved (#{e.message})")
      end
    end

    def invalid_spec(stage, value, detail)
      label = stage ? "stage #{stage} permissions" : "permissions"
      Hive::ConfigError.new("#{label} #{value.inspect} is invalid: #{detail}")
    end
  end
end
