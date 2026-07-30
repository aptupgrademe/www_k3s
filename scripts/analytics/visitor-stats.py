#!/usr/bin/env python3
"""
Visitor statistics for the WordPress blog, derived from the nginx-ingress
access log.

Runs ON the blog host, not from a workstation: it needs /var/log/pods and the
local GeoLite2 database. That is deliberate - visitor IPs are personal data
under GDPR, so they are never sent to a third-party geolocation API and never
leave the server. Only aggregated, /24-masked output is printed.

Usage (on the host):
    python3 visitor-stats.py
    python3 visitor-stats.py --days 7 --top 50

Usage (from a workstation, one shot):
    scp -P 10022 scripts/analytics/visitor-stats.py root@<host>:/tmp/
    ssh -p 10022 root@<host> 'python3 /tmp/visitor-stats.py'

-------------------------------------------------------------------------------
What counts as a "regular visitor"
-------------------------------------------------------------------------------
Raw unique-IP counts are worthless on a public site: the overwhelming majority
of traffic is crawlers and scanners, and a large share of it sends a perfectly
ordinary browser User-Agent. Measured on this blog, 21k requests over 4.3 days
reduced to roughly 68 plausible human visitors - a filter that only looked at
the User-Agent string reported 959.

Three filters are applied in sequence, each one narrowing the set:

  1. User-Agent blocklist            - catches self-declaring bots only
  2. Asset correlation (>= 3 assets) - a real browser fetches the CSS/JS/images
                                       referenced by the HTML it just loaded.
                                       Scrapers request the HTML and stop. This
                                       is by far the strongest single signal.
  3. Cloud/datacenter netblocks      - what survives step 2 is mostly headless
                                       browsers on Tencent Cloud, OVH, Alibaba
                                       and friends, geolocating to whatever
                                       country the VM happens to sit in.

Known limits - read before quoting any number:
  * An IP is not a person. Mobile users rotate addresses, households share one,
    CGNAT puts hundreds behind one. Counts are an order of magnitude, not a
    headcount.
  * The cloud netblock list below is hand-maintained and incomplete. It will
    drift as providers get new allocations.
  * No cookies, no JS beacon - this is server-log analysis. It cannot tell a
    returning reader from a new one beyond the IP.
  * Log retention is the real constraint: k3s rotates container logs at 10 MB
    and keeps very few, so in practice only ~4 days are on disk at any time.
    For genuine weekly numbers, ship the logs somewhere persistent first.
"""

import argparse
import collections
import datetime
import glob
import ipaddress
import re
import socket
import subprocess
from concurrent.futures import ThreadPoolExecutor

DEFAULT_LOGS = "/var/log/pods/ingress-nginx_*/*/*.log"
DEFAULT_MMDB = "/usr/share/GeoIP/GeoLite2-Country.mmdb"

# CRI log line wrapping the standard nginx combined format:
#   <rfc3339> stdout F <ip> - - [<time>] "<method> <path> <proto>" <st> <b> "<ref>" "<ua>"
LINE_RE = re.compile(
    r'^\S+ stdout \w+ (?P<ip>[0-9a-fA-F.:]+) \S+ \S+ \[(?P<t>[^\]]+)\] '
    r'"(?P<method>[A-Z]+) (?P<path>\S*)[^"]*" (?P<status>\d{3}) \S+ '
    r'"(?P<ref>[^"]*)" "(?P<ua>[^"]*)"')

BOT_UA = re.compile(
    r'bot|crawl|spider|slurp|facebookexternalhit|python|curl/|wget|scrapy|'
    r'httpclient|go-http|java/|libwww|okhttp|monitor|uptime|zgrab|masscan|'
    r'censys|nmap|scanner|expanse|archive\.org|semrush|ahrefs|mj12|dotbot|'
    r'petalbot|yandex|applebot|duckduck|baidu|sogou|gptbot|claudebot|ccbot|'
    r'perplexity|amazonbot|dataforseo|serpstat|seekport|validator|pingdom|'
    r'site24x7|newrelic|headlesschrome|phantomjs|selenium|axios|node-fetch|'
    r'whatsapp|telegram|discord|slack|preview|fetcher|feed|rss|guzzle|'
    r'postman|lighthouse|pagespeed|gtmetrix', re.I)

ASSET = re.compile(
    r'\.(css|js|mjs|png|jpe?g|gif|ico|svg|webp|avif|woff2?|ttf|eot|otf)(\?|$)', re.I)

# Not a page view: monitoring endpoints, admin surface, and scanner bait.
# /grafana is in here because the Grafana health ping would otherwise show up
# as the single most-read "page" on the blog.
SKIP_PATH = re.compile(
    r'^/grafana|wp-login|xmlrpc|/wp-admin|/wp-json|/\.env|/\.git|phpmyadmin|'
    r'/vendor/|/setup|/shell|/cgi-bin|/boaform|/autodiscover|/owa/|/telescope|'
    r'/actuator|/feed|\.php$|robots\.txt|sitemap|favicon', re.I)

