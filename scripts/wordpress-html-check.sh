#!/bin/bash
# Checks every WordPress post and page for malformed HTML.
#
# Usage:
#   ./wordpress-html-check.sh [host]        # host defaults to www.apt-upgrade.me
#
# Why this exists: WordPress warns about Gutenberg block markup that no longer
# matches its expected structure, but it does not validate HTML. An
# administrator has the unfiltered_html capability, so hand-written markup goes
# into the database exactly as typed - unclosed tag and all. Browsers then
# silently repair it, which usually surfaces as "the layout is subtly wrong on
# one post" rather than as an error anyone can act on.
#
# Fetches all content in a single SSH round trip (one call per post is
# painfully slow at ~100 posts) and validates locally with Python's HTML parser.
#
# Exit code 1 if any document has problems, so it can gate a CI job.

set -euo pipefail

HOST_ALIAS="${1:-www.apt-upgrade.me}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/inventory-lookup.sh"
inventory_lookup "$HOST_ALIAS"

SSH_KEY="$HOME/.ssh/id_rsa"
RAW_FILE="$(mktemp)"
trap 'rm -f "$RAW_FILE"' EXIT

echo "=== Fetching content from $REMOTE_HOST ==="

# Each document is preceded by a marker line: \x01<id>\x01<type>,<title>
# \x01 cannot occur in post content, so it is a safe record separator.
ssh -i "$SSH_KEY" -p "$REMOTE_SSH_PORT" -o LogLevel=ERROR "root@$REMOTE_HOST" '
  WP="php /usr/local/lib/wp-cli/wp-cli.phar"
  K="k3s kubectl exec deployment/wordpress -n wordpress -c wordpress-fpm --"
  ids=$($K $WP post list --post_type=post,page --post_status=any --format=ids \
        --path=/var/www/html --allow-root 2>/dev/null)
  for id in $ids; do
    meta=$($K $WP post get "$id" --fields=post_type,post_title --format=csv \
          --path=/var/www/html --allow-root 2>/dev/null | tail -1)
    printf "\001%s\001%s\n" "$id" "$meta"
    $K $WP post get "$id" --field=content --path=/var/www/html --allow-root 2>/dev/null
  done
' > "$RAW_FILE"

python3 - "$RAW_FILE" <<'PYEOF'
import sys
from html.parser import HTMLParser

VOID = {"br", "hr", "img", "input", "meta", "link", "source", "col",
        "area", "base", "embed", "param", "track", "wbr"}

class Check(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if tag not in self.stack:
            self.errors.append("</%s> with no matching opening tag" % tag)
            return
        while self.stack:                    # unwind, reporting what got skipped
            t = self.stack.pop()
            if t == tag:
                break
            self.errors.append("<%s> never closed (found </%s> instead)" % (t, tag))

docs, cur = [], None
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("\001"):
            parts = line.split("\001")
            cur = {"id": parts[1] if len(parts) > 1 else "?",
                   "meta": parts[2] if len(parts) > 2 else "",
                   "body": []}
            docs.append(cur)
        elif cur is not None:
            cur["body"].append(line)

bad = 0
for d in docs:
    p = Check()
    try:
        p.feed("\n".join(d["body"]))
        p.close()
    except Exception as exc:
        p.errors.append("parser error: %s" % exc)
    if p.errors or p.stack:
        bad += 1
        print("\n  Post %s  %s" % (d["id"], d["meta"][:70]))
        for e in p.errors[:5]:
            print("      %s" % e)
        if p.stack:
            print("      still open at end: %s" % p.stack[:6])

print("\n=== %d documents checked, %d with problems ===" % (len(docs), bad))
sys.exit(1 if bad else 0)
PYEOF
