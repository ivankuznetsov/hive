require "test_helper"
require "bigdecimal"
require "net/http"
require "yaml"
require "hive/model_pricing"

class ModelPricingTest < Minitest::Test
  CHECKED_AT = "2026-08-16"
  STARTED_AT = "2026-08-16T12:00:00Z"

  def setup
    @pricing = Hive::ModelPricing.new
  end

  def test_prices_each_supported_first_party_provider_from_the_local_catalog
    cases = [
      [ "openai", "gpt-5.6-sol", openai_dimensions, "35" ],
      [ "anthropic", "claude-sonnet-4-6", anthropic_dimensions, "18" ],
      [ "xai", "grok-4.6", xai_dimensions, "8" ]
    ]

    cases.each do |provider, model, dimensions, expected|
      result = @pricing.estimate(
        session(provider:, model:, input: 1_000_000, output: 1_000_000,
                pricing_dimensions: dimensions)
      )

      assert_equal "complete", result.fetch(:coverage), "#{provider}/#{model}"
      assert_equal BigDecimal(expected), result.fetch(:subtotal_usd)
      assert_equal provider, result.fetch(:provider)
      assert_equal model, result.fetch(:canonical_model)
      assert_equal CHECKED_AT, result.dig(:rate_basis, :checked_at)
      assert_match(%r{\Ahttps://}, result.dig(:rate_basis, :source_url))
    end
  end

  def test_resolves_alias_only_inside_the_rate_cards_effective_interval
    current = @pricing.estimate(
      session(provider: "openai", model: "gpt-5.6",
              pricing_dimensions: openai_dimensions)
    )
    historical = @pricing.estimate(
      session(provider: "openai", model: "gpt-5.6",
              started_at: "2026-08-15T23:59:59Z",
              pricing_dimensions: openai_dimensions)
    )

    assert_equal "complete", current.fetch(:coverage)
    assert_equal "gpt-5.6-sol", current.fetch(:canonical_model)
    assert_equal "unavailable", historical.fetch(:coverage)
    assert_includes historical.fetch(:missing_dimensions), "rate_card"
  end

  def test_cache_and_reasoning_categories_are_charged_once
    result = @pricing.estimate(
      session(
        provider: "anthropic", model: "claude-sonnet-4-6",
        input: 1_000_000, output: 200_000,
        cache_read: 100_000, cache_write: 100_000, reasoning: 50_000,
        input_includes_cache_read: true, input_includes_cache_write: true,
        output_includes_reasoning: true,
        pricing_dimensions: anthropic_dimensions.merge("cache_write_ttl" => "5m")
      )
    )

    assert_equal "complete", result.fetch(:coverage)
    assert_equal BigDecimal("5.805"), result.fetch(:subtotal_usd)
    assert_equal 800_000, result.dig(:quantities, :input)
    assert_equal 200_000, result.dig(:quantities, :output)
  end

  def test_missing_cache_ttl_exposes_only_an_observed_partial_subtotal
    result = @pricing.estimate(
      session(
        provider: "anthropic", model: "claude-sonnet-4-6",
        input: 100, output: 100, cache_write: 25,
        input_includes_cache_write: true,
        pricing_dimensions: anthropic_dimensions
      )
    )

    assert_equal "partial", result.fetch(:coverage)
    assert_nil result[:subtotal_usd]
    assert_kind_of BigDecimal, result.fetch(:observed_subtotal_usd)
    assert_includes result.fetch(:missing_dimensions), "cache_write_ttl"
  end

  def test_unknown_included_cache_quantity_is_not_repriced_as_uncached_input
    result = @pricing.estimate(
      session(
        provider: "openai", model: "gpt-5.6-sol",
        input: 100, output: 100, cache_read: nil,
        input_includes_cache_read: true,
        pricing_dimensions: openai_dimensions
      )
    )

    assert_equal "partial", result.fetch(:coverage)
    assert_includes result.fetch(:missing_dimensions), "cache_read"
    refute result.fetch(:category_subtotals_usd).key?(:input)
    assert_equal BigDecimal("0.003"), result.fetch(:observed_subtotal_usd)
  end

  def test_unknown_model_and_request_modifier_are_not_guessed
    unknown_model = @pricing.estimate(
      session(provider: "openai", model: "partner/gpt-5.6-sol",
              pricing_dimensions: openai_dimensions)
    )
    unknown_tier = @pricing.estimate(
      session(provider: "openai", model: "gpt-5.6-sol",
              pricing_dimensions: openai_dimensions.merge("service_tier" => "priority"))
    )

    assert_equal "unavailable", unknown_model.fetch(:coverage)
    assert_includes unknown_model.fetch(:missing_dimensions), "model"
    assert_equal "partial", unknown_tier.fetch(:coverage)
    assert_includes unknown_tier.fetch(:missing_dimensions), "service_tier"
    assert_kind_of BigDecimal, unknown_tier.fetch(:observed_subtotal_usd)
  end

  def test_context_and_inference_geo_modifiers_require_evidence
    missing_context = @pricing.estimate(
      session(provider: "xai", model: "grok-4.6",
              pricing_dimensions: xai_dimensions.reject { |key, _| key == "context_tokens" })
    )
    long_context = @pricing.estimate(
      session(provider: "xai", model: "grok-4.6", input: 300_000, output: 0,
              pricing_dimensions: xai_dimensions.merge("context_tokens" => 300_000))
    )
    us_only = @pricing.estimate(
      session(provider: "anthropic", model: "claude-sonnet-4-6",
              input: 1_000_000, output: 0,
              pricing_dimensions: anthropic_dimensions.merge("inference_geo" => "us"))
    )

    assert_equal "partial", missing_context.fetch(:coverage)
    assert_includes missing_context.fetch(:missing_dimensions), "context_tokens"
    assert_kind_of BigDecimal, missing_context.fetch(:observed_subtotal_usd)
    assert_equal BigDecimal("1.2"), long_context.fetch(:subtotal_usd)
    assert_equal BigDecimal("3.3"), us_only.fetch(:subtotal_usd)
  end

  def test_openai_long_context_multiplier_starts_above_272k_tokens
    at_threshold = @pricing.estimate(
      session(provider: "openai", model: "gpt-5.6-sol", input: 272_000, output: 100,
              pricing_dimensions: openai_dimensions.merge("context_tokens" => 272_000))
    )
    above_threshold = @pricing.estimate(
      session(provider: "openai", model: "gpt-5.6-sol", input: 272_001, output: 100,
              pricing_dimensions: openai_dimensions.merge("context_tokens" => 272_001))
    )

    assert_equal BigDecimal("1.363"), at_threshold.fetch(:subtotal_usd)
    assert_equal BigDecimal("2.72451"), above_threshold.fetch(:subtotal_usd)
  end

  def test_retired_or_redirected_cards_are_never_silently_priced
    %w[retired redirect].each do |lifecycle|
      catalog = YAML.safe_load(File.read(Hive::ModelPricing::CATALOG_PATH), aliases: false)
      catalog["cards"] = [ catalog.fetch("cards").first.merge("lifecycle" => lifecycle) ]
      result = Hive::ModelPricing.new(catalog: catalog).estimate(
        session(provider: "openai", model: "gpt-5.6-sol",
                pricing_dimensions: openai_dimensions)
      )

      assert_equal "unavailable", result.fetch(:coverage)
      assert_includes result.fetch(:missing_dimensions), "model_lifecycle"
    end
  end

  def test_rejects_invalid_rate_card_intervals_and_modifier_shapes
    invalid_interval = catalog_with_first_card(
      "effective_until" => "2026-08-15T00:00:00Z"
    )
    invalid_modifier = catalog_with_first_card(
      "modifiers" => {
        "standard_service_tier" => "standard",
        "long_context" => { "threshold_tokens" => 0, "input" => "2", "output" => "1.5" }
      }
    )

    assert_raises(Hive::ModelPricing::CatalogError) do
      Hive::ModelPricing.new(catalog: invalid_interval)
    end
    assert_raises(Hive::ModelPricing::CatalogError) do
      Hive::ModelPricing.new(catalog: invalid_modifier)
    end
  end

  def test_decimal_precision_is_exact_and_calculation_never_uses_the_network
    without_http do
      result = @pricing.estimate(
        session(provider: "openai", model: "gpt-5.6-sol", input: 1, output: 1,
                pricing_dimensions: openai_dimensions)
      )

      assert_equal BigDecimal("0.000035"), result.fetch(:subtotal_usd)
      refute_kind_of Float, result.fetch(:subtotal_usd)
    end
  end

  private

  def catalog_with_first_card(**changes)
    catalog = YAML.safe_load(File.read(Hive::ModelPricing::CATALOG_PATH), aliases: false)
    catalog["cards"] = [ catalog.fetch("cards").first.merge(changes) ]
    catalog
  end

  def without_http
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "network forbidden" }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def session(provider:, model:, input: 100, output: 50, cache_read: 0,
              cache_write: 0, reasoning: 0, started_at: STARTED_AT,
              input_includes_cache_read: false,
              input_includes_cache_write: false,
              output_includes_reasoning: true, pricing_dimensions:)
    {
      actual_backend: provider, actual_model: model, started_at: started_at,
      input: input, output: output, cache_read: cache_read,
      cache_write: cache_write, reasoning: reasoning,
      input_includes_cache_read: input_includes_cache_read,
      input_includes_cache_write: input_includes_cache_write,
      output_includes_reasoning: output_includes_reasoning,
      pricing_dimensions: pricing_dimensions
    }
  end

  def openai_dimensions
    { "service_tier" => "standard", "context_tokens" => 1_000,
      "server_tool_usage" => "none" }
  end

  def anthropic_dimensions
    { "service_tier" => "standard", "inference_geo" => "global",
      "server_tool_usage" => "none" }
  end

  def xai_dimensions
    { "service_tier" => "standard", "context_tokens" => 1_000,
      "server_tool_usage" => "none" }
  end
end
