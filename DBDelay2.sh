#!/usr/bin/env bash
set -euo pipefail

TEST_NETWORK_NAME="myTestBridge"
COMPOSE_FILE="docker-compose.yml"
INFO_FILE="container_bridge_info.txt"
LOG_FILE="containers_update.log"

usage() {
  cat <<'USAGE'
Docker Bridge Network Emulator

Usage:
  sudo ./DBDelay.sh test <container-count> <htb|cbq>
  sudo ./DBDelay.sh modify <docker-network-name> [htb|cbq]
  sudo ./DBDelay.sh clean
  ./DBDelay.sh --help

Examples:
  sudo ./DBDelay.sh test 3 htb
  sudo ./DBDelay.sh modify my_existing_network htb
  sudo ./DBDelay.sh clean

Notes:
  - <docker-network-name> is the Docker network name shown by: docker network ls
  - htb is the recommended default. cbq is kept for comparison/legacy testing.
USAGE
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "ERROR: neither 'docker compose' nor 'docker-compose' is available." >&2
    exit 1
  fi
}

validate_class() {
  local class_type="$1"
  if [[ "$class_type" != "htb" && "$class_type" != "cbq" ]]; then
    echo "ERROR: traffic-control class must be either 'htb' or 'cbq'." >&2
    exit 1
  fi
}

cleanup() {
  echo "Cleaning generated test containers and network..."

  docker ps -a --format '{{.Names}}' \
    | grep -E '^client[0-9]+$' \
    | xargs -r docker rm -f

  docker network rm "$TEST_NETWORK_NAME" >/dev/null 2>&1 || true

  rm -f "$COMPOSE_FILE" "$INFO_FILE" "$LOG_FILE"
}

create_test_network() {
  local container_count="$1"

  if ! [[ "$container_count" =~ ^[0-9]+$ ]] || [[ "$container_count" -lt 2 ]]; then
    echo "ERROR: container-count must be an integer >= 2." >&2
    exit 1
  fi

  cat > "$COMPOSE_FILE" <<YAML
networks:
  testNet:
    name: ${TEST_NETWORK_NAME}
    driver: bridge

services:
YAML

  for i in $(seq 1 "$container_count"); do
    cat >> "$COMPOSE_FILE" <<YAML
  client${i}:
    container_name: client${i}
    build: ./client
    tty: true
    networks:
      - testNet

YAML
  done

  compose_cmd -f "$COMPOSE_FILE" up --build -d
}

CONTAINER_NAMES=()
CONTAINER_IPS=()
CONTAINER_VETHS=()

load_network_info() {
  local network_name="$1"

  : > "$INFO_FILE"
  CONTAINER_NAMES=()
  CONTAINER_IPS=()
  CONTAINER_VETHS=()

  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    echo "ERROR: Docker network '$network_name' does not exist." >&2
    exit 1
  fi

  echo "Detected containers on Docker network '$network_name':"

  while read -r container_name cidr_ip; do
    [[ -z "${container_name:-}" || -z "${cidr_ip:-}" ]] && continue

    local container_ip="${cidr_ip%%/*}"
    local iflink
    local host_veth

    iflink="$(docker exec "$container_name" cat /sys/class/net/eth0/iflink)"
    host_veth="$(ip -o link show | awk -F': ' -v idx="$iflink" '$1 == idx {print $2}' | cut -d '@' -f 1)"

    if [[ -z "$host_veth" ]]; then
      echo "ERROR: could not map container '$container_name' eth0 to host-side veth." >&2
      exit 1
    fi

    printf '%s %s %s\n' "$container_name" "$container_ip" "$host_veth" | tee -a "$INFO_FILE"

    CONTAINER_NAMES+=("$container_name")
    CONTAINER_IPS+=("$container_ip")
    CONTAINER_VETHS+=("$host_veth")
  done < <(docker network inspect "$network_name" --format '{{range .Containers}}{{printf "%s %s\n" .Name .IPv4Address}}{{end}}')

  if [[ "${#CONTAINER_NAMES[@]}" -lt 2 ]]; then
    echo "ERROR: at least two containers must be attached to the network." >&2
    exit 1
  fi
}

