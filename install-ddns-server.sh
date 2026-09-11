#!/usr/bin/env bash
#
# install-ddns-server.sh — set up the authoritative BIND 9 DDNS server (Docker)
#
#   sudo ./install-ddns-server.sh            install / update everything
#   sudo ./install-ddns-server.sh --check    verify an existing install, change nothing
#
# Idempotent: safe to re-run. It never overwrites the zone file (live records),
# and never touches config/routers.list or config/keys/ — those belong to ddns-router.
# Everything it would change is reported; nothing else is silently modified.
#
# Place ddns-router next to this script to have it installed too.

set -euo pipefail

# ─── CONFIGURATION — edit these ────────────────────────────────────────────────
ZONE="dyn.example.com"               # the delegated subzone
NS_NAME="ns-dyn.example.com"         # nameserver name (A record in the parent zone)
HOSTMASTER="hostmaster.example.com"  # zone contact (@ becomes .)
PUBLIC_IP="203.0.113.10"             # public IP the routers send updates to
BIND_IP="192.168.1.10"               # this VM's LAN IP (the NAT/dst-nat target)
BASE="/var/data/containers/bind9"    # install folder (anything you like)
OWNER="youruser"                     # user owning config/ and compose/
IMAGE="internetsystemsconsortium/bind9:9.20"
SUBNET="172.30.53.0/24"              # docker network for the container
BRIDGE="br-dns"                      # bridge name the egress rules match
NTFY_URL=""                          # optional: update notifications
NTFY_TOKEN=""
# ───────────────────────────────────────────────────────────────────────────────

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

COMPOSE="$BASE/compose"; CONF="$BASE/config"; ZONES="$BASE/zones"; CACHE="$BASE/cache"
ZONEFILE="$ZONES/$ZONE.zone"
NS_RE=$(printf '%s' "$NS_NAME" | sed 's/\./\\./g')   # NS_NAME with dots escaped, for grep
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CHANGED=0; FAILED=0

