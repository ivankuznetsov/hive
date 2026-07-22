# frozen_string_literal: true

module Hive
  module Web
    module RequestLimits
      IDEA_IMAGE_COUNT = 8
      IDEA_IMAGE_BYTES = 10 * 1024 * 1024

      # Eight maximum-sized images plus a bounded allowance for multipart
      # headers and idea text. Puma enforces declared lengths before Rails/Rack
      # parameter parsing; PumaRequestLimits rejects chunked bodies there too.
      MAX_BODY_BYTES = (IDEA_IMAGE_COUNT * IDEA_IMAGE_BYTES) + (1024 * 1024)
    end
  end
end
