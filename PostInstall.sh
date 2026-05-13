#!/bin/bash
# TenantOS Unified Network Configuration
# Runs during PXE post-install (bare metal) for all OS families.
# For cloud-init VMs this script is not called; FirstBoot.sh handles that path.
# Handles: RHEL/Rocky/Alma, Ubuntu, Debian

# -- 1. TARGET detection (real mountpoint only) --------------------------------
is_mountpoint() { grep -q " $1 " /proc/self/mounts 2>/dev/null; }
if   is_mountpoint "/mnt/sysimage"; then TARGET="/mnt/sysimage"
elif is_mountpoint "/target";        then TARGET="/target"
else                                      TARGET=""
fi

# -- 2. Logging ----------------------------------------------------------------
LOGFILE="${TARGET}/var/log/tenantos-network-setup.log"
mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1
echo "=== TenantOS NetworkConfig: $(date) ==="
set -x

# -- 3. Idempotency marker -----------------------------------------------------
MARKER="${TARGET}/var/log/tenantos-network-setup.done"
if [ -f "$MARKER" ]; then
  echo "INFO: marker found at $MARKER - network already configured, exiting."
  exit 0
fi

# -- 4. OS detection (reads target OS, not the installer environment) ----------
OS_ID=""
ID_LIKE=""
if [ -f "${TARGET}/etc/os-release" ]; then
  OS_ID=$(grep '^ID='      "${TARGET}/etc/os-release" | cut -d= -f2 | tr -d '"')
  ID_LIKE=$(grep '^ID_LIKE=' "${TARGET}/etc/os-release" | cut -d= -f2 | tr -d '"')
fi
case "$OS_ID $ID_LIKE" in
  *rhel*|*rocky*|*alma*|*centos*|*fedora*) OS_FAMILY="rhel"   ;;
  *ubuntu*|*debian*)                        OS_FAMILY="debian" ;;
  *) echo "WARN: Unknown OS ID '$OS_ID', defaulting to debian-style config."
     OS_FAMILY="debian" ;;
esac
echo "INFO: OS_ID=$OS_ID  OS_FAMILY=$OS_FAMILY  TARGET='$TARGET'"

# -- 5. Template variables -----------------------------------------------------
PXE_MAC=$(echo "{{mac}}" | tr '[:upper:]' '[:lower:]')
IPV4_ADDR="{{server.ipassignments.0.ip}}"
IPV4_GW="{{server.ipassignments.0.subnetinformation.gw}}"
RAW_IPV6="{{server.ipassignments.1.ip}}"
IPV6_GW="{{server.ipassignments.1.subnetinformation.gw}}"
SERVER_TAGS_RAW='{{server.tags}}'

# -- 6. IPv6 address parse: subnet ::/XX -> host ::4/XX ------------------------
# ::1 = VRRP virtual, ::2/::3 = TNSR router interfaces; ::4 is first tenant address
V6_PREFIX=$(echo "$RAW_IPV6" | grep -oE '[0-9]+$')
V6_BASE=$(echo "$RAW_IPV6"   | sed 's/::.*/::/')
IPV6_HOST="${V6_BASE}4/${V6_PREFIX}"

# -- 7. VLAN tag parse (tolerates vlan/101; no fallback) ----------------------
CLEAN_TAGS=$(echo "$SERVER_TAGS_RAW" | tr -d '[]"' | tr ',' '\n' | tr -d ' /')
VLAN_ID=$(echo "$CLEAN_TAGS" | grep -oE 'vlan[0-9]+' | head -n 1 | sed 's/vlan//')
if [ -z "$VLAN_ID" ]; then
  echo "WARN: No vlan### tag found - IPv6 VLAN will not be configured."
fi

# -- 8. NIC detection ----------------------------------------------------------
PXE_IFACE=$(ip -o link show | grep -i "$PXE_MAC" | awk -F': ' '{print $2}' | sed 's/:$//')
SLOT_ID=$(echo "$PXE_IFACE" | grep -oE '^(ens[0-9]+f|enp[0-9]+s[0-9]+f)' | head -n 1)
if [ -n "$SLOT_ID" ]; then
  IFACES=$(ls /sys/class/net | grep "^${SLOT_ID}" | sort | tr '\n' ' ' | sed 's/ $//')
