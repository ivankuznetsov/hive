require "test_helper"
require "bundler"
require "json"
require "open3"
require "rbconfig"
require "ripper"
require "tmpdir"
require "yaml"
require_relative "../../../packaging/live_agent_skills/workflow_creator_values"

class WorkflowCreatorValuesTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  VALUES_PATH = File.join(ROOT, "packaging", "live_agent_skills", "workflow_creator_values.rb")
  Values = HiveLiveAgentProof::WorkflowCreator::Values
  MAX_DEPTH = 64
  MAX_NODES = 8_192
  MAX_SOURCE_BYTES = 262_144
  MAX_CANONICAL_BYTES = 1_048_576
  MAX_WORK_UNITS = 4_194_304
  MAX_INTEGER_BITS = 4_096
  POISONED_CHILD_ENV = %w[HIVE_COVERAGE HIVE_COVERAGE_ROOT HIVE_COVERAGE_RUN_ID RUBYOPT]
    .to_h { |name| [ name, nil ] }.freeze
  DECISION_NODES = %i[
    if unless elsif if_mod unless_mod ifop when in rescue rescue_mod
    while until for while_mod until_mod
  ].freeze
  POST_LOAD_FAILURE_POISONS = {
    "Kernel#raise" => "Kernel.module_eval { define_method(:raise) { |*| Process.exit!(71) } }",
    "Exception#initialize" => "Exception.class_eval { define_method(:initialize) { |*| Process.exit!(72) } }",
    "Exception#exception" => "Exception.class_eval { define_method(:exception) { |*| attacker } }",
    "Exception#backtrace" => "Exception.class_eval { define_method(:backtrace) { Process.exit!(73) } }",
    "Exception#set_backtrace" =>
      "Exception.class_eval { define_method(:set_backtrace) { |*| Process.exit!(74) } }",
    "Exception#cause" => "Exception.class_eval { define_method(:cause) { Process.exit!(80) } }",
    "Exception#message" => "Exception.class_eval { define_method(:message) { Process.exit!(81) } }",
    "Exception#to_s" => "Exception.class_eval { define_method(:to_s) { Process.exit!(82) } }",
    "Module#===" => "Module.class_eval { define_method(:===) { |*| Process.exit!(75) } }",
    "Class#===" => "Class.class_eval { define_method(:===) { |*| Process.exit!(76) } }",
    "clone protocol" => <<~'RUBY',
      Object.class_eval { define_method(:clone) { |*| Process.exit!(77) } }
      Exception.class_eval do
        define_method(:initialize_clone) { |*| Process.exit!(78) }
        define_method(:initialize_copy) { |*| Process.exit!(79) }
      end
    RUBY
    "complete failure surface" => <<~'RUBY'
      Kernel.module_eval { define_method(:raise) { |*| Process.exit!(71) } }
      Object.class_eval { define_method(:clone) { |*| Process.exit!(77) } }
      Exception.class_eval do
        define_method(:initialize) { |*| Process.exit!(72) }
        define_method(:exception) { |*| attacker }
        define_method(:backtrace) { Process.exit!(73) }
        define_method(:set_backtrace) { |*| Process.exit!(74) }
        define_method(:cause) { Process.exit!(80) }
        define_method(:message) { Process.exit!(81) }
        define_method(:to_s) { Process.exit!(82) }
        define_method(:initialize_clone) { |*| Process.exit!(78) }
        define_method(:initialize_copy) { |*| Process.exit!(79) }
      end
      Module.class_eval { define_method(:===) { |*| Process.exit!(75) } }
      Class.class_eval { define_method(:===) { |*| Process.exit!(76) } }
    RUBY
  }.freeze

  def test_capture_copies_every_exact_json_type_into_compact_canonical_bytes
    input = {
      "z" => [ true, false, nil, 0, -7, 1.0, -0.0 ],
      "a" => { "empty_object" => {}, "empty_array" => [], "empty_string" => "" }
    }
    captured = Values.capture(input)

    expected_value = {
      "a" => { "empty_array" => [], "empty_object" => {}, "empty_string" => "" },
      "z" => [ true, false, nil, 0, -7, 1.0, -0.0 ]
    }
    assert_equal expected_value, captured.value
    assert_equal "{\"a\":{\"empty_array\":[],\"empty_object\":{},\"empty_string\":\"\"}," \
                 "\"z\":[true,false,null,0,-7,1.0,-0.0]}\n", captured.canonical_bytes
    refute_same input, captured.value
    assert_deeply_frozen captured.value
    assert captured.canonical_bytes.frozen?
    assert_equal Encoding::UTF_8, captured.canonical_bytes.encoding
  end

  def test_capture_rejects_subclasses_non_string_keys_and_lookalikes
    hash_subclass = Class.new(Hash).new
    hash_subclass["key"] = "value"
    array_subclass = Class.new(Array).new([ "value" ])
    string_subclass = Class.new(String).new("value")
    unsupported = [ hash_subclass, array_subclass, string_subclass, { 1 => "value" }, Object.new, :symbol ]

    unsupported.each do |value|
      assert_capture_error(value)
    end
  end

  def test_exact_base_objects_bypass_direct_public_protected_and_private_hooks
    key = +"key"
    value = +"value"
    list = [ value ]

    install_direct_poison(key, :public, %i[class encoding bytesize encode each_byte byteslice to_json hash eql? ==])
    install_direct_poison(value, :protected, %i[encoding bytesize encode each_byte byteslice to_json])
    install_direct_poison(list, :private, %i[class each length to_json])
    key.freeze
    input = {}.compare_by_identity
    input[key] = list
    install_direct_poison(input, :public, %i[class each each_pair length to_json])
    assert_same key, input.keys.first

    captured = Values.capture(input)

    assert_equal({ "key" => [ "value" ] }, captured.value)
    assert_equal "{\"key\":[\"value\"]}\n", captured.canonical_bytes
  end

  def test_exact_base_objects_bypass_extend_include_prepend_and_missing_hooks
    poison = Module.new do
      def class = raise("class dispatched")
      def each = raise("each dispatched")
      def each_pair = raise("each_pair dispatched")
      def length = raise("length dispatched")
      def encoding = raise("encoding dispatched")
      def bytesize = raise("bytesize dispatched")
      def encode(*) = raise("encode dispatched")
      def each_byte = raise("each_byte dispatched")
      def byteslice(*) = raise("byteslice dispatched")
      def to_json(*) = raise("to_json dispatched")
      def respond_to_missing?(*) = raise("respond_to_missing? dispatched")
      def method_missing(*) = raise("method_missing dispatched")

      protected :each, :bytesize, :respond_to_missing?
      private :each_pair, :encode, :method_missing
    end
    key = +"key"
    key.extend(poison)
    key.freeze
    value = +"value"
    value.singleton_class.include(poison)
    list = [ value ]
    list.singleton_class.prepend(poison)
    input = {}.compare_by_identity
    input[key] = list
    input.singleton_class.prepend(poison)
    assert_same key, input.keys.first

    captured = Values.capture(input)

    assert_equal({ "key" => [ "value" ] }, captured.value)
    assert_equal "{\"key\":[\"value\"]}\n", captured.canonical_bytes
  end

  def test_exact_base_objects_bypass_undefined_hooks
    key = +"key"
    key.singleton_class.undef_method(:encode)
    key.freeze
    value = +"value"
    value.singleton_class.undef_method(:bytesize)
    list = [ value ]
    list.singleton_class.undef_method(:each)
    input = {}.compare_by_identity
    input[key] = list
    input.singleton_class.undef_method(:each_pair)
    assert_same key, input.keys.first

    captured = Values.capture(input)

    assert_equal({ "key" => [ "value" ] }, captured.value)
    assert_equal "{\"key\":[\"value\"]}\n", captured.canonical_bytes
  end

  def test_snapshot_is_anonymous_frozen_secret_free_and_not_reconstructible
    secret = "u1a1vi-secret-value"
    snapshot = Values.capture({ "secret" => secret })
    snapshot_class = snapshot.class

    refute Values.const_defined?(:Snapshot, false)
    refute_respond_to Values, :snapshot?
    assert Values.frozen?
    assert Values::Error.frozen?
    assert snapshot_class.frozen?
    assert snapshot.frozen?
    assert_equal "#<HiveLiveAgentProof::WorkflowCreator::Values snapshot>", snapshot.inspect
    refute_includes snapshot.inspect, secret
    refute_respond_to snapshot_class, :new
    refute_respond_to snapshot_class, :allocate
    refute_respond_to snapshot, :dup
    refute_respond_to snapshot, :clone
    refute_respond_to snapshot, :with
    refute_respond_to snapshot, :update
    refute_respond_to snapshot, :instance_variable_set
    assert_raises(NoMethodError) { snapshot_class.new(nil, +"mutable") }
    assert_raises(NoMethodError) { snapshot_class.allocate }
    assert_raises(NoMethodError) { snapshot.dup }
    assert_raises(NoMethodError) { snapshot.clone }
    assert_raises(TypeError) { Marshal.dump(snapshot) }
    assert_raises(TypeError) { snapshot.__send__(:marshal_dump) }
    assert_raises(TypeError) { snapshot.__send__(:marshal_load, {}) }
  end

  def test_capture_owns_fresh_aliases_and_survives_caller_and_module_mutation
    extension = Module.new do
      def to_json(*) = "\"forged\""
    end
    child = { "message" => +"original" }
    child.extend(extension)
    input = [ child, child ]
    captured = Values.capture(input)

    child.fetch("message").replace("changed")
    child["new"] = true
    extension.module_eval do
      define_method(:each_pair) { raise("late module dispatch") }
    end

    assert_equal [ { "message" => "original" }, { "message" => "original" } ], captured.value
    refute_same captured.value.fetch(0), captured.value.fetch(1)
    refute_same captured.value.fetch(0).keys.first, captured.value.fetch(1).keys.first
    assert_equal "[{\"message\":\"original\"},{\"message\":\"original\"}]\n", captured.canonical_bytes
  end

  def test_load_captured_core_and_invocation_paths_resist_post_load_replacement
    script = <<~'RUBY'
      require ARGV.fetch(0)
      UnboundMethod.class_eval do
        define_method(:bind_call) { |*| raise("intercepted UnboundMethod#bind_call") }
        define_method(:bind) { |*| raise("intercepted UnboundMethod#bind") }
      end
      Method.class_eval { define_method(:call) { |*| raise("intercepted Method#call") } }
      BasicObject.class_eval { define_method(:__send__) { |*| raise("intercepted BasicObject#__send__") } }
      {
        Hash => %i[each_pair length key? [] []= delete],
        String => %i[initialize encoding valid_encoding? bytesize encode each_byte byteslice << <=> % hash eql? == dup],
        Integer => %i[+ - * / % > >= < <= == bit_length to_s zero?],
        Float => %i[finite? to_s],
        Encoding => %i[dummy?],
        Object => %i[class freeze instance_variable_get instance_variable_set],
        BasicObject => %i[equal? __id__],
        Class => %i[allocate],
        Array => %i[each index length << pop sort! [] []=]
      }.each do |owner, names|
        names.each { |name| owner.class_eval { define_method(name) { |*| raise("intercepted #{owner}##{name}") } } }
      end
      captured = HiveLiveAgentProof::WorkflowCreator::Values.capture(
        { "z" => [1.5, "value"], "a" => -7 }
      )
      STDOUT.write(captured.canonical_bytes)
    RUBY

    out, err, status = poisoned_capture3(script, VALUES_PATH)

    assert status.success?, err
    assert_equal "{\"a\":-7,\"z\":[1.5,\"value\"]}\n", out
  end

  def test_capture_error_resists_post_load_raise_and_exception_construction_replacement
    assert_failure_poison_resistance(
      expression: "values.capture(Object.new)",
      rescue_class: "values::Error",
      expected: "HiveLiveAgentProof::WorkflowCreator::Values::Error|" \
                "workflow-creator value cannot be captured|true|false"
    )
  end

  def test_snapshot_marshal_error_resists_post_load_raise_and_exception_construction_replacement
    assert_failure_poison_resistance(
      expression: "snapshot.__send__(:marshal_dump)",
      rescue_class: "TypeError",
      expected: "TypeError|workflow-creator snapshots cannot be marshaled|true|false",
      setup: "snapshot = values.capture(nil)"
    )
  end

  def test_encoding_normalization_controls_and_unicode_are_exact
    latin = "é".encode(Encoding::ISO_8859_1)
    normalized = Values.capture(latin)
    assert_equal "é", normalized.value
    assert_equal Encoding::UTF_8, normalized.value.encoding

    controls = "\0\b\f\n\r\t\x1f\"\\é😀"
    expected = "\"\\u0000\\b\\f\\n\\r\\t\\u001f\\\"\\\\é😀\"\n"
    assert_equal expected, Values.capture(controls).canonical_bytes

    collision = { "é" => 1, latin => 2 }
    invalid_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)
    dummy = "\x00a".dup.force_encoding(Encoding::UTF_16)
    binary = "ascii".b
    [ collision, invalid_utf8, dummy, binary ].each { |value| assert_capture_error(value) }
  end

  def test_integer_float_and_signed_zero_boundaries_are_exact
    largest_positive = 1 << (MAX_INTEGER_BITS - 1)
    largest_negative = -(1 << MAX_INTEGER_BITS)
    assert_equal largest_positive, Values.capture(largest_positive).value
    assert_equal largest_negative, Values.capture(largest_negative).value
    assert_capture_error(1 << MAX_INTEGER_BITS)
    assert_capture_error(-(1 << MAX_INTEGER_BITS) - 1)

    assert_equal "[1,1.0,-0.0]\n", Values.capture([ 1, 1.0, -0.0 ]).canonical_bytes
    assert_equal(-Float::INFINITY, 1.0 / Values.capture(-0.0).value)
    [ Float::NAN, Float::INFINITY, -Float::INFINITY ].each { |value| assert_capture_error(value) }
  end

  def test_deterministic_finite_ieee_754_tokens_roundtrip_byte_exactly
    patterns = [ 0, 1 << 63 ]
    seen = patterns.to_h { |bits| [ bits, true ] }
    random = Random.new(0x1EE7_F10A7)
    while patterns.length < 20_000
      bits = random.rand(0..0xffff_ffff_ffff_ffff)
      next if seen.key?(bits)

      value = [ bits ].pack("Q>").unpack1("G")
      next unless value.finite?

      seen[bits] = true
      patterns << bits
    end

    patterns.each_with_index do |bits, index|
      value = [ bits ].pack("Q>").unpack1("G")
      canonical = Values.capture(value).canonical_bytes
      token = canonical.delete_suffix("\n")
      roundtrip_bits = [ Float(token) ].pack("G").unpack1("Q>")
      assert_equal bits, roundtrip_bits, "IEEE-754 case #{index}: #{token}"
      assert_equal "#{value}\n", canonical, "IEEE-754 token #{index}"
    end
    assert_equal "0.0\n", Values.capture(0.0).canonical_bytes
    assert_equal "-0.0\n", Values.capture(-0.0).canonical_bytes
  end

  def test_large_finite_float_roundtrip_and_canonical_property_corpus
    floats = [ Float::MAX, -Float::MAX, Float::MIN, Float::EPSILON, 1.0e300, 1.0e-300, 3.141592653589793 ]
    floats.each do |value|
      bytes = Values.capture(value).canonical_bytes
      token = bytes.delete_suffix("\n")
      assert_equal value, Float(token), token
      assert_equal "#{value}\n", bytes
    end

    random = Random.new(0xA11A1)
    250.times do |index|
      value = property_value(random)
      captured = Values.capture(value)
      assert_equal reference_canonical(value), captured.canonical_bytes, "property case #{index}"
      assert captured.value == JSON.parse(captured.canonical_bytes), "semantic case #{index}"
    end
  end

  def test_shared_graphs_copy_per_occurrence_and_cycles_fail_closed
    shared = { "value" => [ 1, 2, 3 ] }
    captured = Values.capture([ shared, shared ])
    refute_same captured.value.fetch(0), captured.value.fetch(1)
    refute_same captured.value.fetch(0).fetch("value"), captured.value.fetch(1).fetch("value")

    array_cycle = []
    array_cycle << array_cycle
    hash_cycle = {}
    hash_cycle["self"] = hash_cycle
    assert_capture_error(array_cycle)
    assert_capture_error(hash_cycle)
  end

  def test_depth_cap_accepts_n_and_rejects_n_plus_one
    at_limit = nil
    MAX_DEPTH.times { at_limit = [ at_limit ] }
    over_limit = [ at_limit ]

    assert_equal at_limit, Values.capture(at_limit).value
    assert_capture_error(over_limit)
  end

  def test_node_cap_accepts_n_and_rejects_n_plus_one_before_child_import
    at_limit = Array.new(MAX_NODES - 1, nil)
    over_limit = Array.new(MAX_NODES, nil)
    assert_equal MAX_NODES - 1, Values.capture(at_limit).value.length
    assert_capture_error(over_limit)
    assert_capture_error([ Array.new(MAX_NODES - 2, nil), nil ])

    impossible_hash = (0...(MAX_NODES / 2)).to_h { |index| [ "key-#{index}", nil ] }
    encode_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      encode_calls += 1 if event.defined_class == String && event.method_id == :encode
    end
    trace.enable { assert_capture_error(impossible_hash) }
    assert_equal 0, encode_calls, "impossible cardinality must fail before key transcoding"
  end

  def test_maximum_hash_collision_admission_has_no_quadratic_key_comparison_scan
    maximum_entries = (MAX_NODES - 1) / 2
    input = maximum_entries.times.to_h do |index|
      [ format("key-%04d", maximum_entries - index), nil ]
    end
    captured = nil
    comparisons = string_comparison_counts { captured = Values.capture(input) }

    comparison_budget = maximum_entries * maximum_entries.bit_length * 2
    assert_equal maximum_entries, captured.value.length
    assert_operator comparisons.values.sum, :<=, comparison_budget,
                    "collision admission must not scan every previously imported key"

    diagnostic_size = 128
    diagnostic_keys = Array.new(diagnostic_size) { |index| format("probe-%03d", index) }
    quadratic = string_comparison_counts do
      diagnostic_keys.each_with_index do |key, index|
        diagnostic_keys.first(index).each { |prior| key == prior || key.eql?(prior) }
      end
    end
    equality_comparisons = quadratic.fetch(:==, 0) + quadratic.fetch(:eql?, 0)
    diagnostic_budget = diagnostic_size * diagnostic_size.bit_length * 2
    assert_operator equality_comparisons, :>, diagnostic_budget,
                    "diagnostic fixture must expose equality-based quadratic scans"
  end

  def test_source_string_byte_cap_accepts_n_and_rejects_n_plus_one_before_transcode
    at_limit = "x" * MAX_SOURCE_BYTES
    assert_equal at_limit, Values.capture(at_limit).value

    encode_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      encode_calls += 1 if event.defined_class == String && event.method_id == :encode
    end
    trace.enable { assert_capture_error("x" * (MAX_SOURCE_BYTES + 1)) }
    assert_equal 0, encode_calls, "source limit must be charged before transcoding"
  end

  def test_canonical_byte_cap_including_newline_accepts_n_and_rejects_n_plus_one
    at_limit = ("\0" * 174_762) + "a"
    over_limit = at_limit + "a"

    captured = Values.capture(at_limit)
    assert_equal MAX_CANONICAL_BYTES, captured.canonical_bytes.bytesize
    assert_capture_error(over_limit)
  end

  def test_logical_work_cap_accepts_n_and_rejects_n_plus_one
    at_limit = logical_work_value(source_bytes: 62_510, escaped_bytes: 24)
    over_limit = logical_work_value(source_bytes: 62_511, escaped_bytes: 23)

    assert Values.capture(at_limit).frozen?
    assert_capture_error(over_limit)
  end

  def test_errors_are_fixed_secret_free_and_have_no_cause
    secret = "u1a1vi-rejected-secret"
    invalid = "#{secret}\xFF".dup.force_encoding(Encoding::UTF_8)

    error = assert_capture_error(invalid)

    assert_equal "workflow-creator value cannot be captured", error.message
    assert_nil error.cause
    refute_includes error.full_message, secret
    refute_includes error.inspect, secret
  end

  def test_clean_disable_gems_load_has_no_json_dependency_or_named_snapshot
    script = <<~'RUBY'
      require ARGV.fetch(0)
      values = HiveLiveAgentProof::WorkflowCreator::Values
      abort("JSON loaded") if defined?(JSON)
      abort("named Snapshot") if values.const_defined?(:Snapshot, false)
      captured = values.capture({ "b" => true, "a" => nil })
      abort("wrong bytes") unless captured.canonical_bytes == "{\"a\":null,\"b\":true}\n"
    RUBY
    out, err, status = Open3.capture3(
      POISONED_CHILD_ENV,
      RbConfig.ruby,
      "--disable-gems",
      "-I#{ROOT}",
      "-e",
      script,
      VALUES_PATH
    )

    assert status.success?, "stdout=#{out.inspect} stderr=#{err.inspect}"
  end

  def test_capture_is_pure_and_source_has_no_io_or_json_dependency
    source = File.read(VALUES_PATH)
    refute_match(/^\s*require\b/, source)
    refute_match(/\bJSON\b/, source)
    refute_match(/\b(?:File|IO|Dir|Process|Open3)\b/, source)

    script = <<~'RUBY'
      require ARGV.fetch(0)
      [File, Dir, Process].each do |owner|
        %i[open read write binread binwrite spawn exec].each do |name|
          owner.define_singleton_method(name) { |*| raise("I/O dispatched: #{owner}.#{name}") }
        end
      end
      HiveLiveAgentProof::WorkflowCreator::Values.capture({ "safe" => [1, true, nil] })
    RUBY
    out, err, status = poisoned_capture3(script, VALUES_PATH)
    assert status.success?, "stdout=#{out.inspect} stderr=#{err.inspect}"
  end

  def test_static_metric_harness_counts_every_decision_form
    fixtures = {
      if: [ "if flag\n  work\nend\n", 1 ],
      unless: [ "unless flag\n  work\nend\n", 1 ],
      elsif: [ "if first\n  work\nelsif second\n  work\nend\n", 2 ],
      if_modifier: [ "work if flag\n", 1 ],
      unless_modifier: [ "work unless flag\n", 1 ],
      ternary: [ "flag ? left : right\n", 1 ],
      when: [ "case value\nwhen 1\n  work\nend\n", 1 ],
      in: [ "case value\nin Integer\n  work\nend\n", 1 ],
      rescue: [ "begin\n  work\nrescue Error\n  recover\nend\n", 1 ],
      rescue_modifier: [ "work rescue recover\n", 1 ],
      while: [ "while flag\n  work\nend\n", 1 ],
      until: [ "until flag\n  work\nend\n", 1 ],
      for: [ "for value in values\n  work\nend\n", 1 ],
      while_modifier: [ "work while flag\n", 1 ],
      until_modifier: [ "work until flag\n", 1 ],
      boolean_and: [ "left && right\n", 1 ],
      boolean_or: [ "left || right\n", 1 ]
    }

    fixtures.each do |name, (source, expected)|
      assert_equal expected, static_metrics(source).fetch(:decisions), name
    end
  end

  def test_static_metric_harness_rejects_donor_shaped_false_green_fixture
    definitions = 8.times.map { |index| "def method_#{index}; true; end" }.join("\n")
    closures = 7.times.map { |index| "LAMBDA_#{index} = -> { true }" } +
               5.times.map { |index| "PROC_#{index} = proc { true }" } +
               [ "PROC_NEW = Proc.new { true }" ]
    source = "#{definitions}\n#{closures.join("\n")}\n"
    naive_method_only_count = source.lines.count { |line| line.match?(/^def /) }
    observed = static_metrics(source)

    assert_equal 8, naive_method_only_count
    assert_equal 21, observed.fetch(:callables)
    assert_operator observed.fetch(:callables), :>, 20
    assert_includes observed.fetch(:closure_nodes), :proc_new
    assert_equal 0, naive_decision_count("def guarded; left && right || fallback; end\n")
    assert_equal 2, static_metrics("def guarded; left && right || fallback; end\n").fetch(:decisions)
  end

  def test_production_file_stays_within_u1a1vi_exact_caps
    source = File.read(VALUES_PATH)
    metrics = static_metrics(source)
    required_callables = %i[
      value canonical_bytes inspect marshal_dump marshal_load capture import_value
      import_hash import_array import_string import_integer import_float escape_byte append! charge! seal
      fail_capture! ===
    ]

    assert_operator source.lines.length, :<=, 300
    assert_operator metrics.fetch(:callables), :<=, 20
    assert_operator metrics.fetch(:decisions), :<=, 32
    assert_empty metrics.fetch(:closure_nodes)
    required_callables.each { |name| assert_includes metrics.fetch(:method_names), name }
    refute_match(/rubocop\s*:(?:disable|todo)/i, source)
    refute_match(/\b(?:Struct|Data)\b/, source)
    refute_match(/\b(?:define_method|define_singleton_method|attr_reader|attr_writer|attr_accessor)\b/, source)
    refute_match(/\b(?:lambda|proc)\b|\bProc\.new\b/, source)
  end

  def test_every_production_method_passes_the_explicit_r43_rubocop_overlay
    overlay = {
      "AllCops" => {
        "TargetRubyVersion" => 3.4,
        "DisabledByDefault" => true,
        "NewCops" => "disable"
      },
      "Metrics/CyclomaticComplexity" => { "Enabled" => true, "Max" => 15 },
      "Metrics/PerceivedComplexity" => { "Enabled" => true, "Max" => 15 },
      "Metrics/AbcSize" => { "Enabled" => true, "Max" => 25 },
      "Metrics/MethodLength" => { "Enabled" => true, "Max" => 40 },
      "Layout/LineLength" => { "Enabled" => true, "Max" => 120 }
    }

    Dir.mktmpdir do |directory|
      config = File.join(directory, "u1a1vi-rubocop.yml")
      File.write(config, YAML.dump(overlay))
      rubocop_spec = Bundler.load.specs.find { |spec| spec.name == "rubocop" }
      refute_nil rubocop_spec, "the selected bundle must include RuboCop"
      rubocop_executable = File.join(rubocop_spec.full_gem_path, "exe", "rubocop")
      assert File.file?(rubocop_executable), "missing #{rubocop_executable}"
      out, status = Open3.capture2e(
        POISONED_CHILD_ENV,
        RbConfig.ruby,
        rubocop_executable,
        "--config",
        config,
        "--format",
        "simple",
        VALUES_PATH,
        chdir: ROOT
      )

      assert status.success?, out
    end
  end

  private

  def assert_failure_poison_resistance(expression:, rescue_class:, expected:, setup: "")
    observed = POST_LOAD_FAILURE_POISONS.map do |label, poison|
      script = <<~RUBY
        require ARGV.fetch(0)
        values = HiveLiveAgentProof::WorkflowCreator::Values
        attacker = RuntimeError.new("attacker failure")
        module_case = Module.instance_method(:===)
        class_case = Class.instance_method(:===)
        #{setup}
        errors = 2.times.map do
          begin
            #{poison}
            begin
              #{expression}
            ensure
              Module.class_eval { define_method(:===, module_case) }
              Class.class_eval { define_method(:===, class_case) }
            end
          rescue #{rescue_class} => error
            error
          end
        end
        error = errors.fetch(0)
        STDOUT.write(
          [ error.class.name, error.message, error.cause.nil?, error.equal?(errors.fetch(1)) ].join("|")
        )
      RUBY

      out, err, status = poisoned_capture3(script, VALUES_PATH)
      [ label, status.exitstatus, out, err ]
    end

    expected_results = POST_LOAD_FAILURE_POISONS.keys.map { |label| [ label, 0, expected, "" ] }
    assert_equal expected_results, observed
  end

  def assert_capture_error(value)
    error = assert_raises(Values::Error) { Values.capture(value) }
    assert_equal "workflow-creator value cannot be captured", error.message
    assert_nil error.cause
    error
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) } if value.instance_of?(Hash)
    value.each { |nested| assert_deeply_frozen(nested) } if value.instance_of?(Array)
  end

  def install_direct_poison(value, visibility, names)
    singleton = value.singleton_class
    names.each do |name|
      singleton.define_method(name) { |*| raise("direct #{visibility} #{name} dispatched") }
      singleton.send(visibility, name)
    end
  end

  def logical_work_value(source_bytes:, escaped_bytes:)
    # For D nested one-item arrays around L source bytes with Q quotes, capture charges
    # (D + 3) * L + (D + 2) * Q + D**2 + 7 * D + 6 deterministic work units.
    leaf = ('"' * escaped_bytes) + ("a" * (source_bytes - escaped_bytes))
    MAX_DEPTH.times { leaf = [ leaf ] }
    leaf
  end

  def property_value(random, depth = 0)
    strings = [ "", "plain", "quote=\" slash=\\ control=\0\n", "é😀" ]
    floats = [ 0.0, -0.0, 1.0e20, 1.0e-6, 1.0e-7, 3.141592653589793 ]
    scalars = [ nil, true, false, random.rand(-1_000_000..1_000_000),
               floats.fetch(random.rand(floats.length)), strings.fetch(random.rand(strings.length)) ]
    return scalars.fetch(random.rand(scalars.length)) if depth >= 3 || random.rand(3).zero?

    return Array.new(random.rand(5)) { property_value(random, depth + 1) } if random.rand(2).zero?

    Array.new(random.rand(5)) do |index|
      [ "k#{depth}-#{index}-#{random.rand(1_000_000)}", property_value(random, depth + 1) ]
    end.to_h
  end

  def reference_canonical(value)
    "#{reference_token(value)}\n"
  end

  def reference_token(value)
    if value.instance_of?(Hash)
      entries = value.map do |key, nested|
        normalized = key.encode(Encoding::UTF_8)
        [ normalized, "#{JSON.generate(normalized)}:#{reference_token(nested)}" ]
      end
      "{#{entries.sort_by { |key, _token| key.b }.map(&:last).join(',')}}"
    elsif value.instance_of?(Array)
      "[#{value.map { |nested| reference_token(nested) }.join(',')}]"
    elsif value.instance_of?(String)
      JSON.generate(value.encode(Encoding::UTF_8))
    elsif value.instance_of?(Integer) || value.instance_of?(Float)
      value.to_s
    elsif value.equal?(true)
      "true"
    elsif value.equal?(false)
      "false"
    else
      "null"
    end
  end

  def poisoned_capture3(script, *arguments)
    Bundler.with_unbundled_env do
      Open3.capture3(POISONED_CHILD_ENV, RbConfig.ruby, "-e", script, *arguments)
    end
  end

  def string_comparison_counts
    counts = Hash.new(0)
    methods = %i[<=> == eql?]
    trace = TracePoint.new(:c_call) do |event|
      counts[event.method_id] += 1 if event.defined_class == String && methods.include?(event.method_id)
    end
    trace.enable { yield }
    counts
  end

  def naive_decision_count(source)
    syntax = Ripper.sexp(source) or raise "invalid Ruby fixture"
    count = 0
    walk = lambda do |node|
      next unless node.instance_of?(Array)

      count += 1 if DECISION_NODES.include?(node.first)
      node.each { |child| walk.call(child) }
    end
    walk.call(syntax)
    count
  end

  def static_metrics(source)
    syntax = Ripper.sexp(source) or raise "invalid Ruby source"
    metrics = { callables: 0, decisions: 0, method_names: [], closure_nodes: [] }
    walk = lambda do |node|
      next unless node.instance_of?(Array)

      type = node.first
      if %i[def defs].include?(type)
        metrics[:callables] += 1
        name_node = type == :def ? node[1] : node[3]
        metrics[:method_names] << name_node[1].to_sym
      elsif type == :lambda
        metrics[:callables] += 1
        metrics[:closure_nodes] << type
      elsif (closure_kind = proc_block_kind(node))
        metrics[:callables] += 1
        metrics[:closure_nodes] << closure_kind
      end
      metrics[:decisions] += 1 if DECISION_NODES.include?(type)
      metrics[:decisions] += 1 if type == :binary && %i[&& ||].include?(node[2])
      node.each { |child| walk.call(child) }
    end
    walk.call(syntax)
    metrics
  end

  def proc_block_kind(node)
    return unless node.first == :method_add_block

    call = node[1]
    identifiers = []
    constants = []
    collect_identifiers = lambda do |child|
      next unless child.instance_of?(Array)

      identifiers << child[1] if child.first == :@ident
      constants << child[1] if child.first == :@const
      child.each { |nested| collect_identifiers.call(nested) }
    end
    collect_identifiers.call(call)
    return :proc_new if constants.include?("Proc") && identifiers.include?("new")
    :proc if identifiers.include?("lambda") || identifiers.include?("proc")
  end
end
