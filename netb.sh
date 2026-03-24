#!/usr/bin/env bash
set -euo pipefail

# Share Network: Ethernet -> Ethernet via NetworkManager (Static or Dynamic)
# Usage:
#   1) Auto/dynamic (NM shared mode):
#      sudo netb -ee <ETH_IF> -auto
#
#   2) Static:
#      sudo netb -ee <ETH_IF> <CIDR> [DNS1 [DNS2 ...]]
#      es: sudo netb -ee enp3s0 192.168.2.1/24 1.1.1.1 8.8.8.8
#
# Notes:
#  - ETH_IF is mandatory; Chose a valid ethernet interface as share destination.
#  - <CIDR> must be like 192.168.2.1/24
#  - If no DNS are given in static mode, defaults to "8.8.8.8 8.8.4.4".
#
# Share Network: Wi-Fi -> Ethernet via NetworkManager (Static or Dynamic)
# Usage:
#   1) Auto/dynamic (NM shared mode):
#      sudo netb -we [ETH_IF] -auto
#
#   2) Static:
#      sudo netb -we [ETH_IF] <CIDR> [DNS1 [DNS2 ...]]
#      es: sudo netb -we enp3s0 192.168.2.1/24 1.1.1.1 8.8.8.8
#
# Notes:
#  - ETH_IF is optional; if omitted, the first Ethernet device is used.
#  - <CIDR> must be like 192.168.2.1/24
#  - If no DNS are given in static mode, defaults to "8.8.8.8 8.8.4.4".
#
#
# Disable Network Sharing:
#
#    sudo netb -d [ETH_IF]
# 
# Debug: /tmp/netb-debug.log

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

require() { command -v "$1" >/dev/null 2>&1 || { echo "Err: '$1' not found." >&2; exit 1; }; }
require nmcli
require iptables

usage() {
  sed -n '4,37p' "$0" >&2
  exit 1
}

validate_first_param() {
  local f_param="$1"
  if [[ "$f_param" == "-d" || "$f_param" == "-ee" || "$f_param" == "-we" ]]; then
      return 0
  fi
  usage
}

is_cidr() {
  local cidr="$1"
  local ip mask o1 o2 o3 o4

  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1

  ip="${cidr%/*}"
  mask="${cidr#*/}"

  # Check mask range
  (( mask >= 0 && mask <= 32 )) || return 1

  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

  for o in "$o1" "$o2" "$o3" "$o4"; do
    (( o >= 0 && o <= 255 )) || return 1
  done

  return 0
}

is_ip() {
  is_cidr "$1/32"
}

is_eth_if() {
  [[ -n "${1:-}" && "$1" =~ ^(enp|eno|ens|eth|enx)[0-9a-z]+$ ]]
}

