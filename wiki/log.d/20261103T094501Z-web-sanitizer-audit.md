# Clear web sanitizer dependency advisories

Relock only Loofah, Nokogiri and rails-html-sanitizer conservatively to 2.25.3,
1.19.7 and 1.7.2 respectively, preserving the web bundle's eight native Nokogiri
platforms. Both dependency audits report no vulnerabilities, and the focused
Rails markdown/sanitization checks pass three tests and 33 assertions.
