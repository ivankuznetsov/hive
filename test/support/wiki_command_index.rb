# frozen_string_literal: true

module WikiCommandIndex
  ANSI_ESCAPE = /\e\[[0-?]*[ -\/]*[@-~]/.freeze
  COMMAND_NAME = /\A[a-z0-9_][a-z0-9_-]*\z/.freeze
  OWNER_TARGET = /\A(?:commands|modules)\/[a-z0-9][a-z0-9_-]*\z/.freeze
  WRAPPER_ALIASES = { "-v" => "version" }.freeze
  COMMAND_OWNERS = {
    "accept-finding" => "commands/findings",
    "act" => "commands/status",
    "answer" => "commands/answer",
    "answer-digest" => "commands/answer-digest",
    "approve" => "commands/approve",
    "archive" => "commands/stage_action",
    "artifacts" => "commands/stage_action",
    "babysit" => "commands/babysit",
    "bench" => "commands/bench-submit",
    "bot" => "commands/bot",
    "brainstorm" => "commands/stage_action",
    "circuits" => "commands/circuits",
    "connect" => "commands/screenote",
    "daemon" => "commands/daemon",
    "decide" => "commands/workflow",
    "develop" => "commands/stage_action",
    "disconnect" => "commands/screenote",
    "doctor" => "commands/doctor",
    "drop" => "commands/drop",
    "evidence" => "commands/evidence",
    "finalize" => "commands/stage_action",
    "findings" => "commands/findings",
    "forget" => "commands/forget",
    "generate-name" => "commands/generate-name",
    "help" => "commands/help",
    "init" => "commands/init",
    "markers" => "commands/markers",
    "metrics" => "commands/metrics",
    "migrate" => "commands/migrate",
    "module" => "commands/module",
    "new" => "commands/new",
    "open-pr" => "commands/stage_action",
    "pairing" => "commands/pairing",
    "patrol" => "commands/patrol",
    "plan" => "commands/stage_action",
    "plan-review" => "modules/plan_review",
    "plan-review-run" => "modules/plan_review",
    "prune" => "commands/prune",
    "rebase-status" => "commands/rebase-status",
    "refactor-patrol" => "commands/refactor-patrol",
    "reject-finding" => "commands/findings",
    "review" => "commands/stage_action",
    "run" => "commands/run",
    "runtime" => "commands/runtime",
    "setup" => "commands/setup",
    "setup-agents" => "commands/setup-agents",
    "status" => "commands/status",
    "task" => "commands/task",
    "tree" => "commands/tree",
    "tui" => "commands/tui",
    "uninstall" => "commands/uninstall",
    "update" => "commands/update",
    "version" => "commands/version",
    "watch" => "commands/watch",
    "web" => "commands/web",
    "wiki" => "commands/wiki",
    "workflow" => "commands/workflow",
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
    CONTRACT_CHECKS = {
      syntax: lambda { |text|
        text.match?(/^##+ (?:Usage|Synopsis|CLI|Invocation|Surface|Subcommands)\b/i) ||
          text.scan(/`hive\s|^\s*hive\s/m).size >= 2
      },
      options: ->(text) { text.match?(/\boptions?\b|--[a-z]|options?: (?:not applicable|none)/i) },
      behavior: lambda { |text|
        text.scan(/^##+ (.+)$/).flatten.any? do |heading|
          !heading.match?(/\A(?:Usage|Synopsis|CLI|Invocation|Surface|Options?|Output|JSON|Errors?|Serialization|Exit codes?|Examples?|Tests?|Backlinks|Related|Notes)\b/i)
        end
      },
      examples: lambda { |text|
        text.match?(/^##+ Examples?\b/i) || text.scan(/`hive\s|^\s*hive\s/m).size >= 2
      },
      schema: ->(text) { text.match?(/schema|JSON|text-only|human-readable|plain text|no structured output/i) },
      output_exceptions: ->(text) { text.match?(/error|failure|refus|warning|exception|output exception/i) },
      serialization_fallback: lambda { |text|
        text.match?(/serializ|GeneratorError|does not emit JSON|no JSON/i)
      },
      exit_codes: lambda { |text|
        text.match?(/exit code|exit status|exits? (?:with )?[0-9]|returns? (?:success|failure|0|1)|status [0-9]/i)
      }
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

      diagnostics.concat(duplicate_diagnostics(help_commands, :duplicate_help_command))
      diagnostics.concat(duplicate_diagnostics(rows.map(&:command).compact, :duplicate_index_command))

      help_set = help_commands.uniq
      index_set = rows.map(&:command).compact.uniq
      (help_set - index_set).each do |command|
        diagnostics << diagnostic(:missing_index_command, command)
      end
      (index_set - help_set).each do |command|
        diagnostics << diagnostic(:stale_index_command, command)
      end

      owners, owner_documents, owner_diagnostics = resolve_owners(rows)
      diagnostics.concat(owner_diagnostics)
      diagnostics.concat(validate_owner_contracts(owner_documents)) if validate_contracts

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
        match = line.match(/\A\s{2}\S+\s+([a-z0-9_][a-z0-9_-]*)\b/)
        commands << match[1] if match
      end

      diagnostics = []
      diagnostics << diagnostic(:empty_help_commands_section) if commands.empty?
      [ commands, diagnostics ]
    end

    def parse_index(text)
      lines = text.lines
      start = lines.index { |line| line.strip == "## Command index" }
      return [ [], [ diagnostic(:missing_index_section) ] ] unless start

      section = []
      lines.drop(start + 1).each do |line|
        break if line.start_with?("## ")
        section << line
      end

      table_lines = section.each_with_index.filter_map do |line, offset|
        [ line, start + offset + 2 ] if line.lstrip.start_with?("|")
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

        command_match = row_cells[0].match(/\A`hive ([a-z0-9_][a-z0-9_-]*)`\z/)
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
        if @expected_owners
          expected = @expected_owners[command]
          unless expected
            diagnostics << diagnostic(:missing_expected_owner, command, target)
            next
          end
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

    def validate_owner_contracts(documents)
      documents.flat_map do |target, document|
        CONTRACT_CHECKS.filter_map do |requirement, check|
          diagnostic(:incomplete_owner_contract, target, requirement) unless check.call(document)
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
