require "test_helper"
require "digest"
require "find"
require "ripper"
require "hive/cli"
require "hive/remote/command_policy"
require_relative "../support/wiki_command_index"

module DocsCliAuthority
  SUPPORT_CLASSES = %w[stable experimental maintenance deprecated visible_internal].freeze
  COVERAGE_STATES = %w[full checked_exception].freeze
  EVIDENCE_STATES = %w[
    top_level
    structured_synopsis
    registry_expanded_placeholder
    inline_help_and_dispatcher
    catalog_declared_with_exception
  ].freeze
  CONTEXT_POSTURES = %w[context_management supported_remote local_only].freeze
  ALLOWED_CATALOG_DECLARED_PARENTS = %w[context token].freeze
  SELECTOR_PLACEHOLDERS = %w[SUBCOMMAND ACTION SERVICE].freeze
  INHERITED_CLASS_OPTIONS = %w[--context --json].freeze

  Diagnostic = Struct.new(:kind, :subject, :detail, keyword_init: true) do
    def sort_key
      [ kind.to_s, subject.to_s, detail.to_s ]
    end

    def to_s
      [ kind, subject, detail ].compact.map(&:to_s).join(": ")
    end
  end

  OptionSpec = Struct.new(:switch, :type, :required, :repeatable, :hidden, keyword_init: true)
  Atom = Struct.new(:kind, :name, :value, :required, :repeatable, :rest, keyword_init: true) do
    def to_s
      case kind
      when :literal, :separator
        name
      when :operand
        token = rest ? "#{name}..." : name
        required ? token : "[#{token}]"
      when :option
        token = if value
          repeatable ? "#{name} #{value}..." : "#{name} #{value}"
        else
          name
        end
        required ? token : "[#{token}]"
      end
    end
  end

  Form = Struct.new(:atoms, keyword_init: true) do
    def canonical
      atoms.map(&:to_s).join(" ")
    end

    def option_switches
      atoms.select { |atom| atom.kind == :option }.map(&:name).uniq.sort
    end

    def operands
      atoms.select { |atom| atom.kind == :operand }
    end

    def literals
      atoms.select { |atom| atom.kind == :literal }.map(&:name)
    end
  end

  ModeSpec = Struct.new(:name, :condition, :required_options, :forbidden_options, :owner_evidence, keyword_init: true)
  RuntimeLeaf = Struct.new(
    :path, :top_level, :aliases, :evidence_state, :forms,
    :context_posture, :expected_modes, :forbidden_options, :owner_tail_check,
    keyword_init: true
  )
  RuntimeSurfaceData = Struct.new(
    :leaves, :visible_options_by_top_level, :hidden_commands, :hidden_options,
    :private_routes, :aliases, :diagnostics,
    keyword_init: true
  )

  CatalogMode = Struct.new(:name, :condition, :options, :details, keyword_init: true)
  CatalogException = Struct.new(:field, :evidence, :owner, :follow_up, keyword_init: true)
  CatalogLeaf = Struct.new(
    :path, :top_level, :aliases, :support, :coverage, :evidence, :exception,
    :context_posture, :signatures, :options, :output, :context_behavior,
    :exits_and_retry, :effects_and_approvals, :example, :modes, :raw_body,
    keyword_init: true
  )
  ExclusionEntry = Struct.new(:category, :name, :support, :source, :reason, keyword_init: true)
  CatalogData = Struct.new(:leaves, :exclusions, :diagnostics, keyword_init: true)
  AuditResult = Struct.new(:runtime, :catalog, :diagnostics, keyword_init: true) do
    def success?
      diagnostics.empty?
    end
  end

  class SignatureGrammar
    class ParseError < StandardError; end

    Token = Struct.new(:type, :value, :glued_left, :glued_right, keyword_init: true)
    SeqNode = Struct.new(:items, keyword_init: true)
    WordNode = Struct.new(:value, keyword_init: true)
    ChoiceNode = Struct.new(:branches, keyword_init: true)
    OptionalNode = Struct.new(:inner, keyword_init: true)

    def self.expand(text, options_by_switch:)
      new(text, options_by_switch: options_by_switch).expand
    end

    def initialize(text, options_by_switch:)
      @text = text.to_s.strip
      @options_by_switch = options_by_switch
    end

    def expand
      raise ParseError, "empty signature" if @text.empty?

      tokens = tokenize(@text)
      @tokens = tokens
      @pos = 0
      ast = parse_sequence(stop_tokens: [])
      raise ParseError, "unexpected trailing token #{@tokens[@pos].value.inspect}" if @pos < @tokens.length

      expand_node(ast, inside_optional: false).map do |raw_items|
        Form.new(atoms: resolve_atoms(raw_items)).freeze
      end
    end

    private

    def tokenize(input)
      tokens = []
      index = 0
      length = input.length

      while index < length
        ch = input[index]
        if ch.match?(/\s/)
          index += 1
          next
        end

        glued_left = index.positive? && !input[index - 1].match?(/\s/)
        case ch
        when "(", ")", "[", "]", "|"
          type = { "(" => :lparen, ")" => :rparen, "[" => :lbracket, "]" => :rbracket, "|" => :pipe }.fetch(ch)
          glued_right = (index + 1) < length && !input[index + 1].match?(/\s/)
          tokens << Token.new(type: type, value: ch, glued_left: glued_left, glued_right: glued_right)
          index += 1
        else
          start = index
          bracket_depth = 0
          while index < length
            c = input[index]
            if c == "["
              bracket_depth += 1
              index += 1
            elsif c == "]"
              break if bracket_depth.zero?

              bracket_depth -= 1
              index += 1
            elsif bracket_depth.zero? && (c.match?(/\s/) || "()|".include?(c))
              break
            else
              index += 1
            end
          end
          raise ParseError, "unbalanced inline bracket in #{input[start...index].inspect}" unless bracket_depth.zero?

          glued_right = index < length && !input[index].match?(/\s/)
          tokens << Token.new(type: :word, value: input[start...index], glued_left: glued_left, glued_right: glued_right)
        end
      end

      tokens
    end

    def parse_choice(stop_tokens:)
      branches = [ parse_sequence(stop_tokens: stop_tokens + [ :pipe ]) ]
      while peek && peek.type == :pipe
        consume(:pipe)
        branches << parse_sequence(stop_tokens: stop_tokens + [ :pipe ])
      end
      if branches.any? { |branch| branch.items.empty? }
        raise ParseError, "empty alternative in #{@text.inspect}"
      end

      branches.one? ? branches.first : ChoiceNode.new(branches: branches)
    end

    def parse_sequence(stop_tokens:)
      items = []
      while peek && !stop_tokens.include?(peek.type)
        items << parse_inline_choice(stop_tokens: stop_tokens)
      end
      SeqNode.new(items: items)
    end

    def parse_inline_choice(stop_tokens:)
      first = parse_primary
      return first unless peek && peek.type == :pipe && peek.glued_left && peek.glued_right && !stop_tokens.include?(:pipe)

      branches = [ SeqNode.new(items: [ first ]) ]
      while peek && peek.type == :pipe && peek.glued_left && peek.glued_right
        consume(:pipe)
        raise ParseError, "empty inline alternative in #{@text.inspect}" unless peek && !stop_tokens.include?(peek.type) && peek.type != :pipe

        branches << SeqNode.new(items: [ parse_primary ])
      end
      ChoiceNode.new(branches: branches)
    end

    def parse_primary
      token = peek
      raise ParseError, "unexpected end of signature #{@text.inspect}" unless token

      case token.type
      when :word
        consume(:word)
        WordNode.new(value: token.value)
      when :lparen
        consume(:lparen)
        inner = parse_choice(stop_tokens: [ :rparen ])
        raise ParseError, "unbalanced '(' in #{@text.inspect}" unless peek&.type == :rparen

        consume(:rparen)
        inner
      when :lbracket
        consume(:lbracket)
        inner = parse_choice(stop_tokens: [ :rbracket ])
        raise ParseError, "unbalanced '[' in #{@text.inspect}" unless peek&.type == :rbracket

        consume(:rbracket)
        OptionalNode.new(inner: inner)
      when :rparen, :rbracket
        raise ParseError, "unbalanced #{token.value.inspect} in #{@text.inspect}"
      when :pipe
        raise ParseError, "unexpected '|' in #{@text.inspect}"
      end
    end

    def peek
      @tokens[@pos]
    end

    def consume(expected)
      token = @tokens[@pos]
      raise ParseError, "expected #{expected}, got #{token&.type.inspect}" unless token && token.type == expected

      @pos += 1
      token
    end

    def expand_node(node, inside_optional:)
      case node
      when WordNode
        [ [ [ node.value, inside_optional ] ] ]
      when SeqNode
        results = [ [] ]
        node.items.each do |item|
          expanded = expand_node(item, inside_optional: inside_optional)
          results = results.flat_map { |prefix| expanded.map { |suffix| prefix + suffix } }
        end
        results
      when ChoiceNode
        node.branches.flat_map { |branch| expand_node(branch, inside_optional: inside_optional) }
      when OptionalNode
        if node.inner.is_a?(ChoiceNode)
          [ [] ] + expand_node(node.inner, inside_optional: false)
        else
          expand_node(node.inner, inside_optional: true)
        end
      end
    end

    def resolve_atoms(raw_items)
      atoms = []
      index = 0
      while index < raw_items.length
        word, optional = raw_items[index]
        if word == "--"
          atoms << Atom.new(kind: :separator, name: "--", required: !optional, repeatable: false, rest: false).freeze
          index += 1
        elsif word.start_with?("--")
          atom, consumed = resolve_option(raw_items, index)
          atoms << atom
          index += consumed
        else
          atoms << resolve_non_option(word, optional: optional)
          index += 1
        end
      end
      atoms.freeze
    end

    def resolve_option(raw_items, index)
      word, optional = raw_items[index]
      flag, attached = word.split("=", 2)
      spec = lookup_option(flag)
      raise ParseError, "undeclared option #{flag.inspect} in #{@text.inspect}" unless spec
      raise ParseError, "hidden option #{flag.inspect} in public signature #{@text.inspect}" if spec.hidden

      if spec.type == :boolean
        raise ParseError, "boolean option #{flag.inspect} does not accept value #{attached.inspect}" if attached

        atom = Atom.new(
          kind: :option, name: spec.switch, value: nil,
          required: !optional, repeatable: spec.repeatable, rest: false
        ).freeze
        return [ atom, 1 ]
      end

      raw_value, consumed = if attached
        raise ParseError, "empty option value for #{flag.inspect}" if attached.empty?

        [ attached, 1 ]
      else
        next_item = raw_items[index + 1]
        if !next_item || next_item[0] == "--" || next_item[0].start_with?("-")
          raise ParseError, "unbound option value for #{flag.inspect} in #{@text.inspect}"
        end

        [ next_item[0], 2 ]
      end

      repeatable = raw_value.end_with?("...")
      value_name = repeatable ? raw_value.delete_suffix("...") : raw_value
      if repeatable && !spec.repeatable && spec.type != :array
        raise ParseError, "option #{flag.inspect} is not repeatable in #{@text.inspect}"
      end
      raise ParseError, "malformed option value #{raw_value.inspect}" unless valid_operand?(value_name)

      atom = Atom.new(
        kind: :option, name: spec.switch, value: value_name,
        required: !optional, repeatable: repeatable, rest: false
      ).freeze
      [ atom, consumed ]
    end

    def lookup_option(flag)
      return @options_by_switch[flag] if @options_by_switch.key?(flag)
      return nil unless flag.start_with?("--no-", "--skip-")

      base = "--#{flag.sub(/\A--(?:no|skip)-/, "")}"
      candidate = @options_by_switch[base]
      candidate if candidate && candidate.type == :boolean
    end

    def resolve_non_option(word, optional:)
      rest = word.end_with?("...")
      base = rest ? word.delete_suffix("...") : word
      raise ParseError, "empty operand in #{@text.inspect}" if base.empty?

      if !rest && base.match?(/\A[a-z][a-z0-9_-]*\z/)
        Atom.new(kind: :literal, name: base, required: !optional, repeatable: false, rest: false).freeze
      elsif valid_operand?(base)
        Atom.new(kind: :operand, name: base, required: !optional, repeatable: false, rest: rest).freeze
      else
        raise ParseError, "unparsable signature token #{word.inspect} in #{@text.inspect}"
      end
    end

    def valid_operand?(token)
      token.match?(/\A<[A-Za-z0-9_-]+>\z/) ||
        token.match?(/\A[A-Z][A-Z0-9_]*\z/) ||
        token.match?(/\A[a-z0-9_-]+\/[A-Z][A-Z0-9_]*(?:\[@[A-Z][A-Z0-9_]*\])?\z/)
    end
  end

  class SourceEvidence
    def initialize(root:, overrides: {})
      @root = root
      @overrides = overrides
    end

    def read_file(relative)
      return @overrides[relative] if @overrides.key?(relative)

      File.read(File.join(@root, relative))
    end

    def method_sexp(relative, method_name)
      sexp = Ripper.sexp(read_file(relative))
      raise "could not parse #{relative}" unless sexp

      find_def(sexp, method_name.to_s) ||
        raise("missing method #{method_name} in #{relative}")
    end

    def pre_thor_routes
      sexp = Ripper.sexp(read_file("bin/hive"))
      raise "could not parse bin/hive" unless sexp

      routes = []
      walk(sexp) do |node|
        next unless node.is_a?(Array) && node[0] == :binary && node[2] == :==

        left, right = node[1], node[3]
        if argv_first?(left) && (literal = string_literal(right))
          routes << literal
        end
      end
      routes.uniq.sort
    end

    def when_string_literals(relative, method_name)
      body = method_sexp(relative, method_name)
      literals = []
      walk(body) do |node|
        next unless node.is_a?(Array) && node[0] == :when

        extract_strings(node[1], literals)
      end
      literals.uniq
    end

    def percent_w_arrays(relative, method_name)
      body = method_sexp(relative, method_name)
      arrays = []
      walk(body) do |node|
        next unless node.is_a?(Array) && node[0] == :array

        words = []
        ok = true
        Array(node[1]).each do |elem|
          str = string_literal(elem)
          if str
            words << str
          else
            ok = false
            break
          end
        end
        arrays << words if ok && words.any?
      end
      arrays
    end

    def method_calls_identifier?(relative, method_name, callee_name)
      body = method_sexp(relative, method_name)
      found = false
      walk(body) do |node|
        next unless node.is_a?(Array)

        if (node[0] == :vcall || node[0] == :fcall) && node[1].is_a?(Array) && node[1][1] == callee_name
          found = true
        elsif node[0] == :call && node[3].is_a?(Array) && node[3][1] == callee_name
          found = true
        end
      end
      found
    end

    def method_source_slice(relative, method_name)
      lines = read_file(relative).lines
      start_idx = lines.index { |line| line.match?(/\A(\s*)def #{Regexp.escape(method_name.to_s)}(?:\s|\(|$)/) }
      raise "missing def #{method_name} in #{relative}" unless start_idx

      indent = lines[start_idx][/\A(\s*)/, 1]
      end_idx = ((start_idx + 1)...lines.length).find { |i| lines[i].match?(/\A#{Regexp.escape(indent)}end\b/) }
      raise "unterminated def #{method_name} in #{relative}" unless end_idx

      lines[start_idx..end_idx].join
    end

    def receipt_when_branches
      body = method_sexp("lib/hive/commands/receipt.rb", "execute")
      branches = {}
      walk(body) do |node|
        next unless node.is_a?(Array) && node[0] == :when

        names = []
        extract_strings(node[1], names)
        has_req_id = false
        walk(node[2]) do |inner|
          next unless inner.is_a?(Array)

          if (inner[0] == :vcall || inner[0] == :fcall) && inner[1].is_a?(Array) && inner[1][1] == "required_identifier!"
            has_req_id = true
          end
        end
        names.each { |name| branches[name] = has_req_id }
      end
      # `retire` delegates to `execute_retire`, which calls `required_identifier!` on every valid branch
      if branches.key?("retire") && method_calls_identifier?("lib/hive/commands/receipt.rb", "execute_retire", "required_identifier!")
        branches["retire"] = true
      end
      branches
    end

    private

    def find_def(node, name)
      return nil unless node.is_a?(Array)
      return node if node[0] == :def && node[1].is_a?(Array) && node[1][1] == name

      node.each do |child|
        found = find_def(child, name)
        return found if found
      end
      nil
    end

    def walk(node, &block)
      return unless node.is_a?(Array)

      yield node
      node.each { |child| walk(child, &block) if child.is_a?(Array) }
    end

    def argv_first?(node)
      node.is_a?(Array) && node[0] == :call &&
        node[1].is_a?(Array) && node[1][0] == :var_ref &&
        node[1][1].is_a?(Array) && node[1][1][1] == "ARGV" &&
        node[3].is_a?(Array) && node[3][1] == "first"
    end

    def string_literal(node)
      return nil unless node.is_a?(Array)

      if node[0] == :string_literal && node[1].is_a?(Array) && node[1][0] == :string_content
        parts = node[1].drop(1)
        return parts.map { |part| part[1] if part.is_a?(Array) && part[0] == :@tstring_content }.join if parts.all? { |p| p.is_a?(Array) && p[0] == :@tstring_content }
      elsif node[0] == :@tstring_content
        return node[1]
      end
      nil
    end

    def extract_strings(node, out)
      return unless node.is_a?(Array)

      if (str = string_literal(node))
        out << str
        return
      end
      node.each { |child| extract_strings(child, out) if child.is_a?(Array) }
    end
  end

  class RuntimeExtractor
    ADAPTER_STATES = {
      "babysit" => :structured_synopsis,
      "bench" => :inline_help_and_dispatcher,
      "bot" => :structured_synopsis,
      "connect" => :inline_help_and_dispatcher,
      "context" => :catalog_declared_with_exception,
      "daemon" => :structured_synopsis,
      "digest" => :inline_help_and_dispatcher,
      "disconnect" => :inline_help_and_dispatcher,
      "evidence" => :structured_synopsis,
      "markers" => :structured_synopsis,
      "mcp" => :inline_help_and_dispatcher,
      "metrics" => :inline_help_and_dispatcher,
      "module" => :structured_synopsis,
      "pairing" => :structured_synopsis,
      "plan-review" => :inline_help_and_dispatcher,
      "proposal" => :inline_help_and_dispatcher,
      "receipt" => :inline_help_and_dispatcher,
      "runtime" => :structured_synopsis,
      "token" => :catalog_declared_with_exception,
      "web" => :registry_expanded_placeholder,
      "wiki" => :structured_synopsis,
      "workflow" => :structured_synopsis,
      "worktree" => :structured_synopsis
    }.freeze

    def initialize(root:, all_commands: Hive::CLI.all_commands, command_map: Hive::CLI.map,
                   class_options: Hive::CLI.class_options, method_params: nil,
                   registries: {}, long_descs: {}, source_overrides: {},
                   policy_classifier: Hive::Remote::CommandPolicy.method(:classify))
      @root = root
      @all_commands = all_commands
      @command_map = command_map
      @class_options = class_options
      @method_params = method_params
      @registries = registries
      @long_descs = long_descs
      @source = SourceEvidence.new(root: root, overrides: source_overrides)
      @policy_classifier = policy_classifier
      @diagnostics = []
    end

    def extract
      guard = WikiCommandIndex::Guard.new
      metadata = guard.metadata(all_commands: @all_commands, command_map: @command_map)
      metadata.diagnostics.each do |diag|
        @diagnostics << Diagnostic.new(kind: diag.kind, subject: diag.subject, detail: diag.detail).freeze
      end

      commands_by_public = {}
      @all_commands.each do |method_name, command|
        public_name = command.usage.to_s.split.first
        commands_by_public[public_name] = [ method_name.to_s, command ] if public_name
      end

      aliases_by_canonical = Hash.new { |h, k| h[k] = [] }
      metadata.aliases.each { |alias_name, canonical| aliases_by_canonical[canonical] << alias_name }

      leaves = []
      visible_options_by_top_level = {}
      hidden_options = []

      metadata.visible.each do |top_level|
        method_name, command = commands_by_public.fetch(top_level)
        opts_by_switch = build_options_map(command)
        visible_options_by_top_level[top_level] = opts_by_switch.values.reject(&:hidden).map(&:switch).sort.freeze
        opts_by_switch.values.select(&:hidden).each do |opt|
          hidden_options << "#{top_level} #{opt.switch}"
        end

        long_desc = @long_descs.fetch(top_level) { command.long_description.to_s }
        posture = @policy_classifier.call(top_level).to_s
        aliases = aliases_by_canonical[top_level].sort.freeze

        if ADAPTER_STATES.key?(top_level)
          extracted = extract_selector_parent(
            top_level: top_level, method_name: method_name, command: command,
            long_desc: long_desc, opts_by_switch: opts_by_switch,
            posture: posture, aliases: aliases
          )
          leaves.concat(extracted)
        elsif selector_parent_candidate?(command, long_desc)
          @diagnostics << Diagnostic.new(
            kind: :unadapted_selector_parent,
            subject: top_level,
            detail: "visible selector parent has no registered evidence adapter"
          ).freeze
        else
          forms = parse_top_level_forms(command, opts_by_switch)
          leaves << RuntimeLeaf.new(
            path: top_level, top_level: top_level, aliases: aliases,
            evidence_state: :top_level, forms: forms, context_posture: posture,
            expected_modes: expected_modes_for(top_level),
            forbidden_options: [], owner_tail_check: nil
          ).freeze
        end
      end

      RuntimeSurfaceData.new(
        leaves: leaves.sort_by(&:path).freeze,
        visible_options_by_top_level: visible_options_by_top_level.freeze,
        hidden_commands: metadata.hidden.sort.freeze,
        hidden_options: hidden_options.sort.freeze,
        private_routes: @source.pre_thor_routes.freeze,
        aliases: metadata.aliases.freeze,
        diagnostics: @diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    private

    def build_options_map(command)
      map = {}
      @class_options.each do |key, opt|
        switch = opt_switch(key, opt)
        map[switch] = OptionSpec.new(
          switch: switch, type: opt.type, required: !!opt.required,
          repeatable: !!opt.repeatable, hidden: !!opt.hide
        ).freeze
      end
      command.options.each do |key, opt|
        switch = opt_switch(key, opt)
        map[switch] = OptionSpec.new(
          switch: switch, type: opt.type, required: !!opt.required,
          repeatable: !!opt.repeatable, hidden: !!opt.hide
        ).freeze
      end
      map
    end

    def opt_switch(key, opt)
      return opt.switch_name if opt.respond_to?(:switch_name) && opt.switch_name

      "--#{key.to_s.tr("_", "-")}"
    end

    def selector_parent_candidate?(command, long_desc)
      usage_tokens = command.usage.to_s.split.drop(1).map { |tok| tok.gsub(/[\[\]]/, "") }
      return true if (usage_tokens & SELECTOR_PLACEHOLDERS).any?

      long_desc.match?(/^\s*(?:Subcommands|Actions):/)
    end

    def parse_top_level_forms(command, opts_by_switch)
      usage_str = command.usage.to_s.dup
      required_opts = command.options.select { |_, opt| opt.required && !opt.hide }
      required_opts.keys.sort_by(&:to_s).each do |key|
        opt = required_opts.fetch(key)
        switch = opt_switch(key, opt)
        next if usage_str.include?(switch)

        placeholder = key.to_s.upcase
        usage_str << " #{switch}=#{placeholder}"
      end
      SignatureGrammar.expand(usage_str, options_by_switch: opts_by_switch)
    rescue SignatureGrammar::ParseError => error
      @diagnostics << Diagnostic.new(kind: :runtime_signature_parse_error, subject: command.usage.to_s, detail: error.message).freeze
      []
    end

    def selector_optional?(method_name, slot: 0)
      params = if @method_params && @method_params.key?(method_name)
        @method_params.fetch(method_name)
      else
        Hive::CLI.instance_method(method_name.to_sym).parameters
      end
      kind = params[slot]&.first
      kind == :opt || kind == :rest
    end

    def registry(key, &default)
      return @registries.fetch(key) if @registries.key?(key)

      default.call
    end

    def extract_selector_parent(top_level:, method_name:, command:, long_desc:, opts_by_switch:, posture:, aliases:)
      state = ADAPTER_STATES.fetch(top_level)
      case top_level
      when "babysit" then extract_babysit(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "bench" then extract_bench(long_desc, opts_by_switch, posture, aliases, state)
      when "bot" then extract_structured_registry_parent(
        "bot", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("bot") { require "hive/commands/bot"; Hive::Commands::Bot::VALID_SUBCOMMANDS }
      )
      when "connect" then extract_screenote("connect", long_desc, opts_by_switch, posture, aliases, state)
      when "disconnect" then extract_screenote("disconnect", long_desc, opts_by_switch, posture, aliases, state)
      when "context" then extract_context(method_name, opts_by_switch, posture, aliases, state)
      when "token" then extract_token(method_name, opts_by_switch, posture, aliases, state)
      when "daemon" then extract_daemon(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "digest" then extract_digest(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "evidence" then extract_structured_registry_parent(
        "evidence", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("evidence") { require "hive/commands/evidence"; Hive::Commands::Evidence::SUBCOMMANDS },
        has_descriptions: false
      )
      when "markers" then extract_structured_registry_parent(
        "markers", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("markers") { require "hive/commands/markers"; Hive::Commands::Markers::VALID_SUBCOMMANDS }
      )
      when "mcp" then extract_mcp(method_name, opts_by_switch, posture, aliases, state)
      when "metrics" then extract_metrics(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "module" then extract_structured_registry_parent(
        "module", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("module") { require "hive/commands/module"; Hive::Commands::Module::SUBCOMMANDS }
      )
      when "pairing" then extract_structured_registry_parent(
        "pairing", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("pairing") { require "hive/commands/pairing"; Hive::Commands::Pairing::VALID_SUBCOMMANDS }
      )
      when "plan-review" then extract_plan_review(long_desc, opts_by_switch, posture, aliases, state)
      when "proposal" then extract_proposal(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "receipt" then extract_receipt(long_desc, opts_by_switch, posture, aliases, state)
      when "runtime" then extract_runtime(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when "web" then extract_web(method_name, command, long_desc, opts_by_switch, posture, aliases, state)
      when "wiki" then extract_structured_registry_parent(
        "wiki", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("wiki") { require "hive/commands/wiki"; Hive::Commands::Wiki::VALID_SUBCOMMANDS }
      )
      when "workflow" then extract_structured_registry_parent(
        "workflow", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("workflow") { require "hive/commands/workflow"; Hive::Commands::Workflow::SUBCOMMANDS }
      )
      when "worktree" then extract_structured_registry_parent(
        "worktree", method_name, long_desc, opts_by_switch, posture, aliases, state,
        registry("worktree") { require "hive/commands/worktree"; Hive::Commands::Worktree::SUBCOMMANDS }
      )
      end
    end

    def extract_synopsis_rows(long_desc, section_headers: [ "Subcommands:" ], has_descriptions: true)
      lines = long_desc.lines
      rows = []
      in_section = false
      lines.each do |line|
        stripped = line.strip
        if section_headers.any? { |header| stripped == header }
          in_section = true
          next
        end
        next unless in_section
        next if stripped.empty? && rows.empty?

        if stripped.empty? || !line.start_with?("  ")
          in_section = false
          next
        end
        # Continuation description lines have deep indentation (>= 6 spaces)
        next if line.match?(/\A {6,}/)

        synopsis = if has_descriptions
          stripped.split(/ {2,}(?=\(?[A-Z][a-z])/, 2).first.strip.gsub(/\s+/, " ")
        else
          stripped.gsub(/\s+/, " ")
        end
        rows << synopsis unless synopsis.empty?
      end
      rows
    end

    def extract_structured_registry_parent(top_level, method_name, long_desc, opts_by_switch, posture, aliases, state, expected_tokens,
                                           has_descriptions: true)
      rows = extract_synopsis_rows(long_desc, has_descriptions: has_descriptions)
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        expanded = SignatureGrammar.expand("#{top_level} #{row}", options_by_switch: opts_by_switch)
        expanded.each do |form|
          selector = form.atoms[1]&.name
          grouped[selector] << form if selector
        end
      end

      verify_registry_match!(top_level, grouped.keys, expected_tokens)

      leaves = []
      if selector_optional?(method_name)
        leaves << bare_leaf(top_level, opts_by_switch, posture, aliases, state)
      end
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "#{top_level} #{selector}", top_level: top_level, aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: expected_modes_for("#{top_level} #{selector}"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_babysit(method_name, long_desc, opts_by_switch, posture, aliases, state)
      expected = registry("babysit") { require "hive/commands/babysit"; Hive::Commands::Babysit::VALID_SUBCOMMANDS }
      rows = extract_synopsis_rows(long_desc)
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        SignatureGrammar.expand("babysit #{row}", options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("babysit", grouped.keys, expected)

      oneshot_rows = extract_synopsis_rows(long_desc, section_headers: [ "One-shot:" ]).map { |r| r.delete_prefix("hive ") }
      bare_forms = SignatureGrammar.expand("babysit", options_by_switch: opts_by_switch)
      oneshot_rows.each { |r| bare_forms.concat(SignatureGrammar.expand(r, options_by_switch: opts_by_switch)) }

      leaves = []
      if selector_optional?(method_name)
        leaves << RuntimeLeaf.new(
          path: "babysit", top_level: "babysit", aliases: aliases,
          evidence_state: state, forms: bare_forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: expected_modes_for("babysit"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "babysit #{selector}", top_level: "babysit", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: %w[--once --all], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_daemon(method_name, long_desc, opts_by_switch, posture, aliases, state)
      expected = registry("daemon") { require "hive/commands/daemon"; Hive::Commands::Daemon::VALID_SUBCOMMANDS }
      queue_expected = registry("daemon_queue") { require "hive/commands/daemon"; Hive::Commands::Daemon::VALID_QUEUE_ACTIONS }
      rows = extract_synopsis_rows(long_desc)

      named_forms = Hash.new { |h, k| h[k] = [] }
      top_selectors = []
      queue_actions = []

      rows.each do |row|
        SignatureGrammar.expand("daemon #{row}", options_by_switch: opts_by_switch).each do |form|
          selector = form.atoms[1]&.name
          top_selectors << selector if selector
          if selector == "queue"
            if form.atoms[2] && form.atoms[2].kind == :literal
              nested = form.atoms[2].name
              queue_actions << nested
              named_forms["daemon queue #{nested}"] << form
            else
              named_forms["daemon queue"] << form
            end
          else
            named_forms["daemon #{selector}"] << form
          end
        end
      end

      verify_registry_match!("daemon", top_selectors.uniq, expected)
      verify_registry_match!("daemon queue", queue_actions.uniq, queue_expected)

      leaves = []
      if selector_optional?(method_name)
        leaves << RuntimeLeaf.new(
          path: "daemon", top_level: "daemon", aliases: aliases,
          evidence_state: state,
          forms: SignatureGrammar.expand("daemon", options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: expected_modes_for("daemon"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      named_forms.each do |path, forms|
        leaves << RuntimeLeaf.new(
          path: path, top_level: "daemon", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: expected_modes_for(path),
          forbidden_options: %w[--once], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_runtime(method_name, long_desc, opts_by_switch, posture, aliases, state)
      expected = registry("runtime") { require "hive/commands/runtime"; Hive::Commands::Runtime::ACTIONS }
      rows = extract_synopsis_rows(
        long_desc,
        section_headers: [
          "Read-only actions (nothing is created, migrated, or repaired):",
          "Bootstrap:"
        ]
      )
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        SignatureGrammar.expand("runtime #{row}", options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("runtime", grouped.keys, expected)

      leaves = []
      leaves << bare_leaf("runtime", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "runtime #{selector}", top_level: "runtime", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_web(method_name, _command, long_desc, opts_by_switch, posture, aliases, state)
      unless extract_synopsis_rows(long_desc).empty?
        @diagnostics << Diagnostic.new(
          kind: :stale_evidence_state,
          subject: "web",
          detail: "web now publishes structured synopsis rows; retire registry_expanded_placeholder"
        ).freeze
      end

      expected = registry("web") { require "hive/commands/web"; Hive::Commands::Web::VALID_SUBCOMMANDS }
      web_call = @source.method_source_slice("lib/hive/commands/web.rb", "call")
      unless web_call.include?("when nil then run_foreground") && web_call.include?('when "start" then @detach ? start_service : run_foreground')
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "web", detail: "Commands::Web#call dispatch shape changed").freeze
      end

      leaves = []
      leaves << bare_leaf("web", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      expected.each do |sub|
        leaves << RuntimeLeaf.new(
          path: "web #{sub}", top_level: "web", aliases: [],
          evidence_state: state,
          forms: SignatureGrammar.expand("web #{sub}", options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: expected_modes_for("web #{sub}"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_bench(long_desc, opts_by_switch, posture, aliases, state)
      when_tokens = @source.when_string_literals("lib/hive/cli.rb", "bench")
      rows = extract_synopsis_rows(long_desc)
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        SignatureGrammar.expand("bench #{row}", options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("bench", grouped.keys, when_tokens)
      grouped.map do |selector, forms|
        RuntimeLeaf.new(
          path: "bench #{selector}", top_level: "bench", aliases: aliases,
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
    end

    def extract_metrics(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when_tokens = @source.when_string_literals("lib/hive/commands/metrics.rb", "do_call")
      rows = extract_synopsis_rows(long_desc)
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        SignatureGrammar.expand("metrics #{row}", options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("metrics", grouped.keys, when_tokens)

      leaves = []
      leaves << bare_leaf("metrics", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "metrics #{selector}", top_level: "metrics", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_screenote(top_level, long_desc, opts_by_switch, posture, aliases, state)
      source_file = "lib/hive/commands/#{top_level}.rb"
      slice = @source.method_source_slice(source_file, "ensure_screenote!")
      services = slice.scan(/@service\s*==\s*"([a-z0-9_-]+)"/).flatten.uniq
      if services.empty? || !long_desc.include?("`#{services.first}`")
        @diagnostics << Diagnostic.new(
          kind: :source_evidence_drift, subject: top_level,
          detail: "service guard and help prose disagree"
        ).freeze
      end
      services.map do |service|
        RuntimeLeaf.new(
          path: "#{top_level} #{service}", top_level: top_level, aliases: aliases,
          evidence_state: state,
          forms: SignatureGrammar.expand("#{top_level} #{service}", options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
    end

    def extract_digest(method_name, long_desc, opts_by_switch, posture, aliases, state)
      when_tokens = @source.when_string_literals("lib/hive/cli.rb", "digest")
      rows = extract_synopsis_rows(long_desc, section_headers: [ "Mutations are separate explicit actions:" ])
        .map { |row| row.delete_prefix("hive ") }
      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each do |row|
        SignatureGrammar.expand(row, options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("digest", grouped.keys, when_tokens)

      leaves = []
      leaves << bare_leaf("digest", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "digest #{selector}", top_level: "digest", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_mcp(method_name, opts_by_switch, posture, aliases, state)
      expected = registry("mcp") { require "hive/commands/mcp"; Hive::Commands::Mcp::SUBCOMMANDS }
      when_tokens = @source.when_string_literals("lib/hive/commands/mcp.rb", "call")
      verify_registry_match!("mcp", when_tokens, expected)

      import_src = @source.method_source_slice("lib/hive/commands/mcp.rb", "import")
      login_src = @source.method_source_slice("lib/hive/commands/mcp.rb", "login")
      unless import_src.include?("takes no SERVER argument") && login_src.include?("name the catalog SERVER") && login_src.include?("--agent must be one of")
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "mcp", detail: "Commands::Mcp operand guards changed").freeze
      end

      leaves = []
      leaves << bare_leaf("mcp", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      leaves << RuntimeLeaf.new(
        path: "mcp import", top_level: "mcp", aliases: [],
        evidence_state: state,
        forms: SignatureGrammar.expand("mcp import", options_by_switch: opts_by_switch).freeze,
        context_posture: posture, expected_modes: [],
        forbidden_options: %w[--agent], owner_tail_check: nil
      ).freeze
      leaves << RuntimeLeaf.new(
        path: "mcp login", top_level: "mcp", aliases: [],
        evidence_state: state,
        forms: SignatureGrammar.expand("mcp login SERVER --agent AGENT", options_by_switch: opts_by_switch).freeze,
        context_posture: posture, expected_modes: [],
        forbidden_options: %w[--all --only --dry-run --yes --update], owner_tail_check: nil
      ).freeze
      leaves
    end

    def extract_plan_review(long_desc, opts_by_switch, posture, aliases, state)
      decision_actions = registry("plan_review") do
        require "hive/plan_review/decision"
        Hive::PlanReview::Decision::ACTIONS.map { |name| name.tr("_", "-") }
      end
      cli_slice = @source.method_source_slice("lib/hive/cli.rb", "plan_review")
      has_show = cli_slice.include?('action.to_s == "show"')
      expected = (has_show ? [ "show" ] : []) + decision_actions

      prose_line = long_desc[/Actions:\s*(.+?)\./m, 1].to_s
      prose_tokens = prose_line.gsub(/\(read-only\)/, "").split(",").map(&:strip).reject(&:empty?)
      verify_registry_match!("plan-review", prose_tokens, expected)

      expected.map do |action|
        RuntimeLeaf.new(
          path: "plan-review TARGET #{action}", top_level: "plan-review", aliases: (action == "show" ? aliases : []),
          evidence_state: state,
          forms: SignatureGrammar.expand("plan-review TARGET #{action}", options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: (action == "show" ? %w[--review-id --task-generation --policy-fingerprint --expected-artifact-digest --target-fingerprint --answer --coverage --level --reason] : []),
          owner_tail_check: nil
        ).freeze
      end
    end

    def extract_proposal(method_name, long_desc, opts_by_switch, posture, aliases, state)
      expected = registry("proposal") { require "hive/commands/proposal"; Hive::Commands::Proposal::COMMANDS }
      headers = [
        "Source commands use or create a durable proposal-bound task attempt:",
        "Live discovery reads canonical hive/state projections:",
        "Lifecycle actions are tracking-only and require a fresh observed head:",
        "Generated-view maintenance runs through the managed llm-wiki boundary:"
      ]
      raw_rows = extract_synopsis_rows(long_desc, section_headers: headers, has_descriptions: false)
      lifecycle_src = @source.method_source_slice("lib/hive/commands/proposal.rb", "lifecycle_command")
      unless lifecycle_src.include?("--authority") && lifecycle_src.include?("--policy-fingerprint") && lifecycle_src.include?("expected_head")
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "proposal", detail: "lifecycle_command guards changed").freeze
      end
      decide_tail = "--input FILE --authority ID --policy-fingerprint SHA --expected-head-version N --expected-head-digest SHA"

      grouped = Hash.new { |h, k| h[k] = [] }
      raw_rows.each do |row|
        expanded_row = row.sub(/\A(supersede|rollback) PROPOSAL_ID \.\.\.\z/, "\\1 PROPOSAL_ID #{decide_tail}")
        SignatureGrammar.expand("proposal #{expanded_row}", options_by_switch: opts_by_switch).each do |form|
          grouped[form.atoms[1].name] << form
        end
      end
      verify_registry_match!("proposal", grouped.keys, expected)

      leaves = []
      leaves << bare_leaf("proposal", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      grouped.each do |selector, forms|
        leaves << RuntimeLeaf.new(
          path: "proposal #{selector}", top_level: "proposal", aliases: [],
          evidence_state: state, forms: forms.uniq(&:canonical).freeze,
          context_posture: posture, expected_modes: expected_modes_for("proposal #{selector}"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
      leaves
    end

    def extract_receipt(long_desc, opts_by_switch, posture, aliases, state)
      prose_line = long_desc[/Subcommands:\s*(.+?)\./m, 1].to_s
      prose_tokens = prose_line.gsub(/\band\b/, ",").split(",").map(&:strip).reject(&:empty?)
      branches = @source.receipt_when_branches
      verify_registry_match!("receipt", prose_tokens, branches.keys)

      branches.map do |sub, needs_identifier|
        usage_str = needs_identifier ? "receipt #{sub} IDENTIFIER" : "receipt #{sub}"
        RuntimeLeaf.new(
          path: "receipt #{sub}", top_level: "receipt", aliases: [],
          evidence_state: state,
          forms: SignatureGrammar.expand(usage_str, options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: expected_modes_for("receipt #{sub}"),
          forbidden_options: [], owner_tail_check: nil
        ).freeze
      end
    end

    def extract_token(method_name, opts_by_switch, posture, aliases, state)
      tokens = @source.when_string_literals("lib/hive/commands/token.rb", "call")
      call_src = @source.method_source_slice("lib/hive/commands/token.rb", "call")
      unless call_src.include?("only token revoke accepts a public ID") && call_src.include?("token public ID is required")
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "token", detail: "Commands::Token#call ID guards changed").freeze
      end
      if tokens.empty?
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "token", detail: "no when branches in Commands::Token#call").freeze
      end

      leaves = []
      leaves << bare_leaf("token", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      tokens.each do |action|
        tail_check = if action == "revoke"
          ->(form) { form.operands.size == 1 && form.operands.first.required && form.operands.first.name == "ID" }
        else
          ->(form) { form.operands.empty? }
        end
        usage_str = action == "revoke" ? "token revoke ID" : "token #{action}"
        leaves << RuntimeLeaf.new(
          path: "token #{action}", top_level: "token", aliases: [],
          evidence_state: state,
          forms: SignatureGrammar.expand(usage_str, options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: (action == "create" ? [] : %w[--scopes --projects --all-projects --name --expires-at]),
          owner_tail_check: tail_check
        ).freeze
      end
      leaves
    end

    def extract_context(method_name, opts_by_switch, posture, aliases, state)
      arrays = @source.percent_w_arrays("lib/hive/commands/context.rb", "validate_options!")
      actions = arrays.find { |arr| arr.include?("add") && arr.include?("list") } || []
      validate_src = @source.method_source_slice("lib/hive/commands/context.rb", "validate_options!")
      unless validate_src.include?("requires NAME") && validate_src.include?("context list takes no NAME") &&
             validate_src.include?("context add requires --url and --token-stdin")
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "context", detail: "Commands::Context#validate_options! guards changed").freeze
      end
      if actions.empty?
        @diagnostics << Diagnostic.new(kind: :source_evidence_drift, subject: "context", detail: "action allowlist missing in Commands::Context#validate_options!").freeze
      end

      leaves = []
      leaves << bare_leaf("context", opts_by_switch, posture, aliases, state) if selector_optional?(method_name)
      actions.each do |action|
        usage_str, tail_check = case action
        when "add"
          [ "context add NAME --url URL --token-stdin",
            ->(form) { form.operands.size == 1 && form.operands.first.required && form.operands.first.name == "NAME" && form.option_switches.include?("--url") && form.option_switches.include?("--token-stdin") } ]
        when "use"
          [ "context use NAME",
            ->(form) { form.operands.size == 1 && form.operands.first.required && form.operands.first.name == "NAME" } ]
        when "list"
          [ "context list",
            ->(form) { form.operands.empty? } ]
        when "show"
          [ "context show [NAME]",
            ->(form) { form.operands.size == 1 && !form.operands.first.required && form.operands.first.name == "NAME" } ]
        else
          [ "context #{action}", nil ]
        end
        leaves << RuntimeLeaf.new(
          path: "context #{action}", top_level: "context", aliases: [],
          evidence_state: state,
          forms: SignatureGrammar.expand(usage_str, options_by_switch: opts_by_switch).freeze,
          context_posture: posture, expected_modes: [],
          forbidden_options: (action == "add" ? [] : %w[--url --token-stdin]),
          owner_tail_check: tail_check
        ).freeze
      end
      leaves
    end

    def bare_leaf(top_level, opts_by_switch, posture, aliases, state)
      RuntimeLeaf.new(
        path: top_level, top_level: top_level, aliases: aliases,
        evidence_state: state,
        forms: SignatureGrammar.expand(top_level, options_by_switch: opts_by_switch).freeze,
        context_posture: posture, expected_modes: expected_modes_for(top_level),
        forbidden_options: [], owner_tail_check: nil
      ).freeze
    end

    def verify_registry_match!(subject, observed, expected)
      missing = expected.uniq - observed.uniq
      extra = observed.uniq - expected.uniq
      missing.sort.each do |token|
        @diagnostics << Diagnostic.new(kind: :registry_help_mismatch, subject: subject, detail: "missing in help: #{token}").freeze
      end
      extra.sort.each do |token|
        @diagnostics << Diagnostic.new(kind: :registry_help_mismatch, subject: subject, detail: "extra in help: #{token}").freeze
      end
    end

    def expected_modes_for(path)
      case path
      when "status"
        verify_owner_pattern!("status", "lib/hive/commands/status.rb", "validate_mode_combinations!", /@operational|@diagnose|@write|@force/)
        [
          ModeSpec.new(name: "running", condition: "no --operational and no --diagnose", required_options: %w[--json --context], forbidden_options: %w[--operational --diagnose --write --force --stage]),
          ModeSpec.new(name: "operational", condition: "--operational", required_options: %w[--operational --project --json --context], forbidden_options: %w[--diagnose --write --force --stage]),
          ModeSpec.new(name: "diagnose", condition: "--diagnose SLUG without --write", required_options: %w[--diagnose --project --stage --json --context], forbidden_options: %w[--operational --write --force]),
          ModeSpec.new(name: "diagnose_write", condition: "--diagnose SLUG --write", required_options: %w[--diagnose --write --force --project --stage --json --context], forbidden_options: %w[--operational])
        ]
      when "archive"
        verify_owner_pattern!("archive", "lib/hive/cli.rb", "archive", /target\.nil\?.*closure_options\?/m)
        [
          ModeSpec.new(name: "list", condition: "no TARGET", required_options: %w[--project --from --json --context], forbidden_options: %w[--reason --evidence --successor --attestation --yes --idempotency-key --retry-horizon-expires-at]),
          ModeSpec.new(name: "stage_action", condition: "TARGET without closure options", required_options: %w[--from --project --idempotency-key --retry-horizon-expires-at --json --context], forbidden_options: %w[--reason --evidence --successor --attestation --yes]),
          ModeSpec.new(name: "closure_preview", condition: "TARGET with --reason and --json without --yes", required_options: %w[--from --project --reason --evidence --successor --attestation --json --context], forbidden_options: %w[--yes --idempotency-key --retry-horizon-expires-at]),
          ModeSpec.new(name: "closure_apply", condition: "TARGET with --reason and --yes or TTY confirmation", required_options: %w[--from --project --reason --evidence --successor --attestation --yes --idempotency-key --retry-horizon-expires-at --json --context], forbidden_options: [])
        ]
      when "review"
        verify_owner_pattern!("review", "lib/hive/cli.rb", "review", /if options\[:pr\].*unless target/m)
        [
          ModeSpec.new(name: "task", condition: "TARGET without --pr", required_options: %w[--from --project --idempotency-key --retry-horizon-expires-at --json --context], forbidden_options: %w[--pr]),
          ModeSpec.new(name: "adhoc_pr", condition: "--pr PR without TARGET", required_options: %w[--pr --project --json --context], forbidden_options: %w[--from --idempotency-key --retry-horizon-expires-at]),
          ModeSpec.new(name: "missing_target", condition: "no TARGET and no --pr", required_options: %w[--json --context], forbidden_options: %w[--pr])
        ]
      when "daemon"
        verify_owner_pattern!("daemon", "lib/hive/cli.rb", "daemon", /if options\[:once\].*if subcommand\.nil\?/m)
        [
          ModeSpec.new(name: "missing_subcommand", condition: "no SUBCOMMAND and no --once", required_options: %w[--json --context], forbidden_options: %w[--once]),
          ModeSpec.new(name: "once", condition: "--once PROJECT without named SUBCOMMAND", required_options: %w[--once --dry-run --json --context], forbidden_options: %w[--detach --all --force --timeout])
        ]
      when "babysit"
        verify_owner_pattern!("babysit", "lib/hive/cli.rb", "babysit", /if options\[:once\]/)
        [
          ModeSpec.new(name: "missing_subcommand", condition: "no SUBCOMMAND and no --once", required_options: %w[--json --context], forbidden_options: %w[--once]),
          ModeSpec.new(name: "once_project", condition: "--once PROJECT without named SUBCOMMAND", required_options: %w[--once --dry-run --json --context], forbidden_options: %w[--detach --force --all]),
          ModeSpec.new(name: "once_all", condition: "--once --all without named SUBCOMMAND", required_options: %w[--once --all --dry-run --json --context], forbidden_options: %w[--detach --force])
        ]
      when "web start"
        verify_owner_pattern!("web start", "lib/hive/commands/web.rb", "call", /when "start" then @detach \? start_service : run_foreground/)
        [
          ModeSpec.new(name: "foreground", condition: "without --detach", required_options: %w[--bind --port --no-bootstrap --unsafe --allow-public --json --context], forbidden_options: %w[--detach]),
          ModeSpec.new(name: "detached", condition: "--detach", required_options: %w[--detach --json --context], forbidden_options: %w[--bind --port --no-bootstrap --unsafe --allow-public])
        ]
      when "answer"
        verify_owner_pattern!("answer", "lib/hive/commands/answer.rb", "call", /if @binding_token\.empty\?/)
        [
          ModeSpec.new(name: "inventory", condition: "without --binding", required_options: %w[--project --json --context], forbidden_options: %w[--binding --idempotency-key]),
          ModeSpec.new(name: "write", condition: "--binding TOKEN", required_options: %w[--project --binding --idempotency-key --json --context], forbidden_options: [])
        ]
      when "patrol"
        verify_owner_pattern!("patrol", "lib/hive/commands/patrol.rb", "call", /return run_once if @once.*return list_findings if @list/m)
        [
          ModeSpec.new(name: "cycle", condition: "without --list and without --once", required_options: %w[--dry-run --json --context], forbidden_options: %w[--list --once]),
          ModeSpec.new(name: "list", condition: "--list", required_options: %w[--list --json --context], forbidden_options: %w[--once --dry-run]),
          ModeSpec.new(name: "once", condition: "--once", required_options: %w[--once --dry-run --json --context], forbidden_options: %w[--list])
        ]
      when "refactor-patrol"
        verify_owner_pattern!("refactor-patrol", "lib/hive/cli.rb", "refactor_patrol", /options\[:once\].*options\[:list\]/m)
        [
          ModeSpec.new(name: "discover", condition: "without --list, --show, --archive, --once", required_options: %w[--dry-run --feature --entrypoint --path --changed-since --pr --job-manifest --result-file --json --context], forbidden_options: %w[--list --show --archive --limit --cursor --full --once]),
          ModeSpec.new(name: "list", condition: "--list", required_options: %w[--list --limit --cursor --json --context], forbidden_options: %w[--show --archive --full --once]),
          ModeSpec.new(name: "show", condition: "--show JOB_ID", required_options: %w[--show --limit --full --json --context], forbidden_options: %w[--list --archive --cursor --once]),
          ModeSpec.new(name: "archive", condition: "--archive JOB_ID", required_options: %w[--archive --json --context], forbidden_options: %w[--list --show --limit --cursor --full --once]),
          ModeSpec.new(name: "once", condition: "--once", required_options: %w[--once --dry-run --json --context], forbidden_options: %w[--list --show --archive --feature --entrypoint --path --changed-since --pr --job-manifest --result-file --limit --cursor --full])
        ]
      when "init"
        verify_owner_pattern!("init", "lib/hive/commands/init.rb", "envelope_schema", /@preview \? "hive-init-preview" : "hive-init"/)
        [
          ModeSpec.new(name: "standard", condition: "without --preview", required_options: %w[--force --workflow --new-workflow --minimal --refactor-patrol --json --context], forbidden_options: %w[--preview]),
          ModeSpec.new(name: "minimal_preview", condition: "--new-workflow ID --minimal --preview", required_options: %w[--new-workflow --minimal --preview --json --context], forbidden_options: %w[--force --workflow])
        ]
      when "setup"
        verify_owner_pattern!("setup", "lib/hive/commands/setup.rb", "call", /@no_bootstrap/)
        [
          ModeSpec.new(name: "managed_service", condition: "default --service without --no-bootstrap", required_options: %w[--yes --service --no-init --install-command-receipts --json --context], forbidden_options: %w[--no-bootstrap]),
          ModeSpec.new(name: "service_opt_out", condition: "--no-service without --no-bootstrap", required_options: %w[--yes --service --no-init --install-command-receipts --json --context], forbidden_options: %w[--no-bootstrap]),
          ModeSpec.new(name: "diagnose_only", condition: "--no-bootstrap", required_options: %w[--no-bootstrap --service --no-init --yes --install-command-receipts --json --context], forbidden_options: [])
        ]
      when "receipt prune"
        verify_owner_pattern!("receipt prune", "lib/hive/commands/receipt.rb", "execute_prune", /if @confirm/)
        [
          ModeSpec.new(name: "preview", condition: "without --confirm", required_options: %w[--project --namespace-id --limit --cursor --json --context], forbidden_options: %w[--confirm --idempotency-key]),
          ModeSpec.new(name: "confirm", condition: "--confirm", required_options: %w[--project --namespace-id --limit --confirm --reason --idempotency-key --json --context], forbidden_options: %w[--cursor])
        ]
      when "receipt retire"
        verify_owner_pattern!("receipt retire", "lib/hive/commands/receipt.rb", "execute_retire", /@settle_without_result.*@orphaned_owner.*@evidence_path/m)
        [
          ModeSpec.new(name: "settle_without_result", condition: "--settle-without-result", required_options: %w[--project --namespace-id --expected-generation --confirm --settle-without-result --reason --json --context], forbidden_options: %w[--orphaned-owner --evidence]),
          ModeSpec.new(name: "orphaned_owner", condition: "--orphaned-owner", required_options: %w[--project --namespace-id --expected-generation --confirm --orphaned-owner --reason --json --context], forbidden_options: %w[--settle-without-result --evidence]),
          ModeSpec.new(name: "with_evidence", condition: "--evidence FILE", required_options: %w[--project --namespace-id --expected-generation --confirm --evidence --reason --json --context], forbidden_options: %w[--settle-without-result --orphaned-owner])
        ]
      when "proposal refresh"
        verify_owner_pattern!("proposal refresh", "lib/hive/commands/proposal.rb", "refresh", /return check_refresh\(ops, source_ref\) if @check/)
        [
          ModeSpec.new(name: "queue", condition: "without --check", required_options: %w[--json --context], forbidden_options: %w[--check]),
          ModeSpec.new(name: "check", condition: "--check", required_options: %w[--check --json --context], forbidden_options: [])
        ]
      else
        []
      end
    end

    def verify_owner_pattern!(subject, file, method_name, pattern)
      slice = @source.method_source_slice(file, method_name)
      return if slice.match?(pattern)

      @diagnostics << Diagnostic.new(
        kind: :mode_evidence_drift, subject: subject,
        detail: "expected mode pattern not found in #{file}##{method_name}"
      ).freeze
    end
  end

  class CatalogParser
    def parse(text)
      @diagnostics = []
      lines = visible_markdown_lines(text)
      catalog_lines = section_lines(lines, "## Command Catalog")
      exclusion_lines = section_lines(lines, "## Excluded Hidden and Private Routes")

      @diagnostics << Diagnostic.new(kind: :missing_catalog_section, subject: "docs/cli.md", detail: "missing ## Command Catalog").freeze if catalog_lines.nil?
      @diagnostics << Diagnostic.new(kind: :missing_exclusions_section, subject: "docs/cli.md", detail: "missing ## Excluded Hidden and Private Routes").freeze if exclusion_lines.nil?

      leaves = catalog_lines ? parse_leaves(catalog_lines) : []
      exclusions = exclusion_lines ? parse_exclusions(exclusion_lines) : []

      CatalogData.new(
        leaves: leaves.freeze,
        exclusions: exclusions.freeze,
        diagnostics: @diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    private

    def visible_markdown_lines(text)
      fence = nil
      comment = false
      result = []
      text.each_line.with_index(1) do |raw, number|
        if fence
          marker = raw.match(/\A {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = nil if marker&.start_with?(fence[0]) && marker.length >= fence.length
          result << [ number, raw, true ]
        else
          cleaned, comment = strip_html_comments(raw, comment)
          marker = cleaned.match(/\A {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = marker if marker
          result << [ number, cleaned, !marker.nil? ]
        end
      end
      result
    end

    def strip_html_comments(text, in_comment)
      visible = +""
      rest = text
      loop do
        if in_comment
          idx = rest.index("-->")
          return [ visible, true ] unless idx

          rest = rest[(idx + 3)..]
          in_comment = false
        else
          idx = rest.index("<!--")
          unless idx
            visible << rest
            return [ visible, false ]
          end
          visible << rest[...idx]
          rest = rest[(idx + 4)..]
          in_comment = true
        end
      end
    end

    def section_lines(lines, heading)
      start = lines.index { |_, text, fenced| !fenced && text.strip == heading }
      return nil unless start

      lines.drop(start + 1).take_while { |_, text, fenced| fenced || !text.start_with?("## ") }
    end

    def parse_leaves(lines)
      blocks = []
      current_heading = nil
      current_lines = []

      lines.each do |number, text, fenced|
        if !fenced && text.start_with?("### ")
          blocks << [ current_heading, current_lines ] if current_heading
          current_heading = [ number, text.strip ]
          current_lines = []
        elsif current_heading
          current_lines << [ number, text, fenced ]
        end
      end
      blocks << [ current_heading, current_lines ] if current_heading

      blocks.filter_map { |(number, heading), body_lines| parse_leaf(number, heading, body_lines) }
    end

    def parse_leaf(number, heading, body_lines)
      match = heading.match(/\A### `hive ([^`]+)`\z/)
      unless match
        @diagnostics << Diagnostic.new(kind: :malformed_leaf_heading, subject: "line #{number}", detail: heading).freeze
        return nil
      end

      path = match[1].strip
      fields = {}
      signatures = []
      modes = []
      current_list = nil

      body_lines.each do |line_no, text, fenced|
        next if fenced

        line = text.chomp
        stripped = line.strip
        next if stripped.empty?

        if (field_match = line.match(/\A- \*\*([A-Za-z ]+):\*\*(?: (.*))?\z/))
          key = field_match[1].strip
          val = field_match[2].to_s.strip
          if fields.key?(key)
            @diagnostics << Diagnostic.new(kind: :duplicate_field, subject: path, detail: "#{key} (line #{line_no})").freeze
          end
          fields[key] = val
          current_list = %w[Signatures Modes].include?(key) ? key : nil
        elsif current_list == "Signatures" && (sig_match = line.match(/\A  - `hive ([^`]+)`\s*\z/))
          signatures << sig_match[1].strip
        elsif current_list == "Modes" && line.start_with?("  - ")
          modes << parse_mode(path, line_no, line)
        elsif current_list && line.start_with?("  - ")
          @diagnostics << Diagnostic.new(kind: :malformed_list_item, subject: path, detail: "line #{line_no}: #{stripped}").freeze
        elsif line.start_with?("- ")
          @diagnostics << Diagnostic.new(kind: :malformed_field, subject: path, detail: "line #{line_no}: #{stripped}").freeze
          current_list = nil
        end
      end

      CatalogLeaf.new(
        path: path,
        top_level: path.split.first,
        aliases: parse_code_list(fields["Aliases"]),
        support: extract_single_code(fields["Support"]),
        coverage: extract_single_code(fields["Coverage"]),
        evidence: extract_single_code(fields["Evidence"]),
        exception: parse_exception(path, fields["Exception"]),
        context_posture: extract_single_code(fields["Context posture"]),
        signatures: signatures.freeze,
        options: parse_code_list(fields["Options"]),
        output: fields["Output"].to_s,
        context_behavior: fields["Context behavior"].to_s,
        exits_and_retry: fields["Exits and retry"].to_s,
        effects_and_approvals: fields["Effects and approvals"].to_s,
        example: fields["Example"].to_s,
        modes: modes.compact.freeze,
        raw_body: body_lines.map { |_, t, _| t }.join.freeze
      ).freeze
    end

    def parse_mode(path, line_no, text)
      match = text.match(/\A  - \*\*Mode `([^`]+)`\*\* \(condition: `([^`]+)`; options: ([^)]+)\): (.+)\z/)
      unless match
        @diagnostics << Diagnostic.new(kind: :malformed_mode, subject: path, detail: "line #{line_no}: #{text.strip}").freeze
        return nil
      end

      CatalogMode.new(
        name: match[1].strip,
        condition: match[2].strip,
        options: parse_code_list(match[3].strip),
        details: match[4].strip
      ).freeze
    end

    def parse_exception(path, raw)
      return nil if raw.nil? || raw.empty?

      pairs = {}
      raw.split(";").each do |segment|
        part = segment.strip
        next if part.empty?

        m = part.match(/\A([a-z_]+)=`([^`]*)`\z/)
        unless m
          @diagnostics << Diagnostic.new(kind: :malformed_exception, subject: path, detail: part).freeze
          next
        end
        pairs[m[1]] = m[2].strip
      end
      CatalogException.new(
        field: pairs["field"].to_s,
        evidence: pairs["evidence"].to_s,
        owner: pairs["owner"].to_s,
        follow_up: pairs["follow_up"].to_s
      ).freeze
    end

    def parse_exclusions(lines)
      category = nil
      entries = []
      lines.each do |line_no, text, fenced|
        next if fenced

        stripped = text.strip
        next if stripped.empty?

        if stripped.start_with?("### ")
          category = case stripped
          when "### Hidden Commands" then :hidden_command
          when "### Hidden Options" then :hidden_option
          when "### Private Pre-Thor Routes" then :private_route
          else
            @diagnostics << Diagnostic.new(kind: :unknown_exclusion_subsection, subject: "line #{line_no}", detail: stripped).freeze
            nil
          end
          next
        end
        next unless category && text.start_with?("- ")

        m = text.match(/\A- `([^`]+)` \(support: `([^`]+)`; source: `([^`]+)`; reason: ([^)]+)\)\s*\z/)
        unless m
          @diagnostics << Diagnostic.new(kind: :malformed_exclusion, subject: "line #{line_no}", detail: stripped).freeze
          next
        end
        entries << ExclusionEntry.new(
          category: category, name: m[1].strip, support: m[2].strip,
          source: m[3].strip, reason: m[4].strip
        ).freeze
      end
      entries
    end

    def extract_single_code(raw)
      return "" if raw.nil?

      raw.strip.match(/\A`([^`]+)`\z/)&.[](1).to_s.strip
    end

    def parse_code_list(raw)
      return [] if raw.nil? || raw.strip.empty? || raw.strip.downcase == "none"

      raw.scan(/`([^`]+)`/).flatten.map(&:strip)
    end
  end

  class Auditor
    def initialize(root:)
      @root = root
    end

    def audit(document_text:, runtime: nil, **runtime_overrides)
      runtime_data = runtime || RuntimeExtractor.new(root: @root, **runtime_overrides).extract
      catalog_data = CatalogParser.new.parse(document_text)
      diagnostics = runtime_data.diagnostics.dup + catalog_data.diagnostics.dup

      check_duplicate_paths(catalog_data.leaves, diagnostics)
      runtime_by_path = runtime_data.leaves.to_h { |leaf| [ leaf.path, leaf ] }
      catalog_by_path = {}
      catalog_data.leaves.each { |leaf| catalog_by_path[leaf.path] ||= leaf }

      check_path_parity(runtime_by_path, catalog_by_path, diagnostics)
      check_aliases(runtime_data, catalog_data.leaves, diagnostics)
      check_leaves(runtime_by_path, catalog_by_path, runtime_data, diagnostics, runtime_overrides)
      check_option_unions(runtime_data, catalog_data.leaves, diagnostics)
      check_exclusions(runtime_data, catalog_data.exclusions, diagnostics)

      AuditResult.new(
        runtime: runtime_data,
        catalog: catalog_data,
        diagnostics: diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    private

    def check_duplicate_paths(leaves, diagnostics)
      leaves.map(&:path).tally.each do |path, count|
        next unless count > 1

        diagnostics << Diagnostic.new(kind: :duplicate_catalog_path, subject: path, detail: "count=#{count}").freeze
      end
    end

    def check_path_parity(runtime_by_path, catalog_by_path, diagnostics)
      (runtime_by_path.keys - catalog_by_path.keys).sort.each do |path|
        diagnostics << Diagnostic.new(kind: :missing_command, subject: path, detail: "missing from docs/cli.md").freeze
      end
      (catalog_by_path.keys - runtime_by_path.keys).sort.each do |path|
        diagnostics << Diagnostic.new(kind: :extra_command, subject: path, detail: "not in visible CLI surface").freeze
      end
    end

    def check_aliases(runtime_data, catalog_leaves, diagnostics)
      owners_by_alias = Hash.new { |h, k| h[k] = [] }
      catalog_leaves.each do |leaf|
        leaf.aliases.each { |alias_name| owners_by_alias[alias_name] << leaf.path }
      end

      owners_by_alias.each do |alias_name, owners|
        if owners.uniq.size > 1
          diagnostics << Diagnostic.new(
            kind: :duplicate_alias_owner, subject: alias_name, detail: "owners=#{owners.uniq.sort.join(",")}"
          ).freeze
        end
      end

      runtime_data.aliases.each do |alias_name, canonical|
        owners = owners_by_alias[alias_name]
        unless owners.include?(canonical)
          diagnostics << Diagnostic.new(
            kind: :missing_alias, subject: canonical, detail: "alias=#{alias_name}"
          ).freeze
        end
      end

      owners_by_alias.each do |alias_name, owners|
        expected = runtime_data.aliases[alias_name]
        if expected.nil?
          diagnostics << Diagnostic.new(
            kind: :extra_alias, subject: alias_name, detail: "owners=#{owners.uniq.sort.join(",")}"
          ).freeze
        elsif (owners.uniq - [ expected ]).any?
          diagnostics << Diagnostic.new(
            kind: :misassigned_alias, subject: alias_name,
            detail: "expected=#{expected} actual=#{owners.uniq.sort.join(",")}"
          ).freeze
        end
      end
    end

    def check_leaves(runtime_by_path, catalog_by_path, runtime_data, diagnostics, runtime_overrides)
      all_commands = runtime_overrides.fetch(:all_commands, Hive::CLI.all_commands)
      class_options = runtime_overrides.fetch(:class_options, Hive::CLI.class_options)
      commands_by_public = all_commands.values.to_h { |cmd| [ cmd.usage.to_s.split.first, cmd ] }

      catalog_by_path.each do |path, leaf|
        check_classifications(leaf, diagnostics)
        runtime_leaf = runtime_by_path[path]
        next unless runtime_leaf

        check_evidence_state(leaf, runtime_leaf, diagnostics)
        check_context_posture(leaf, runtime_leaf, diagnostics)
        check_leaf_signatures(leaf, runtime_leaf, commands_by_public[leaf.top_level], class_options, diagnostics)
        check_leaf_options(leaf, runtime_leaf, runtime_data, diagnostics)
        check_leaf_modes(leaf, runtime_leaf, diagnostics)
      end
    end

    def check_classifications(leaf, diagnostics)
      unless SUPPORT_CLASSES.include?(leaf.support)
        diagnostics << Diagnostic.new(kind: :invalid_support_class, subject: leaf.path, detail: leaf.support.inspect).freeze
      end
      unless COVERAGE_STATES.include?(leaf.coverage)
        diagnostics << Diagnostic.new(kind: :invalid_coverage_state, subject: leaf.path, detail: leaf.coverage.inspect).freeze
      end
      unless EVIDENCE_STATES.include?(leaf.evidence)
        diagnostics << Diagnostic.new(kind: :invalid_evidence_state, subject: leaf.path, detail: leaf.evidence.inspect).freeze
      end
      unless CONTEXT_POSTURES.include?(leaf.context_posture)
        diagnostics << Diagnostic.new(kind: :invalid_context_posture, subject: leaf.path, detail: leaf.context_posture.inspect).freeze
      end

      if leaf.evidence == "catalog_declared_with_exception" && !ALLOWED_CATALOG_DECLARED_PARENTS.include?(leaf.top_level)
        diagnostics << Diagnostic.new(
          kind: :disallowed_catalog_declared_parent, subject: leaf.path,
          detail: "only #{ALLOWED_CATALOG_DECLARED_PARENTS.join(", ")} may use catalog_declared_with_exception"
        ).freeze
      end

      if leaf.coverage == "checked_exception"
        check_exception_record(leaf, diagnostics)
      elsif leaf.coverage == "full"
        if leaf.exception
          diagnostics << Diagnostic.new(kind: :unexpected_exception, subject: leaf.path, detail: "full record must not carry Exception").freeze
        end
        check_required_semantic_fields(leaf, excluded_field: nil, diagnostics: diagnostics)
      end
    end

    def check_exception_record(leaf, diagnostics)
      exc = leaf.exception
      if exc.nil?
        diagnostics << Diagnostic.new(kind: :incomplete_exception, subject: leaf.path, detail: "missing Exception metadata").freeze
        return
      end
      %i[field evidence owner follow_up].each do |attr|
        if exc.public_send(attr).empty?
          diagnostics << Diagnostic.new(kind: :incomplete_exception, subject: leaf.path, detail: "missing exception #{attr}").freeze
        end
      end
      check_required_semantic_fields(leaf, excluded_field: exc.field, diagnostics: diagnostics)
    end

    def check_required_semantic_fields(leaf, excluded_field:, diagnostics:)
      {
        "output" => leaf.output,
        "context_behavior" => leaf.context_behavior,
        "exits_and_retry" => leaf.exits_and_retry,
        "effects_and_approvals" => leaf.effects_and_approvals,
        "example" => leaf.example
      }.each do |name, value|
        next if excluded_field == name
        next unless value.strip.empty?

        diagnostics << Diagnostic.new(kind: :missing_semantic_field, subject: leaf.path, detail: name).freeze
      end
    end

    def check_evidence_state(leaf, runtime_leaf, diagnostics)
      expected = runtime_leaf.evidence_state.to_s
      if leaf.evidence != expected
        diagnostics << Diagnostic.new(
          kind: :evidence_state_mismatch, subject: leaf.path,
          detail: "expected=#{expected} actual=#{leaf.evidence}"
        ).freeze
      end
      if expected == "catalog_declared_with_exception" && leaf.coverage != "checked_exception"
        diagnostics << Diagnostic.new(
          kind: :missing_checked_exception, subject: leaf.path,
          detail: "catalog_declared_with_exception requires coverage=checked_exception"
        ).freeze
      end
    end

    def check_context_posture(leaf, runtime_leaf, diagnostics)
      return unless CONTEXT_POSTURES.include?(leaf.context_posture)
      return if leaf.context_posture == runtime_leaf.context_posture

      diagnostics << Diagnostic.new(
        kind: :context_posture_mismatch, subject: leaf.path,
        detail: "expected=#{runtime_leaf.context_posture} actual=#{leaf.context_posture}"
      ).freeze
    end

    def check_leaf_signatures(leaf, runtime_leaf, command, class_options, diagnostics)
      if leaf.signatures.empty?
        diagnostics << Diagnostic.new(kind: :missing_signature, subject: leaf.path, detail: "no signatures declared").freeze
        return
      end

      opts_map = options_map_for(command, class_options)
      parsed_forms = []
      leaf.signatures.each do |raw_sig|
        begin
          expanded = SignatureGrammar.expand(raw_sig, options_by_switch: opts_map)
          parsed_forms.concat(expanded)
        rescue SignatureGrammar::ParseError => error
          diagnostics << Diagnostic.new(kind: :malformed_signature, subject: leaf.path, detail: "#{raw_sig}: #{error.message}").freeze
        end
      end

      parsed_forms.map(&:canonical).tally.each do |canonical, count|
        next unless count > 1

        diagnostics << Diagnostic.new(kind: :duplicate_signature, subject: leaf.path, detail: canonical).freeze
      end

      parsed_forms.each do |form|
        (form.option_switches - leaf.options).each do |opt|
          diagnostics << Diagnostic.new(kind: :signature_option_unlisted, subject: leaf.path, detail: opt).freeze
        end
        if runtime_leaf.owner_tail_check && !runtime_leaf.owner_tail_check.call(form)
          diagnostics << Diagnostic.new(kind: :owner_tail_mismatch, subject: leaf.path, detail: form.canonical).freeze
        end
      end

      expected_set = runtime_leaf.forms.map(&:canonical).uniq
      actual_set = parsed_forms.map(&:canonical).uniq
      (expected_set - actual_set).sort.each do |missing|
        diagnostics << Diagnostic.new(kind: :missing_signature, subject: leaf.path, detail: missing).freeze
      end
      (actual_set - expected_set).sort.each do |extra|
        diagnostics << Diagnostic.new(kind: :extra_signature, subject: leaf.path, detail: extra).freeze
      end
    end

    def options_map_for(command, class_options)
      map = {}
      class_options.each do |key, opt|
        sw = opt.respond_to?(:switch_name) && opt.switch_name ? opt.switch_name : "--#{key.to_s.tr("_", "-")}"
        map[sw] = OptionSpec.new(switch: sw, type: opt.type, required: !!opt.required, repeatable: !!opt.repeatable, hidden: !!opt.hide).freeze
      end
      if command
        command.options.each do |key, opt|
          sw = opt.respond_to?(:switch_name) && opt.switch_name ? opt.switch_name : "--#{key.to_s.tr("_", "-")}"
          map[sw] = OptionSpec.new(switch: sw, type: opt.type, required: !!opt.required, repeatable: !!opt.repeatable, hidden: !!opt.hide).freeze
        end
      end
      map
    end

    def check_leaf_options(leaf, runtime_leaf, runtime_data, diagnostics)
      visible = runtime_data.visible_options_by_top_level.fetch(leaf.top_level, [])
      (INHERITED_CLASS_OPTIONS - leaf.options).each do |flag|
        diagnostics << Diagnostic.new(kind: :missing_inherited_option, subject: leaf.path, detail: flag).freeze
      end
      (leaf.options - visible).sort.each do |extra|
        diagnostics << Diagnostic.new(kind: :extra_option, subject: leaf.path, detail: extra).freeze
      end
      (leaf.options & runtime_leaf.forbidden_options).sort.each do |forbidden|
        diagnostics << Diagnostic.new(kind: :misassigned_option, subject: leaf.path, detail: forbidden).freeze
      end
    end

    def check_option_unions(runtime_data, catalog_leaves, diagnostics)
      by_top = catalog_leaves.group_by(&:top_level)
      runtime_data.visible_options_by_top_level.each do |top_level, expected_visible|
        leaves = by_top[top_level] || []
        next if leaves.empty?

        documented_union = leaves.flat_map(&:options).uniq.sort
        (expected_visible - documented_union).each do |missing|
          diagnostics << Diagnostic.new(kind: :missing_option, subject: top_level, detail: missing).freeze
        end
        (documented_union - expected_visible).each do |extra|
          diagnostics << Diagnostic.new(kind: :extra_option, subject: top_level, detail: extra).freeze
        end
      end
    end

    def check_leaf_modes(leaf, runtime_leaf, diagnostics)
      leaf.modes.map(&:name).tally.each do |mode_name, count|
        next unless count > 1

        diagnostics << Diagnostic.new(kind: :duplicate_mode, subject: leaf.path, detail: mode_name).freeze
      end

      expected_by_name = runtime_leaf.expected_modes.to_h { |mode| [ mode.name, mode ] }
      actual_by_name = {}
      leaf.modes.each { |mode| actual_by_name[mode.name] ||= mode }

      (expected_by_name.keys - actual_by_name.keys).sort.each do |name|
        spec = expected_by_name.fetch(name)
        diagnostics << Diagnostic.new(
          kind: :missing_mode, subject: leaf.path, detail: "#{name} (condition: #{spec.condition})"
        ).freeze
      end

      (actual_by_name.keys - expected_by_name.keys).sort.each do |name|
        kind = runtime_leaf.expected_modes.empty? ? :misplaced_mode : :extra_mode
        diagnostics << Diagnostic.new(kind: kind, subject: leaf.path, detail: name).freeze
      end

      expected_by_name.each do |name, spec|
        actual = actual_by_name[name]
        next unless actual

        if actual.condition != spec.condition
          diagnostics << Diagnostic.new(
            kind: :mode_condition_mismatch, subject: "#{leaf.path}:#{name}",
            detail: "expected=#{spec.condition.inspect} actual=#{actual.condition.inspect}"
          ).freeze
        end
        (spec.required_options - actual.options).sort.each do |opt|
          diagnostics << Diagnostic.new(kind: :missing_mode_option, subject: "#{leaf.path}:#{name}", detail: opt).freeze
        end
        (actual.options & spec.forbidden_options).sort.each do |opt|
          diagnostics << Diagnostic.new(kind: :misassigned_mode_option, subject: "#{leaf.path}:#{name}", detail: opt).freeze
        end
      end

      return if leaf.modes.empty?

      mode_union = leaf.modes.flat_map(&:options).uniq.sort
      leaf_opts = leaf.options.uniq.sort
      if mode_union != leaf_opts
        diagnostics << Diagnostic.new(
          kind: :mode_option_union_mismatch, subject: leaf.path,
          detail: "leaf=#{leaf_opts.join(",")} modes=#{mode_union.join(",")}"
        ).freeze
      end
    end

    def check_exclusions(runtime_data, exclusions, diagnostics)
      exclusions.each do |entry|
        unless entry.support == "private"
          diagnostics << Diagnostic.new(kind: :invalid_exclusion_support, subject: entry.name, detail: entry.support).freeze
        end
      end

      visible_top_levels = runtime_data.leaves.map(&:top_level).uniq
      doc_hidden_cmds = exclusions.select { |e| e.category == :hidden_command }.map(&:name)
      doc_hidden_opts = exclusions.select { |e| e.category == :hidden_option }.map(&:name)
      doc_private_routes = exclusions.select { |e| e.category == :private_route }.map(&:name)

      doc_hidden_cmds.each do |name|
        if visible_top_levels.include?(name)
          diagnostics << Diagnostic.new(kind: :visible_command_in_exclusions, subject: name, detail: "visible command cannot be excluded").freeze
        end
      end
      (runtime_data.hidden_commands - doc_hidden_cmds).sort.each do |name|
        diagnostics << Diagnostic.new(kind: :missing_exclusion, subject: name, detail: "hidden_command").freeze
      end
      (doc_hidden_cmds - runtime_data.hidden_commands - visible_top_levels).sort.each do |name|
        diagnostics << Diagnostic.new(kind: :extra_exclusion, subject: name, detail: "hidden_command").freeze
      end

      doc_hidden_opts.each do |entry|
        top, flag = entry.split(" ", 2)
        if runtime_data.visible_options_by_top_level.fetch(top, []).include?(flag)
          diagnostics << Diagnostic.new(kind: :visible_option_in_exclusions, subject: entry, detail: "visible option cannot be excluded").freeze
        end
      end
      (runtime_data.hidden_options - doc_hidden_opts).sort.each do |entry|
        diagnostics << Diagnostic.new(kind: :missing_exclusion, subject: entry, detail: "hidden_option").freeze
      end
      (doc_hidden_opts - runtime_data.hidden_options).sort.each do |entry|
        top, flag = entry.split(" ", 2)
        next if runtime_data.visible_options_by_top_level.fetch(top, []).include?(flag)

        diagnostics << Diagnostic.new(kind: :extra_exclusion, subject: entry, detail: "hidden_option").freeze
      end

      (runtime_data.private_routes - doc_private_routes).sort.each do |route|
        diagnostics << Diagnostic.new(kind: :missing_exclusion, subject: route, detail: "private_route").freeze
      end
      (doc_private_routes - runtime_data.private_routes).sort.each do |route|
        diagnostics << Diagnostic.new(kind: :extra_exclusion, subject: route, detail: "private_route").freeze
      end
    end
  end
end

class DocsCliAuthorityTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOCS_CLI_PATH = File.join(ROOT, "docs/cli.md")

  FakeOption = Struct.new(:switch_name, :type, :required, :repeatable, :hide, keyword_init: true)
  FakeCommand = Struct.new(:usage, :hidden, :options, :long_description, keyword_init: true) do
    def hidden? = !!hidden
  end

  def auditor
    @auditor ||= DocsCliAuthority::Auditor.new(root: ROOT)
  end

  def docs_cli_text
    File.read(DOCS_CLI_PATH)
  end

  def assert_diagnostic(result, kind, subject = nil, detail_pattern = nil)
    match = result.diagnostics.find do |diag|
      diag.kind == kind &&
        (subject.nil? || diag.subject == subject) &&
        (detail_pattern.nil? || diag.detail.to_s.match?(detail_pattern))
    end
    assert match, "expected diagnostic #{kind} (#{subject.inspect}, #{detail_pattern.inspect}) in:\n#{result.diagnostics.map(&:to_s).join("\n")}"
  end

  # Scenario 1: Shared partition, bidirectional parity, unique paths, grammar fixtures, unadapted parent
  def test_live_docs_cli_catalog_matches_runtime_surface_bidirectionally
    result = auditor.audit(document_text: docs_cli_text)

    assert result.success?, result.diagnostics.map(&:to_s).join("\n")
    paths = result.catalog.leaves.map(&:path)
    assert_equal paths.uniq, paths

    # R6 acceptance examples
    %w[
      answer watch act web connect\ screenote disconnect\ screenote drop
      plan-review\ TARGET\ show module\ dry-run worktree\ status
      context\ list token\ list operation stack status
    ].each do |path|
      assert_includes paths, path
    end

    status_leaf = result.catalog.leaves.find { |leaf| leaf.path == "status" }
    %w[--diagnose --project --stage --write --force --operational --json --context].each do |flag|
      assert_includes status_leaf.options, flag
    end
  end

  def test_signature_grammar_fixtures_and_malformed_rejections
    opts = {
      "--project" => DocsCliAuthority::OptionSpec.new(switch: "--project", type: :string, required: false, repeatable: false, hidden: false),
      "--on" => DocsCliAuthority::OptionSpec.new(switch: "--on", type: :string, required: false, repeatable: true, hidden: false),
      "--clear" => DocsCliAuthority::OptionSpec.new(switch: "--clear", type: :boolean, required: false, repeatable: false, hidden: false),
      "--all" => DocsCliAuthority::OptionSpec.new(switch: "--all", type: :boolean, required: false, repeatable: false, hidden: false),
      "--json" => DocsCliAuthority::OptionSpec.new(switch: "--json", type: :boolean, required: false, repeatable: false, hidden: false),
      "--from" => DocsCliAuthority::OptionSpec.new(switch: "--from", type: :string, required: false, repeatable: false, hidden: false)
    }

    op_forms = DocsCliAuthority::SignatureGrammar.expand("operation ID --project PROJECT", options_by_switch: opts)
    assert_equal [ "operation ID --project PROJECT" ], op_forms.map(&:canonical)
    assert_equal [ "ID" ], op_forms.first.operands.map(&:name)
    assert_equal [ "--project" ], op_forms.first.option_switches

    stack_forms = DocsCliAuthority::SignatureGrammar.expand("stack TARGET (--on PREREQUISITE... | --clear)", options_by_switch: opts)
    assert_equal [ "stack TARGET --on PREREQUISITE...", "stack TARGET --clear" ], stack_forms.map(&:canonical)
    assert stack_forms.first.atoms.last.repeatable

    enable_forms = DocsCliAuthority::SignatureGrammar.expand("daemon enable PROJECT|--all [--json]", options_by_switch: opts)
    assert_equal [ "daemon enable PROJECT [--json]", "daemon enable --all [--json]" ], enable_forms.map(&:canonical)

    disable_forms = DocsCliAuthority::SignatureGrammar.expand("daemon disable PROJECT|--all [--json]", options_by_switch: opts)
    assert_equal [ "daemon disable PROJECT [--json]", "daemon disable --all [--json]" ], disable_forms.map(&:canonical)

    queue_forms = DocsCliAuthority::SignatureGrammar.expand("daemon queue [list|show <id>|prune]", options_by_switch: opts)
    assert_equal [ "daemon queue", "daemon queue list", "daemon queue show <id>", "daemon queue prune" ], queue_forms.map(&:canonical)

    wf_forms = [
      *DocsCliAuthority::SignatureGrammar.expand("workflow install honeycomb/NAME[@VERSION]", options_by_switch: opts),
      *DocsCliAuthority::SignatureGrammar.expand("workflow install ID --from REPOSITORY", options_by_switch: opts)
    ]
    assert_equal [ "workflow install honeycomb/NAME[@VERSION]", "workflow install ID --from REPOSITORY" ], wf_forms.map(&:canonical)

    # Distinct operand/rest shapes
    new_form = DocsCliAuthority::SignatureGrammar.expand("new PROJECT TEXT", options_by_switch: opts).first
    watch_form = DocsCliAuthority::SignatureGrammar.expand("watch [TARGET...]", options_by_switch: opts).first
    ev_term = DocsCliAuthority::SignatureGrammar.expand("evidence terminal NAME -- COMMAND...", options_by_switch: opts).first
    assert_equal [ true, true ], new_form.operands.map(&:required)
    assert_equal [ false, false ], new_form.operands.map(&:rest)
    assert_equal [ false ], watch_form.operands.map(&:required)
    assert_equal [ true ], watch_form.operands.map(&:rest)
    assert_equal :separator, ev_term.atoms[3].kind
    assert_equal [ false, true ], ev_term.operands.map(&:rest)

    # Malformed signatures fail closed
    [
      "stack TARGET (--on PREREQUISITE... | --clear",
      "daemon queue [list|show <id>",
      "daemon enable PROJECT||--all",
      "stack TARGET (| --clear)",
      "operation ID --project",
      "stack TARGET --clear EXTRA_VAL",
      "status --undeclared-flag",
      "operation ID --project PROJECT..."
    ].each do |bad|
      if bad == "stack TARGET --clear EXTRA_VAL"
        # Boolean switch cannot accept =value
        assert_raises(DocsCliAuthority::SignatureGrammar::ParseError) do
          DocsCliAuthority::SignatureGrammar.expand("stack TARGET --clear=EXTRA_VAL", options_by_switch: opts)
        end
      else
        assert_raises(DocsCliAuthority::SignatureGrammar::ParseError, "expected parse error for #{bad.inspect}") do
          DocsCliAuthority::SignatureGrammar.expand(bad, options_by_switch: opts)
        end
      end
    end
  end

  def test_unadapted_visible_selector_parent_fails_closed
    mutated_commands = Hive::CLI.all_commands.merge(
      "mystery" => FakeCommand.new(usage: "mystery SUBCOMMAND", hidden: false, options: {}, long_description: "Subcommands:\n  run  Run it\n")
    )
    result = auditor.audit(document_text: docs_cli_text, all_commands: mutated_commands)

    assert_diagnostic result, :unadapted_selector_parent, "mystery"
  end

  # Scenario 2: Missing answer and extra retired circuits
  def test_removing_answer_and_injecting_retired_circuits_report_exact_diagnostics
    without_answer = remove_leaf(docs_cli_text, "answer")
    missing_result = auditor.audit(document_text: without_answer)
    assert_diagnostic missing_result, :missing_command, "answer"

    with_circuits = inject_leaf(docs_cli_text, <<~MARKDOWN)
      ### `hive circuits`

      - **Aliases:** none
      - **Support:** `stable`
      - **Coverage:** `full`
      - **Evidence:** `top_level`
      - **Context posture:** `local_only`
      - **Signatures:**
        - `hive circuits`
      - **Options:** `--json`, `--context`
      - **Output:** Retired fixture.
      - **Context behavior:** Local only.
      - **Exits and retry:** Exit 0.
      - **Effects and approvals:** Read-only.
      - **Example:** `hive circuits`
    MARKDOWN
    extra_result = auditor.audit(document_text: with_circuits)
    assert_diagnostic extra_result, :extra_command, "circuits"
  end

  # Scenario 3: Removing --force from status option union and applicable mode
  def test_removing_force_from_status_reports_missing_option
    mutated = mutate_leaf(docs_cli_text, "status") do |section|
      section.gsub(", `--force`", "").gsub("`--force`, ", "")
    end
    result = auditor.audit(document_text: mutated)

    assert_diagnostic result, :missing_option, "status", /--force/
    assert_diagnostic result, :missing_mode_option, "status:diagnose_write", /--force/
  end

  # Scenario 4: Omitting module dry-run, pairing literal/operand, daemon queue show operand
  def test_selector_path_and_signature_component_omissions_fail_closed
    without_dry_run = remove_leaf(docs_cli_text, "module dry-run")
    assert_diagnostic auditor.audit(document_text: without_dry_run), :missing_command, "module dry-run"

    bad_pairing_literal = mutate_leaf(docs_cli_text, "pairing approve") do |section|
      section.sub("`hive pairing approve telegram <CODE> [--json]`", "`hive pairing approve <CODE> [--json]`")
    end
    assert_diagnostic auditor.audit(document_text: bad_pairing_literal), :missing_signature, "pairing approve", /telegram <CODE>/

    bad_pairing_operand = mutate_leaf(docs_cli_text, "pairing approve") do |section|
      section.sub("`hive pairing approve telegram <CODE> [--json]`", "`hive pairing approve telegram [--json]`")
    end
    assert_diagnostic auditor.audit(document_text: bad_pairing_operand), :missing_signature, "pairing approve", /<CODE>/

    bad_queue_show = mutate_leaf(docs_cli_text, "daemon queue show") do |section|
      section.sub("`hive daemon queue show <id>`", "`hive daemon queue show`")
    end
    assert_diagnostic auditor.audit(document_text: bad_queue_show), :missing_signature, "daemon queue show", /<id>/
  end

  # Scenario 5: Web registry expansion, bare web removal, stale registry-expansion when structured rows appear
  def test_web_registry_expansion_bare_path_and_staleness_checks
    require "hive/commands/web"
    expanded = Hive::Commands::Web::VALID_SUBCOMMANDS + [ "restart" ]
    result = auditor.audit(document_text: docs_cli_text, registries: { "web" => expanded })
    assert_diagnostic result, :missing_command, "web restart"

    without_bare_web = remove_leaf(docs_cli_text, "web")
    assert_diagnostic auditor.audit(document_text: without_bare_web), :missing_command, "web"

    stale_result = auditor.audit(
      document_text: docs_cli_text,
      long_descs: { "web" => "Subcommands:\n  install  Install web\n" }
    )
    assert_diagnostic stale_result, :stale_evidence_state, "web"
  end

  # Scenario 6: Workflow install dual signatures and duplicate signature failure
  def test_workflow_install_requires_both_signatures_and_rejects_duplicates
    missing_honeycomb = mutate_leaf(docs_cli_text, "workflow install") do |section|
      section.sub("  - `hive workflow install honeycomb/NAME[@VERSION]`\n", "")
    end
    assert_diagnostic auditor.audit(document_text: missing_honeycomb), :missing_signature, "workflow install", /honeycomb\/NAME\[@VERSION\]/

    missing_git = mutate_leaf(docs_cli_text, "workflow install") do |section|
      section.sub("  - `hive workflow install ID --from REPOSITORY`\n", "")
    end
    assert_diagnostic auditor.audit(document_text: missing_git), :missing_signature, "workflow install", /--from REPOSITORY/

    duplicate_sig = mutate_leaf(docs_cli_text, "workflow install") do |section|
      section.sub(
        "  - `hive workflow install ID --from REPOSITORY`\n",
        "  - `hive workflow install ID --from REPOSITORY`\n  - `hive workflow install ID --from=REPOSITORY`\n"
      )
    end
    assert_diagnostic auditor.audit(document_text: duplicate_sig), :duplicate_signature, "workflow install"
  end

  # Scenario 7: Receipt, token, context owner-grammar and checked-exception boundaries
  def test_receipt_token_and_context_evidence_and_exception_guards
    without_abandon = remove_leaf(docs_cli_text, "receipt abandon-batch")
    assert_diagnostic auditor.audit(document_text: without_abandon), :missing_command, "receipt abandon-batch"

    bad_token_revoke = mutate_leaf(docs_cli_text, "token revoke") do |section|
      section.sub("`hive token revoke ID`", "`hive token revoke`")
    end
    token_result = auditor.audit(document_text: bad_token_revoke)
    assert_diagnostic token_result, :missing_signature, "token revoke", /token revoke ID/
    assert_diagnostic token_result, :owner_tail_mismatch, "token revoke"

    without_context_show = remove_leaf(docs_cli_text, "context show")
    assert_diagnostic auditor.audit(document_text: without_context_show), :missing_command, "context show"

    optional_context_use = mutate_leaf(docs_cli_text, "context use") do |section|
      section.sub("`hive context use NAME`", "`hive context use [NAME]`")
    end
    use_result = auditor.audit(document_text: optional_context_use)
    assert_diagnostic use_result, :missing_signature, "context use", /context use NAME/
    assert_diagnostic use_result, :owner_tail_mismatch, "context use"

    broken_exception = mutate_leaf(docs_cli_text, "token list") do |section|
      section.sub(/follow_up=`[^`]+`/, "follow_up=``")
    end
    assert_diagnostic auditor.audit(document_text: broken_exception), :incomplete_exception, "token list", /follow_up/

    disallowed_state4 = mutate_leaf(docs_cli_text, "doctor") do |section|
      section.sub("- **Evidence:** `top_level`", "- **Evidence:** `catalog_declared_with_exception`")
    end
    assert_diagnostic auditor.audit(document_text: disallowed_state4), :disallowed_catalog_declared_parent, "doctor"
  end

  # Scenario 8: Mode deletion and misassignment for daemon, archive, and review
  def test_mode_isolation_for_daemon_once_archive_and_review
    missing_daemon_once = mutate_leaf(docs_cli_text, "daemon") do |section|
      section.lines.reject { |line| line.include?("**Mode `once`**") }.join
    end
    daemon_result = auditor.audit(document_text: missing_daemon_once)
    assert_diagnostic daemon_result, :missing_mode, "daemon", /--once PROJECT without named SUBCOMMAND/

    misplaced_daemon_once = mutate_leaf(docs_cli_text, "daemon start") do |section|
      section.sub(
        "- **Options:**",
        "- **Modes:**\n  - **Mode `once`** (condition: `--once PROJECT`; options: `--once`, `--json`, `--context`): misplaced.\n- **Options:**"
      ).sub("- **Options:** ", "- **Options:** `--once`, ")
    end
    misplaced_result = auditor.audit(document_text: misplaced_daemon_once)
    assert_diagnostic misplaced_result, :misplaced_mode, "daemon start", /once/
    assert_diagnostic misplaced_result, :misassigned_option, "daemon start", /--once/

    missing_archive_mode = mutate_leaf(docs_cli_text, "archive") do |section|
      section.lines.reject { |line| line.include?("**Mode `closure_preview`**") }.join
    end
    assert_diagnostic auditor.audit(document_text: missing_archive_mode), :missing_mode, "archive", /closure_preview/

    missing_review_mode = mutate_leaf(docs_cli_text, "review") do |section|
      section.lines.reject { |line| line.include?("**Mode `adhoc_pr`**") }.join
    end
    assert_diagnostic auditor.audit(document_text: missing_review_mode), :missing_mode, "review", /adhoc_pr/
  end

  # Scenario 9: Context posture, support class, coverage/evidence, duplicate path, unassigned option, incomplete exception
  def test_classification_context_posture_and_structural_failures
    bad_posture = mutate_leaf(docs_cli_text, "status") do |section|
      section.sub("- **Context posture:** `supported_remote`", "- **Context posture:** `local_only`")
    end
    assert_diagnostic auditor.audit(document_text: bad_posture), :context_posture_mismatch, "status", /expected=supported_remote actual=local_only/

    bad_support = mutate_leaf(docs_cli_text, "doctor") do |section|
      section.sub("- **Support:** `stable`", "- **Support:** `private`")
    end
    assert_diagnostic auditor.audit(document_text: bad_support), :invalid_support_class, "doctor"

    bad_coverage = mutate_leaf(docs_cli_text, "doctor") do |section|
      section.sub("- **Coverage:** `full`", "- **Coverage:** `partial`")
    end
    assert_diagnostic auditor.audit(document_text: bad_coverage), :invalid_coverage_state, "doctor"

    dup_path = inject_leaf(docs_cli_text, extract_leaf(docs_cli_text, "doctor"))
    assert_diagnostic auditor.audit(document_text: dup_path), :duplicate_catalog_path, "doctor"

    unassigned_opt = mutate_leaf(docs_cli_text, "doctor") do |section|
      section.sub("- **Options:** `--json`, `--context`", "- **Options:** `--context`")
    end
    opt_result = auditor.audit(document_text: unassigned_opt)
    assert_diagnostic opt_result, :missing_inherited_option, "doctor", /--json/
    assert_diagnostic opt_result, :missing_option, "doctor", /--json/
  end

  # Scenario 10: Alias omission, duplicate alias owner, hidden-to-visible exclusion flip
  def test_alias_parity_collisions_and_hidden_to_visible_exclusion_failure
    without_pr = mutate_leaf(docs_cli_text, "open-pr") do |section|
      section.sub("- **Aliases:** `pr`", "- **Aliases:** none")
    end
    assert_diagnostic auditor.audit(document_text: without_pr), :missing_alias, "open-pr", /pr/

    duplicate_pr = mutate_leaf(docs_cli_text, "review") do |section|
      section.sub("- **Aliases:** none", "- **Aliases:** `pr`")
    end
    dup_alias_result = auditor.audit(document_text: duplicate_pr)
    assert_diagnostic dup_alias_result, :duplicate_alias_owner, "pr"

    # Flip hidden command to visible in memory
    flipped = Hive::CLI.all_commands.transform_values do |cmd|
      if cmd.usage.to_s.split.first == "refactor-patrol-scheduled"
        FakeCommand.new(usage: cmd.usage, hidden: false, options: cmd.options, long_description: cmd.long_description)
      else
        cmd
      end
    end
    flip_result = auditor.audit(document_text: docs_cli_text, all_commands: flipped)
    assert_diagnostic flip_result, :visible_command_in_exclusions, "refactor-patrol-scheduled"
    assert_diagnostic flip_result, :missing_command, "refactor-patrol-scheduled"
  end

  # Scenario 11: Deterministic repeated runs and zero file writes
  def test_repeated_audit_is_deterministic_and_read_only
    before = tree_snapshot(File.join(ROOT, "docs"))
    valid_first = auditor.audit(document_text: docs_cli_text)
    valid_second = auditor.audit(document_text: docs_cli_text)
    assert_equal valid_first.success?, valid_second.success?
    assert_equal valid_first.diagnostics.map(&:to_s), valid_second.diagnostics.map(&:to_s)

    broken = remove_leaf(docs_cli_text, "answer")
    invalid_first = auditor.audit(document_text: broken)
    invalid_second = auditor.audit(document_text: broken)
    assert_equal invalid_first.success?, invalid_second.success?
    assert_equal invalid_first.diagnostics.map(&:to_s), invalid_second.diagnostics.map(&:to_s)
    assert_equal invalid_first.diagnostics.map(&:sort_key).sort, invalid_first.diagnostics.map(&:sort_key)
    assert_equal before, tree_snapshot(File.join(ROOT, "docs"))
  end

  private

  def extract_leaf(document, path)
    heading = "### `hive #{path}`\n"
    start = document.index(heading)
    raise "leaf #{path.inspect} not found in document" unless start

    rest = document[(start + heading.length)..]
    stop = rest.index(/\n###? /)
    stop ? document[start...(start + heading.length + stop + 1)] : document[start..]
  end

  def remove_leaf(document, path)
    section = extract_leaf(document, path)
    document.sub(section, "")
  end

  def mutate_leaf(document, path)
    section = extract_leaf(document, path)
    document.sub(section, yield(section))
  end

  def inject_leaf(document, leaf_markdown)
    anchor = "## Excluded Hidden and Private Routes"
    document.sub(anchor, "#{leaf_markdown.rstrip}\n\n#{anchor}")
  end

  def tree_snapshot(dir)
    Find.find(dir).sort.map do |path|
      stat = File.lstat(path)
      digest = stat.file? ? Digest::SHA256.file(path).hexdigest : stat.ftype
      [ path, stat.ftype, stat.size, stat.mtime.to_r, digest ]
    end
  end
end
