require "json"

# A read-only, line-based view of the operator's `$CODEX_HOME/config.toml`.
# Hive launches Codex with `--ignore-user-config`, so the few personal
# settings it carries over (plan 2026-10-15-001, OD-A) are read here and
# replayed as `-c key=value` overrides. Values stay raw TOML text so Codex
# parses them exactly as it would from the file; a value spanning lines is
# reported in `skipped` instead of guessed at.
module Hive::AgentSupport::Codex::UserConfig
  Document = Data.define(:top, :sections, :skipped) do
    # Raw TOML value for a top-level key, or nil.
    def [](key) = top[key]

    # Raw `key => value` pairs of one table, addressed by its dotted path.
    def table(*path) = sections.fetch(path, {})

    # Tables under `prefix`, keyed by their full path.
    def tables_under(*prefix)
      sections.select { |path, _values| path.length > prefix.length && path.first(prefix.length) == prefix }
    end
  end

  EMPTY = Document.new(top: {}.freeze, sections: {}.freeze, skipped: [].freeze)
  BARE_KEY = /[A-Za-z0-9_-]+/
  KEY_SEGMENT = /\A\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(#{BARE_KEY}))\s*/
  HEADER = /\A\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?\z/
  SCALAR = /
    "(?:[^"\\]|\\.)*" | '[^']*' | true | false |
    [+-]?(?:\d[\d_]*)(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)? |
    \[[^\[\]]*\] | \{[^{}]*\}
  /x
  ASSIGNMENT = /\A(#{BARE_KEY}|"(?:[^"\\]|\\.)*")\s*=\s*(#{SCALAR})\s*(?:#.*)?\z/

  module_function

  def path(env: ENV)
    home = env["CODEX_HOME"].to_s
    home = File.join(Dir.home, ".codex") if home.empty?
    File.join(home, "config.toml")
  end

  def load(file = path)
    parse(File.read(file))
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
    EMPTY
  end

  def parse(content)
    top = {}
    sections = {}
    skipped = []
    current = nil
    content.each_line do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      if stripped.start_with?("[")
        header = stripped.match(HEADER)
        current = header && dotted_path(header[1])
        sections[current] ||= {} if current
        next
      end
      match = stripped.match(ASSIGNMENT)
      unless match
        key = stripped[/\A(#{BARE_KEY})\s*=/, 1]
        skipped << (current ? [ *current, key ].join(".") : key) if key
        next
      end

      key = unquote(match[1])
      current ? sections.fetch(current)[key] = match[2] : top[key] = match[2]
    end
    Document.new(top: top.freeze, sections: sections.freeze, skipped: skipped.freeze)
  end

  # `mcp_servers."a.b"` -> ["mcp_servers", "a.b"]; nil for an array-of-tables
  # or otherwise unsupported header.
  def dotted_path(text)
    segments = []
    rest = text
    loop do
      match = rest.match(KEY_SEGMENT) or return nil
      segments << (match[1] ? JSON.parse(%("#{match[1]}")) : match[2] || match[3])
      rest = match.post_match
      return segments.freeze if rest.empty?
      return nil unless rest.start_with?(".")

      rest = rest[1..]
    end
  end

  def unquote(key) = key.start_with?('"') ? JSON.parse(key) : key

  # A raw TOML string value as a Ruby string; nil for any other type.
  def string(raw)
    return if raw.nil?
    return JSON.parse(raw) if raw.start_with?('"')

    raw[1...-1] if raw.start_with?("'")
  end
  private_class_method :dotted_path, :unquote
end