# Hand-maintained. Mostly Tencent Cloud, which is the single largest source of
# browser-faking traffic hitting this blog, plus the usual VPS suspects.
CLOUD_NETS = [
    "43.128.0.0/10", "124.156.0.0/16", "129.226.0.0/16", "150.109.0.0/16",
    "119.28.0.0/16", "170.106.0.0/16", "49.51.0.0/16", "106.55.0.0/16",
    "139.199.0.0/16", "183.60.0.0/16", "14.152.0.0/16", "81.71.0.0/16",
    "27.115.0.0/16", "123.6.0.0/16", "27.44.0.0/16",
    "158.69.0.0/16", "51.79.0.0/16",                     # OVH
    "47.235.0.0/16", "47.251.0.0/16", "8.209.0.0/16",    # Alibaba
    "103.11.48.0/22", "104.28.0.0/16", "84.247.40.0/21",
    "2a09:bac0::/29",                                     # Cloudflare WARP-ish
]

# rDNS hints for hosts that are not in the netblock list above.
DC_PTR = re.compile(
    r'amazonaws|tencent|qcloud|ovh|hetzner|digitalocean|linode|vultr|azure|'
    r'googleusercontent|contabo|scaleway|oracle|alibaba|aliyun|huawei|cloud|'
    r'vps|server|dedi|colo|datacenter|hosting|leaseweb|choopa|netcup|ionos|'
    r'gcore|fastly|cloudflare|akamai|m247|zenlayer|equinix', re.I)

# A single IP responsible for hundreds of page views in a short burst is a
# scraper, whatever its netblock says.
SCRAPER_PAGE_THRESHOLD = 200


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--logs", default=DEFAULT_LOGS, help="glob for ingress logs")
    p.add_argument("--mmdb", default=DEFAULT_MMDB, help="GeoLite2 Country database")
    p.add_argument("--days", type=float, default=None,
                   help="only consider the last N days (default: whole log)")
    p.add_argument("--top", type=int, default=40, help="rows in the per-visitor table")
    p.add_argument("--min-assets", type=int, default=3,
                   help="assets an IP must fetch to count as a real browser")
    p.add_argument("--no-rdns", action="store_true", help="skip reverse-DNS lookups")
    # Your own connection dwarfs everything else in the log - editing a post
    # touches more pages in an evening than a month of real readers. Pass your
    # home prefix here (repeatable) to keep it out of the numbers.
    p.add_argument("--exclude", action="append", default=[], metavar="CIDR",
                   help="prefix to exclude entirely, e.g. --exclude 203.0.113.0/24")
    return p.parse_args()


def read_log(pattern):
    rows = []
    for path in sorted(glob.glob(pattern)):
        with open(path, errors="replace") as fh:
            for line in fh:
                m = LINE_RE.match(line)
                if not m:
                    continue
                try:
                    ts = datetime.datetime.strptime(m["t"].split()[0], "%d/%b/%Y:%H:%M:%S")
                except ValueError:
                    continue
                rows.append((ts, m["ip"], m["method"], m["path"],
                             int(m["status"]), m["ua"]))
    rows.sort()
    return rows


