"""Data presence check (common_verify, both stacks), run from stdin.

"Configured and running" missed two silent gaps: node_exporter lost its disk
metrics for two days (a hidden SELinux denial) and alert rules without a
condition never fired. This asks the two places that would show them:
  1. Prometheus: every scrape target up, each key metric has a series,
     no periodic job's heartbeat overdue
  2. Grafana: no alert rule in health "error" or "nodata"
Output: one line per finding, last line "RESULT <failures>".
Grafana login from the environment (GF_USER, GF_PASS).
"""
import base64, json, os, urllib.parse, urllib.request

KEY = {  # metric -> what is missing when it has no series
    'node_filesystem_size_bytes{mountpoint="/"}': 'disk metrics (node_exporter filesystem)',
    'node_memory_MemAvailable_bytes': 'memory metrics (node_exporter)',
    'node_scrape_collector_success{collector="filesystem"} == 1': 'filesystem collector',
    'mysql_up == 1': 'MariaDB exporter',
    'phpfpm_up == 1': 'PHP-FPM exporter',
    'container_memory_working_set_bytes': 'container metrics (cAdvisor)',
    'kube_pod_status_phase': 'kube-state-metrics',
    'trivy_last_run_timestamp_seconds': 'Trivy textfile metric',
}
fails = 0


def get(url, auth=None):
    req = urllib.request.Request(url)
    if auth:
        req.add_header('Authorization', 'Basic ' + base64.b64encode(auth.encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def prom(q):
    return get('http://127.0.0.1:9090/api/v1/query?' + urllib.parse.urlencode({'query': q}))['data']['result']


try:
    down = [r['metric'].get('job', '?') for r in prom('up == 0')]
    for job in down:
        print(f'FAIL scrape target down: {job}')
    fails += len(down)
    for q, what in KEY.items():
        if not prom(q):
            print(f'FAIL no data: {what} ({q})')
            fails += 1
    # heartbeats of the periodic jobs (heartbeat-mark): name the overdue ones
    for r in prom('time() - job_heartbeat_timestamp_seconds - job_heartbeat_max_age_seconds > 0'):
        print(f"FAIL job heartbeat overdue: {r['metric'].get('task', '?')} by {int(float(r['value'][1]))} s")
        fails += 1
except Exception as e:
    print(f'FAIL Prometheus query: {e.__class__.__name__}')
    fails += 1

try:
    d = get('http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules',
            f"{os.environ['GF_USER']}:{os.environ['GF_PASS']}")
    n = 0
    for g in d['data']['groups']:
        for r in g['rules']:
            n += 1
            if r.get('health') in ('error', 'nodata'):
                print(f"FAIL alert rule {r['name']}: {r.get('health')} {r.get('lastError', '')[:80]}")
                fails += 1
    print(f'alert rules checked: {n}')
except Exception as e:
    print(f'FAIL Grafana rule query: {e.__class__.__name__}')
    fails += 1
print(f'RESULT {fails}')