else
  IFACES="$PXE_IFACE"
fi
NIC_COUNT=$(echo "$IFACES" | wc -w)
echo "INFO: PXE_IFACE=$PXE_IFACE  IFACES=$IFACES  NIC_COUNT=$NIC_COUNT"

# ==============================================================================
# -- RHEL / Rocky / Alma -------------------------------------------------------
# ==============================================================================
if [ "$OS_FAMILY" = "rhel" ]; then

  gen_uuid() {
    if   [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1;  then uuidgen
    else date +%s%N; fi
  }

  CONN_DIR="${TARGET}/etc/NetworkManager/system-connections"
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
    mkdir -p "${TARGET}/etc/sysctl.d/"
    printf "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.accept_ra=0\n" \
      > "${TARGET}/etc/sysctl.d/99-ipv6-routing.conf"
  fi

  chmod 600 "${CONN_DIR}/"*.nmconnection 2>/dev/null || true
  rm -f "${CONN_DIR}/cloud-init-${PARENT_DEV}.nmconnection" 2>/dev/null || true
  rm -f "${CONN_DIR}/${PARENT_DEV}.nmconnection" 2>/dev/null || true
  mkdir -p "${TARGET}/etc/modules-load.d"
  echo "bonding" > "${TARGET}/etc/modules-load.d/bonding.conf"
  [ -n "$VLAN_ID" ] && echo "8021q" > "${TARGET}/etc/modules-load.d/8021q.conf"

# ==============================================================================
# -- Debian / Ubuntu -----------------------------------------------------------
# ==============================================================================
else

  if command -v netplan >/dev/null 2>&1 || [ -d "${TARGET}/etc/netplan" ]; then
    USE_NETPLAN=1
  else
    USE_NETPLAN=0
  fi
  echo "INFO: USE_NETPLAN=$USE_NETPLAN"

  if [ "$USE_NETPLAN" = "1" ]; then
    mkdir -p "${TARGET}/etc/netplan/"
    rm -f "${TARGET}/etc/netplan/50-cloud-init.yaml"
    NETPLAN_FILE="${TARGET}/etc/netplan/99-tenantos.yaml"

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
      mkdir -p "${TARGET}/etc/sysctl.d/"
      printf "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.accept_ra=0\n" \
        > "${TARGET}/etc/sysctl.d/99-ipv6-routing.conf"
    fi

    chmod 600 "$NETPLAN_FILE"

    if command -v netplan >/dev/null 2>&1 && [ -z "$TARGET" ]; then
      netplan generate && echo "Netplan syntax: VALID" || echo "Netplan syntax: INVALID"
    fi

  else
    # ifupdown - Debian bare metal without netplan
    IFACE_FILE="${TARGET}/etc/network/interfaces"
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

    MODULES_FILE="${TARGET}/etc/modules"
    touch "$MODULES_FILE"
    grep -qxF "bonding" "$MODULES_FILE" || echo "bonding" >> "$MODULES_FILE"
    [ -n "$VLAN_ID" ] && { grep -qxF "8021q" "$MODULES_FILE" || echo "8021q" >> "$MODULES_FILE"; }
  fi
fi

# -- 9. Disable cloud-init networking (live OS only, not installer) ------------
if [ -z "$TARGET" ] && [ -d /run/cloud-init ]; then
  mkdir -p /etc/cloud/cloud.cfg.d
  printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  echo "INFO: cloud-init network config disabled."
fi

# -- 10. Write idempotency marker ----------------------------------------------
date -u "+%Y-%m-%dT%H:%M:%SZ  OS_FAMILY=${OS_FAMILY}  TARGET=${TARGET}" > "$MARKER"
echo "INFO: Marker written to $MARKER"

echo "=== TenantOS NetworkConfig: DONE ==="
set +x
