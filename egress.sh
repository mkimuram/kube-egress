#!/usr/bin/env bash
#!/bin/bash -x
#
# Debugging:
# sudo iptables -nvL -t mangle
# sudo iptables -t raw -I PREROUTING -j TRACE
# sudo iptables -t mangle -A EGRESS -j LOG --log-prefix "egress: " --log-level 4
# sudo tail -f /var/log/syslog | grep "egress: "

set -e

# Parse Options
NAME=$(basename $0 | tr - ' ')
OPTS=$(getopt --options dhi:p:r:s:u:v: --longoptions delete,help,interface:,pod-subnet:,vip-routeid-mappings:,service-subnet:,update-interval:,podip-vip-mappings: --name "$NAME" -- "$@")
[[ $? != 0 ]] && echo "Failed parsing options" >&2 && exit 1
eval set -- "$OPTS"

# Variables
INTERFACE="eth0"
POD_SUBNET="10.32.0.0/12"
SERVICE_SUBNET="10.96.0.0/12"
ROUTE_TABLE_PREFIX="egress"
PODIP_VIP_MAPPING_DIR="config/podip_vip_mapping/"
VIP_ROUTEID_MAPPING_DIR="config/vip_routeid_mapping/"
UPDATE_INTERVAL=
DELETE=false

# Functions
function help() {
  cat << EOF
Redirects container traffic from all nodes to the node with the VIP

Usage:
  $NAME [options]

Options:
  -d, --delete               Deletes all iptables and routing rules associated with the egress and exit
  -h, --help                 Displays the help text
  -i, --interface            The network interface to use. Default is ${INTERFACE}
  -p, --pod-subnet           The Kubernetes pod IP allocation range. Default is ${POD_SUBNET}
  -r, --vip-routeid-mappings The directory that contains mappings from VIP to route ID. Default is ${VIP_ROUTEID_MAPPING_DIR}
  -s, --service-subnet       The Kubernetes service IP allocation range. Default is ${SERVICE_SUBNET}
  -u, --update-interval      How often to check to see if the rules need to be updated based upon VIP changes. Default is empty for run once
  -v, --podip-vip-mappings   The directory that contains mappings from Pod IP to VIP. Default is ${PODIP_VIP_MAPPING_DIR}
EOF
}

function reload_mappings() {
  while read config;do
    PODIP_VIP_MAPPINGS["${config}"]=$(cat "${PODIP_VIP_MAPPING_DIR}/${config}")
  done <<< "$(ls ${PODIP_VIP_MAPPING_DIR})"

  while read config;do
    VIP_ROUTEID_MAPPINGS["${config}"]=$(cat "${VIP_ROUTEID_MAPPING_DIR}/${config}")
  done <<< "$(ls ${VIP_ROUTEID_MAPPING_DIR})"
}

function log() {
  local message="${1}"
  local timestamp=$(date -Iseconds)
  echo "${timestamp} ${message}"
}

function apply() {
  log "Applying common iptables rules"
  iptables -t mangle -N EGRESS
  iptables -t mangle -A EGRESS -d "${POD_SUBNET}" -j RETURN
  iptables -t mangle -A EGRESS -d "${SERVICE_SUBNET}" -j RETURN
  iptables -t mangle -A PREROUTING -j EGRESS

  unset configured_vips
  declare -A configured_vips

  for POD_IP in "${!PODIP_VIP_MAPPINGS[@]}"; do
    VIP="${PODIP_VIP_MAPPINGS[$POD_IP]}"
    ROUTE_ID="${VIP_ROUTEID_MAPPINGS[$VIP]}"
    ROUTE_TABLE="${ROUTE_TABLE_PREFIX}_${ROUTE_ID}"

    iptables -t mangle -A EGRESS -s "${POD_IP}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}"

    if (ip -o addr show "${INTERFACE}" | grep -Fq "${VIP}"); then
      log "VIP ${VIP} for ${POD_IP} transitioned to primary"
      iptables -t mangle -A FORWARD -s "${POD_IP}" -i "${INTERFACE}" -o "${INTERFACE}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}"
      iptables -t nat -I POSTROUTING -o "${INTERFACE}" -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j SNAT --to "${VIP}"
    else
      if [[ -z "${configured_vips[$VIP]+unset}" ]]; then
        log "VIP ${VIP} transitioned to secondary"
        iptables -t nat -I POSTROUTING -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j RETURN
        echo "${ROUTE_ID} ${ROUTE_TABLE}" > "/etc/iproute2/rt_tables.d/${ROUTE_TABLE}.conf"
        ip route add default via "${VIP}" dev "${INTERFACE}" table "${ROUTE_TABLE}"
        ip rule add fwmark "${ROUTE_ID}" table "${ROUTE_TABLE}"
        configured_vips["${VIP}"]=true
      fi
    fi
  done

  ip route flush cache
}

