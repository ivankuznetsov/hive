require "bigdecimal"
require "time"
require "uri"
require "yaml"

module Hive
  class ModelPricing
    CATALOG_PATH = File.expand_path("../../config/model-pricing.v1.yml", __dir__).freeze
    PROVIDERS = %w[openai anthropic xai].freeze
    SOURCE_HOSTS = {
      "openai" => "developers.openai.com",
      "anthropic" => "platform.claude.com",
      "xai" => "docs.x.ai"
    }.freeze
    LIFECYCLES = %w[active deprecated retired redirect].freeze
    TOP_LEVEL_KEYS = %w[schema schema_version checked_at currency unit cards].freeze
    CARD_KEYS = %w[
      provider canonical_model aliases effective_from effective_until lifecycle
      source_url rates required_dimensions modifiers
    ].freeze
    RATE_KEYS = %w[
      input cache_read cache_write cache_write_5m cache_write_1h output
    ].freeze
    DIMENSION_KEYS = %w[
      service_tier context_tokens inference_geo server_tool_usage
    ].freeze
    MODIFIER_KEYS = %w[
      standard_service_tier standard_inference_geo inference_geo_us long_context
    ].freeze
    LONG_CONTEXT_KEYS = %w[
      threshold_tokens input cache_read cache_write output
    ].freeze
    MILLION = BigDecimal("1000000")

    class CatalogError < ArgumentError; end

    def initialize(catalog_path: CATALOG_PATH, catalog: nil)
      @catalog = validate_catalog!(catalog || load_catalog(catalog_path))
    end

    def estimate(session)
      session = symbolize(session)
      provider = normalize_provider(session[:actual_backend] || session[:provider])
      model = text(session[:actual_model] || session[:model])
      return unavailable("provider", provider:, model:) unless PROVIDERS.include?(provider)
      return unavailable("model", provider:, model:) if model.nil?

      started_at = parse_time(session[:started_at])
      return unavailable("session_time", provider:, model:) unless started_at

      card = resolve_card(provider, model, started_at)
      unless card
        known_model = @catalog.fetch("cards").any? do |candidate|
          candidate.fetch("provider") == provider &&
            [ candidate.fetch("canonical_model"), *candidate.fetch("aliases") ].include?(model)
        end
        return unavailable(known_model ? "rate_card" : "model", provider:, model:)
      end
      unless card.fetch("lifecycle") == "active"
        return unavailable(
          "model_lifecycle", provider:, model: card.fetch("canonical_model"), card: card
        )
      end

      calculate(session, card)
    rescue CatalogError
      raise
    rescue StandardError
      unavailable("usage", provider: nil, model: nil)
    end

    private

    def load_catalog(path)
      YAML.safe_load(
        File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false
      )
    rescue Errno::ENOENT, Psych::Exception => e
      raise CatalogError, "model pricing catalog is unavailable: #{e.message}"
    end

    def validate_catalog!(catalog)
      invalid!("catalog", "must be an object") unless catalog.is_a?(Hash)
      exact_keys!(catalog, TOP_LEVEL_KEYS, "catalog")
      invalid!("schema", "must be hive-model-pricing") unless
        catalog["schema"] == "hive-model-pricing"
      invalid!("schema_version", "must be 1") unless catalog["schema_version"] == 1
      invalid!("currency", "must be USD") unless catalog["currency"] == "USD"
      invalid!("unit", "must be usd_per_million_tokens") unless
        catalog["unit"] == "usd_per_million_tokens"
      checked_at = catalog["checked_at"].to_s
      invalid!("checked_at", "must be YYYY-MM-DD") unless
        /\A\d{4}-\d{2}-\d{2}\z/.match?(checked_at)
      cards = catalog["cards"]
      invalid!("cards", "must be a non-empty array") unless cards.is_a?(Array) && !cards.empty?

      cards.each_with_index { |card, index| validate_card!(card, index) }
      validate_alias_intervals!(cards)
      catalog.freeze
    end

    def validate_card!(card, index)
      path = "cards[#{index}]"
      invalid!(path, "must be an object") unless card.is_a?(Hash)
      exact_keys!(card, CARD_KEYS, path)
      provider = card["provider"].to_s
      invalid!("#{path}.provider", "is unsupported") unless PROVIDERS.include?(provider)
      invalid!("#{path}.canonical_model", "must be non-empty") if text(card["canonical_model"]).nil?
      aliases = card["aliases"]
      invalid!("#{path}.aliases", "must contain unique non-empty strings") unless
        aliases.is_a?(Array) && aliases.all? { |item| !text(item).nil? } && aliases.uniq == aliases
      effective_from = parse_required_time!(card["effective_from"], "#{path}.effective_from")
      if card["effective_until"]
        effective_until = parse_required_time!(
          card["effective_until"], "#{path}.effective_until"
        )
        invalid!("#{path}.effective_until", "must be after effective_from") unless
          effective_until > effective_from
      end
      invalid!("#{path}.lifecycle", "is invalid") unless LIFECYCLES.include?(card["lifecycle"])
      validate_source!(provider, card["source_url"], "#{path}.source_url")
      rates = card["rates"]
      invalid!("#{path}.rates", "must be an object") unless rates.is_a?(Hash)
      invalid!("#{path}.rates", "contains unknown categories") unless
        (rates.keys - RATE_KEYS).empty?
      %w[input output].each do |key|
        invalid!("#{path}.rates.#{key}", "is required") unless rates.key?(key)
      end
      rates.each { |key, value| decimal!(value, "#{path}.rates.#{key}") }
      dimensions = card["required_dimensions"]
      invalid!("#{path}.required_dimensions", "must be unique strings") unless
        dimensions.is_a?(Array) && dimensions.all? { |item| !text(item).nil? } &&
          dimensions.uniq == dimensions
      invalid!("#{path}.required_dimensions", "contains unknown dimensions") unless
        (dimensions - DIMENSION_KEYS).empty?
      validate_modifiers!(card["modifiers"], provider, path)
    end

    def validate_modifiers!(modifiers, provider, path)
      invalid!("#{path}.modifiers", "must be an object") unless modifiers.is_a?(Hash)
      invalid!("#{path}.modifiers", "contains unknown modifiers") unless
        (modifiers.keys - MODIFIER_KEYS).empty?
      invalid!("#{path}.modifiers.standard_service_tier", "must be non-empty") if
        text(modifiers["standard_service_tier"]).nil?

      if provider == "anthropic"
        invalid!("#{path}.modifiers.standard_inference_geo", "must be non-empty") if
          text(modifiers["standard_inference_geo"]).nil?
        decimal!(modifiers["inference_geo_us"], "#{path}.modifiers.inference_geo_us")
        invalid!("#{path}.modifiers.long_context", "is unsupported") if
          modifiers.key?("long_context")
      else
        validate_long_context!(modifiers["long_context"], path)
        %w[standard_inference_geo inference_geo_us].each do |key|
          invalid!("#{path}.modifiers.#{key}", "is unsupported") if modifiers.key?(key)
        end
      end
    end

    def validate_long_context!(modifier, path)
      target = "#{path}.modifiers.long_context"
      invalid!(target, "must be an object") unless modifier.is_a?(Hash)
      invalid!(target, "contains unknown keys") unless
        (modifier.keys - LONG_CONTEXT_KEYS).empty?
      invalid!("#{target}.threshold_tokens", "must be a positive integer") unless
        modifier["threshold_tokens"].is_a?(Integer) && modifier["threshold_tokens"].positive?
      %w[input output].each do |key|
        invalid!("#{target}.#{key}", "is required") unless modifier.key?(key)
      end
      modifier.each do |key, value|
        next if key == "threshold_tokens"

        decimal!(value, "#{target}.#{key}")
      end
    end

    def validate_source!(provider, value, path)
      uri = URI.parse(value.to_s)
      invalid!(path, "must use the official HTTPS host") unless
        uri.scheme == "https" && uri.host == SOURCE_HOSTS.fetch(provider)
    rescue URI::InvalidURIError
      invalid!(path, "must be a valid URL")
    end

    def validate_alias_intervals!(cards)
      cards.each_with_index do |left, index|
        left_names = [ left["canonical_model"], *left["aliases"] ]
        cards.drop(index + 1).each do |right|
          next unless left["provider"] == right["provider"]
          next if (left_names & [ right["canonical_model"], *right["aliases"] ]).empty?
          next unless intervals_overlap?(left, right)

          invalid!("cards", "contain an ambiguous model alias interval")
        end
      end
    end

    def intervals_overlap?(left, right)
      left_start = Time.iso8601(left.fetch("effective_from"))
      right_start = Time.iso8601(right.fetch("effective_from"))
      left_end = left["effective_until"] && Time.iso8601(left["effective_until"])
      right_end = right["effective_until"] && Time.iso8601(right["effective_until"])
      (left_end.nil? || right_start < left_end) && (right_end.nil? || left_start < right_end)
    end

    def resolve_card(provider, model, started_at)
      @catalog.fetch("cards").find do |card|
        next false unless card.fetch("provider") == provider
        next false unless [ card.fetch("canonical_model"), *card.fetch("aliases") ].include?(model)

        effective_from = Time.iso8601(card.fetch("effective_from"))
        effective_until = card["effective_until"] && Time.iso8601(card["effective_until"])
        started_at >= effective_from && (effective_until.nil? || started_at < effective_until)
      end
    end

    def calculate(session, card)
      dimensions = stringify(session[:pricing_dimensions] || {})
      missing = card.fetch("required_dimensions").reject do |name|
        dimensions.key?(name) && !text(dimensions[name]).nil?
      end
      modifiers = card.fetch("modifiers")
      if dimensions["service_tier"] &&
          dimensions["service_tier"] != modifiers["standard_service_tier"]
        missing << "service_tier"
      end
      if dimensions["inference_geo"] &&
          ![ modifiers["standard_inference_geo"], "us" ].compact.include?(dimensions["inference_geo"])
        missing << "inference_geo"
      end
      missing << "server_tool_usage" unless dimensions["server_tool_usage"] == "none"

      quantities, usage_missing = disjoint_quantities(session)
      missing.concat(usage_missing)
      rates, modifier_missing = selected_rates(card, dimensions, quantities)
      missing.concat(modifier_missing)
      missing.uniq!

      priced_categories = quantities.each_with_object({}) do |(category, quantity), result|
        next if quantity.nil?

        rate = rates[category]
        result[category] = decimal_cost(quantity, rate) if rate
      end
      observed = unless priced_categories.empty?
        priced_categories.values.reduce(BigDecimal("0"), :+)
      end
      coverage = missing.empty? ? "complete" : "partial"
      {
        coverage: coverage,
        subtotal_usd: coverage == "complete" ? observed : nil,
        observed_subtotal_usd: coverage == "partial" ? observed : nil,
        missing_dimensions: missing.sort,
        provider: card.fetch("provider"),
        canonical_model: card.fetch("canonical_model"),
        quantities: quantities,
        category_subtotals_usd: priced_categories,
        rate_basis: rate_basis(card, rates)
      }
    rescue ArgumentError, TypeError
      unavailable(
        "usage", provider: card.fetch("provider"),
        model: card.fetch("canonical_model"), card: card
      )
    end

    def disjoint_quantities(session)
      missing = []
      input = token_count(session[:input], "input", missing)
      output = token_count(session[:output], "output", missing)
      cache_read = optional_category(session, :cache_read, :input_includes_cache_read, missing)
      cache_write = optional_category(session, :cache_write, :input_includes_cache_write, missing)

      uncached_input = input
      if session[:input_includes_cache_read] == true
        uncached_input = uncached_input && cache_read && uncached_input - cache_read
      elsif cache_read.to_i.positive? && session[:input_includes_cache_read] != false
        missing << "input_includes_cache_read"
      end
      if session[:input_includes_cache_write] == true
        uncached_input = uncached_input && cache_write && uncached_input - cache_write
      elsif cache_write.to_i.positive? && session[:input_includes_cache_write] != false
        missing << "input_includes_cache_write"
      end
      raise ArgumentError, "cache categories exceed input" if uncached_input&.negative?

      reasoning_flag = session[:output_includes_reasoning]
      if reasoning_flag == false
        reasoning = token_count(session[:reasoning], "reasoning", missing)
        output = output && reasoning && output + reasoning
      elsif reasoning_flag != true
        missing << "output_includes_reasoning"
      end
      [
        { input: uncached_input, cache_read: cache_read,
          cache_write: cache_write, output: output },
        missing
      ]
    end

    def optional_category(session, category, inclusion_key, missing)
      value = session[category]
      return token_count(value, category.to_s, missing) unless value.nil?
      return 0 if session[inclusion_key] == false

      missing << category.to_s
      nil
    end

    def token_count(value, name, missing)
      if value.nil?
        missing << name
        return nil
      end
      number = Integer(value)
      raise ArgumentError, "negative token count" if number.negative?

      number
    end

    def selected_rates(card, dimensions, quantities)
      rates = card.fetch("rates").to_h { |key, value| [ key.to_sym, BigDecimal(value) ] }
      missing = []
      if rates.key?(:cache_write_5m)
        ttl = dimensions["cache_write_ttl"]
        if quantities.fetch(:cache_write).to_i.positive?
          selected = { "5m" => rates[:cache_write_5m], "1h" => rates[:cache_write_1h] }[ttl]
          if selected
            rates[:cache_write] = selected
          else
            rates.delete(:cache_write)
            missing << "cache_write_ttl"
          end
        else
          rates[:cache_write] = BigDecimal("0")
        end
      elsif quantities.fetch(:cache_write).to_i.positive? && !rates.key?(:cache_write)
        missing << "cache_write_semantics"
      end

      long_context = card.dig("modifiers", "long_context")
      if long_context
        context_tokens = integer_dimension(dimensions["context_tokens"])
        if context_tokens.nil?
          missing << "context_tokens"
        elsif context_tokens >= Integer(long_context.fetch("threshold_tokens"))
          %i[input cache_read cache_write output].each do |category|
            next unless rates[category] && long_context[category.to_s]

            rates[category] *= BigDecimal(long_context.fetch(category.to_s))
          end
        end
      end
      if card.fetch("provider") == "anthropic"
        geo = dimensions["inference_geo"]
        if geo == "us"
          multiplier = card.dig("modifiers", "inference_geo_us")
          if multiplier
            rates.transform_values! { |rate| rate * BigDecimal(multiplier) }
          else
            missing << "inference_geo"
            rates = {}
          end
        elsif geo != card.dig("modifiers", "standard_inference_geo")
          missing << "inference_geo"
        end
      end
      [ rates, missing ]
    end

    def rate_basis(card, rates)
      {
        source_url: card.fetch("source_url"),
        checked_at: @catalog.fetch("checked_at"),
        effective_from: card.fetch("effective_from"),
        effective_until: card["effective_until"],
        lifecycle: card.fetch("lifecycle"),
        unit: @catalog.fetch("unit"),
        rates: rates
      }
    end

    def unavailable(dimension, provider:, model:, card: nil)
      {
        coverage: "unavailable", subtotal_usd: nil, observed_subtotal_usd: nil,
        missing_dimensions: [ dimension ], provider: provider,
        canonical_model: card&.fetch("canonical_model", nil) || model,
        quantities: nil, category_subtotals_usd: {},
        rate_basis: card && rate_basis(card, {})
      }
    end

    def decimal_cost(tokens, rate)
      BigDecimal(tokens.to_s) * rate / MILLION
    end

    def normalize_provider(value)
      normalized = text(value)&.downcase
      { "claude" => "anthropic", "grok" => "xai" }.fetch(normalized, normalized)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_required_time!(value, path)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      invalid!(path, "must be ISO8601")
    end

    def integer_dimension(value)
      number = Integer(value)
      number.negative? ? nil : number
    rescue ArgumentError, TypeError
      nil
    end

    def decimal!(value, path)
      invalid!(path, "must be a decimal string") unless value.is_a?(String)
      decimal = BigDecimal(value.to_s)
      invalid!(path, "must be non-negative") if decimal.negative?
    rescue ArgumentError
      invalid!(path, "must be a decimal string")
    end

    def exact_keys!(object, allowed, path)
      missing = allowed.reject { |key| object.key?(key) }
      extra = object.keys - allowed
      invalid!(path, "missing #{missing.join(', ')}") unless missing.empty?
      invalid!(path, "contains unknown keys #{extra.join(', ')}") unless extra.empty?
    end

    def invalid!(path, message)
      raise CatalogError, "#{path} #{message}"
    end

    def stringify(value)
      value.to_h.transform_keys(&:to_s)
    end

    def symbolize(value)
      value.to_h.transform_keys(&:to_sym)
    end

    def text(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
