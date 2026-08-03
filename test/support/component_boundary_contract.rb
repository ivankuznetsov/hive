require "json"
require "open3"
require "pathname"
require "rbconfig"
require "ripper"
require "set"
require "yaml"

# Test-only architecture contract for config/component-boundaries.yml.
#
# This validates declared source boundaries plus literal require,
# require_relative, and Constant.new syntax. It is not runtime isolation:
# dynamic requires, aliases, factory calls, reflection, monkeypatching, and
# arbitrary same-user code execution remain outside this harness.
class ComponentBoundaryContract
  class ValidationError < StandardError; end

  STATES = %w[candidate boundary-ready].freeze
  REQUIRED_FIELDS = %w[
    id
    name
    state
    entrypoint
    public_contract
    owned_paths
    state_contracts
    schema_contracts
    lock_contracts
    component_dependencies
    allowed_hive_dependencies
    internal_collaborators
    forbidden_constructions
    authorized_internal_constructions
    hive_consumers
    mutation_authority
    recovery_surface
    wiki_page
    focused_tests
    migration_exceptions
  ].freeze
  ARRAY_FIELDS = %w[
    owned_paths
    state_contracts
    schema_contracts
    lock_contracts
    component_dependencies
    allowed_hive_dependencies
    internal_collaborators
    forbidden_constructions
    hive_consumers
    focused_tests
    migration_exceptions
  ].freeze
  PATH_FIELDS = %w[owned_paths hive_consumers focused_tests].freeze
  FORBIDDEN_REQUIRE_PREFIXES = %w[
    hive/cli
    hive/commands
    hive/release
    hive/stages
    hive/web
  ].freeze
  FORBIDDEN_CONSTANTS = %w[Hive::Commands Hive::Stages Hive::Web].freeze
  SAFE_ID = /\A[a-z][a-z0-9-]*\z/
  SAFE_CONSTANT = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

  attr_reader :components

  def self.load(path:, root:)
    document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    new(document, root: root)
  rescue Psych::Exception, Errno::ENOENT, Errno::EACCES => e
    raise ValidationError, "#{path}: #{e.message}"
  end

  def initialize(document, root:)
    @document = document
    @root = File.realpath(root)
    @components = []
  end

  def component(id)
    ensure_components!
    @components.find { |entry| entry.fetch("id") == id.to_s } ||
      raise(ValidationError, "unknown component #{id.inspect}")
  end

  def validate!
    validate_catalog!
    validate_static_boundaries!
    validate_clean_loads!
    true
  end

  def validate_catalog!
    root = expect_hash(@document, "catalog")
    assert_keys!(root, %w[schema_version components], "catalog")
    invalid!("catalog.schema_version", "expected 1") unless root["schema_version"] == 1

    @components = expect_array(root.fetch("components"), "catalog.components").map.with_index do |entry, index|
      validate_component!(entry, index)
    end
    invalid!("catalog.components", "must contain at least one component") if @components.empty?

    index_components!
    validate_unique_ownership!
    validate_dependencies!
    true
  rescue KeyError => e
    raise ValidationError, "catalog: missing required key #{e.key.inspect}"
  end

  def validate_static_boundaries!
    validate_catalog! if @components.empty?

    boundary_ready_components.each { |entry| validate_requires!(entry) }
    @components.each { |entry| validate_constructions!(entry) }
    true
  end

  def validate_clean_loads!
    validate_catalog! if @components.empty?

    boundary_ready_components.to_h do |entry|
      [ entry.fetch("id"), clean_load_entry!(entry) ]
    end
  end

  def validate_clean_load!(id)
    clean_load_entry!(component(id))
  end

  private

  def validate_component!(entry, index)
    path = "catalog.components[#{index}]"
    row = expect_hash(entry, path)
    missing = REQUIRED_FIELDS - row.keys
    invalid!(path, "missing required fields: #{missing.join(', ')}") unless missing.empty?

    id = string!(row.fetch("id"), "#{path}.id")
    invalid!("#{path}.id", "must match #{SAFE_ID.inspect}") unless id.match?(SAFE_ID)
    component_path = "component #{id}"

    state = string!(row.fetch("state"), "#{component_path}.state")
    invalid!("#{component_path}.state", "must be one of #{STATES.join(', ')}") unless STATES.include?(state)

    string!(row.fetch("name"), "#{component_path}.name")
    entrypoint = expect_hash(row.fetch("entrypoint"), "#{component_path}.entrypoint")
    assert_keys!(entrypoint, %w[file require constant], "#{component_path}.entrypoint")
    repo_path!(entrypoint.fetch("file"), "#{component_path}.entrypoint.file")
    string!(entrypoint.fetch("require"), "#{component_path}.entrypoint.require")
    constant = string!(entrypoint.fetch("constant"), "#{component_path}.entrypoint.constant")
    invalid!("#{component_path}.entrypoint.constant", "must be a constant path") unless constant.match?(SAFE_CONSTANT)

    public_contract = expect_hash(row.fetch("public_contract"), "#{component_path}.public_contract")
    assert_keys!(public_contract, %w[values errors], "#{component_path}.public_contract")
    %w[values errors].each do |field|
      string_array!(public_contract.fetch(field), "#{component_path}.public_contract.#{field}",
                    allow_empty: field == "errors")
    end

    ARRAY_FIELDS.each do |field|
      value = expect_array(row.fetch(field), "#{component_path}.#{field}")
      next if field == "migration_exceptions"

      string_array!(value, "#{component_path}.#{field}",
                    allow_empty: %w[component_dependencies allowed_hive_dependencies forbidden_constructions hive_consumers].include?(field))
    end
    forbidden_allowed = row.fetch("allowed_hive_dependencies").select { |required| forbidden_require?(required) }
    unless forbidden_allowed.empty?
      invalid!("#{component_path}.allowed_hive_dependencies",
               "cannot include forbidden upward dependency #{forbidden_allowed.join(', ')}")
    end
    PATH_FIELDS.each do |field|
      row.fetch(field).each { |value| repo_path!(value, "#{component_path}.#{field}") }
    end
    repo_path!(row.fetch("wiki_page"), "#{component_path}.wiki_page")
    validate_migration_exceptions!(row, component_path)
    if row.fetch("hive_consumers").empty? &&
        (state != "candidate" || row.fetch("migration_exceptions").empty?)
      invalid!("#{component_path}.hive_consumers",
               "may be empty only for a candidate with a bounded migration exception")
    end
    validate_authorized_internal_constructions!(row, component_path)
    string!(row.fetch("mutation_authority"), "#{component_path}.mutation_authority")
    string!(row.fetch("recovery_surface"), "#{component_path}.recovery_surface")
    row
  end

  def validate_migration_exceptions!(row, component_path)
    exceptions = expect_array(row.fetch("migration_exceptions"), "#{component_path}.migration_exceptions")
    exceptions.each_with_index do |entry, index|
      path = "#{component_path}.migration_exceptions[#{index}]"
      exception = expect_hash(entry, path)
      assert_keys!(exception, %w[reason removal_unit], path)
      string!(exception.fetch("reason"), "#{path}.reason")
      removal_unit = string!(exception.fetch("removal_unit"), "#{path}.removal_unit")
      unless removal_unit.match?(/\AU\d+(?:[a-z]\d*)*\z/)
        invalid!("#{path}.removal_unit", "must name a plan unit such as U3 or U1a1c")
      end
    end
    if row.fetch("state") == "boundary-ready" && !exceptions.empty?
      invalid!("#{component_path}.migration_exceptions", "boundary-ready components cannot retain exceptions")
    end
  end

  def validate_authorized_internal_constructions!(row, component_path)
    sites = expect_array(
      row.fetch("authorized_internal_constructions"),
      "#{component_path}.authorized_internal_constructions"
    )
    return if sites.empty?

    seen_constants = Set.new
    owned_files = ruby_files(row.fetch("owned_paths"))

    sites.each_with_index do |entry, index|
      path = "#{component_path}.authorized_internal_constructions[#{index}]"
      site = expect_hash(entry, path)
      assert_keys!(site, %w[constant files reason], path)
      constant = string!(site.fetch("constant"), "#{path}.constant")
      invalid!("#{path}.constant", "must be a constant path") unless constant.match?(SAFE_CONSTANT)
      unless row.fetch("internal_collaborators").include?(constant)
        invalid!("#{path}.constant", "must name a declared internal collaborator")
      end
      unless row.fetch("forbidden_constructions").include?(constant)
        invalid!("#{path}.constant", "must name a forbidden construction")
      end
      unless seen_constants.add?(constant)
        invalid!("#{path}.constant", "duplicates #{constant.inspect}")
      end

      files = string_array!(site.fetch("files"), "#{path}.files")
      invalid!("#{path}.files", "must not contain duplicates") unless files.uniq == files
      files.each_with_index do |relative, file_index|
        repo_path!(relative, "#{path}.files[#{file_index}]")
        if owned_files.include?(relative)
          invalid!("#{path}.files[#{file_index}]",
                   "component-owned files do not need construction authorization")
        end
        unless ruby_syntax(relative).constructions.include?(constant)
          invalid!("#{path}.files[#{file_index}]",
                   "#{relative} does not construct #{constant}")
        end
      end
      string!(site.fetch("reason"), "#{path}.reason")
    end
  end

  def index_components!
    duplicates = @components.group_by { |entry| entry.fetch("id") }.select { |_id, rows| rows.length > 1 }.keys
    invalid!("catalog.components", "duplicate component ids: #{duplicates.join(', ')}") unless duplicates.empty?
    @component_index = @components.to_h { |entry| [ entry.fetch("id"), entry ] }
  end

  def validate_unique_ownership!
    ownership = []
    @components.each do |entry|
      entry.fetch("owned_paths").each do |relative|
        owner = entry.fetch("id")
        conflict = ownership.find do |other_path, _other_owner|
          relative == other_path ||
            relative.start_with?("#{other_path}/") ||
            other_path.start_with?("#{relative}/")
        end
        if conflict
          other_path, other_owner = conflict
          invalid!("component #{owner}.owned_paths",
                   "#{relative.inspect} overlaps #{other_path.inspect} owned by #{other_owner}")
        end
        ownership << [ relative, owner ]
      end
    end
  end

  def validate_dependencies!
    @components.each do |entry|
      id = entry.fetch("id")
      entry.fetch("component_dependencies").each do |dependency|
        invalid!("component #{id}.component_dependencies", "unknown component #{dependency.inspect}") unless @component_index.key?(dependency)
        invalid!("component #{id}.component_dependencies", "cannot depend on itself") if dependency == id
        if entry.fetch("state") == "boundary-ready" &&
            @component_index.fetch(dependency).fetch("state") != "boundary-ready"
          invalid!("component #{id}.component_dependencies",
                   "boundary-ready component cannot depend on candidate #{dependency.inspect}")
        end
      end
    end

    visiting = {}
    visited = {}
    visit = lambda do |id, trail|
      if visiting[id]
        cycle = (trail + [ id ]).drop_while { |item| item != id }
        invalid!("component #{id}.component_dependencies", "dependency cycle: #{cycle.join(' -> ')}")
      end
      return if visited[id]

      visiting[id] = true
      @component_index.fetch(id).fetch("component_dependencies").each do |dependency|
        visit.call(dependency, trail + [ id ])
      end
      visiting.delete(id)
      visited[id] = true
    end
    @component_index.each_key { |id| visit.call(id, []) }
  end

  def validate_requires!(entry)
    require_owners = component_require_owners
    allowed_components = entry.fetch("component_dependencies")

    ruby_files(entry.fetch("owned_paths")).each do |relative|
      ruby_syntax(relative).requires.each do |required|
        if forbidden_require?(required)
          invalid!("component #{entry.fetch('id')}.owned_paths",
                   "#{relative} requires forbidden upward dependency #{required.inspect}")
        end

        dependency = require_owners[required]
        next unless dependency && dependency != entry.fetch("id")
        next if allowed_components.include?(dependency)

        invalid!("component #{entry.fetch('id')}.component_dependencies",
                 "#{relative} requires undeclared component #{dependency.inspect} via #{required.inspect}")
      end
    end
  end

  def validate_constructions!(entry)
    forbidden = entry.fetch("forbidden_constructions")
    return if forbidden.empty?

    authorized = entry.fetch("authorized_internal_constructions").each_with_object(Set.new) do |site, pairs|
      site.fetch("files").each { |relative| pairs << [ relative, site.fetch("constant") ] }
    end
    owned_files = ruby_files(entry.fetch("owned_paths"))
    (production_ruby_files - owned_files).each do |relative|
      constructions = ruby_syntax(relative).constructions
      invalid_constants = (constructions & forbidden).reject do |constant|
        authorized.include?([ relative, constant ])
      end
      next if invalid_constants.empty?

      invalid!("component #{entry.fetch('id')}.forbidden_constructions",
               "#{relative} directly constructs internal #{invalid_constants.join(', ')}")
    end
  end

  def clean_load_entry!(entry)
    entrypoint = entry.fetch("entrypoint")
    allowed_components = entry.fetch("component_dependencies")
    unrelated_owned_features = component_require_owners.filter_map do |required, owner|
      next if owner == entry.fetch("id") || allowed_components.include?(owner)

      "#{required}.rb"
    end
    script = <<~RUBY
      require "json"
      require #{entrypoint.fetch("require").dump}

      prefixes = #{FORBIDDEN_REQUIRE_PREFIXES.inspect}
      unrelated = #{unrelated_owned_features.inspect}
      loaded = $LOADED_FEATURES.filter_map do |feature|
        relative = feature.sub(%r{\\A#{Regexp.escape(File.join(@root, "lib"))}/?}, "")
        next unless prefixes.any? { |prefix| relative == "\#{prefix}.rb" || relative.start_with?("\#{prefix}/") } ||
                    unrelated.include?(relative)
        relative
      end
      forbidden_constants = #{FORBIDDEN_CONSTANTS.inspect}.select do |name|
        Object.const_defined?(name, false)
      end
      puts JSON.generate(
        "constant" => #{entrypoint.fetch("constant").dump},
        "constant_defined" => Object.const_defined?(#{entrypoint.fetch("constant").dump}, false),
        "forbidden_loaded_features" => loaded.sort,
        "forbidden_constants" => forbidden_constants.sort
      )
    RUBY

    load_paths = [ "-I#{File.join(@root, 'lib')}" ]
    load_paths.unshift("-I#{@root}") unless entrypoint.fetch("file").start_with?("lib/")

    out, err, status = Open3.capture3(
      RbConfig.ruby,
      *load_paths,
      "-e",
      script,
      chdir: @root
    )
    invalid!("component #{entry.fetch('id')}.entrypoint",
             "clean load failed: #{err.strip}") unless status.success?
    result = JSON.parse(out)
    invalid!("component #{entry.fetch('id')}.entrypoint.constant",
             "#{entrypoint.fetch('constant')} was not defined") unless result.fetch("constant_defined")
    unless result.fetch("forbidden_loaded_features").empty?
      invalid!("component #{entry.fetch('id')}.entrypoint.require",
               "clean load pulled forbidden features: #{result.fetch('forbidden_loaded_features').join(', ')}")
    end
    unless result.fetch("forbidden_constants").empty?
      invalid!("component #{entry.fetch('id')}.entrypoint.constant",
               "clean load defined forbidden constants: #{result.fetch('forbidden_constants').join(', ')}")
    end
    result
  rescue JSON::ParserError => e
    invalid!("component #{entry.fetch('id')}.entrypoint", "clean load returned invalid JSON: #{e.message}")
  end

  def boundary_ready_components
    @components.select { |entry| entry.fetch("state") == "boundary-ready" }
  end

  def component_require_owners
    @component_require_owners ||= @component_index.each_with_object({}) do |(id, entry), owners|
      ruby_files(entry.fetch("owned_paths")).each do |relative|
        require_path = require_path_for(relative)
        owners[require_path] = id if require_path
      end
    end
  end

  def production_ruby_files
    @production_ruby_files ||= ruby_files([ "lib" ])
  end

  def ruby_files(paths)
    paths.flat_map do |relative|
      absolute = File.join(@root, relative)
      File.directory?(absolute) ? Dir.glob(File.join(absolute, "**", "*.rb")).sort : [ absolute ]
    end.select { |path| path.end_with?(".rb") }.map { |path| Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s }.uniq
  end

  def ruby_syntax(relative)
    @ruby_syntax ||= {}
    @ruby_syntax[relative] ||= RubySyntax.new(File.read(File.join(@root, relative)), relative)
  end

  def require_path_for(relative)
    return unless relative.start_with?("lib/") && relative.end_with?(".rb")

    relative.delete_prefix("lib/").delete_suffix(".rb")
  end

  def forbidden_require?(required)
    FORBIDDEN_REQUIRE_PREFIXES.any? do |prefix|
      required == prefix || required.start_with?("#{prefix}/")
    end
  end

  def repo_path!(value, path)
    relative = string!(value, path)
    pathname = Pathname.new(relative)
    invalid!(path, "must be repository-relative") if pathname.absolute? || pathname.each_filename.include?("..")

    absolute = File.expand_path(relative, @root)
    real = File.realpath(absolute)
    unless real == @root || real.start_with?("#{@root}/")
      invalid!(path, "#{relative.inspect} resolves outside the repository")
    end
    relative
  rescue Errno::ENOENT
    invalid!(path, "#{relative.inspect} does not exist")
  rescue SystemCallError => e
    invalid!(path, "#{relative.inspect} could not be resolved: #{e.message}")
  end

  def ensure_components!
    validate_catalog! if @components.empty?
  end

  def expect_hash(value, path)
    return value if value.is_a?(Hash)

    invalid!(path, "must be a mapping")
  end

  def expect_array(value, path)
    return value if value.is_a?(Array)

    invalid!(path, "must be an array")
  end

  def string!(value, path)
    return value if value.is_a?(String) && !value.strip.empty?

    invalid!(path, "must be a non-empty string")
  end

  def string_array!(value, path, allow_empty: false)
    rows = expect_array(value, path)
    invalid!(path, "must not be empty") if rows.empty? && !allow_empty
    rows.each_with_index { |item, index| string!(item, "#{path}[#{index}]") }
    rows
  end

  def assert_keys!(hash, allowed, path)
    missing = allowed - hash.keys
    extra = hash.keys - allowed
    invalid!(path, "missing required fields: #{missing.join(', ')}") unless missing.empty?
    invalid!(path, "unknown fields: #{extra.join(', ')}") unless extra.empty?
  end

  def invalid!(path, message)
    raise ValidationError, "#{path}: #{message}"
  end

  class RubySyntax
    attr_reader :requires, :constructions

    def initialize(source, path)
      @requires = []
      @constructions = []
      @path = path
      sexp = Ripper.sexp(source)
      raise ValidationError, "#{path}: Ruby syntax could not be parsed" unless sexp

      walk(sexp, [])
      @requires.uniq!
      @constructions.uniq!
    end

    private

    def walk(node, namespace)
      return unless node.is_a?(Array)

      required = require_literal(node)
      @requires << required if required
      @constructions.concat(construction_constants(node, namespace))
      child_namespace = definition_namespace(node, namespace) || namespace
      node.each do |child|
        walk(child, child_namespace) if child.is_a?(Array)
      end
    end

    def require_literal(node)
      method_name, arguments =
        if node[0] == :command && identifier(node[1]) == "require"
          [ "require", node[2] ]
        elsif node[0] == :command && identifier(node[1]) == "require_relative"
          [ "require_relative", node[2] ]
        elsif node[0] == :method_add_arg && %w[require require_relative].include?(fcall_identifier(node[1]))
          [ fcall_identifier(node[1]), node[2] ]
        end
      return unless arguments

      required = literal_string(arguments)
      return required if required && method_name == "require"
      relative_require_path(required) if required
    end

    def construction_constants(node, namespace)
      return [] unless node[0] == :call &&
                       identifier(node[3]) == "new"

      receiver = constant_path(node[1])
      return [] unless receiver

      candidates = [ receiver ]
      unless absolute_constant_path?(node[1])
        namespace.length.downto(1) do |length|
          candidates << [ *namespace.first(length), receiver ].join("::")
        end
      end
      candidates.uniq
    end

    def definition_namespace(node, namespace)
      return unless %i[module class].include?(node[0])

      name_node = node[1]
      name = constant_path(name_node)
      return unless name
      return name.split("::") if absolute_constant_path?(name_node)

      first = name.split("::").first
      return name.split("::") if first == namespace.first

      [ *namespace, *name.split("::") ]
    end

    def absolute_constant_path?(node)
      return false unless node.is_a?(Array)
      return true if node[0] == :top_const_ref

      node[0] == :const_path_ref && absolute_constant_path?(node[1])
    end

    def fcall_identifier(node)
      return unless node.is_a?(Array) && node[0] == :fcall

      identifier(node[1])
    end

    def identifier(node)
      return unless node.is_a?(Array) && %i[@ident @const].include?(node[0])

      node[1]
    end

    def literal_string(node)
      return unless node.is_a?(Array)
      return if contains_type?(node, :string_embexpr)

      if node[0] == :string_literal
        return node.flatten.each_slice(2).filter_map do |type, value|
          value if type == :@tstring_content
        end.join
      end
      node.each do |child|
        next unless child.is_a?(Array)

        value = literal_string(child)
        return value if value
      end
      nil
    end

    def contains_type?(node, type)
      node.is_a?(Array) && (node[0] == type || node.any? { |child| contains_type?(child, type) })
    end

    def relative_require_path(required)
      relative = Pathname.new(File.join(File.dirname(@path), required)).cleanpath.to_s
      return unless relative.start_with?("lib/")

      relative.delete_prefix("lib/").delete_suffix(".rb")
    end

    def constant_path(node)
      return unless node.is_a?(Array)

      case node[0]
      when :var_ref, :const_ref
        identifier(node[1])
      when :top_const_ref
        identifier(node[1])
      when :const_path_ref
        left = constant_path(node[1])
        right = identifier(node[2])
        [ left, right ].compact.join("::") unless left.nil? || right.nil?
      end
    end
  end
end
