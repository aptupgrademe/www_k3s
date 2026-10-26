#!/bin/bash
# fail2ban effect test (common_verify, both stacks), run from stdin:
#   1. every filter matches a canned line in today's log format
#      (containerd-prefixed ingress line / sshd journal line)
#   2. per jail: ban a TEST-NET address (192.0.2.x / 2001:db8::x) -> it is in
#      that jail's own set pair f2b_<set>4/6; unban -> gone
#   3. one address in two jails, unban in one -> still in the other set
# The test addresses never route on the internet; every ban is lifted again.
# Output: one line per check, last line "RESULT <failures>".
# Argument: "jail=set jail=set ..." (fail2ban_nft_jails from group_vars).
set -u
declare -A SET
for p in "$@"; do SET[${p%%=*}]=${p#*=}; done
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- 1. canned lines ----------------------------------------------------------
pre='2026-10-26T08:00:00.000000000+01:00 stdout F 192.0.2.50 - - [26/Oct/2026:07:00:00 +0000]'
declare -A LINE=(
  [nginx-k3s-wp-login]="$pre \"POST /wp-login.php HTTP/1.1\" 200 4512 \"-\" \"test\" \"-\""
  [nginx-k3s-nc-login]="$pre \"POST /index.php/login HTTP/1.1\" 303 0 \"-\" \"test\" \"-\""
  [nginx-k3s-grafana-login]="$pre \"POST /grafana/login HTTP/1.1\" 401 52 \"-\" \"test\" \"-\""
  [nginx-k3s-scanner]="$pre \"GET /nothing-here HTTP/1.1\" 404 548 \"-\" \"test\" \"-\""
  [nginx-k3s-bad-paths]="$pre \"GET /.env HTTP/1.1\" 404 548 \"-\" \"test\" \"-\""
  [sshd]="Oct 26 08:00:00 host sshd-session[4242]: Invalid user test from 192.0.2.50 port 4242"
)
for f in "${!LINE[@]}"; do
  n=$(fail2ban-regex "${LINE[$f]}" "/etc/fail2ban/filter.d/$f.conf" 2>/dev/null | sed -n 's/^Lines: .* \([0-9]*\) matched.*/\1/p')
  [ "${n:-0}" -ge 1 ] && echo "filter $f ok" || fail "filter $f: canned line not matched"
done

# --- 2. ban chain per jail ----------------------------------------------------
in_set() { nft list set inet filter "f2b_$1" 2>/dev/null | grep -qw -- "$2"; }
i=10
for j in $(fail2ban-client status | sed -n 's/.*Jail list:\s*//p' | tr -d ' ' | tr ',' ' '); do
  s=${SET[$j]:-}
  [ -n "$s" ] || { fail "jail $j: no set in fail2ban_nft_jails"; continue; }
  v4=192.0.2.$i v6=2001:db8::$i; i=$((i + 1))
  fail2ban-client set "$j" banip "$v4" "$v6" >/dev/null; sleep 1
  b4=FAIL b6=FAIL u4=ok u6=ok
  in_set "${s}4" "$v4" && b4=ok
  in_set "${s}6" "$v6" && b6=ok
  fail2ban-client set "$j" unbanip "$v4" "$v6" >/dev/null; sleep 1
  in_set "${s}4" "$v4" && u4=FAIL
  in_set "${s}6" "$v6" && u6=FAIL
  r="ban4=$b4 ban6=$b6 unban4=$u4 unban6=$u6"
  [[ $r == *FAIL* ]] && fail "jail $j $r" || echo "jail $j $r"
done

# --- 3. two jails, one address --------------------------------------------------
x=192.0.2.99
fail2ban-client set sshd banip $x >/dev/null
fail2ban-client set nginx-k3s-scanner banip $x >/dev/null; sleep 1
fail2ban-client set sshd unbanip $x >/dev/null; sleep 1
if in_set "${SET[nginx-k3s-scanner]}4" $x && ! in_set "${SET[sshd]}4" $x; then
  echo "cross-jail ok"
else
  fail "cross-jail: unban in sshd changed the scanner set"
fi
fail2ban-client set nginx-k3s-scanner unbanip $x >/dev/null
echo "RESULT $fails"