c_ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
c_new()  { printf '  \033[33m+\033[0m     %s\n' "$*"; CHANGED=1; }
c_warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
c_err()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
step()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()    { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# would_write <path> <content>  — write unless unchanged; never in --check mode
would_write() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    c_ok "$(basename "$path") unchanged"; return 1
  fi
  if [ "$CHECK_ONLY" = 1 ]; then
    c_warn "$(basename "$path") would be $([ -f "$path" ] && echo updated || echo created)"
    CHANGED=1; return 1
  fi
  printf '%s\n' "$content" > "$path"
  c_new "$(basename "$path") $([ -s "$path" ] && echo written)"
  return 0
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
id -u "$OWNER" >/dev/null 2>&1 || die "user '$OWNER' does not exist — set OWNER at the top"
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "PUBLIC_IP is not an IPv4 address"
[[ "$BIND_IP"   =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "BIND_IP is not an IPv4 address"

step "1. Preflight"
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
c_ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

if ss -lunp "sport = :53" 2>/dev/null | grep -q . || ss -ltnp "sport = :53" 2>/dev/null | grep -q .; then
  if docker ps --format '{{.Names}}' | grep -qx bind9; then
    c_ok "port 53 held by the bind9 container"
  else
    c_err "port 53 is already in use by something else:"; ss -lunptH "sport = :53" | sed 's/^/        /'
  fi
else
  c_ok "port 53 free"
fi

iptables -L DOCKER-USER -n >/dev/null 2>&1 \
  && c_ok "DOCKER-USER chain present" \
  || c_err "DOCKER-USER chain missing — docker is using the nftables backend; step 5 needs adapting"

timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes \
  && c_ok "clock synchronised" \
  || c_warn "clock not NTP-synchronised — TSIG rejects updates more than 5 min off"

command -v dig >/dev/null && command -v nsupdate >/dev/null \
  && c_ok "dig and nsupdate present" \
  || { [ "$CHECK_ONLY" = 1 ] && c_warn "bind9-dnsutils missing" || { apt-get install -y bind9-dnsutils >/dev/null && c_new "installed bind9-dnsutils"; }; }

step "2. Image and runtime user"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  [ "$CHECK_ONLY" = 1 ] && die "image $IMAGE not pulled"
  docker pull -q "$IMAGE" >/dev/null && c_new "pulled $IMAGE"
else
  c_ok "image present: $(docker run --rm --entrypoint named "$IMAGE" -v 2>/dev/null | head -1)"
fi
BIND_USER=$(docker run --rm --entrypoint sh "$IMAGE" -c 'id -un bind 2>/dev/null || id -un named' | tr -d '\r')
BIND_UID=$(docker run --rm --entrypoint id "$IMAGE" -u "$BIND_USER" | tr -d '\r')
BIND_GID=$(docker run --rm --entrypoint id "$IMAGE" -g "$BIND_USER" | tr -d '\r')
[[ "$BIND_UID" =~ ^[0-9]+$ && "$BIND_GID" =~ ^[0-9]+$ ]] || die "could not detect the image's bind uid/gid"
c_ok "runs as $BIND_USER ($BIND_UID:$BIND_GID)"

step "3. Folders and files"
for d in "$COMPOSE" "$CONF" "$CONF/keys" "$ZONES" "$CACHE"; do
  [ -d "$d" ] && c_ok "${d#$BASE/} exists" || { [ "$CHECK_ONLY" = 1 ] && { c_warn "${d#$BASE/} missing"; CHANGED=1; } || { mkdir -p "$d"; c_new "${d#$BASE/} created"; }; }
done
[ -d "$COMPOSE" ] || { echo; echo "Run without --check to create the install."; exit 1; }

would_write "$COMPOSE/.env" "$(cat <<EOF
BIND_IP=$BIND_IP
BIND_USER=$BIND_USER
BIND_UID=$BIND_UID
BIND_GID=$BIND_GID
DDNS_SERVER=$PUBLIC_IP
NTFY_URL=$NTFY_URL
NTFY_TOKEN=$NTFY_TOKEN
EOF
)" || true

would_write "$CONF/named.conf" "$(cat <<EOF
// GENERATED by install-ddns-server.sh
options {
    directory "/var/cache/bind";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";

    listen-on { any; };
    listen-on-v6 { none; };

    // Authoritative only — never a resolver
    recursion no;
    allow-recursion { none; };
    allow-query-cache { none; };
    allow-query { any; };
    allow-transfer { none; };
    notify no;
    dnssec-validation no;

    // Anti-amplification
    minimal-responses yes;
    minimal-any yes;
    rate-limit { responses-per-second 10; window 5; };

    // Don't advertise anything
    version none;
    hostname none;
    server-id none;
};

controls { };   // no rndc command channel

include "/etc/bind/ddns.conf";   // generated by ddns-router: keys + zone + update-policy
EOF
)" || true

if [ -f "$ZONEFILE" ]; then
  c_ok "zone file exists (serial $(awk '/SOA/{getline; print $1}' "$ZONEFILE" 2>/dev/null | head -1)) — left untouched"
elif [ "$CHECK_ONLY" = 1 ]; then
  c_warn "zone file would be created"; CHANGED=1
else
  cat > "$ZONEFILE" <<EOF
\$TTL 60
@   IN SOA $NS_NAME. $HOSTMASTER. (
        1        ; serial (BIND increments it on each update)
        3600     ; refresh
        600      ; retry
        604800   ; expire
        60 )     ; negative-cache TTL
    IN NS  $NS_NAME.
EOF
  c_new "zone file created"
fi

would_write "$COMPOSE/compose.yml" "$(cat <<EOF
name: bind9          # without it, compose names the project after the folder ("compose")

services:
  bind9:
    image: $IMAGE
    container_name: bind9
    restart: unless-stopped
    entrypoint: ["/usr/sbin/named"]
    command: ["-g", "-c", "/etc/bind/named.conf", "-u", "\${BIND_USER}"]
    ports:
      - "\${BIND_IP}:53:53/udp"
      - "\${BIND_IP}:53:53/tcp"
    volumes:
      - ../config:/etc/bind:ro
      - ../zones:/var/lib/bind
      - ../cache:/var/cache/bind
    tmpfs:
      - /run/named:uid=\${BIND_UID},gid=\${BIND_GID},mode=0750,size=1m
      - /tmp:size=16m
      - /var/log:size=16m      # the image declares VOLUME /var/log
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE, SETUID, SETGID, CHOWN, DAC_READ_SEARCH]
    pids_limit: 256
    mem_limit: 256m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [dns]

networks:
  dns:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: $BRIDGE
    ipam:
      config:
        - subnet: $SUBNET
EOF
)" || true

