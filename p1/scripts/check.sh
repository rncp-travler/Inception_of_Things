#!/usr/bin/env bash
# p1 검증 스크립트 (F-P1-01: VM 2대, hostname, 전용 IP, 비밀번호 없는 ssh, 리소스
#                   F-P1-02/03: K3s 노드 2개 Ready, INTERNAL-IP, control-plane, sudo 없는 kubectl)
# 사용법: p1 디렉터리(Vagrantfile 위치)에서 ./scripts/check.sh
#         LOGIN=다른로그인 ./scripts/check.sh  (기본값: taebkim)
# 결과: 항목별 PASS/FAIL, FAIL이 하나라도 있으면 exit 1
#
# 항목 추가 방법 (F-P1-02/03 K3s 등):
#   check_xxx 함수를 만들고 GLOBAL_CHECKS(전체 1회) 또는 VM_CHECKS(VM마다, 인자 = VM 이름)에 이름을 넣는다

set -u

LOGIN="${LOGIN:-taebkim}"
SERVER="${LOGIN}S"
WORKER="${LOGIN}SW"
SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"
VMS=("$SERVER" "$WORKER")
MAX_MEM_MB=1024
# vagrant up 직후 agent가 아직 NotReady일 수 있어 Ready 판정은 재시도한다
NODES_WAIT_SEC=120
NODES_RETRY_SEC=5

GLOBAL_CHECKS=(check_vagrant_status check_vbox_running
               check_kubectl_nopass check_nodes_ready check_node_ips check_control_plane)
VM_CHECKS=(check_ssh_nopass check_hostname check_iface check_ping check_resources show_release show_free)

PASS=0
FAIL=0
# kubectl get nodes 출력. check_kubectl_nopass가 채우고 check_nodes_ready가 갱신, 이후 K3s 항목이 재사용
NODES=""
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $1"; }

# BatchMode: 비밀번호를 물으면 기다리지 않고 실패한다
run() { vagrant ssh "$1" -c "$2" -- -o BatchMode=yes -o ConnectTimeout=5 2>/dev/null | tr -d '\r'; }

ip_of() {
  case "$1" in
    "$SERVER") echo "$SERVER_IP" ;;
    "$WORKER") echo "$WORKER_IP" ;;
  esac
}

peer_of() {
  case "$1" in
    "$SERVER") echo "$WORKER" ;;
    "$WORKER") echo "$SERVER" ;;
  esac
}

# ---------------------------------------------------------------
check_vagrant_status() {
  local name
  for name in "${VMS[@]}"; do
    if vagrant status "$name" --machine-readable 2>/dev/null | grep -q ",state,running"; then
      ok "vagrant status: $name running"
    else
      ko "vagrant status: $name not running"
    fi
  done
}

check_vbox_running() {
  local name list
  list="$(VBoxManage list runningvms 2>/dev/null)"
  for name in "${VMS[@]}"; do
    if grep -q "^\"${name}\" " <<< "$list"; then
      ok "VBoxManage runningvms: $name"
    else
      ko "VBoxManage runningvms: $name 없음"
    fi
  done
}

check_ssh_nopass() {
  local name="$1" got
  got="$(run "$name" 'echo ok')"
  if [[ "$got" == "ok" ]]; then ok "vagrant ssh 비밀번호 없이 명령 실행"; else ko "vagrant ssh 명령 실행 실패 (비밀번호 요구 또는 접속 불가)"; fi
}

check_hostname() {
  local name="$1" got
  got="$(run "$name" 'hostname')"
  if [[ "$got" == "$name" ]]; then ok "hostname = $got"; else ko "hostname: expected $name, got '$got'"; fi
}

check_iface() {
  # interface 이름은 하드코딩하지 않고 IP로 찾는다
  local name="$1" want iface
  want="$(ip_of "$name")"
  iface="$(run "$name" "ip -4 -o addr show | awk -v ip='${want}' 'index(\$4, ip \"/\") == 1 {print \$2}'")"
  if [[ -n "$iface" ]]; then
    ok "ip $want on interface $iface"
  else
    ko "ip $want 을 가진 interface 없음"
  fi
}

check_ping() {
  local name="$1" peer peer_ip
  peer="$(peer_of "$name")"
  peer_ip="$(ip_of "$peer")"
  if [[ "$(run "$name" "ping -c 2 -W 2 ${peer_ip} >/dev/null 2>&1 && echo ok")" == "ok" ]]; then
    ok "ping $peer ($peer_ip)"
  else
    ko "ping $peer ($peer_ip) 실패"
  fi
}

