require "test_helper"
require "hive/web/sse_limiter"
require "hive/commands/web"

# The SSE connection cap is the structural defense against open dashboards
# starving Puma's thread pool: it must admit up to `max` concurrent streams,
# reject the next one, and re-admit once a stream releases.
class SseLimiterTest < Minitest::Test
  def test_admits_up_to_max_then_rejects
    limiter = Hive::Web::SseLimiter.new(max: 2)

    assert limiter.acquire
    assert limiter.acquire
    refute limiter.acquire, "the third concurrent stream must be rejected"
  end

  def test_release_frees_a_slot
    limiter = Hive::Web::SseLimiter.new(max: 1)

    assert limiter.acquire
    refute limiter.acquire
    limiter.release
    assert limiter.acquire, "a released slot must be reusable"
  end

  def test_release_never_drops_below_zero
    limiter = Hive::Web::SseLimiter.new(max: 1)

    limiter.release
    limiter.release
    assert limiter.acquire
    refute limiter.acquire, "spurious releases must not inflate the cap"
  end

  # The SSE ceiling MUST sit strictly below Puma's thread pool, leaving
  # headroom for non-SSE work. If the cap met or exceeded MAX_THREADS, open
  # dashboards could pin every Puma thread while the limiter still reported
  # capacity, starving the auth/action routes.
  def test_app_sse_cap_is_below_puma_thread_pool
    assert_operator Hive::Commands::Web::MAX_SSE_STREAMS, :<, Hive::Commands::Web::MAX_THREADS,
                    "the SSE limiter cap must leave headroom below the Puma thread pool"
    assert_operator Hive::Commands::Web::MAX_SSE_STREAMS, :>, 0,
                    "the SSE cap must still admit some streams"
  end
end