step "4. Permissions"
if [ "$CHECK_ONLY" = 1 ]; then
  [ "$(stat -c %U:%G "$CONF")" = "$OWNER:$BIND_GID" ] || [ "$(stat -c %U "$CONF")" = "$OWNER" ] \
    && c_ok "config/ owned by $OWNER" || c_warn "config/ ownership differs"
  [ "$(stat -c %u "$ZONES")" = "$BIND_UID" ] && c_ok "zones/ writable by named" || c_warn "zones/ not owned by $BIND_UID — named cannot write its journal"
else
  chown -R "$OWNER:$BIND_GID" "$CONF"
  find "$CONF" -type d -exec chmod 750 {} +
  find "$CONF" -type f -exec chmod 640 {} +
  chown -R "$BIND_UID:$BIND_GID" "$ZONES" "$CACHE"
  chmod 770 "$ZONES" "$CACHE"
  chown -R "$OWNER:$OWNER" "$COMPOSE"; chmod 640 "$COMPOSE/.env"
  c_ok "config/ $OWNER:$BIND_GID 750/640 · zones+cache $BIND_UID:$BIND_GID 770"
  c_warn "never run 'chown -R $OWNER' on zones/ — named would stop writing its journal"
fi

step "5. ddns-router"
if [ -f "$SRC_DIR/ddns-router" ]; then
  if [ "$CHECK_ONLY" = 1 ]; then
    cmp -s "$SRC_DIR/ddns-router" /usr/local/sbin/ddns-router && c_ok "ddns-router up to date" || { c_warn "ddns-router would be installed/updated"; CHANGED=1; }
  else
    install -o root -g root -m 750 "$SRC_DIR/ddns-router" /usr/local/sbin/ddns-router
    sed -i 's/\r$//' /usr/local/sbin/ddns-router   # in case it passed through Windows
    c_new "ddns-router installed"
    [ -f "$CONF/ddns.conf" ] || { DDNS_BASE="$BASE" /usr/local/sbin/ddns-router init && c_new "ddns-router init done"; }
  fi
elif [ -x /usr/local/sbin/ddns-router ]; then
  c_ok "ddns-router already installed"
else
  c_warn "ddns-router not found next to this script — copy it in and re-run"
fi

step "6. Container"
if [ "$CHECK_ONLY" = 1 ]; then
  docker ps --format '{{.Names}}' | grep -qx bind9 && c_ok "bind9 running" || c_warn "bind9 not running"
else
  if [ ! -f "$CONF/ddns.conf" ]; then
    c_warn "config/ddns.conf missing — ddns-router init did not run (step 5); fix that, then re-run"
  else
    (cd "$COMPOSE" && docker compose up -d >/dev/null 2>&1) && c_ok "bind9 up" || c_err "compose up failed: cd $COMPOSE && docker compose logs bind9"
  fi
fi

step "7. Egress lock (container may not initiate connections)"
EGRESS=/usr/local/sbin/bind9-egress.sh
would_write "$EGRESS" "$(cat <<EOF
#!/bin/sh
# GENERATED by install-ddns-server.sh — the bind9 container answers, it never calls out.
set -e
BR=$BRIDGE
add() { iptables -C "\$@" 2>/dev/null || iptables -I "\$@"; }

add DOCKER-USER -i "\$BR" -m conntrack --ctstate NEW -j DROP
add DOCKER-USER -i "\$BR" -m conntrack --ctstate NEW -m limit --limit 6/min -j LOG --log-prefix "bind9-egress: "
add INPUT       -i "\$BR" -m conntrack --ctstate NEW -j DROP
add INPUT       -i "\$BR" -m conntrack --ctstate NEW -m limit --limit 6/min -j LOG --log-prefix "bind9-egress: "
EOF
)" || true
chmod 755 "$EGRESS"

would_write /etc/systemd/system/bind9-egress.service "$(cat <<'EOF'
[Unit]
Description=Block outbound connections from the bind9 container
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bind9-egress.sh

[Install]
WantedBy=docker.service
EOF
)" || true

step "8. Weekly image update with health check and rollback"
UPD=/usr/local/sbin/bind9-update.sh
would_write "$UPD" "$(cat <<EOF
#!/usr/bin/env bash
# GENERATED by install-ddns-server.sh
set -euo pipefail
cd $COMPOSE
IMAGE=$IMAGE

