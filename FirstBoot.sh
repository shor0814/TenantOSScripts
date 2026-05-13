#!/bin/bash
# TenantOS Unified First Boot
# Bare metal: triggered by cron.d/firstboot (wget | bash), self-deletes after run.
# Proxmox VM: triggered by QEMU guest agent guest-exec (curl/wget | bash).
# Applies network config if not already done (marker absent), then validates connectivity.

LOGFILE="/var/log/tenantos-first-boot.log"
mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1
echo "=== TenantOS FirstBoot: $(date) ==="
set -x

MARKER="/var/log/tenantos-network-setup.done"

if [ ! -f "$MARKER" ]; then
  echo "INFO: No network config marker found - running network configuration now."

  # -- OS detection -------------------------------------------------------------
  OS_ID=""
  ID_LIKE=""
  if [ -f /etc/os-release ]; then
    OS_ID=$(grep '^ID='      /etc/os-release | cut -d= -f2 | tr -d '"')
    ID_LIKE=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
  fi
  case "$OS_ID $ID_LIKE" in
    *rhel*|*rocky*|*alma*|*centos*|*fedora*) OS_FAMILY="rhel"   ;;
    *ubuntu*|*debian*)                        OS_FAMILY="debian" ;;
    *) echo "WARN: Unknown OS ID '$OS_ID', defaulting to debian-style config."
       OS_FAMILY="debian" ;;
  esac
  echo "INFO: OS_ID=$OS_ID  OS_FAMILY=$OS_FAMILY"

  # -- Template variables (rendered server-side by TenantOS API before delivery) -
  PXE_MAC=$(echo "{{mac}}" | tr '[:upper:]' '[:lower:]')
  IPV4_ADDR="{{server.ipassignments.0.ip}}"
  IPV4_GW="{{server.ipassignments.0.subnetinformation.gw}}"
  RAW_IPV6="{{server.ipassignments.1.ip}}"
  IPV6_GW="{{server.ipassignments.1.subnetinformation.gw}}"
  SERVER_TAGS_RAW='{{server.tags}}'

  # -- IPv6 address parse: subnet ::/XX -> host ::4/XX --------------------------
  # ::1 = VRRP virtual, ::2/::3 = TNSR router interfaces; ::4 is first tenant address
  V6_PREFIX=$(echo "$RAW_IPV6" | grep -oE '[0-9]+$')
  V6_BASE=$(echo "$RAW_IPV6"   | sed 's/::.*/::/')
  IPV6_HOST="${V6_BASE}4/${V6_PREFIX}"

  # -- VLAN tag parse (tolerates vlan/101; no fallback) ------------------------
  CLEAN_TAGS=$(echo "$SERVER_TAGS_RAW" | tr -d '[]"' | tr ',' '\n' | tr -d ' /')
  VLAN_ID=$(echo "$CLEAN_TAGS" | grep -oE 'vlan[0-9]+' | head -n 1 | sed 's/vlan//')
  [ -z "$VLAN_ID" ] && echo "WARN: No vlan### tag found - IPv6 VLAN will not be configured."

  # -- NIC detection ------------------------------------------------------------
  PXE_IFACE=$(ip -o link show | grep -i "$PXE_MAC" | awk -F': ' '{print $2}' | sed 's/:$//')
  SLOT_ID=$(echo "$PXE_IFACE" | grep -oE '^(ens[0-9]+f|enp[0-9]+s[0-9]+f)' | head -n 1)
  if [ -n "$SLOT_ID" ]; then
    IFACES=$(ls /sys/class/net | grep "^${SLOT_ID}" | sort | tr '\n' ' ' | sed 's/ $//')
  else
    IFACES="$PXE_IFACE"
  fi
  NIC_COUNT=$(echo "$IFACES" | wc -w)
  echo "INFO: PXE_IFACE=$PXE_IFACE  IFACES=$IFACES  NIC_COUNT=$NIC_COUNT"

  # ============================================================================
  # -- RHEL / Rocky / Alma -----------------------------------------------------
  # ============================================================================
  if [ "$OS_FAMILY" = "rhel" ]; then

    gen_uuid() {
      if   [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
      elif command -v uuidgen >/dev/null 2>&1;  then uuidgen
      else date +%s%N; fi
    }

    CONN_DIR="/etc/NetworkManager/system-connections"
    mkdir -p "$CONN_DIR"

    if [ "$NIC_COUNT" -ge 2 ]; then
      PARENT_DEV="bond0"
      BOND_UUID="$(gen_uuid)"
      cat > "${CONN_DIR}/bond0.nmconnection" <<EOF
[connection]
id=bond0
uuid=${BOND_UUID}
type=bond
interface-name=bond0
autoconnect=true

[bond]
options=mode=802.3ad,miimon=100,xmit_hash_policy=layer3+4

[ipv4]
method=manual
addresses1=${IPV4_ADDR}/24,${IPV4_GW}
dns=1.1.1.1;1.0.0.1;
ignore-auto-dns=true

[ipv6]
method=ignore
EOF

      for i in $IFACES; do
        SLAVE_UUID="$(gen_uuid)"
        cat > "${CONN_DIR}/bond0-${i}.nmconnection" <<EOF
[connection]
id=bond0-${i}
uuid=${SLAVE_UUID}
type=ethernet
interface-name=${i}
master=bond0
slave-type=bond
autoconnect=true

[ipv4]
method=disabled

[ipv6]
method=ignore
EOF
      done

    else
      PARENT_DEV="$PXE_IFACE"
      BASE_UUID="$(gen_uuid)"
      cat > "${CONN_DIR}/base-iface.nmconnection" <<EOF
[connection]
id=base-iface
uuid=${BASE_UUID}
type=ethernet
interface-name=${PARENT_DEV}
autoconnect=true

[ipv4]
method=manual
addresses1=${IPV4_ADDR}/24,${IPV4_GW}
dns=1.1.1.1;1.0.0.1;
ignore-auto-dns=true

[ipv6]
method=ignore
EOF
    fi

    if [ -n "$VLAN_ID" ]; then
      VLAN_UUID="$(gen_uuid)"
      cat > "${CONN_DIR}/vlan${VLAN_ID}.nmconnection" <<EOF
[connection]
id=vlan${VLAN_ID}
uuid=${VLAN_UUID}
type=vlan
interface-name=${PARENT_DEV}.${VLAN_ID}
autoconnect=true

[vlan]
id=${VLAN_ID}
parent=${PARENT_DEV}

[ipv4]
method=disabled

[ipv6]
method=manual
addresses1=${IPV6_HOST}
gateway=${IPV6_GW}
dns=2606:4700:4700::1111;2001:4860:4860::8888;
ignore-auto-routes=true
EOF
      mkdir -p /etc/sysctl.d/
      printf "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.accept_ra=0\n" \
        > /etc/sysctl.d/99-ipv6-routing.conf
      sysctl -p /etc/sysctl.d/99-ipv6-routing.conf
    fi

    chmod 600 "${CONN_DIR}/"*.nmconnection 2>/dev/null || true
    rm -f "${CONN_DIR}/cloud-init-${PARENT_DEV}.nmconnection" 2>/dev/null || true
    rm -f "${CONN_DIR}/${PARENT_DEV}.nmconnection" 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo "bonding" > /etc/modules-load.d/bonding.conf
    [ -n "$VLAN_ID" ] && echo "8021q" > /etc/modules-load.d/8021q.conf

    systemctl reload-or-restart NetworkManager 2>/dev/null || true
    nmcli connection reload
    sleep 3
    if [ "$NIC_COUNT" -ge 2 ]; then
      nmcli connection up "bond0" 2>/dev/null || true
    else
      nmcli connection up "base-iface" 2>/dev/null || true
    fi
    [ -n "$VLAN_ID" ] && { nmcli connection up "vlan${VLAN_ID}" 2>/dev/null || true; sleep 5; }

  # ============================================================================
  # -- Debian / Ubuntu ----------------------------------------------------------
  # ============================================================================
  else

    if command -v netplan >/dev/null 2>&1 || [ -d /etc/netplan ]; then
      USE_NETPLAN=1
    else
      USE_NETPLAN=0
    fi
    echo "INFO: USE_NETPLAN=$USE_NETPLAN"

    if [ "$USE_NETPLAN" = "1" ]; then
      mkdir -p /etc/netplan/
      rm -f /etc/netplan/50-cloud-init.yaml
      NETPLAN_FILE="/etc/netplan/99-tenantos.yaml"

      printf "network:\n  version: 2\n" > "$NETPLAN_FILE"

      if [ "$NIC_COUNT" -ge 2 ]; then
        PARENT="bond0"
        printf "  ethernets:\n" >> "$NETPLAN_FILE"
        for i in $IFACES; do
          printf "    %s:\n      dhcp4: no\n      mtu: 1500\n" "$i" >> "$NETPLAN_FILE"
        done
        printf "  bonds:\n    bond0:\n      interfaces:\n" >> "$NETPLAN_FILE"
        for i in $IFACES; do
          printf "        - %s\n" "$i" >> "$NETPLAN_FILE"
        done
        cat >> "$NETPLAN_FILE" <<EOF
      addresses:
        - "${IPV4_ADDR}/24"
      routes:
        - to: default
          via: "${IPV4_GW}"
      nameservers:
        addresses:
          - "1.1.1.1"
          - "1.0.0.1"
      parameters:
        mode: 802.3ad
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
EOF
      else
        PARENT="$PXE_IFACE"
        cat >> "$NETPLAN_FILE" <<EOF
  ethernets:
    ${PARENT}:
      dhcp4: no
      mtu: 1500
      addresses:
        - "${IPV4_ADDR}/24"
      routes:
        - to: default
          via: "${IPV4_GW}"
      nameservers:
        addresses:
          - "1.1.1.1"
          - "1.0.0.1"
EOF
      fi

      if [ -n "$VLAN_ID" ]; then
        cat >> "$NETPLAN_FILE" <<EOF
  vlans:
    ${PARENT}.${VLAN_ID}:
      id: ${VLAN_ID}
      link: ${PARENT}
      accept-ra: no
      dhcp6: no
      addresses:
        - "${IPV6_HOST}"
      routes:
        - to: default
          via: "${IPV6_GW}"
      nameservers:
        addresses:
          - "2606:4700:4700::1111"
          - "2001:4860:4860::8888"
EOF
        mkdir -p /etc/sysctl.d/
        printf "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.accept_ra=0\n" \
          > /etc/sysctl.d/99-ipv6-routing.conf
        sysctl -p /etc/sysctl.d/99-ipv6-routing.conf
      fi

      chmod 600 "$NETPLAN_FILE"
      netplan generate && echo "Netplan syntax: VALID" || echo "Netplan syntax: INVALID"
      netplan apply  && echo "Netplan applied."  || echo "WARN: netplan apply failed."

    else
      # ifupdown - Debian bare metal without netplan (should not normally run here
      # since FirstBoot always runs on a live OS, but handled for completeness)
      IFACE_FILE="/etc/network/interfaces"
      {
        printf "auto lo\niface lo inet loopback\n\n"

        if [ "$NIC_COUNT" -ge 2 ]; then
          for i in $IFACES; do
            printf "auto %s\niface %s inet manual\n    bond-master bond0\n    mtu 1500\n\n" "$i" "$i"
          done
          printf "auto bond0\niface bond0 inet static\n"
          printf "    address %s/24\n    gateway %s\n" "$IPV4_ADDR" "$IPV4_GW"
          printf "    dns-nameservers 1.1.1.1 1.0.0.1\n"
          printf "    bond-slaves %s\n    bond-mode 802.3ad\n" "$IFACES"
          printf "    bond-miimon 100\n    bond-lacp-rate 1\n    bond-xmit-hash-policy layer3+4\n\n"
          NET_PARENT="bond0"
        else
          printf "auto %s\niface %s inet static\n" "$PXE_IFACE" "$PXE_IFACE"
          printf "    address %s/24\n    gateway %s\n" "$IPV4_ADDR" "$IPV4_GW"
          printf "    dns-nameservers 1.1.1.1 1.0.0.1\n\n"
          NET_PARENT="$PXE_IFACE"
        fi

        if [ -n "$VLAN_ID" ]; then
          printf "auto %s.%s\niface %s.%s inet6 static\n" \
            "$NET_PARENT" "$VLAN_ID" "$NET_PARENT" "$VLAN_ID"
          printf "    address %s\n    gateway %s\n" "$IPV6_HOST" "$IPV6_GW"
          printf "    dns-nameservers 2606:4700:4700::1111\n"
          printf "    accept_ra 0\n    autoconf 0\n"
        fi
      } > "$IFACE_FILE"

      echo "DEBUG: /etc/network/interfaces:"
      cat "$IFACE_FILE"

      MODULES_FILE="/etc/modules"
      touch "$MODULES_FILE"
      grep -qxF "bonding" "$MODULES_FILE" || echo "bonding" >> "$MODULES_FILE"
      [ -n "$VLAN_ID" ] && { grep -qxF "8021q" "$MODULES_FILE" || echo "8021q" >> "$MODULES_FILE"; }

      ifup -a 2>/dev/null || true
    fi
  fi

  # -- Disable cloud-init networking (always live OS in FirstBoot context) ------
  if [ -d /run/cloud-init ]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    echo "INFO: cloud-init network config disabled."
  fi

  # -- Write idempotency marker -------------------------------------------------
  date -u "+%Y-%m-%dT%H:%M:%SZ  OS_FAMILY=${OS_FAMILY}  source=firstboot" > "$MARKER"
  echo "INFO: Marker written to $MARKER"

else
  echo "INFO: Network config marker found ($MARKER) - skipping config, running validation only."
fi

# -- Validation ----------------------------------------------------------------
sleep 5
echo "====================================================="
echo "NETWORK VALIDATION: $(date)"
echo "====================================================="

ip -br addr show
[ -f /proc/net/bonding/bond0 ] && grep -E "Slave Interface|MII Status|Partner Mac" /proc/net/bonding/bond0

V4_GW=$(ip -4 route show default | awk '/via/{print $3; exit}')
V6_GW=$(ip -6 route show default | awk '/via/{print $3; exit}')
ERRORS=0

if [ -z "$V4_GW" ]; then
  echo "Local IPv4 GW: NOT FOUND"; ERRORS=$((ERRORS+1))
else
  printf "Local IPv4 GW (%s): " "$V4_GW"
  ping -c 3 -W 5 "$V4_GW" >/dev/null 2>&1 && echo "PASS" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }
