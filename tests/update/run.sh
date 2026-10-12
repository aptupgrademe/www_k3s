#!/bin/bash
# =============================================================================
# Scenario test for blog-update.yml and nextcloud-update.yml - no server, no
# cluster: "k3s kubectl" and crictl are replaced by fakes (fake-*) that play
# a healthy instance, an upstream image rebuild, or a failure at one step.
# Each scenario checks the exit code, the calls made (restarts, occ, update
# job) and - for Nextcloud - the maintenance mode left behind.
#
#   tests/update/run.sh
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=$HERE/.work
rm -rf "$WORK"; mkdir -p "$WORK"

# Homepage for the blog's final check: a local web server, not the real blog.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$WORK/www" && echo ok > "$WORK/www/index.html"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
HTTP=$!
trap 'kill $HTTP 2>/dev/null' EXIT

FAIL=0
# scenario <playbook> <name> <SCENARIO> <REBUILT> <expected rc> <expected maintenance|-> <must-calls> <must-not-calls> [args]
scenario() {
  local pb=$1 name=$2 sc=$3 rebuilt=$4 want_rc=$5 want_maint=$6 must=$7 mustnot=$8; shift 8
  local sim=$WORK/$pb-$name; mkdir -p "$sim/bin" "$sim/data" "$sim/backups"
  cp "$HERE/fake-crictl" "$sim/bin/crictl"
  case $pb in
    nextcloud) cp "$HERE/fake-k3s-nextcloud" "$sim/bin/k3s"; group=nextcloud ;;
    blog)      cp "$HERE/fake-k3s-blog" "$sim/bin/k3s"; group=blog ;;
  esac
  echo '{"message":"test log line"}' > "$sim/data/nextcloud.log"
  touch "$sim/backups/wordpress-db-2026-10-12_0300.sql.gz"
  cat > "$sim/inventory.yml" <<EOF
$group:
  hosts:
    sim:
      ansible_connection: local
      ansible_python_interpreter: $(command -v python3)
      nextcloud_data_dir: $sim/data
      blog_hostname: blog.example.test
      blog_k3s_update_backup_dir: $sim/backups
EOF
  SIM=$sim SCENARIO=$sc REBUILT=$rebuilt PATH=$sim/bin:$PATH ANSIBLE_CONFIG=$REPO/ansible.cfg \
    ansible-playbook -i "$sim/inventory.yml" "$REPO/$pb-update.yml" --limit sim \
      -e "home_url=http://127.0.0.1:$PORT/" "$@" </dev/null > "$sim/run.log" 2>&1
  local rc=$? calls maint="-" problems=""
  calls=""; [ -f "$sim/calls.log" ] && calls=$(tr '\n' ';' < "$sim/calls.log")
  [ -f "$sim/state.json" ] && maint=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['maintenance'])" "$sim/state.json")
  [ "$pb" = nextcloud ] && [ "$maint" = "-" ] && maint=False
  [ "$rc" = "$want_rc" ] || problems+=" rc=$rc(want $want_rc)"
  [ "$want_maint" = "-" ] || [ "$maint" = "$want_maint" ] || problems+=" maintenance=$maint(want $want_maint)"
  local c
  # call patterns are comma-separated, "_" stands for a space
  for c in ${must//,/ }; do [[ "$calls" == *"${c//_/ }"* ]] || problems+=" missing:$c"; done
  for c in ${mustnot//,/ }; do [[ "$calls" == *"${c//_/ }"* ]] && problems+=" unexpected:$c"; done
  if [ -z "$problems" ]; then printf 'ok    %-34s %s\n' "$pb/$name" "${calls:-no calls}"
  else printf 'FAIL  %-34s%s\n      calls: %s\n      log: %s\n' "$pb/$name" "$problems" "$calls" "$sim/run.log"; FAIL=1; fi
}

#        playbook  name                  SCENARIO           REBUILT    rc maint  must-calls                               must-not-calls
scenario nextcloud healthy               ""                 ""         0  False  "occ_upgrade,occ_app:update"             "rollout"
scenario nextcloud image_rebuilt         ""                 nextcloud  0  False  "restart_deployment/nextcloud"           "deployment/collabora"
scenario nextcloud maintenance_before    maintenance_before ""         2  True   ""                                       "pull,occ_upgrade,maintenance:mode"
scenario nextcloud upgrade_fails         upgrade_fails      ""         2  True   "occ_upgrade"                            "maintenance:mode"
scenario nextcloud apps_fail             apps_fail          ""         2  False  "maintenance:mode_--off"                 ""
scenario nextcloud rollout_fails         rollout_fails      nextcloud  2  False  "restart_deployment/nextcloud"           "occ_upgrade"
scenario nextcloud check_mode            ""                 nextcloud  0  False  ""                                       "pull,rollout,occ_upgrade" --check
scenario blog      healthy               ""                 ""         0  -      "create_job"                             "rollout"
scenario blog      plugin_updated        plugin_updated     ""         0  -      "restart_deployment/wordpress"           "deployment/redis"
scenario blog      image_rebuilt         ""                 redis      0  -      "restart_deployment/redis"               "deployment/wordpress"
scenario blog      job_fails             job_fails          ""         2  -      "create_job"                             "rollout"
scenario blog      rollout_fails         rollout_fails      ""         2  -      "status_deployment/wordpress"            ""
scenario blog      not_running           not_running        ""         2  -      ""                                       "create_job,pull"
scenario blog      check_mode            ""                 redis      0  -      ""                                       "create_job,pull,rollout" --check

[ "$FAIL" = 0 ] && echo "== PASSED" || echo "== FAILED"
exit "$FAIL"
