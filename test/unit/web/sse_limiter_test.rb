require "test_helper"
require "hive/web/sse_limiter"

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
end