validate_ee() {
  if [[ -z "${1:-}" ]]; then
    usage
  fi

  if is_eth_if "${1:-}"; then
    ETH_IF="${1:-}"
    shift
    if [[ "${1:-}" == "-auto" ]]; then
      MODE="auto"; shift
    elif is_cidr "${1:-}"; then
      MODE="static"
      CIDR="$1"; shift
    else
      echo "Err: Missing address or a route. You can also try -auto option." >&2
      usage
    fi
  else
    echo "Err: Provide a valid ethernet interface a share destination." >&2
    usage
  fi

  if [[ -z "${MODE}" ]]; then
    # Somethig gone wrong → script usage
    echo "Err: Wrong arguments." >&2
    usage
  elif [[ "$MODE" == "auto" && $# -gt 0 ]]; then
    echo "Err: Too many arguments for -auto mode." >&2
    usage
  else
    if [[ "${MODE}" == "static" ]]; then
      # Remaining args are DNS entries
      if [[ $# -gt 0 ]]; then
        for dns in "$@"; do
          is_ip "$dns" || {
            echo "Err: Invalid DNS address: $dns" >&2
            exit 1
          }
        done
        DNS_LIST="$*"
      else
        echo "No DNS provided, using default list 8.8.8.8 8.8.4.4 ..." >&2
        DNS_LIST="8.8.8.8 8.8.4.4"
      fi
    fi
  fi
}

validate_we() {
  if [[ -z "${1:-}" ]]; then
    echo "Err: At least one argument required." >&2
    usage
  fi

  if [[ "${1:-}" == "-auto" ]]; then
    MODE="auto"; shift
    # No ETH_IF provided → we will auto-detect later
  elif is_cidr "${1:-}"; then
    MODE="static"
    CIDR="$1"; shift
    # No ETH_IF provided → we will auto-detect later
  elif is_eth_if "${1:-}"; then
    ETH_IF="${1:-}"
    shift
    if [[ "${1:-}" == "-auto" ]]; then
      MODE="auto"; shift
    elif is_cidr "${1:-}"; then
      MODE="static"
      CIDR="$1"; shift
    else
      echo "Err: Missing address or a route. You can also try -auto option." >&2
      usage
    fi
  fi

  if [[ -z "${MODE}" ]]; then
    # Somethig gone wrong → script usage
    echo "Err: Wrong arguments." >&2
    usage
  elif [[ "$MODE" == "auto" && $# -gt 0 ]]; then
    echo "Err: Too many arguments for -auto mode." >&2
    usage
  else
    if [[ "${MODE}" == "static" ]]; then
      # Remaining args are DNS entries
      if [[ $# -gt 0 ]]; then
        for dns in "$@"; do
          is_ip "$dns" || {
            echo "Err: Invalid DNS address: $dns" >&2
            exit 1
          }
        done
        DNS_LIST="$*"
      else
        echo "No DNS provided, using default list 8.8.8.8 8.8.4.4 ..." >&2
        DNS_LIST="8.8.8.8 8.8.4.4"
      fi
    fi
  fi
}

# ---------- Arg parsing ----------
OPT="${1:-}"
validate_first_param "$OPT"

ETH_IF=""     # eth port name
MODE=""       # "auto" or "static"
CIDR=""       # e.g., 192.168.2.1/24
DNS_LIST=""   # space-separated
CON_NAME=""
TAG=""

if [[ "$OPT" == "-ee" ]]; then
  shift
  validate_ee "$@"
  # ---------- Discover interfaces ethernet ----------
  # Find connected ETH uplink
  UPLINK=$(nmcli -t -f DEVICE,TYPE,STATE device | \
    awk -F: -v skip="$ETH_IF" '$2=="ethernet" && $3=="connected" && $1!=skip {print $1; exit}')

  if [[ "${UPLINK}" = "${ETH_IF}" ]]; then
    echo "Impossible to set source ethernet as destination. Source: ${ETH_IF}, Dest: ${UPLINK}" >&2
  fi
elif [[ "$OPT" == "-we" ]]; then
  shift
  validate_we "$@"
  # ---------- Discover interfaces wi-fi----------
  # Find connected Wi-Fi uplink
  UPLINK=$(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')
  if [[ -z "${UPLINK}" ]]; then
    echo "Err: no connected Wi-Fi interface found. Connect Wi-Fi first." >&2
    exit 1
  fi

  # If ETH_IF not provided, pick the first Ethernet device
  if [[ -z "${ETH_IF}" ]]; then
    ETH_IF=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1; exit}')
  fi
  if [[ -z "${ETH_IF}" ]]; then
    echo "Err: no Ethernet interface found. Use: sudo $0 <ETH_IF> ..." >&2
    nmcli device
    exit 1
  fi
else
  shift
  ETH_IF="${1:-}"

  # Try to discover eth-share-<if>
  if [[ -z "${ETH_IF}" ]]; then
    CON_NAME=$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-3-ethernet" && $1 ~ /^eth-share-/{print $1; exit}')
    if [[ -n "${CON_NAME}" ]]; then
      ETH_IF=$(nmcli -g connection.interface-name connection show "${CON_NAME}")
    else
      ETH_IF=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1; exit}')
    fi
  fi

  if [[ -z "${ETH_IF}" ]]; then
    echo "Err: Ethernet interface not found. Use: sudo $0 <interface_name>" >&2
    nmcli device
    exit 1
  fi

  CON_NAME="eth-share-${ETH_IF}"
  TAG="${CON_NAME}"
  LOG_FILE="/tmp/netb-debug.log"

  echo $(date) | tee -a "${LOG_FILE}"

  echo "==> Disabling shared network for Ethernet: ${ETH_IF}" | tee -a "${LOG_FILE}"

  # Identify uplink (if connected)
  UPLINK=$(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}') || true
  [[ -n "${UPLINK}" ]] && echo "   Detected uplink: ${UPLINK}" | tee -a "${LOG_FILE}"

  ###############################################################################
  #                    REMOVE FIREWALL & NAT RULES (by comment)
  ###############################################################################

  # Remove FORWARD rules tagged with ${TAG}
  # We parse -S output, pick lines with the comment and transform -A into -D for deletion.
  FORWARD_RULES=$(iptables -S FORWARD | grep -F -- "-m comment --comment ${TAG}" || true)
  if [[ -n "${FORWARD_RULES}" ]]; then
    echo "   Removing FORWARD rules tagged [${TAG}]..." | tee -a "${LOG_FILE}"
    # Delete in reverse order to avoid dependency on rule order
    echo "${FORWARD_RULES}" | tac | sed 's/^-A /-D /' | while read -r rule; do
      iptables $rule || true
    done
  else
    echo "   No FORWARD rules tagged [${TAG}] found." | tee -a "${LOG_FILE}"
  fi

  # Remove NAT MASQUERADE tagged with ${TAG} (usually on POSTROUTING)
  NAT_RULES=$(iptables -t nat -S POSTROUTING | grep -F -- "-m comment --comment ${TAG} -j MASQUERADE" || true)
  if [[ -n "${NAT_RULES}" ]]; then
    echo "   Removing NAT MASQUERADE tagged [${TAG}]..." | tee -a "${LOG_FILE}"
    # If rule includes '-o UPLINK', remove with it; otherwise fallback without '-o'
    # Convert -A into -D as above.
    echo "${NAT_RULES}" | tac | sed 's/^-A /-D /' | while read -r rule; do
      iptables -t nat $rule || true
    done
  else
    echo "   No NAT MASQUERADE tagged [${TAG}] found." | tee -a "${LOG_FILE}"
  fi

  # ip_forward: turn off only if there are no other MASQUERADE rules and no other forward accepts
  HAS_MASQ=$(iptables -t nat -S POSTROUTING | grep -q -- '-j MASQUERADE' && echo yes || echo no)
  HAS_FWD_ACCEPT=$(iptables -S FORWARD | grep -q -- '-j ACCEPT' && echo yes || echo no)

  if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then
    if [[ "${HAS_MASQ}" == "no" && "${HAS_FWD_ACCEPT}" == "no" ]]; then
      echo 0 | tee /proc/sys/net/ipv4/ip_forward >/dev/null
      echo "   ip_forward disabled (no other MASQUERADE/ACCEPT forward rules detected)" | tee -a "${LOG_FILE}"
    else
      echo "   ip_forward kept enabled (other forwarding/NAT rules still present)" | tee -a "${LOG_FILE}"
    fi
  fi

  ###############################################################################
  #                REMOVE/DELETE NETWORKMANAGER CONNECTION
  ###############################################################################
  if nmcli -t -f NAME connection show | grep -Fxq "${CON_NAME}"; then
    echo "   Bringing down and deleting NM connection '${CON_NAME}'..." | tee -a "${LOG_FILE}"
    nmcli connection down "${CON_NAME}" || true
    nmcli connection delete "${CON_NAME}" || true
    # Flush residual IPs on the interface
    ip addr flush dev "${ETH_IF}" || true
  else
    echo "   NM connection '${CON_NAME}' not found (nothing to delete)." | tee -a "${LOG_FILE}"
  fi

  echo -e "==> Shared network disabled for ${ETH_IF}.\n\n" | tee -a "${LOG_FILE}"
  ``
  exit 0
fi

# Create log file
LOG_FILE="/tmp/netb-debug.log"
touch "${LOG_FILE}"
echo "$(date)  --  start" | tee -a "${LOG_FILE}"

CON_NAME="eth-share-${ETH_IF}"
TAG="${CON_NAME}"

echo "==> Mode: ${MODE} | uplink: ${UPLINK} | Ethernet LAN: ${ETH_IF}" | tee -a "${LOG_FILE}"

# Ensure the interface is managed by NetworkManager
nmcli device set "${ETH_IF}" managed yes || true

# Create/ensure the Ethernet connection profile exists
if nmcli -t -f NAME connection show | grep -Fxq "${CON_NAME}"; then
  echo "NM: updating existing connection '${CON_NAME}'..." | tee -a "${LOG_FILE}"
else
  echo "NM: creating connection '${CON_NAME}' on ${ETH_IF}..." | tee -a "${LOG_FILE}"
  nmcli connection add type ethernet ifname "${ETH_IF}" con-name "${CON_NAME}" || true
fi

# Helper to remove previously-tagged firewall rules (used when switching to -auto)
remove_tagged_rules() {
  local TAG="$1"
  # Remove FORWARD rules with TAG
  local FR
  FR=$(iptables -S FORWARD | grep -F -- "-m comment --comment ${TAG}" || true)
  if [[ -n "${FR}" ]]; then
    echo "Removing FORWARD rules [${TAG}]..." | tee -a "${LOG_FILE}"
    echo "${FR}" | tac | sed 's/^-A /-D /' | while read -r rule; do iptables $rule || true; done
  fi
  # Remove NAT MASQUERADE with TAG
  local NR
  NR=$(iptables -t nat -S POSTROUTING | grep -F -- "-m comment --comment ${TAG} -j MASQUERADE" || true)
  if [[ -n "${NR}" ]]; then
    echo "Removing NAT MASQUERADE [${TAG}]..." | tee -a "${LOG_FILE}"
    echo "${NR}" | tac | sed 's/^-A /-D /' | while read -r rule; do iptables -t nat $rule || true; done
  fi
}

if [[ "${MODE}" == "auto" ]]; then
  ###########################################################################
  # DYNAMIC (NetworkManager shared)
  ###########################################################################
  # Clean any previous tagged firewall rules from static mode
  remove_tagged_rules "${TAG}"

  nmcli connection modify "${CON_NAME}" \
    ipv4.method shared \
    ipv4.never-default yes \
    ipv6.method ignore \
    connection.autoconnect yes

  nmcli connection up "${CON_NAME}" || true

  echo "NM shared mode enabled on ${ETH_IF}. NAT+DHCP handled by NetworkManager." | tee -a "${LOG_FILE}"

else
  ###########################################################################
  # STATIC (manual IP + our NAT/FORWARD rules)
  ###########################################################################
  # Configure static IP/DNS on the Ethernet LAN
  nmcli connection modify "${CON_NAME}" \
    ipv4.method manual \
    ipv4.addresses "${CIDR}" \
    ipv4.gateway "" \
    ipv4.dns "${DNS_LIST}" \
    ipv6.method ignore \
    connection.autoconnect yes

  # Bring up Ethernet LAN
  nmcli connection up "${CON_NAME}" || true

  # Enable IPv4 forwarding (runtime)
  if [[ -w /proc/sys/net/ipv4/ip_forward ]]; then
    echo 1 | tee /proc/sys/net/ipv4/ip_forward >/dev/null
    echo "ip_forward enabled (runtime)" | tee -a "${LOG_FILE}"
  else
    echo "Warn: cannot write /proc/sys/net/ipv4/ip_forward" | tee -a "${LOG_FILE}"
  fi

  # NAT (MASQUERADE) on uplink
  if ! iptables -t nat -C POSTROUTING -o "${UPLINK}" -m comment --comment "${TAG}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "${UPLINK}" -m comment --comment "${TAG}" -j MASQUERADE
    echo "Added NAT MASQUERADE on ${UPLINK} [${TAG}]" | tee -a "${LOG_FILE}"
  else
    echo "NAT MASQUERADE already present on ${UPLINK} [${TAG}]" | tee -a "${LOG_FILE}"
  fi

  # FORWARD rules (interface-based, no need to compute network)
  if ! iptables -C FORWARD -i "${ETH_IF}" -o "${UPLINK}" -m comment --comment "${TAG}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${ETH_IF}" -o "${UPLINK}" -m comment --comment "${TAG}" -j ACCEPT
    echo "Added FORWARD LAN -> [${TAG}]" | tee -a "${LOG_FILE}"
  else
    echo "FORWARD LAN -> connection already present [${TAG}]" | tee -a "${LOG_FILE}"
  fi

  if ! iptables -C FORWARD -i "${UPLINK}" -o "${ETH_IF}" -m state --state ESTABLISHED,RELATED -m comment --comment "${TAG}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${UPLINK}" -o "${ETH_IF}" -m state --state ESTABLISHED,RELATED -m comment --comment "${TAG}" -j ACCEPT
    echo "Added FORWARD -> LAN (ESTABLISHED,RELATED) [${TAG}]" | tee -a "${LOG_FILE}"
  else
    echo "FORWARD -> LAN already present [${TAG}]" | tee -a "${LOG_FILE}"
  fi
fi

# Final info
IP_INFO=$(nmcli -g IP4.ADDRESS connection show "${CON_NAME}" | head -n1 || true)
GATEWAY=${IP_INFO%%/*}; SUBNET=${IP_INFO#*/}

echo "------------------------------------------------------------" | tee -a "${LOG_FILE}"
echo "Mode: ${MODE}" | tee -a "${LOG_FILE}"
echo "Uplink: ${UPLINK} | Ethernet LAN: ${ETH_IF}" | tee -a "${LOG_FILE}"
if [[ "${MODE}" == "static" ]]; then
  echo "LAN IP: ${CIDR} | DNS: ${DNS_LIST}" | tee -a "${LOG_FILE}"
else
  echo "LAN IP (NM): ${IP_INFO:-unknown} (assigned by NM shared)" | tee -a "${LOG_FILE}"
fi
echo "NM connection: ${CON_NAME}" | tee -a "${LOG_FILE}"
echo -e "------------------------------------------------------------\n" | tee -a "${LOG_FILE}"
``

