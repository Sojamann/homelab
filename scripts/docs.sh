#!/usr/bin/env bash
# Serves the docs site, or builds it to docs/book/ and checks its links.
#
#   scripts/docs.sh [build]
set -euo pipefail
cd "$(dirname "$0")/../docs"

# Generated from the pinned binary rather than committed: 2.6MB of vendored JS.
mdbook-mermaid install . >/dev/null 2>&1

case "${1:-serve}" in
  serve)
    exec mdbook serve --open
    ;;
  build)
    mdbook build
    # Mermaid parses labels as markdown and renders a URL as "Unsupported
    # markdown: link" instead of the diagram text.
    if bad=$(find book -name '*.html' ! -name print.html -exec awk '/<pre class="mermaid">/{m=1} m && /https?:\/\/|www\./{print FILENAME": "$0} /<\/pre>/{m=0}' {} +); [ -n "$bad" ]; then
      echo "URL in a mermaid label (drop the scheme):" >&2
      echo "$bad" >&2
      exit 1
    fi
    # Offline: the GitHub links point at main, where a file added on a branch
    # does not exist yet. Local links and anchors are what drift.
    lychee --offline --include-fragments --no-progress --root-dir "$PWD/book" book
    ;;
  *)
    echo "usage: docs.sh [build]" >&2
    exit 1
    ;;
esac