function delete() {
  for POD_IP in "${!PODIP_VIP_MAPPINGS[@]}"; do
    VIP="${PODIP_VIP_MAPPINGS[$POD_IP]}"
    ROUTE_ID="${VIP_ROUTEID_MAPPINGS[$VIP]}"
    ROUTE_TABLE="${ROUTE_TABLE_PREFIX}_${ROUTE_ID}"

    log "Deleting rule for VIP ${VIP} for ${POD_IP}"
    iptables -t mangle -D EGRESS -s "${POD_IP}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}" 2>/dev/null || true

    iptables -t mangle -D FORWARD -s "${POD_IP}" -i "${INTERFACE}" -o "${INTERFACE}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "${INTERFACE}" -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j SNAT --to "${VIP}" 2>/dev/null || true

    ip rule del table "${ROUTE_TABLE}" 2>/dev/null || true
    ip route flush table "${ROUTE_TABLE}" 2>/dev/null || true
    rm -f "/etc/iproute2/rt_tables.d/${ROUTE_TABLE}.conf"
    iptables -t nat -D POSTROUTING -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j RETURN 2>/dev/null || true
  done

  ip route flush cache

  log "Deleting common iptables rules"
  iptables -t mangle -F EGRESS 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j EGRESS 2>/dev/null || true
  iptables -t mangle -X EGRESS 2>/dev/null || true
}

while true
do
  case "$1" in
    -d | --delete)
      DELETE=true
      shift
      ;;
    -h | --help)
      help
      exit 0
      ;;
    -i | --interface)
      INTERFACE="${2:-$INTERFACE}"
      shift 2
      ;;
    -p | --pod-subnet)
      POD_SUBNET="${2:-$POD_SUBNET}"
      shift 2
      ;;
    -r | --vip-routeid-mappings)
      VIP_ROUTEID_MAPPING_DIR="${2:-$VIP_ROUTEID_MAPPING_DIR}"
      shift 2
      ;;
    -s | --service-subnet)
      SERVICE_SUBNET="${2:-$SERVICE_SUBNET}"
      shift 2
      ;;
    -u | --update-interval)
      UPDATE_INTERVAL="${2:-$UPDATE_INTERVAL}"
      shift 2
      ;;
    -v | --podip-vip-mappings)
      PODIP_VIP_MAPPING_DIR="${2:-$PODIP_VIP_MAPPING_DIR}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
  esac
done

# Verify interface exists
ip addr show "${INTERFACE}" >/dev/null

trap "echo Stopping $NAME; if [ -n "${UPDATE_INTERVAL}" ];then delete; fi" SIGTERM SIGINT

declare -A PODIP_VIP_MAPPINGS
declare -A VIP_ROUTEID_MAPPINGS
reload_mappings

while :; do
  delete
  if [ $DELETE == true ];then
    exit 0
  fi

  unset PODIP_VIP_MAPPINGS
  unset VIP_ROUTEID_MAPPINGS
  declare -A PODIP_VIP_MAPPINGS
  declare -A VIP_ROUTEID_MAPPINGS
  reload_mappings
  apply

  if [[ -z "${UPDATE_INTERVAL}" ]];then
    exit 0
  fi
  sleep "${UPDATE_INTERVAL}"
done

exit 0