# runs as root: parse the user-owned .env, never source it
envget() {
  local v
  v=\$(sed -n "s/^[[:space:]]*\\(export[[:space:]]\\+\\)\\?\$1=//p" .env | tail -n1 | tr -d '\\r')
  v="\${v%%#*}"; v="\${v%"\${v##*[![:space:]]}"}"
  v="\${v#\\"}"; v="\${v%\\"}"; v="\${v#\\'}"; v="\${v%\\'}"
  printf '%s' "\$v"
}
BIND_IP=\$(envget BIND_IP); NTFY_URL=\$(envget NTFY_URL); NTFY_TOKEN=\$(envget NTFY_TOKEN)
[[ "\$BIND_IP" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}\$ ]] || { echo "BIND_IP in .env is invalid" >&2; exit 1; }
[[ -z "\$NTFY_URL" || "\$NTFY_URL" =~ ^https?://[^[:space:]]+\$ ]] || { echo "NTFY_URL in .env is invalid" >&2; exit 1; }

notify() { [ -n "\$NTFY_URL" ] && curl -fsS \${NTFY_TOKEN:+-H "Authorization: Bearer \$NTFY_TOKEN"} -d "\$1" "\$NTFY_URL" >/dev/null || true; }
healthy() { dig @"\$BIND_IP" $ZONE SOA +short +time=2 +tries=3 | grep -q '$NS_RE\\.'; }

OLD_ID=\$(docker inspect -f '{{.Image}}' bind9)
docker pull -q "\$IMAGE" >/dev/null
NEW_ID=\$(docker image inspect -f '{{.Id}}' "\$IMAGE")
[ "\$OLD_ID" = "\$NEW_ID" ] && exit 0

docker compose up -d
sleep 10
if healthy; then
  notify "bind9 updated: \$(docker exec bind9 named -v)"
else
  docker tag "\$OLD_ID" "\$IMAGE"
  docker compose up -d
  sleep 10
  if healthy; then notify "bind9 update FAILED health check — rolled back"; echo "rolled back" >&2
  else notify "bind9 DOWN after update AND rollback — check now"; echo "DOWN" >&2; fi
  exit 1
fi
EOF
)" || true
chmod 750 "$UPD"

would_write /etc/systemd/system/bind9-update.service "$(cat <<'EOF'
[Unit]
Description=Update bind9 container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bind9-update.sh
EOF
)" || true

would_write /etc/systemd/system/bind9-update.timer "$(cat <<'EOF'
[Unit]
Description=Weekly bind9 container update

[Timer]
OnCalendar=Thu 05:30
Persistent=true

[Install]
WantedBy=timers.target
EOF
)" || true

if [ "$CHECK_ONLY" = 0 ]; then
  systemctl daemon-reload
  systemctl enable --now bind9-egress.service >/dev/null 2>&1 && c_ok "bind9-egress active" || c_err "bind9-egress failed: systemctl status bind9-egress"
  systemctl enable --now bind9-update.timer >/dev/null 2>&1 && c_ok "bind9-update.timer armed" || c_err "bind9-update.timer failed"
else
  systemctl is-active --quiet bind9-egress.service && c_ok "bind9-egress active" || c_warn "bind9-egress not active"
  systemctl is-active --quiet bind9-update.timer && c_ok "bind9-update.timer armed" || c_warn "bind9-update.timer not armed"
fi

step "9. Verification"
if docker ps --format '{{.Names}}' | grep -qx bind9; then
  dig @"$BIND_IP" "$ZONE" SOA +short +time=2 +tries=2 | grep -q . \
    && c_ok "authoritative for $ZONE" || c_err "no SOA answer — cd $COMPOSE && docker compose logs bind9"
  [ "$(dig @"$BIND_IP" google.com +time=2 +tries=1 2>/dev/null | awk '/status:/{print $6}' | tr -d ,)" = "REFUSED" ] \
    && c_ok "recursion refused (not an open resolver)" || c_err "recursion NOT refused — check named.conf"
  docker inspect bind9 --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -q '/var/lib/docker/volumes' \
    && c_warn "an anonymous volume is attached — recreate with: docker compose up -d --force-recreate -V" \
    || c_ok "only the three bind mounts"
  docker exec bind9 sh -c 'netstat -ltn 2>/dev/null | grep -q ":953"' \
    && c_warn "rndc channel open — 'controls { };' missing from named.conf" || c_ok "no rndc channel"
else
  c_warn "container not running — skipping live checks"
