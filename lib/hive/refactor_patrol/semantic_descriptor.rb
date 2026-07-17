require "hive/refactor_patrol/semantic_family"
require "uri"

module Hive
  module RefactorPatrol
    # Derives the durable family vocabulary from a normalized thesis. The
    # inputs are mapper identities and semantic prose, never language syntax,
    # so the same policy applies to every ecosystem ArchitectureMapper finds.
    module SemanticDescriptor
      MAX_CONCEPTS = 24
      CHUNK_SUFFIX = /-part-\d+\z/
      WORD = /[a-z0-9]+/

      STOP_WORDS = %w[
        a about across after again against all also am an and any are as at be
        because been before being behind between both but by can code could
        did do does doing down during each few file files for from further had
        has have having here how i if in into is it its itself may more most
        must my no nor not of off on once only or other our out over own same
        should so some such than that the their theirs them themselves then
        there these they this those through to too under until up very was we
        were what when where which while who why will with would you your
        abstraction adapter architecture boundary centralize change concern
        consolidate contract decision dependency duplicate duty edit extract
        give implementation isolate issue logic move one policy problem proposed
        refactor repeat responsibility shared single split touch
      ].freeze

      TOKEN_ALIASES = {
        "authorise" => "authorization", "authorize" => "authorization",
        "authorised" => "authorization", "authorized" => "authorization",
        "centralise" => "consolidate", "centralize" => "consolidate",
        "classification" => "classifier", "classify" => "classifier",
        "duplicated" => "duplicate", "duplication" => "duplicate",
        "edited" => "edit", "editing" => "edit", "edits" => "edit",
        "execute" => "execution", "executing" => "execution",
        "normalise" => "normalization", "normalize" => "normalization",
        "orchestrate" => "orchestration", "orchestrated" => "orchestration",
        "orchestrating" => "orchestration", "repeated" => "repeat",
        "repeatedly" => "repeat", "repeats" => "repeat", "route" => "routing",
        "routes" => "routing", "validate" => "validation",
        "validated" => "validation", "validating" => "validation"
      }.freeze

      module_function

      def call(thesis:, source:)
        uri = URI.parse(source_value(source, "url"))
        raise ArgumentError, "source URL must include an exact host" unless uri.host

        SemanticFamily.descriptor(
          host: uri.host,
          repository: source_value(source, "repository"),
          component: stable_component(thesis),
          problem_kind: problem_kind(thesis),
          refactor_kind: refactor_kind(thesis),
          anchors: anchors(thesis),
          concepts: concepts(thesis)
        )
      rescue URI::InvalidURIError
        raise ArgumentError, "source URL must include an exact host"
      end

      def stable_component(thesis)
        value(thesis, "feature_id").to_s.strip.sub(CHUNK_SUFFIX, "")
      end
      private_class_method :stable_component

      def anchors(thesis)
        cited = Array(value(thesis, "evidence")).filter_map do |entry|
          hash_value(entry, "file").to_s.strip unless entry.nil?
        end.reject(&:empty?)
        return cited unless cited.empty?

        boundary = value(thesis, "feature_boundary")
        Array(hash_value(boundary, "entrypoints")) + Array(hash_value(boundary, "owned_files"))
      end
      private_class_method :anchors

      def problem_kind(thesis)
        text = semantic_text(thesis, %w[problem cost], evidence: true)
        return "cyclic_dependency" if text.match?(/\b(?:cycle|cyclic|circular)\b.*\bdepend|\bdepend\w*\b.*\b(?:cycle|cyclic|circular)\b/)
        return "unstable_dependency" if text.match?(/\b(?:unstable|volatile|cascad\w*)\b.*\bdepend/)
        if text.match?(/\b(?:boundary|layer|encapsulation)\b.*\b(?:leak|bypass|cross|reach)/) ||
           text.match?(/\b(?:leak|bypass|cross|reach)\w*\b.*\b(?:boundary|layer|encapsulation)/)
          return "boundary_leak"
        end
        return "parallel_implementations" if text.match?(/\b(?:parallel|competing)\b.*\bimplement/) || text.match?(/\btwo\b.*\bimplement\w*\b.*\bsame\b/)
        if text.match?(/\b(?:contract|interface|protocol|schema|api)\b/) &&
           text.match?(/\b(?:scatter|diverg|inconsisten|repeat|duplicat|multiple)\w*\b/)
          return "scattered_contract"
        end
        if text.match?(/\b(?:policy|rule|decision|validation|authorization|classifier)\b/) &&
           text.match?(/\b(?:duplicat|repeat|copy|parallel|scatter)\w*\b/)
          return "duplicated_policy"
        end
        return "oversized_component" if text.match?(/\b(?:oversiz|god|monolith|too many|too large|giant)\w*\b/)
        return "missing_abstraction" if text.match?(/\b(?:missing|no|lack\w*)\b.*\b(?:abstraction|boundary|adapter)\b/)
        if text.match?(/\b(?:mix|combin|unrelated|multiple)\w*\b.*\b(?:responsibil|dut|concern)/) ||
           text.match?(/\b(?:responsibil|dut|concern)\w*\b.*\b(?:mix|combin|unrelated|multiple)/)
          return "mixed_responsibilities"
        end

        "other"
      end
      private_class_method :problem_kind

      def refactor_kind(thesis)
        text = semantic_text(thesis, %w[proposed_refactor], mechanisms: true)
        return "invert_dependency" if text.match?(/\b(?:invert|dependency inversion|reverse dependency)\b/)
        return "introduce_adapter" if text.match?(/\b(?:introduce|add|create|extract)\w*\b.*\badapter\b/)
        if text.match?(/\b(?:contract|interface|protocol|schema|api)\b/) &&
           text.match?(/\b(?:consolidat|centraliz|centralis|unif|single|shared)\w*\b/)
          return "consolidate_contract"
        end
        if text.match?(/\b(?:policy|rule|decision|validation|authorization|classifier)\b/) &&
           text.match?(/\b(?:consolidat|centraliz|centralis|unif|single|shared)\w*\b/)
          return "consolidate_policy"
        end
        return "split_component" if text.match?(/\b(?:split|decompos|partition)\w*\b/)
        return "move_responsibility" if text.match?(/\b(?:move|relocat|transfer)\w*\b.*\b(?:responsibil|ownership|dut|concern|persistence)/)
        return "extract_boundary" if text.match?(/\b(?:extract|isolate|separat)\w*\b/) || text.match?(/\b(?:new|shared|stable)\b.*\bboundary\b/)

        "other"
      end
      private_class_method :refactor_kind

      def concepts(thesis)
        documents = [
          value(thesis, "feature"), value(thesis, "problem"), value(thesis, "cost"),
          value(thesis, "proposed_refactor"),
          *Array(value(thesis, "evidence")).map { |entry| hash_value(entry, "claim") },
          *Array(hash_value(value(thesis, "expected_leverage"), "drivers")).map { |driver| hash_value(driver, "mechanism") }
        ].map { |item| tokens(item) }.reject(&:empty?)
        frequency = Hash.new(0)
        documents.each { |document| document.uniq.each { |token| frequency[token] += 1 } }
        selected = frequency.sort_by { |token, count| [ -count, token ] }.first(MAX_CONCEPTS).map(&:first).sort
        return selected unless selected.empty?

        tokens(stable_component(thesis)) + [ "unspecified" ]
      end
      private_class_method :concepts

      def tokens(value)
        split_camel(value.to_s).downcase.scan(WORD).filter_map do |raw|
          next if raw.length < 3 || raw.match?(/\A\d+\z/)

          stemmed = stem(raw)
          token = TOKEN_ALIASES.fetch(raw, TOKEN_ALIASES.fetch(stemmed, stemmed))
          token unless STOP_WORDS.include?(token)
        end.uniq
      end
      private_class_method :tokens

      def stem(token)
        if token.length > 4 && token.end_with?("ies")
          token.sub(/ies\z/, "y")
        elsif token.length > 4 && token.end_with?("s") && !token.end_with?("ss")
          token.delete_suffix("s")
        else token
        end
      end
      private_class_method :stem

      def split_camel(text)
        text.gsub(/([a-z0-9])([A-Z])/, "\\1 \\2")
      end
      private_class_method :split_camel

      def semantic_text(thesis, fields, evidence: false, mechanisms: false)
        items = fields.map { |field| value(thesis, field) }
        items.concat(Array(value(thesis, "evidence")).map { |entry| hash_value(entry, "claim") }) if evidence
        if mechanisms
          drivers = hash_value(value(thesis, "expected_leverage"), "drivers")
          items.concat(Array(drivers).map { |driver| hash_value(driver, "mechanism") })
        end
        split_camel(items.join(" ")).downcase.gsub(/[^a-z0-9]+/, " ")
      end
      private_class_method :semantic_text

      def value(object, key)
        return hash_value(object, key) if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end
      private_class_method :value

      def source_value(source, key)
        hash_value(source, key).to_s
      end
      private_class_method :source_value

      def hash_value(hash, key)
        return unless hash.is_a?(Hash)
        return hash[key] if hash.key?(key)
        hash[key.to_sym] if hash.key?(key.to_sym)
      end
      private_class_method :hash_value
    end
  end
end
