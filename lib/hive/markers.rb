module Hive
  module Markers
    KNOWN_NAMES = %w[
      WAITING COMPLETE AGENT_WORKING ERROR
      EXECUTE_WAITING EXECUTE_COMPLETE EXECUTE_STALE
    ].freeze
    MARKER_RE = /<!--\s*(?<name>WAITING|COMPLETE|AGENT_WORKING|ERROR|EXECUTE_WAITING|EXECUTE_COMPLETE|EXECUTE_STALE)(?<attrs>(?:\s+[^<>]*?)?)\s*-->/

    State = Struct.new(:name, :attrs, :raw, keyword_init: true) do
      def none?
        name == :none
      end
    end

    module_function

    def current(state_file_path)
      return State.new(name: :none, attrs: {}, raw: nil) unless File.exist?(state_file_path)

      content = File.read(state_file_path)
      last = nil
      content.scan(MARKER_RE) do
        match = Regexp.last_match
        last = match
      end
      return State.new(name: :none, attrs: {}, raw: nil) unless last

      State.new(
        name: last[:name].downcase.to_sym,
        attrs: parse_attrs(last[:attrs]),
        raw: last[0]
      )
    end

    def set(state_file_path, name, attrs = {})
      marker_name = name.to_s.upcase
      raise ArgumentError, "unknown marker #{marker_name}" unless KNOWN_NAMES.include?(marker_name)

      new_marker = build_marker(marker_name, attrs)
      ensure_dir(state_file_path)
      File.open(state_file_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        body = f.read
        replaced, count = replace_last_marker(body, new_marker)
        body = if count.positive?
                 replaced
               else
                 separator = body.empty? || body.end_with?("\n") ? "" : "\n"
                 "#{body}#{separator}#{new_marker}\n"
               end
        f.rewind
        f.truncate(0)
        f.write(body)
        f.flush
      end
      new_marker
    end

    def build_marker(name, attrs)
      pairs = attrs.compact.map { |k, v| "#{k}=#{format_attr(v)}" }
      pairs.empty? ? "<!-- #{name} -->" : "<!-- #{name} #{pairs.join(' ')} -->"
    end

    def parse_attrs(raw_attrs)
      attrs = {}
      raw_attrs.to_s.scan(/(\w[\w-]*)=("[^"]*"|\S+)/).each do |k, v|
        attrs[k] = v.start_with?('"') ? v[1..-2] : v
      end
      attrs
    end

    def format_attr(value)
      str = value.to_s
      str =~ /\s/ ? "\"#{str}\"" : str
    end

    def ensure_dir(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
    end

    def replace_last_marker(body, new_marker)
      matches = body.to_enum(:scan, MARKER_RE).map { Regexp.last_match }
      return [body, 0] if matches.empty?

      last = matches.last
      [body[0...last.begin(0)] + new_marker + body[last.end(0)..], 1]
    end
  end
end
