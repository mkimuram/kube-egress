#!/usr/bin/env bash
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

function handle_rule() {
  local action=${1}
  local table=${2}
  local chain=${3}
  shift 3

  #iptables -t ${table} -C ${chain} $@ 2>/dev/null
  #if [ $? -eq 0 ];then
  if (iptables -t ${table} -C ${chain} $@ 2>/dev/null);then
    if [ ${action} == "-A" ] || [ ${action} == "-I" ] || [ ${action} == "-N" ];then
      # Trying to add/insert existing rule or to create existing chain
      return
    fi
  else
    if [ ${action} == "-D" ];then
      # Trying to delete non-existing rule
       return
    fi
  fi

  iptables -t ${table} ${action} ${chain} $@ 2>/dev/null || true
}

function add_egress_node_rule() {
  local pod_ip=${1}
  local interface=${2}
  local route_id=${3}
  local vip=${4}

  handle_rule -A mangle FORWARD -s "${pod_ip}" -i "${interface}" -o "${interface}" -j MARK --set-mark "${route_id}/${route_id}"
  handle_rule -I nat POSTROUTING -o "${interface}" -m mark --mark "${route_id}/${route_id}" -j SNAT --to "${vip}"
}

function del_egress_node_rule() {
  local pod_ip=${1}
  local interface=${2}
  local route_id=${3}
  local vip=${4}

  handle_rule -D mangle FORWARD -s "${pod_ip}" -i "${interface}" -o "${interface}" -j MARK --set-mark "${route_id}/${route_id}"
  handle_rule -D nat POSTROUTING -o "${interface}" -m mark --mark "${route_id}/${route_id}" -j SNAT --to "${vip}"
}

function add_nonegress_node_rule() {
  local route_id=${1}
  local route_table=${2}
  local vip=${3}
  local interface=${4}

  if ! (grep -q "${route_id} ${route_table}" "/etc/iproute2/rt_tables.d/${route_table}.conf");then
    echo "${route_id} ${route_table}" > "/etc/iproute2/rt_tables.d/${route_table}.conf"
  fi
  ip route add default via "${vip}" dev "${interface}" table "${route_table}" 2>/dev/null || true
  ip rule add fwmark "${route_id}/${route_id}" table "${route_table}"  2>/dev/null || true
}

function del_nonegress_node_rule() {
  local route_table=${1}

  ip rule del table "${route_table}" 2>/dev/null || true
  ip route flush table "${route_table}" 2>/dev/null || true
  rm -f "/etc/iproute2/rt_tables.d/${route_table}.conf"
}

function apply() {
  log "Applying common iptables rules"
  handle_rule -N mangle EGRESS
  handle_rule -A mangle EGRESS -d "${POD_SUBNET}" -j RETURN
  handle_rule -A mangle EGRESS -d "${SERVICE_SUBNET}" -j RETURN
  handle_rule -A mangle PREROUTING -j EGRESS

  log "Applying iptables rules for each egress ip and pod ip"
  for POD_IP in "${!PODIP_VIP_MAPPINGS[@]}"; do
    VIP="${PODIP_VIP_MAPPINGS[$POD_IP]}"
    ROUTE_ID="${VIP_ROUTEID_MAPPINGS[$VIP]}"
    ROUTE_TABLE="${ROUTE_TABLE_PREFIX}_${ROUTE_ID}"

    handle_rule -A mangle EGRESS -s "${POD_IP}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}"
    handle_rule -A nat POSTROUTING -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j RETURN

    if (ip -o addr show "${INTERFACE}" | grep -Fq "${VIP}"); then
      log "VIP ${VIP} transitioned to primary"
      add_egress_node_rule ${POD_IP} ${INTERFACE} ${ROUTE_ID} ${VIP}
      del_nonegress_node_rule ${ROUTE_TABLE}
      log "Egress for ${VIP} now enabled on node ${HOSTNAME}"
    else
      log "VIP ${VIP} transitioned to secondary"
      del_egress_node_rule ${POD_IP} ${INTERFACE} ${ROUTE_ID} ${VIP}
      add_nonegress_node_rule ${ROUTE_ID} ${ROUTE_TABLE} ${VIP} ${INTERFACE}
      log "Egress for ${VIP} now disabled on node ${HOSTNAME}"
    fi
  done

  ip route flush cache
}

function delete() {
  log "Deleting iptables rules for each egress ip and pod ip"
  for POD_IP in "${!PODIP_VIP_MAPPINGS[@]}"; do
    VIP="${PODIP_VIP_MAPPINGS[$POD_IP]}"
    ROUTE_ID="${VIP_ROUTEID_MAPPINGS[$VIP]}"
    ROUTE_TABLE="${ROUTE_TABLE_PREFIX}_${ROUTE_ID}"

    handle_rule -D mangle EGRESS -s "${POD_IP}" -j MARK --set-mark "${ROUTE_ID}/${ROUTE_ID}"
    handle_rule -D nat POSTROUTING -m mark --mark "${ROUTE_ID}/${ROUTE_ID}" -j RETURN

    del_nonegress_node_rule ${ROUTE_TABLE}
    del_egress_node_rule ${POD_IP} ${INTERFACE} ${ROUTE_ID} ${VIP}
  done

  ip route flush cache

  log "Deleting common iptables rules"
  iptables -t mangle -F EGRESS 2>/dev/null || true
  iptables -t mangle -X EGRESS 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j EGRESS 2>/dev/null || true
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

declare -A PODIP_VIP_MAPPINGS
declare -A VIP_ROUTEID_MAPPINGS
reload_mappings

if [ $DELETE == true ];then
  delete
  exit 0
else
  apply
fi

while [[ -n "${UPDATE_INTERVAL}" ]]; do
  sleep "${UPDATE_INTERVAL}"

  unset PODIP_VIP_MAPPINGS
  unset VIP_ROUTEID_MAPPINGS
  declare -A PODIP_VIP_MAPPINGS
  declare -A VIP_ROUTEID_MAPPINGS
  reload_mappings

  apply
done

exit 0
