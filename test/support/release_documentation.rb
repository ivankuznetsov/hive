# frozen_string_literal: true

require "shellwords"
require_relative "../../lib/hive/version"

# The current, hand-edited release instructions. Never run the examples.
class HiveReleaseDocumentation
  PATHS = %w[README.md wiki/active-areas.md wiki/operating.md wiki/testing.md].freeze

  def self.check(root, version: Hive::VERSION)
    PATHS.flat_map do |path|
      text = File.read(File.join(root, path), encoding: "UTF-8")
      unless text.valid_encoding?
        line = text.each_line.find_index { |value| !value.valid_encoding? }
        next ["#{path}:#{line + 1}: document has invalid bytes; expected UTF-8"]
      end
      new(path, text, version).check
    rescue Errno::ENOENT
      ["#{path}:1: missing document; expected #{path}"]
    end
  end

  # Only the invocation introduced by this job description is a pinned baseline.
  BASELINE = /^(The install-smoke workflow's `verify-release\.sh \(end-to-end behavior\)` job(?:[ \t]+|[ \t]*\n[ \t]*)runs )`packaging\/verify-release\.sh --version=v0\.1\.0`/
  FENCE = /^ {0,3}(`{3,}|~{3,})/
  MARKUP = /(`+)(.+?)\1|<code>(.*?)<\/code>/
  INSTALLER_URL = %r{(?:://|githubusercontent\.com/).*?/install\.sh}i
  VERIFIER = %r{(?:\A|/)verify-release\.sh\z}

  def initialize(path, text, version)
    @path = path
    @tag = "v#{version}"
    @url = "https://raw.githubusercontent.com/ivankuznetsov/hive/#{@tag}/install.sh"
    text = text.sub(BASELINE, '\1') if path == "wiki/testing.md"
    @lines = text.lines(chomp: true)
    @prose = {}
    @fences = {}
    @examples = Hash.new { |hash, kind| hash[kind] = [] }
    @errors = []
  end

  def check
    scan_document
    case @path
    when "README.md" then require_install_table
    when "wiki/operating.md" then require_operating_examples
    when "wiki/active-areas.md" then check_inventory
    end
    @errors.sort_by { |line, message| [line, message] }.map { |line, message| "#{@path}:#{line + 1}: #{message}" }
  end

  private

  def scan_document
    history = @path == "wiki/active-areas.md"
    index = 0
    while index < @lines.size
      line = @lines[index]
      if (marker = line[FENCE, 1])
        finish = index + 1
        finish += 1 while finish < @lines.size && !@lines[finish].match?(/^ {0,3}#{marker}#{marker[0]}*\s*$/)
        body = (index + 1)...finish
        @fences[index] = body
        scan_code(@lines[body], index + 1, fenced: true)
        index = finish
      else
        @prose[index] = line
        history = false if line == "## What exists"
        historical = history && line.match?(/^\|\s*`[0-9a-f]{7,40}`\s*(?:\/|\|)/)
        scan_inline(line, index) unless historical
      end
      index += 1
    end
  end

  def scan_inline(line, index)
    # Keep inline examples separate, even when several share a table cell.
    prose = line.gsub(MARKUP) do
      span = Regexp.last_match
      label = span.pre_match.match?(/\[[^\[\]]*\z/) && span.post_match.match?(/\A[^\[\]]*\]\(/)
      scan_code([span[2] || span[3]], index, fenced: false, link_label: label)
      " "
    end
    prose.scan(%r{[\w.+-]+://[^\s<>()\[\]`"']+}).each do |url|
      check_installer(url, index) if url.match?(INSTALLER_URL)
    end
  end

  # Split on unquoted shell operators before unquoting each complete word.
  # This preserves e.g. a suffix after a closing quote and never expands variables.
  SHELL_TOKEN = /
    (?: [^\s"'\\|&;()<>]+         # unquoted bytes
      | '[^']*(?:'|\z)             # single-quoted segment
      | "(?:[^"\\]|\\.)*(?:"|\z)  # double-quoted segment
      | \\(?:.|\z)                 # escaped byte
    )+ | [|&;()<>]+
  /x
  Command = Struct.new(:line, :words, :operator)

  def shell_commands(lines, start)
    commands = []
    lines.each_with_index do |line, offset|
      words = []
      line.scan(SHELL_TOKEN) do |token|
        break if token.start_with?("#")
        if token.match?(/\A[|&;()<>]+\z/)
          commands << Command.new(start + offset, words, token) unless words.empty?
          words = []
        else
          begin
            words << Shellwords.split(token).fetch(0)
          rescue ArgumentError # Retain unmatched quote bytes for exact comparison.
            words << token
          end
        end
      end
      commands << Command.new(start + offset, words) unless words.empty?
    end

    commands
  end

  def scan_code(lines, start, fenced:, link_label: false)
    commands = shell_commands(lines, start)
    first = commands.first&.words || []
    inline_verifier = first.first&.match?(VERIFIER) && first.drop(1).any? { |arg| arg.start_with?("-") }
    check_invocations = !link_label && (fenced || inline_verifier)
    commands.each_with_index do |command, index|
      words = command.words
      if words.first == "curl"
        check_download(command, commands.drop(index + 1))
      else
        words.each { |word| check_installer(word, command.line) if word.match?(INSTALLER_URL) }
      end
      next unless check_invocations

      words = words.drop(1) if %w[bash sh].include?(words.first)
      check_verifier(words.drop(1), command.line) if words.first&.match?(VERIFIER)
    end
  end

  def check_download(command, following)
    arguments = command.words.drop(1)
    sources = []
    destination = nil
    until arguments.empty?
      word = arguments.shift
      case word
      when /\A--output=(.+)\z/ then destination = Regexp.last_match(1)
      when "--output", /\A-[A-Za-z]*o\z/ then destination = arguments.shift
      when /\A-o(.+)\z/ then destination = Regexp.last_match(1)
      when "-H", "--header", "-d", "--data" then arguments.shift
      else sources << word unless word.start_with?("-")
      end
    end

    piped = command.operator == "|" && %w[bash sh].include?(following.first&.words&.first)
    executed = destination && following.any? do |later|
      %w[bash sh].include?(later.words.first) && later.words[1] == destination
    end
    sources.each do |source|
      next unless executed || piped || source.match?(INSTALLER_URL) || source.match?(%r{\A\$.*?/install\.sh})

      @examples[:installer] << command.line if check_installer(source, command.line)
    end
  end

  def check_installer(url, line)
    return true if url == @url

    @errors << [line, "installer URL #{url.inspect} does not match; expected #{@url}"]
    false
  end

  def check_verifier(options, line)
    versions = options.grep(/\A--version(?:=|\z)/)
    expected = "--version=#{@tag}"
    if versions.empty?
      @errors << [line, "verifier missing version; expected #{expected}"]
      return
    end
    options.each_with_index do |option, index|
      if option == "--version"
        actual = options[index, 2].join(" ")
        @errors << [line, "verifier split version #{actual.inspect}; expected #{expected}"]
      elsif option == "--version="
        @errors << [line, "verifier has empty --version=; expected #{expected}"]
      elsif option.start_with?("--version=") && option != expected
        @errors << [line, "verifier version #{option.inspect} does not match; expected #{expected}"]
      end
    end
    return unless versions.all? { |option| option == expected }

    @examples[:plain] << line if (options - versions).empty?
    @examples[:json] << line if options.include?("--report=json")
  end

  def section(heading)
    start = @prose.key("## #{heading}")
    return unless start

    finish = @prose.find { |line, text| line > start && text.match?(/^\#{1,2} /) }&.first
    start...(finish || @lines.size)
  end

  def require_example(kind, range, anchor, description, expected)
    return if range && @examples[kind].any? { |line| range.cover?(line) }

    @errors << [anchor || 0, "missing #{description}; expected #{expected}"]
  end

  def require_install_table
    install = section("Install")
    header = @prose.find { |i, text| install&.cover?(i) && text.match?(/^\|\s*Platform\s*\|\s*Channel\s*\|$/) }&.first
    if header
      finish = header + 1
      finish += 1 while @prose[finish]&.start_with?("|")
      table = (header + 1)...finish
    end
    require_example(:installer, table, header || install&.begin, "installer command in installation table", @url)
  end

  def require_operating_examples
    channels = @prose.key("Channels:")
    if channels
      following = channels + 1
      following += 1 while @lines[following] == ""
      block = @fences[following]
    end
    require_example(:installer, block, channels, "installer command in Channels block", @url)
    release = section("Release verification")
    require_example(:plain, release, release&.begin, "plain verifier in Release verification", "--version=#{@tag}")
    require_example(:json, release, release&.begin, "JSON verifier in Release verification", "--version=#{@tag} --report=json")
  end

  def check_inventory
    inventory = section("What exists")
    rows = @prose.select { |line, text| inventory&.cover?(line) && text.match?(%r{^\|\s*Release/install\s*\|}) }
    expected = "Current release: `#{@tag}`"
    if rows.empty?
      @errors << [inventory&.begin || 0, "missing Release/install row under What exists; expected #{expected}"]
    end
    rows.each_with_index do |(line, text), index|
      @errors << [line, "duplicate Release/install row; expected one row with #{expected}"] if index.positive?
      count = text.scan("Current release:").size
      if count != 1
        @errors << [line, "#{count.zero? ? 'missing' : 'duplicate'} Current release: marker; expected #{expected}"]
      end
      rest = text.gsub(/Current release:(?: (`[^`]*`|[^\s|`]+))?/) do
        actual = Regexp.last_match(1)
        if !actual&.start_with?("`")
          @errors << [line, "current release #{actual.inspect} needs a backtick-quoted tag; expected #{expected}"]
        elsif actual != "`#{@tag}`"
          @errors << [line, "current release #{actual} does not match; expected #{expected}"]
        end
        ""
      end
      rest.scan(/\bv\d+\.\d+\.\d+(?:[.-][\w.-]+)?/).each do |tag|
        next if count.zero? && tag == @tag

        @errors << [line, "additional release tag #{tag}; expected only #{expected}"]
      end
    end
  end
end
