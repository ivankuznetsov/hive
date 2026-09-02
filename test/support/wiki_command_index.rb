# frozen_string_literal: true

module WikiCommandIndex
  ANSI_ESCAPE = /\e\[[0-?]*[ -\/]*[@-~]/.freeze
  COMMAND_NAME = /\A[a-z0-9_][a-z0-9_-]*\z/.freeze
  INDEX_COMMAND_NAME = /(?:[a-z0-9_][a-z0-9_-]*|--?[a-z0-9][a-z0-9_-]*)/.freeze
  OWNER_TARGET = /\A(?:commands|modules)\/[a-z0-9][a-z0-9_-]*\z/.freeze
  ANY_COMMAND = /\bhive[ \t]+(?:[a-z0-9_][a-z0-9_-]*|--?[a-z0-9][a-z0-9_-]*)/.freeze
  WRAPPER_ALIASES = { "-v" => "version" }.freeze
  COMMAND_OWNERS = {
    "archive" => "commands/stage_action",
    "artifacts" => "commands/stage_action",
    "brainstorm" => "commands/stage_action",
    "develop" => "commands/stage_action",
    "finalize" => "commands/stage_action",
    "open-pr" => "commands/stage_action",
    "plan" => "commands/stage_action",
    "plan-review" => "modules/plan_review",
    "plan-review-run" => "modules/plan_review",
    "review" => "commands/stage_action",
    "worktree" => "modules/worktree"
  }.freeze

  Diagnostic = Struct.new(:kind, :subject, :detail, keyword_init: true) do
    def sort_key
      [ kind.to_s, subject.to_s, detail.to_s ]
    end

    def to_s
      [ kind, subject, detail ].compact.map(&:to_s).join(": ")
    end
  end

  Row = Struct.new(:command, :owner, :line, keyword_init: true)
  Section = Struct.new(:heading, :body, keyword_init: true)
  MarkdownLine = Struct.new(:number, :text, :fenced, keyword_init: true)
  ContractContext = Struct.new(:command, :pattern, :texts, keyword_init: true)
  Result = Struct.new(
    :help_commands,
    :index_commands,
    :owners,
    :owner_documents,
    :diagnostics,
    keyword_init: true
  ) do
    def success?
      diagnostics.empty?
    end
  end

  Metadata = Struct.new(:visible, :hidden, :aliases, :diagnostics, keyword_init: true)

  class Guard
    # Owner pages predate this guard and use domain-specific H2 names. These
    # patterns enumerate that existing heading vocabulary; the requirement
    # checks below still require explicit, command-scoped content rather than
    # treating a heading match alone as a contract.
    CONTRACT_HEADINGS = {
      syntax: /\A(?:Usage|Synopsis|CLI|Invocation|Surface|Subcommands|Mode contract|Inspection|Commands)\b/i,
      options: /\b(?:Usage|Synopsis|CLI|Invocation|Surface|Subcommands|Mode contract|Inspection|Commands|Options?)\b/i,
      behavior: /\A(?:Behavior|Steps performed|Lifecycle|Flow|Pipeline|Effects?|Contract|Commands|Actions?|Mutations?|Guards?|Inspection|Diagnosis|Status|States|Modes|Meaning|Boundaries|Cleanup|Inputs|Outcomes?|Backend|Read-only|Dispatch|Recovery|Preconditions|Events|Channels?|Installers?|Bundle|Surfaces?|Layout|Data source|Class shape|Connect Behavior|Disconnect Behavior|What the daemon dispatches|Runtime control-plane diagnosis|Discovery lifecycle|Applicability and boundary|Consent and lifecycle)\b/i,
      examples: /\b(?:Usage|Synopsis|CLI|Invocation|Surface|Subcommands|Mode contract|Inspection|Commands|Examples?)\b/i,
      schema: /\b(?:JSON|Schema|Output|Contract|Inventory|Outcomes?|Structured log|Inspection|Serialization|CLI|Machine-readable|Status|Task metadata|Data source|Surfaces?|Validation|Usage|Synopsis|Errors?|Exit codes?|Meaning|Events)\b/i,
      output_exceptions: /\b(?:Errors?|Failures?|Refusals?|Output exceptions?|Exit codes?|Outcomes?|Termination|Serialization|Contract|Machine-readable)\b/i,
      serialization_fallback: /\b(?:Serialization|JSON|Output|Errors?|Termination|Exit codes?)\b/i,
      exit_codes: /\b(?:Exit codes?|Errors?|Failures?|Refusals?|Outcomes?|Termination|Serialization|Contract|Machine-readable)\b/i
    }.freeze

    def initialize(wiki_root: nil, owner_reader: nil, expected_owners: COMMAND_OWNERS)
      @wiki_root = wiki_root
      @owner_reader = owner_reader || method(:read_owner)
      @expected_owners = expected_owners
    end

    def evaluate(help_text:, index_text:, validate_contracts: true)
      help_commands, help_diagnostics = parse_help(help_text)
      rows, index_diagnostics = parse_index(index_text)
      diagnostics = help_diagnostics + index_diagnostics
      diagnostics.concat(navigation_only_diagnostics(index_text))

      diagnostics.concat(duplicate_diagnostics(help_commands, :duplicate_help_command))
      diagnostics.concat(duplicate_diagnostics(rows.map(&:command).compact, :duplicate_index_command))
      help_set = help_commands.uniq
      index_set = rows.map(&:command).compact.uniq
      diagnostics.concat(missing_pinned_owner_diagnostics(index_set))
      (help_set - index_set).each do |command|
        diagnostics << diagnostic(:missing_index_command, command)
      end
      (index_set - help_set).each do |command|
        diagnostics << diagnostic(:stale_index_command, command)
      end

      owners, owner_documents, owner_diagnostics = resolve_owners(rows)
      diagnostics.concat(owner_diagnostics)
      diagnostics.concat(validate_owner_contracts(owners, owner_documents)) if validate_contracts

      Result.new(
        help_commands: help_commands.freeze,
        index_commands: rows.map(&:command).compact.freeze,
        owners: owners.freeze,
        owner_documents: owner_documents.freeze,
        diagnostics: diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    def metadata(all_commands:, command_map:)
      diagnostics = []
      public_by_method = {}

      all_commands.each do |method_name, command|
        usage_token = command.usage.to_s.split.first
        unless usage_token&.match?(COMMAND_NAME)
          diagnostics << diagnostic(:invalid_metadata_usage, method_name, command.usage.to_s)
          next
        end

        mapped_names = command_map.each_with_object([]) do |(public_name, target), names|
          names << public_name if target.to_s == method_name.to_s && public_name.match?(COMMAND_NAME)
        end
        if mapped_names.any? && !mapped_names.include?(usage_token)
          diagnostics << diagnostic(
            :metadata_map_mismatch,
            method_name,
            "usage=#{usage_token} mapped=#{mapped_names.sort.join(',')}"
          )
          next
        end

        public_by_method[method_name.to_s] = usage_token
      end

      visible = []
      hidden = []
      all_commands.each do |method_name, command|
        public_name = public_by_method[method_name.to_s]
        next unless public_name

        (command.hidden? ? hidden : visible) << public_name
      end

      aliases = WRAPPER_ALIASES.dup
      command_map.each do |public_name, target|
        canonical = public_by_method[target.to_s]
        next unless canonical
        next if public_name == canonical

        aliases[public_name] = canonical
      end

      (visible & aliases.keys).each do |public_name|
        diagnostics << diagnostic(:alias_canonical_collision, public_name, aliases.fetch(public_name))
      end

      Metadata.new(
        visible: visible.sort.freeze,
        hidden: hidden.sort.freeze,
        aliases: aliases.sort.to_h.freeze,
        diagnostics: diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    private

    def parse_help(text)
      lines = text.gsub(ANSI_ESCAPE, "").lines
      start = lines.index { |line| line.strip == "Commands:" }
      return [ [], [ diagnostic(:missing_help_commands_section) ] ] unless start

      commands = []
      lines.drop(start + 1).each do |line|
        break if commands.any? && line.match?(/\A\S.*:\s*\z/)
        next if line.strip.empty?

        # Thor renders command banners with exactly two leading spaces. Matching
        # that boundary avoids treating wrapped descriptions as commands when
        # the terminal is narrow.
        match = line.match(/\A\s{2}\S+\s+(#{INDEX_COMMAND_NAME})(?=\s|\z)/)
        commands << match[1] if match
      end

      diagnostics = []
      diagnostics << diagnostic(:empty_help_commands_section) if commands.empty?
      [ commands, diagnostics ]
    end

    def parse_index(text)
      lines = markdown_lines(text)
      start = lines.index { |line| !line.fenced && line.text.strip == "## Command index" }
      return [ [], [ diagnostic(:missing_index_section) ] ] unless start

      section = lines.drop(start + 1).take_while do |line|
        line.fenced || !line.text.start_with?("## ")
      end
      table_lines = section.filter_map do |line|
        [ line.text, line.number ] if !line.fenced && line.text.lstrip.start_with?("|")
      end
      diagnostics = []
      if table_lines.size < 2
        return [ [], [ diagnostic(:missing_index_table) ] ]
      end

      header = cells(table_lines[0][0])
      separator = cells(table_lines[1][0])
      unless header == [ "Command", "Owner" ] && separator&.size == 2 &&
          separator.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
        diagnostics << diagnostic(:malformed_index_header, table_lines[0][1])
      end

      rows = table_lines.drop(2).filter_map do |line, line_number|
        row_cells = cells(line)
        unless row_cells&.size == 2
          diagnostics << diagnostic(:malformed_index_row, line_number, line.strip)
          next
        end

        command_match = row_cells[0].match(/\A`hive (#{INDEX_COMMAND_NAME})`\z/)
        unless command_match
          diagnostics << diagnostic(:malformed_command_cell, line_number, row_cells[0])
          next
        end

        owner_links = row_cells[1].scan(/\[\[([^\]]+)\]\]/).flatten
        owner = nil
        case owner_links.size
        when 0
          diagnostics << diagnostic(:missing_owner_link, command_match[1])
        when 1
          owner = owner_links.first
          unless row_cells[1] == "[[#{owner}]]"
            diagnostics << diagnostic(:malformed_owner_cell, command_match[1], row_cells[1])
          end
        else
          diagnostics << diagnostic(:multiple_owner_links, command_match[1], owner_links.sort.join(","))
        end

        Row.new(command: command_match[1], owner: owner, line: line_number).freeze
      end

      [ rows, diagnostics ]
    end

    def cells(line)
      stripped = line.strip
      return unless stripped.start_with?("|") && stripped.end_with?("|")

      stripped[1...-1].split("|", -1).map(&:strip)
    end

    def duplicate_diagnostics(values, kind)
      values.tally.filter_map do |value, count|
        diagnostic(kind, value, "rows=#{count}") if count > 1
      end
    end

    def missing_pinned_owner_diagnostics(index_set)
      return [] unless @expected_owners

      (@expected_owners.keys - index_set).map do |command|
        diagnostic(:missing_pinned_owner, command, @expected_owners.fetch(command))
      end
    end

    def navigation_only_diagnostics(text)
      lines = markdown_lines(text)
      start = lines.index { |line| !line.fenced && line.text.strip == "## Command index" }
      return [] unless start

      finish = lines.each_index.find do |index|
        index > start && !lines[index].fenced && lines[index].text.start_with?("## ")
      end
      finish ||= lines.length
      outside = lines.each_index.filter_map { |index| lines[index] unless (start...finish).cover?(index) }
      visible_blocks(outside).filter_map do |block|
        body = block.map(&:text).join
        table = block.any? { |line| line.text.lstrip.start_with?("|") }
        command = body.match?(ANY_COMMAND)
        schema = body.match?(/`hive-[a-z0-9-]+\.v\d+`/i)
        contract = body.match?(
          /--[a-z0-9-]+|\b(?:schema|serializ(?:ation|e)|exit codes?|stdout|stderr)\b/i
        )
        next unless schema || (command && (table || contract))

        diagnostic(:command_contract_outside_index, block.first.number)
      end
    end

    def visible_blocks(lines)
      lines.chunk { |line| line.fenced || line.text.strip.empty? }.filter_map do |separator, group|
        group unless separator
      end
    end

    def resolve_owners(rows)
      diagnostics = []
      documents = {}
      owners = {}

      rows.group_by(&:command).each do |command, command_rows|
        targets = command_rows.map(&:owner).compact.uniq
        if targets.size > 1
          diagnostics << diagnostic(:ambiguous_ownership, command, targets.sort.join(","))
          next
        end
        next unless targets.one?

        target = targets.first
        if @expected_owners && (expected = @expected_owners[command])
          unless target == expected
            diagnostics << diagnostic(:unexpected_owner, command, "expected=#{expected} actual=#{target}")
            next
          end
        end

        unless target.match?(OWNER_TARGET)
          diagnostics << diagnostic(:disallowed_owner_target, command, target)
          next
        end

        document = @owner_reader.call(target)
        unless document
          diagnostics << diagnostic(:unresolved_owner_target, command, target)
          next
        end

        owners[command] = target
        documents[target] ||= document
      end

      [ owners, documents, diagnostics ]
    end

    def validate_owner_contracts(owners, documents)
      owners.group_by { |_command, target| target }.flat_map do |target, command_owners|
        document = documents.fetch(target)
        sections = contract_sections(document)
        shared = command_owners.size > 1
        units = sections.to_h { |section| [ section, contract_units(section) ] }
        command_owners.flat_map do |command, _|
          pattern = command_pattern(command)
          reference = command_reference_pattern(command)
          texts = units.transform_values do |section_units|
            if shared
              section_units.select { |text| text.match?(pattern) }
            else
              eligible = section_units.reject { |text| text.match?(ANY_COMMAND) && !text.match?(reference) }
              eligible.empty? ? [] : [ eligible.join("\n") ]
            end
          end
          context = ContractContext.new(command: command, pattern: pattern, texts: texts).freeze
          CONTRACT_HEADINGS.keys.filter_map do |requirement|
            next if contract_requirement?(requirement, document, sections, context)

            diagnostic(:incomplete_owner_contract, command, "#{target}:#{requirement}")
          end
        end
      end
    end

    def contract_sections(document)
      sections = []
      heading = nil
      body = +""

      markdown_lines(document).each do |line|
        if !line.fenced && (match = line.text.match(/^## (.+)$/))
          sections << Section.new(heading: heading, body: body.freeze).freeze if heading
          heading = match[1].strip
          body = +""
          next
        end
        body << line.text if heading
      end
      sections << Section.new(heading: heading, body: body.freeze).freeze if heading
      sections
    end

    def contract_requirement?(requirement, document, sections, context)
      return false unless sections.any? do |section|
        section.heading.match?(context.pattern) || section.body.match?(context.pattern)
      end

      case requirement
      when :syntax
        sections.any? do |section|
          section.heading.match?(CONTRACT_HEADINGS.fetch(:syntax)) &&
            section.body.match?(context.pattern)
        end
      when :options
        options_contract?(sections, context)
      when :behavior
        contract_text?(
          sections, :behavior, context, /\S/,
          meaningful: true
        )
      when :examples
        sections.any? { |section|
          section.heading.match?(/\bExamples?\b/i) && section.body.match?(context.pattern)
        } || sections.sum { |section|
          section.heading.match?(CONTRACT_HEADINGS.fetch(:syntax)) ? section.body.scan(context.pattern).size : 0
        } >= 2
      when :schema
        contract_text?(
          sections, :schema, context,
          /hive-[a-z0-9-]+(?:\.v|`?\s+v)\d+|schema\s+`hive-[a-z0-9-]+`|schema(?:_version| version|\s*=).*?\d|schema-less|text-only|human-readable|plain text|no (?:success )?(?:structured|JSON)|no [^.\n]*schema|unversioned/i,
          meaningful: true
        )
      when :output_exceptions
        contract_text?(sections, :output_exceptions, context, /error|fail|refus|warn|exception|invalid|unknown/i) ||
          contract_text?(sections, :output_exceptions, context, /not applicable|none/i, heading_pattern: /\bOutput exceptions?\b/i)
      when :serialization_fallback
        contract_text?(sections, :serialization_fallback, context, /serializ|JSON\.generate|GeneratorError|fallback|propagat|suppress|no JSON/i) ||
          contract_text?(sections, :serialization_fallback, context, /not applicable/i, heading_pattern: /\bSerialization\b/i)
      when :exit_codes
        contract_text?(sections, :exit_codes, context, /\bexit(?:[_ ]code)?s?\b[\s\S]*?(?:`?\d+`?)/i) ||
          contract_text?(sections, :exit_codes, context, /not applicable/i, heading_pattern: /\bExit codes?\b/i)
      end
    end

    def contract_text?(sections, requirement, context, content_pattern,
      heading_pattern: CONTRACT_HEADINGS.fetch(requirement), meaningful: false)
      sections.any? do |section|
        next false unless section.heading.match?(heading_pattern)

        texts = context.texts&.fetch(section) || [ "#{section.heading}\n#{section.body}" ]
        texts.any? do |text|
          text.match?(content_pattern) && (!meaningful || meaningful_contract_text?(text))
        end
      end
    end

    def options_contract?(sections, context)
      sections.any? do |section|
        next false unless section.heading.match?(CONTRACT_HEADINGS.fetch(:options))

        texts = context.texts&.fetch(section) || [ "#{section.heading}\n#{section.body}" ]
        texts.any? do |text|
          explicit_none = text.match?(/options?\s*(?::|are)\s*(?:not applicable|none)|no (?:command-specific )?options?/i)
          flags = text.match?(/--[a-z]/)
          explicit_heading = section.heading.match?(/\bOptions?\b/i)
          explicit_none || (flags && (explicit_heading || prose_contract_text?(text)))
        end
      end
    end

    def contract_units(section)
      units = []
      paragraph = []
      subheading = nil
      was_fenced = false

      flush = lambda do
        if paragraph.any?
          units << [ section.heading, subheading, paragraph.join ].compact.join("\n")
          paragraph.clear
        end
      end

      markdown_lines(section.body).each do |line|
        if line.fenced
          flush.call unless was_fenced
          paragraph << line.text
          was_fenced = true
          next
        elsif was_fenced
          flush.call
          was_fenced = false
        end

        if (match = line.text.match(/^### (.+)$/))
          flush.call
          subheading = match[1].strip
        elsif line.text.lstrip.start_with?("|")
          flush.call
          units << [ section.heading, subheading, line.text ].compact.join("\n")
        elsif line.text.strip.empty?
          flush.call
        else
          paragraph << line.text
        end
      end
      flush.call
      units
    end

    def command_pattern(command)
      /\bhive[ \t]+#{Regexp.escape(command)}(?=\s|`|[.,;:\/\[\]()|]|\z)/
    end

    def command_reference_pattern(command)
      escaped = Regexp.escape(command)
      /(?:\bhive-#{escaped}(?=[.\-])|(?<![a-z0-9_-])#{escaped}(?![a-z0-9_-]))/i
    end

    def markdown_lines(document)
      fence = nil
      comment = false
      document.each_line.with_index(1).map do |text, number|
        if fence
          marker = text.match(/^ {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = nil if marker&.start_with?(fence[0]) && marker.length >= fence.length
          MarkdownLine.new(number: number, text: text, fenced: true).freeze
        elsif !comment && text.match?(/\A(?: {4}|\t)/)
          MarkdownLine.new(number: number, text: text, fenced: true).freeze
        else
          text, comment = visible_comment_text(text, comment)
          marker = text.match(/^ {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = marker if marker
          MarkdownLine.new(number: number, text: text, fenced: !marker.nil?).freeze
        end
      end
    end

    def visible_comment_text(text, comment)
      visible = +""
      remaining = text
      loop do
        if comment
          closing = remaining.index("-->")
          return [ visible, true ] unless closing

          remaining = remaining[(closing + 3)..]
          comment = false
        else
          opening = remaining.index("<!--")
          unless opening
            visible << remaining
            return [ visible, false ]
          end

          visible << remaining[...opening]
          remaining = remaining[(opening + 4)..]
          comment = true
        end
      end
    end

    def meaningful_contract_text?(text)
      !text.match?(/\b(?:TODO|TBD|FIXME)\b/i) &&
        (text.match?(/schema-less|text-only|human-readable|plain text|no (?:success )?(?:structured|JSON)|no [^.\n]*schema|unversioned/i) ||
          text.match?(/\bschema\b/i) || prose_contract_text?(text))
    end

    def prose_contract_text?(text)
      prose = text.gsub(/```.*?```|~~~.*?~~~/m, "").gsub(/`[^`]*`/, "")
      prose.match?(/[A-Za-z]{4,}.*[A-Za-z]{4,}/m) && !prose.match?(/\b(?:TODO|TBD|FIXME)\b/i)
    end

    def read_owner(target)
      return unless @wiki_root

      path = File.join(@wiki_root, "#{target}.md")
      File.read(path) if File.file?(path)
    end

    def diagnostic(kind, subject = nil, detail = nil)
      Diagnostic.new(kind: kind, subject: subject, detail: detail).freeze
    end
  end
end