fi

# Egress test — read-only, so it runs in --check too. If nc is missing from the
# image the docker exec would fail and look like "blocked": use a throwaway alpine
# on the same bridge instead, which the same iptables rules cover.
RULES=$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- "-i $BRIDGE")
RULES=$((RULES + $(iptables -S INPUT 2>/dev/null | grep -c -- "-i $BRIDGE")))
[ "$RULES" -ge 4 ] && c_ok "egress rules present ($RULES on $BRIDGE)" \
  || c_err "only $RULES egress rules on $BRIDGE (expected 4) — a 'blocked' result below would not mean the lock works"

if docker ps --format '{{.Names}}' | grep -qx bind9; then
  if docker exec bind9 sh -c 'command -v nc' >/dev/null 2>&1; then
    RUN() { docker exec bind9 sh -c "$1 </dev/null"; }
  elif docker image inspect alpine >/dev/null 2>&1 || { [ "$CHECK_ONLY" = 0 ] && docker pull -q alpine >/dev/null 2>&1; }; then
    c_warn "nc missing in the image — testing from a throwaway alpine sharing its network namespace"
    RUN() { docker run --rm --network "container:bind9" alpine sh -c "$1 </dev/null"; }
  else
    RUN() { return 99; }
  fi
  for t in "nc -w 3 1.1.1.1 443" "nc -w 3 $BIND_IP 22"; do
    RUN "$t" >/dev/null 2>&1; rc=$?
    case $rc in
      0)  c_err "egress NOT blocked ($t succeeded) — check: iptables -S DOCKER-USER | grep $BRIDGE" ;;
      99) c_err "egress UNTESTED — no nc in the image and alpine unavailable; test by hand before trusting this" ;;
      *)  c_ok "egress blocked: ${t#nc -w 3 }" ;;
    esac
  done
fi

step "Summary"
[ "$FAILED" = 1 ] && printf '  \033[31mproblems found — see FAIL above\033[0m\n' \
  || { [ "$CHANGED" = 1 ] && printf '  changes applied\n' || printf '  nothing to change\n'; }

cat <<EOF

Still to do by hand (not automatable from here):

  1. Parent zone at the DNS host — enter the LABEL only, not the full name:
       A    ns-dyn   $PUBLIC_IP
       NS   dyn      $NS_NAME.
     Verify:  dig NS $ZONE @<parent-ns> +norec     → referral in AUTHORITY

  2. Border router/firewall — forward 53/udp+tcp to this VM, and rate-limit per
     source. MikroTik example; the accept must come BEFORE the drop, and both
     before fasttrack:
       /ip firewall nat
       add chain=dstnat in-interface-list=WAN protocol=udp dst-port=53 action=dst-nat to-addresses=$BIND_IP to-ports=53 comment="bind9 ddns"
       add chain=dstnat in-interface-list=WAN protocol=tcp dst-port=53 action=dst-nat to-addresses=$BIND_IP to-ports=53 comment="bind9 ddns"
       /ip firewall filter
       add chain=forward action=accept protocol=udp dst-address=$BIND_IP dst-port=53 connection-nat-state=dstnat dst-limit=20,40,src-address/1m comment="bind9: per-source limit"
       add chain=forward action=drop   protocol=udp dst-address=$BIND_IP dst-port=53 connection-nat-state=dstnat comment="bind9: drop excess"
       add chain=forward action=accept protocol=tcp dst-address=$BIND_IP dst-port=53 connection-nat-state=dstnat comment="bind9: tcp"
     Then from OFF-LAN (a phone hotspot — hairpin NAT would mislead you):
       dig @$PUBLIC_IP $ZONE SOA        → aa flag
       dig @$PUBLIC_IP google.com       → REFUSED

  3. Routers:  sudo ddns-router add <name>     then enter the printed settings.
     Teltonika RutOS needs firmware 07.20+ (older truncates the zone to its
     first label and every update fails with NOTAUTH).
     DNS server = $PUBLIC_IP (the field rejects hostnames).
     Username needs the hmac-sha256: prefix (without it snsupdate segfaults).
     The router's "Update successful" is meaningless — verify here instead:
       sudo docker compose logs --since 10m bind9 | grep "key <name>"
       dig <name>.$ZONE @1.1.1.1 +short

Backups: $CONF (keys!), $COMPOSE, /usr/local/sbin/ddns-router — encrypt them.
EOF
