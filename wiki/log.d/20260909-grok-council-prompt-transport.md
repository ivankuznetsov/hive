# Keep large documents out of launch arguments

Grok now reads the complete prompt with `--prompt-file=/dev/stdin` through
the existing stdin transport. Council review and revision prompts reference
their target and triage files rather than embedding duplicate document bodies.
Real-process tests cover 256 KiB Grok prompt delivery; council tests cover
large document references without truncating the source files. Claude test
fixtures capture stdin as well as argv, and the configuration digest fixture
reflects Claude's updated transport fingerprint.