def is_internal(ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return addr.is_private or addr.is_loopback or addr.is_link_local


def mask(ip):
    """Anonymise to /24 (IPv4) or /48 (IPv6) - the usual GDPR-safe granularity."""
    addr = ipaddress.ip_address(ip)
    if addr.version == 4:
        return ".".join(ip.split(".")[:3]) + ".xxx"
    return ":".join(ip.split(":")[:3]) + "::xxxx"


def geo(mmdb, ip, *field):
    try:
        out = subprocess.run(["mmdblookup", "--file", mmdb, "--ip", ip, *field],
                             capture_output=True, text=True, timeout=8)
        if out.returncode == 0 and '"' in out.stdout:
            return out.stdout.split('"')[1]
    except Exception:
        pass
    return None


def main():
    args = parse_args()
    rows = read_log(args.logs)
    if not rows:
        raise SystemExit(f"No parseable log lines in {args.logs}")

    if args.days:
        cutoff = rows[-1][0] - datetime.timedelta(days=args.days)
        rows = [r for r in rows if r[0] >= cutoff]

    first_ts, last_ts = rows[0][0], rows[-1][0]
    span = max((last_ts - first_ts).total_seconds() / 86400, 1 / 24)

    cloud_nets = [ipaddress.ip_network(n) for n in CLOUD_NETS]
    excluded = [ipaddress.ip_network(n, strict=False) for n in args.exclude]

    def in_cloud_net(ip):
        addr = ipaddress.ip_address(ip)
        return any(addr in n for n in cloud_nets if n.version == addr.version)

    def is_excluded(ip):
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            return False
        return any(addr in n for n in excluded if n.version == addr.version)

    html = collections.Counter()
    assets = collections.Counter()
    pages_of = collections.defaultdict(list)
    first_of, ua_of = {}, {}

    for ts, ip, method, path, status, ua in rows:
        if is_internal(ip) or is_excluded(ip) or method != "GET":
            continue
        if not ua or ua == "-" or BOT_UA.search(ua):
            continue
        if SKIP_PATH.search(path):
            continue
        if ASSET.search(path):
            if status in (200, 304):
                assets[ip] += 1
        elif status in (200, 301, 302, 304):
            html[ip] += 1
            pages_of[ip].append(path)
            first_of.setdefault(ip, ts)
            ua_of.setdefault(ip, ua)

    browsers = [ip for ip in html if assets[ip] >= args.min_assets]

    ptrs = {}
    if not args.no_rdns:
        def rdns(ip):
            try:
                return socket.gethostbyaddr(ip)[0]
            except Exception:
                return ""
        with ThreadPoolExecutor(max_workers=20) as pool:
            ptrs = dict(zip(browsers, pool.map(rdns, browsers)))

    visitors, machines = [], []
    for ip in browsers:
        rec = {
            "masked": mask(ip),
            "country": (geo(args.mmdb, ip, "country", "names", "en")
                        or geo(args.mmdb, ip, "country", "names", "de")
                        or "unknown"),
            "iso": geo(args.mmdb, ip, "country", "iso_code") or "??",
            "pages": html[ip],
            "assets": assets[ip],
            "first": first_of[ip],
        }
        ptr = ptrs.get(ip, "")
        if in_cloud_net(ip) or (ptr and DC_PTR.search(ptr)):
            machines.append(rec)
        elif html[ip] >= SCRAPER_PAGE_THRESHOLD:
            rec["why"] = f"{html[ip]} page views in {span:.1f}d"
            machines.append(rec)
        else:
            visitors.append(rec)

    # Collapse duplicates created by masking (several hosts in one /24).
    dedup = {}
    for rec in visitors:
        keep = dedup.get(rec["masked"])
        if keep is None or rec["pages"] > keep["pages"]:
            dedup[rec["masked"]] = rec
    visitors = list(dedup.values())

    total = len(visitors) or 1
    bar = "=" * 78

    print(bar)
    print("www.apt-upgrade.me - visitor statistics")
    print(f"Period   : {first_ts:%Y-%m-%d %H:%M} - {last_ts:%Y-%m-%d %H:%M}  ({span:.2f} days)")
    print(f"Requests : {len(rows)}")
    print(bar)
    print(f"IPs with browser behaviour (HTML + >={args.min_assets} assets) : {len(browsers):5d}")
    print(f"  of those cloud/datacenter/scraper                  : {len(machines):5d}")
    print(f"  regular visitors                                   : {len(visitors):5d}")
    print()
    print(f"  per day  : {len(visitors) / span:6.1f}")
    print(f"  per week : {len(visitors) / span * 7:6.0f}")
    print(bar)

    print("\nCOUNTRY DISTRIBUTION")
    print("-" * 60)
    per_country = collections.Counter(v["country"] for v in visitors)
    pv_country = collections.Counter()
    for v in visitors:
        pv_country[v["country"]] += v["pages"]
    print(f"{'Country':<28} {'Visitors':>9} {'Share':>9} {'Pages':>8}")
    print("-" * 60)
    for country, n in per_country.most_common():
        print(f"{country[:28]:<28} {n:>9} {n / total * 100:>8.1f}% {pv_country[country]:>8}")
    print("-" * 60)
    print(f"{'TOTAL':<28} {total:>9} {100.0:>8.1f}% {sum(pv_country.values()):>8}")

    print(f"\nINDIVIDUAL VISITORS (IP masked, top {args.top})")
    print("-" * 78)
    print(f"{'Masked IP':<22} {'Country':<22} {'ISO':<4} {'Pages':>6} {'first seen':<13}")
    print("-" * 78)
    for v in sorted(visitors, key=lambda x: -x["pages"])[:args.top]:
        print(f"{v['masked']:<22} {v['country'][:22]:<22} {v['iso']:<4} "
              f"{v['pages']:>6} {v['first']:%m-%d %H:%M}")

    print("\nMOST-READ PAGES")
    print("-" * 60)
    keep = {v["masked"] for v in visitors}
    read = collections.Counter()
    for ip in browsers:
        if mask(ip) in keep:
            for path in pages_of[ip]:
                read[path] += 1
    for path, n in read.most_common(12):
        print(f"  {n:4d}  {path[:52]}")

    if machines:
        print(f"\nFILTERED OUT: {len(machines)} cloud/scraper IPs")
        print("-" * 60)
        for country, n in collections.Counter(m["country"] for m in machines).most_common(8):
            print(f"  {n:4d}  {country}")
        for m in machines:
            if "why" in m:
                print(f"  outlier {m['masked']} ({m['country']}): {m['why']}")


if __name__ == "__main__":
    main()