configure_root_qdisc() {
  local veth="$1"
  local class_type="$2"
  local total_bw="$3"

  if [[ "$class_type" == "htb" ]]; then
    tc qdisc replace dev "$veth" root handle 1: htb
    tc class add dev "$veth" parent 1: classid 1:1 htb rate "$total_bw" ceil "$total_bw"
  else
    tc qdisc replace dev "$veth" root handle 1: cbq bandwidth "$total_bw" avpkt 1000
    tc class add dev "$veth" parent 1: classid 1:1 cbq bandwidth "$total_bw" rate "$total_bw" allot 1514 avpkt 1000
  fi
}

configure_flow_class() {
  local veth="$1"
  local class_type="$2"
  local parent_bw="$3"
  local class_id="$4"
  local src_ip="$5"
  local flow_bw="$6"
  local delay="$7"

  if [[ "$class_type" == "htb" ]]; then
    tc class add dev "$veth" parent 1:1 classid "1:${class_id}" htb rate "$flow_bw" ceil "$flow_bw"
  else
    tc class add dev "$veth" parent 1:1 classid "1:${class_id}" cbq bandwidth "$parent_bw" rate "$flow_bw" allot 1514 avpkt 1000
  fi

  tc filter add dev "$veth" parent 1: protocol ip u32 match ip src "${src_ip}/32" flowid "1:${class_id}"
  tc qdisc replace dev "$veth" parent "1:${class_id}" handle "${class_id}0:" netem delay "$delay"
}

apply_rules() {
  local class_type="$1"
  validate_class "$class_type"

  echo
  echo "Starting traffic-control configuration using '$class_type'..."
  echo

  for dst_idx in "${!CONTAINER_VETHS[@]}"; do
    local dst_name="${CONTAINER_NAMES[$dst_idx]}"
    local dst_veth="${CONTAINER_VETHS[$dst_idx]}"
    local total_bw

    echo ">>>>>>>>>>>>>>>>>>>>>"
    echo "Destination container : $dst_name"
    echo "Host-side veth        : $dst_veth"
    read -r -p "Total inbound bandwidth for $dst_name, e.g. 100Mbit: " total_bw

    configure_root_qdisc "$dst_veth" "$class_type" "$total_bw"

    local class_id=1
    for src_idx in "${!CONTAINER_NAMES[@]}"; do
      [[ "$src_idx" == "$dst_idx" ]] && continue

      local src_name="${CONTAINER_NAMES[$src_idx]}"
      local src_ip="${CONTAINER_IPS[$src_idx]}"
      local flow_bw
      local delay

      read -r -p "Bandwidth $src_name -> $dst_name, e.g. 10Mbit: " flow_bw
      read -r -p "Delay $src_name -> $dst_name, e.g. 100ms: " delay

      class_id=$((class_id + 1))
      configure_flow_class "$dst_veth" "$class_type" "$total_bw" "$class_id" "$src_ip" "$flow_bw" "$delay"

      echo "Applied: src=$src_name($src_ip) dst=$dst_name veth=$dst_veth bw=$flow_bw delay=$delay"
      echo "--------------"
    done
  done
}

main() {
  local mode="${1:-}"

  case "$mode" in
    clean)
      cleanup
      ;;
    test)
      if [[ "$#" -ne 3 ]]; then
        usage
        exit 1
      fi
      local container_count="$2"
      local class_type="$3"
      validate_class "$class_type"
      cleanup
      create_test_network "$container_count"
      load_network_info "$TEST_NETWORK_NAME"
      apply_rules "$class_type"
      ;;
    modify)
      if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
        usage
        exit 1
      fi
      local network_name="$2"
      local class_type="${3:-htb}"
      validate_class "$class_type"
      load_network_info "$network_name"
      apply_rules "$class_type"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "ERROR: unknown mode '$mode'." >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
