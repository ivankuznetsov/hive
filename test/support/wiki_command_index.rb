# frozen_string_literal: true

module WikiCommandIndex
  ANSI_ESCAPE = /\e\[[0-?]*[ -\/]*[@-~]/.freeze
  COMMAND_NAME = /\A[a-z0-9_][a-z0-9_-]*\z/.freeze
  INDEX_COMMAND_NAME = /(?:[a-z0-9_][a-z0-9_-]*|--?[a-z0-9][a-z0-9_-]*)/.freeze
  OWNER_TARGET = /\A(?:commands|modules)\/[a-z0-9][a-z0-9_-]*\z/.freeze
  ANY_COMMAND = /\bhive[ \t]+(?:[a-z0-9_][a-z0-9_-]*|--?[a-z0-9][a-z0-9_-]*)/.freeze
  WRAPPER_ALIASES = { "-v" => "version" }.freeze
  HISTORICAL_COMMAND_PAGES = %w[commands/migrate].freeze
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
  MarkdownLine = Struct.new(:number, :text, :fenced, keyword_init: true)
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
    def initialize(wiki_root: nil, docs_cli_path: nil, owner_reader: nil, expected_owners: COMMAND_OWNERS)
      @wiki_root = wiki_root
      @docs_cli_path = docs_cli_path || (wiki_root ? File.expand_path("../docs/cli.md", wiki_root) : nil)
      @owner_reader = owner_reader || method(:read_owner)
      @expected_owners = expected_owners
    end

    def evaluate(help_text:, index_text:, validate_authority_links: true)
      help_commands, help_diagnostics = parse_help(help_text)
      rows, index_diagnostics = parse_index(index_text)
      diagnostics = help_diagnostics + index_diagnostics
      diagnostics.concat(navigation_only_diagnostics(index_text))

      diagnostics.concat(duplicate_diagnostics(help_commands, :duplicate_help_command))
      diagnostics.concat(duplicate_diagnostics(rows.map(&:command).compact, :duplicate_index_command))
      index_set = rows.map(&:command).compact.uniq
      diagnostics.concat(missing_pinned_owner_diagnostics(index_set))

      owners, owner_documents, owner_diagnostics = resolve_owners(rows)
      diagnostics.concat(owner_diagnostics)
      if validate_authority_links
        diagnostics.concat(authority_link_diagnostics("cli", index_text))
        owner_documents.each do |target, document|
          next if HISTORICAL_COMMAND_PAGES.include?(target)

          diagnostics.concat(authority_link_diagnostics(target, document))
        end
      end

      Result.new(
        help_commands: help_commands.freeze,
        index_commands: rows.map(&:command).compact.freeze,
        owners: owners.freeze,
        owner_documents: owner_documents.freeze,
        diagnostics: diagnostics.sort_by(&:sort_key).freeze
      ).freeze
    end

    def parse_rendered_help(help_text)
      parse_help(help_text)
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
        [ line.text, line.number ] if !line.fenced && line.text.match?(/\A {0,3}\|/)
      end
      diagnostics = []
      return [ [], [ diagnostic(:missing_index_table) ] ] if table_lines.size < 2

      header = cells(table_lines[0][0])
      separator = cells(table_lines[1][0])
      unless [ [ "Command", "Owner" ], [ "Command", "Architecture" ] ].include?(header) &&
          separator&.size == 2 &&
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
      outside = lines.each_index.filter_map do |index|
        line = lines[index]
        line unless (start...finish).cover?(index) && !line.fenced && line.text.lstrip.start_with?("|")
      end
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

    def authority_link_diagnostics(target, document)
      visible = markdown_lines(document).reject(&:fenced).map(&:text).join
      links = visible.scan(/\[[^\]]+\]\(([^)]*docs\/cli\.md(?:#[^)]+)?)\)/).flatten.uniq
      if links.empty?
        return [ diagnostic(:missing_authority_link, target, "must link to docs/cli.md") ]
      end

      return [] unless @wiki_root && @docs_cli_path && File.file?(@docs_cli_path)

      page_path = File.join(@wiki_root, "#{target}.md")
      anchors = docs_cli_anchors
      links.filter_map do |link|
        rel_path, anchor = link.split("#", 2)
        resolved = File.expand_path(rel_path, File.dirname(page_path))
        if resolved != File.expand_path(@docs_cli_path)
          diagnostic(:broken_authority_link, target, "#{link} -> #{resolved}")
        elsif anchor && !anchors.include?(anchor)
          diagnostic(:broken_authority_anchor, target, "#{link}")
        end
      end
    end

    def docs_cli_anchors
      @docs_cli_anchors ||= File.read(@docs_cli_path).scan(/^#+ (.+)$/).flatten.map do |heading|
        heading.downcase.gsub(/[`.,()]/, "").gsub(/[^a-z0-9 _-]/, "").strip.gsub(/\s+/, "-")
      end
    end

    def markdown_lines(text)
      fence = nil
      comment = false
      result = []
      text.each_line.with_index(1) do |raw, number|
        if fence
          marker = raw.match(/\A {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = nil if marker&.start_with?(fence[0]) && marker.length >= fence.length
          result << MarkdownLine.new(number: number, text: raw, fenced: true).freeze
        else
          visible, comment = strip_html_comments(raw, comment)
          marker = visible.match(/\A {0,3}(`{3,}|~{3,})/)&.[](1)
          fence = marker if marker
          result << MarkdownLine.new(number: number, text: visible, fenced: !marker.nil?).freeze
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
