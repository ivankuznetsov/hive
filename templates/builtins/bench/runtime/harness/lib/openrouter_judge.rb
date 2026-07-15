# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "lib/judge_output"

module HiveBench
  # A judge_fn backed by an OpenRouter chat model (e.g. openai/gpt-5.5-pro) — the
  # family-disjoint judge for a slate that includes claude and glm. Mirrors
  # ClaudeJudge's contract (->(prompt:, seed:) => { score:, reason: }) and shares
  # the same score parsing, so HiveBench::Judge treats both interchangeably.
  #
  # NOTE on cost: judge prompts are input-heavy (the candidate diff), and gpt-5.5-pro
  # bills input at $30/M. Withhold the reference and use 1 seed for affordability.
  module OpenRouterJudge
    Error = JudgeOutput::Error

    ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
    DEFAULT_TIMEOUT = 600

    # Cap the completion budget. Left unset, OpenRouter reserves the model's FULL
    # max output up front — for gpt-5.5-pro that is 65536 tokens (~$11.8 held per
    # call at $180/M), which both inflates spend and trips a 402 "requires more
    # credits" reservation on a low balance even when the actual judgement is far
    # smaller. A judgement is reasoning + a score+rationale; 32k is ample headroom
    # without truncating the verdict, and halves the reserved/worst-case cost.
    MAX_OUTPUT_TOKENS = 32_768

    module_function

    def judge_fn(model:, api_key: ENV.fetch("OPENROUTER_API_KEY", nil), timeout_s: DEFAULT_TIMEOUT,
                 max_tokens: MAX_OUTPUT_TOKENS)
      raise Error, "OPENROUTER_API_KEY is not set (needed for the #{model} judge)" if api_key.to_s.empty?

      lambda do |prompt:, seed:|
        content = request(build_body(model, seed, prompt, max_tokens), api_key, timeout_s)
        JudgeOutput.parse_score(content)
      end
    end

    # The chat-completions request body. max_tokens is always set so OpenRouter
    # reserves only this much output cost (not the model's full ceiling).
    def build_body(model, seed, prompt, max_tokens)
      { "model" => model, "seed" => seed, "max_tokens" => max_tokens,
        "messages" => [{ "role" => "user", "content" => prompt.to_s }] }
    end

    # POSTs the judge prompt and returns the assistant's text. Raises on transport
    # or API errors so a flaky judge call parks the cell rather than scoring noise.
    def request(body, api_key, timeout_s)
      uri = URI(ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = timeout_s

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{api_key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      res = http.request(req)
      raise Error, "openrouter judge HTTP #{res.code}: #{res.body.to_s.strip[0, 300]}" unless res.code == "200"

      parsed = JSON.parse(res.body)
      content = parsed.dig("choices", 0, "message", "content")
      raise Error, "openrouter judge returned no content: #{res.body.to_s.strip[0, 200]}" if content.to_s.empty?

      content
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "openrouter judge timed out: #{e.message}"
    end
  end
end