fi

if [ -z "$V6_GW" ]; then
  echo "Local IPv6 GW: NOT FOUND"; ERRORS=$((ERRORS+1))
else
  printf "Local IPv6 GW (%s): " "$V6_GW"
  ping6 -c 3 -W 5 "$V6_GW" >/dev/null 2>&1 && echo "PASS" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }
fi

ping6_test() {
  local label="$1" host="$2"
  printf "%s" "$label"
  local out; out=$(ping6 -c 2 -W 5 "$host" 2>&1)
  local loss; loss=$(echo "$out" | grep -oE '[0-9]+% packet loss')
  echo "$out" | grep -q " 0% packet loss" \
    && echo "PASS" \
    || { echo "FAIL ($loss)"; ERRORS=$((ERRORS+1)); }
}

ping4_test() {
  local label="$1" host="$2"
  printf "%s" "$label"
  local out; out=$(ping -c 2 -W 5 "$host" 2>&1)
  local loss; loss=$(echo "$out" | grep -oE '[0-9]+% packet loss')
  echo "$out" | grep -q " 0% packet loss" \
    && echo "PASS" \
    || { echo "FAIL ($loss)"; ERRORS=$((ERRORS+1)); }
}

ping4_test "Ext IPv4 Cloudflare/KCIX  (1.1.1.1):               " 1.1.1.1
ping4_test "Ext IPv4 Google/transit   (8.8.8.8):               " 8.8.8.8
ping6_test "Ext IPv6 Cloudflare/KCIX  (2606:4700:4700::1111):  " 2606:4700:4700::1111
ping6_test "Ext IPv6 Google/transit   (2001:4860:4860::8888):  " 2001:4860:4860::8888
ping6_test "DNS IPv6 Cloudflare       (one.one.one.one AAAA):  " one.one.one.one
ping6_test "DNS IPv6 Google           (dns.google AAAA):       " dns.google

echo "-----------------------------------------------------"
[ $ERRORS -eq 0 ] && echo "SUMMARY: ALL TESTS PASSED" || echo "SUMMARY: FAILED ($ERRORS tests failed)"
echo "====================================================="

set +x
echo "=== TenantOS FirstBoot: DONE ==="
