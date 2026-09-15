---
date: 2026-09-15
slug: json-3-rails-compatibility
pages: [dependencies]
---

## JSON 3 Rails session compatibility

**Action:** Added the web-only Active Support JSON decoder compatibility layer
for JSON 3's keyword-only parser options, preserving Rails 8.1.3.1 date
conversion and encrypted cookie/session decoding. Added a focused regression
test for `ActiveSupport::JSON.decode` under JSON 3.

**Why:** The dependency update made every authenticated web request raise
`ArgumentError` before controller execution because Rails passed parser
options positionally.