check_resources() {
  local name="$1" cpu mem_kb mem_mb
  cpu="$(run "$name" 'nproc')"
  mem_kb="$(run "$name" "awk '/^MemTotal:/ {print \$2}' /proc/meminfo")"
  if [[ "$cpu" == "1" ]]; then ok "nproc = $cpu"; else ko "nproc: expected 1, got '$cpu'"; fi
  # MemTotal은 커널 예약분 때문에 설정값보다 조금 작게 나온다
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    mem_mb=$((mem_kb / 1024))
    if (( mem_mb <= MAX_MEM_MB )); then
      ok "MemTotal = ${mem_mb}MB (<= ${MAX_MEM_MB})"
    else
      ko "MemTotal = ${mem_mb}MB (> ${MAX_MEM_MB})"
    fi
  else
    ko "MemTotal 확인 불가 ('${mem_kb}')"
  fi
}

# K8s 노드 이름은 hostname의 소문자
node_of() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

get_nodes() { run "$SERVER" 'kubectl get nodes -o wide --no-headers'; }

check_kubectl_nopass() {
  # run은 vagrant 사용자로 실행하므로 sudo 없이 kubectl이 되는지 확인된다
  NODES="$(get_nodes)"
  if [[ -n "$NODES" ]]; then
    ok "$SERVER: vagrant 사용자로 sudo 없이 kubectl get nodes"
  else
    ko "$SERVER: kubectl get nodes 실패 (kubectl 없음, kubeconfig 권한 또는 K3s 미동작)"
  fi
}

nodes_all_ready() {
  awk 'NF { n++; if ($2 == "Ready") r++ } END { exit !(n == 2 && r == 2) }' <<< "$NODES"
}

check_nodes_ready() {
  local deadline=$((SECONDS + NODES_WAIT_SEC))
  # kubectl 자체가 실패했으면 기다려도 소용없으므로 재시도하지 않는다
  if [[ -n "$NODES" ]]; then
    until nodes_all_ready || (( SECONDS >= deadline )); do
      sleep "$NODES_RETRY_SEC"
      NODES="$(get_nodes)"
    done
  fi
  if nodes_all_ready; then
    ok "노드 2개 모두 Ready"
  else
    ko "노드 2개 Ready 아님 (${NODES_WAIT_SEC}초 대기): $(awk 'NF {printf "%s=%s ", $1, $2}' <<< "$NODES")"
  fi
}

check_node_ips() {
  local name node want got
  for name in "${VMS[@]}"; do
    node="$(node_of "$name")"
    want="$(ip_of "$name")"
    got="$(awk -v n="$node" '$1 == n {print $6}' <<< "$NODES")"
    if [[ "$got" == "$want" ]]; then
      ok "node $node INTERNAL-IP = $got"
    else
      ko "node $node INTERNAL-IP: expected $want, got '$got'"
    fi
  done
}

check_control_plane() {
  local node roles
  node="$(node_of "$SERVER")"
  roles="$(awk -v n="$node" '$1 == n {print $3}' <<< "$NODES")"
  if [[ ",$roles," == *",control-plane,"* ]]; then
    ok "node $node ROLES = $roles"
  else
    ko "node $node control-plane 아님 (ROLES '$roles')"
  fi
}

show_release() {
  # 기록용, PASS/FAIL 아님
  local name="$1"
  info "release: $(run "$name" 'cat /etc/rocky-release 2>/dev/null || echo "(no /etc/rocky-release)"')"
}

show_free() {
  # 기록용, PASS/FAIL 아님
  local name="$1"
  info "free -m: $(run "$name" "free -m | awk '/^Mem:/ {print \"total \" \$2 \" used \" \$3 \" available \" \$7} /^Swap:/ {print \"swap \" \$2}' | paste -sd ' '")"
}

# ---------------------------------------------------------------
if [[ ! -f Vagrantfile ]]; then
  echo "p1 디렉터리(Vagrantfile 위치)에서 실행하세요" >&2
  exit 2
fi

echo "== global =="
for check in "${GLOBAL_CHECKS[@]}"; do
  "$check"
done

for name in "${VMS[@]}"; do
  echo "== $name =="
  for check in "${VM_CHECKS[@]}"; do
    "$check" "$name"
  done
done

echo
echo "결과: PASS $PASS / FAIL $FAIL"
[[ $FAIL -eq 0 ]]
