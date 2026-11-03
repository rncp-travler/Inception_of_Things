#!/usr/bin/env bash
# p2 검증 스크립트 (F-P2-01: VM 1대, hostname, 전용 IP, K3s server 노드 Ready
#                   F-P2-02: app1/app2/app3 Deployment·Service, app2 replicas 3
#                   F-P2-03: Ingress, HOST별 라우팅)
# 사용법: p2 디렉터리(Vagrantfile 위치)에서 ./scripts/check.sh
#         LOGIN=다른로그인 ./scripts/check.sh  (기본값: taebkim)
# 결과: 항목별 PASS/FAIL, FAIL이 하나라도 있으면 exit 1
#
# 항목 추가 방법:
#   check_xxx 함수를 만들고 CHECKS에 이름을 넣는다 (P2는 VM이 1대라 전체 1회)

set -u

LOGIN="${LOGIN:-taebkim}"
SERVER="${LOGIN}S"
P1_WORKER="${LOGIN}SW"   # p1에만 있는 VM. 떠 있으면 p1 클러스터가 살아 있다는 뜻
SERVER_IP="192.168.56.110"
WANT_CPUS=2
MAX_MEM_MB=2048
# vagrant up 직후 pod·Traefik이 아직 준비 중일 수 있어 재시도한다
NODES_WAIT_SEC=120
DEPLOY_WAIT_SEC=180
CURL_WAIT_SEC=120
SSH_WAIT_SEC=60   # vagrant up 직후 과부하 중 SSH가 일시적으로 실패할 수 있다
RETRY_SEC=5
APP2_CALLS=12
APPS=(app1 app2 app3)

CHECKS=(check_p1_down check_vagrant_status check_vbox_running
        check_ssh_nopass check_hostname check_iface check_resources
        check_kubectl_nopass check_nodes_ready check_node_ip
        check_deploys check_endpoints check_ingress
        check_route_app1 check_route_app2 check_route_other check_route_ip check_app2_spread
        show_kube_system show_release show_free)

PASS=0
FAIL=0
# kubectl 출력은 한 번 받아 재사용한다 (재시도 항목만 갱신)
NODES=""
DEPLOYS=""
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $1"; }

# BatchMode: 비밀번호를 물으면 기다리지 않고 실패한다
run() { vagrant ssh "$SERVER" -c "$1" -- -o BatchMode=yes -o ConnectTimeout=5 2>/dev/null | tr -d '\r'; }

# K8s 노드 이름은 hostname의 소문자
node_of() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

# ---------------------------------------------------------------
check_p1_down() {
  # P1과 P2는 VM 이름(taebkimS)과 IP(.110)가 같아 동시에 띄울 수 없다
  if VBoxManage list runningvms 2>/dev/null | grep -q "^\"${P1_WORKER}\" "; then
    ko "p1 VM $P1_WORKER 실행 중 (p1에서 vagrant destroy -f 후 다시 실행)"
  else
    ok "p1 VM $P1_WORKER 실행 중 아님"
  fi
}

check_vagrant_status() {
  if vagrant status "$SERVER" --machine-readable 2>/dev/null | grep -q ",state,running"; then
    ok "vagrant status: $SERVER running"
  else
    ko "vagrant status: $SERVER not running"
  fi
}

check_vbox_running() {
  if VBoxManage list runningvms 2>/dev/null | grep -q "^\"${SERVER}\" "; then
    ok "VBoxManage runningvms: $SERVER"
  else
    ko "VBoxManage runningvms: $SERVER 없음"
  fi
}

# run과 같지만 stderr를 숨기지 않는다 (SSH 실패 원인 출력용). 결과는 PROBE_OUT, SSH_ERR
# $(...) 안에서 부르면 subshell이라 전역 변수가 사라지므로 직접 호출한다
PROBE_OUT=""
SSH_ERR=""
run_probe() {
  local errf
  errf="$(mktemp)"
  PROBE_OUT="$(vagrant ssh "$SERVER" -c 'echo ok' -- -o BatchMode=yes -o ConnectTimeout=5 2>"$errf" | tr -d '\r')"
  SSH_ERR="$(tr -d '\r' < "$errf")"
  rm -f "$errf"
}

check_ssh_nopass() {
  # 첫 SSH 호출이라 응답될 때까지 재시도한다. 첫 실패의 stderr는 출력한다
  local deadline=$((SECONDS + SSH_WAIT_SEC)) got line
  run_probe
  got="$PROBE_OUT"
  if [[ "$got" != "ok" ]]; then
    info "vagrant ssh 첫 시도 실패, stderr:"
    while IFS= read -r line; do
      info "  $line"
    done <<< "${SSH_ERR:-(stderr 없음)}"
  fi
  until [[ "$got" == "ok" ]] || (( SECONDS >= deadline )); do
    sleep "$RETRY_SEC"
    got="$(run 'echo ok')"
  done
  if [[ "$got" == "ok" ]]; then
    ok "vagrant ssh 비밀번호 없이 명령 실행"
  else
    ko "vagrant ssh 명령 실행 실패 (${SSH_WAIT_SEC}초 재시도, 비밀번호 요구 또는 접속 불가)"
    info "원인 힌트: 게스트 콘솔(VirtualBox GUI)에서 journalctl -u sshd | grep penalty 확인 (PerSourcePenalties, HANDOFF 트러블슈팅)"
  fi
}

check_hostname() {
  local got
  got="$(run 'hostname')"
  if [[ "$got" == "$SERVER" ]]; then ok "hostname = $got"; else ko "hostname: expected $SERVER, got '$got'"; fi
}

check_iface() {
  # interface 이름은 하드코딩하지 않고 IP로 찾는다
  local iface
  iface="$(run "ip -4 -o addr show | awk -v ip='${SERVER_IP}' 'index(\$4, ip \"/\") == 1 {print \$2}'")"
  if [[ -n "$iface" ]]; then
    ok "ip $SERVER_IP on interface $iface"
  else
    ko "ip $SERVER_IP 을 가진 interface 없음"
  fi
}

check_resources() {
  # nproc = 2는 p1 VM(1 CPU)이 아니라 p2 VM인지도 간접 확인한다
  local cpu mem_kb mem_mb
  cpu="$(run 'nproc')"
  mem_kb="$(run "awk '/^MemTotal:/ {print \$2}' /proc/meminfo")"
  if [[ "$cpu" == "$WANT_CPUS" ]]; then ok "nproc = $cpu"; else ko "nproc: expected $WANT_CPUS, got '$cpu'"; fi
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

get_nodes() { run 'kubectl get nodes -o wide --no-headers'; }

check_kubectl_nopass() {
  # run은 vagrant 사용자로 실행하므로 sudo 없이 kubectl이 되는지 확인된다
  NODES="$(get_nodes)"
  if [[ -n "$NODES" ]]; then
    ok "vagrant 사용자로 sudo 없이 kubectl get nodes"
  else
    ko "kubectl get nodes 실패 (kubectl 없음, kubeconfig 권한 또는 K3s 미동작)"
  fi
}

nodes_ready() {
  awk 'NF { n++; if ($2 == "Ready") r++ } END { exit !(n == 1 && r == 1) }' <<< "$NODES"
}

check_nodes_ready() {
  local deadline=$((SECONDS + NODES_WAIT_SEC))
  # kubectl 자체가 실패했으면 기다려도 소용없으므로 재시도하지 않는다
  if [[ -n "$NODES" ]]; then
    until nodes_ready || (( SECONDS >= deadline )); do
      sleep "$RETRY_SEC"
      NODES="$(get_nodes)"
    done
  fi
  if nodes_ready; then
    ok "노드 1개 Ready"
  else
    ko "노드 1개 Ready 아님 (${NODES_WAIT_SEC}초 대기): $(awk 'NF {printf "%s=%s ", $1, $2}' <<< "$NODES")"
  fi
}

check_node_ip() {
  local node got
  node="$(node_of "$SERVER")"
  got="$(awk -v n="$node" '$1 == n {print $6}' <<< "$NODES")"
  if [[ "$got" == "$SERVER_IP" ]]; then
    ok "node $node INTERNAL-IP = $got"
  else
    ko "node $node INTERNAL-IP: expected $SERVER_IP, got '$got'"
  fi
}

get_deploys() { run 'kubectl get deploy --no-headers'; }

# deploy 이름 → 기대 READY (app2 replicas 3)
want_ready_of() {
  case "$1" in
    app2) echo "3/3" ;;
    *)    echo "1/1" ;;
  esac
}

ready_of() { awk -v d="$1" '$1 == d {print $2}' <<< "$DEPLOYS"; }

deploys_ready() {
  local app
  for app in "${APPS[@]}"; do
    [[ "$(ready_of "$app")" == "$(want_ready_of "$app")" ]] || return 1
  done
}

check_deploys() {
  local deadline=$((SECONDS + DEPLOY_WAIT_SEC)) app got
  DEPLOYS="$(get_deploys)"
  until deploys_ready || (( SECONDS >= deadline )); do
    sleep "$RETRY_SEC"
    DEPLOYS="$(get_deploys)"
  done
  for app in "${APPS[@]}"; do
    got="$(ready_of "$app")"
    if [[ "$got" == "$(want_ready_of "$app")" ]]; then
      ok "deploy $app READY $got"
    else
      ko "deploy $app READY: expected $(want_ready_of "$app"), got '${got:-없음}'"
    fi
  done
}

check_endpoints() {
  # kubectl get endpoints는 v1.33+ deprecated라 EndpointSlice를 본다
  # 컬럼: NAME(<service>-<hash>) ADDRESSTYPE PORTS ENDPOINTS AGE
  local slices app addrs n
  slices="$(run 'kubectl get endpointslices --no-headers')"
  for app in "${APPS[@]}"; do
    addrs="$(awk -v p="${app}-" 'index($1, p) == 1 && $4 != "<unset>" {print $4}' <<< "$slices" | paste -sd ',' -)"
    if [[ -z "$addrs" ]]; then
      ko "service $app endpoints 비어 있음"
      continue
    fi
    n="$(tr ',' '\n' <<< "$addrs" | grep -c .)"
    if [[ "$app" == "app2" && "$n" != "3" ]]; then
      ko "service $app endpoints ${n}개 (expected 3): $addrs"
    else
      ok "service $app endpoints ${n}개: $addrs"
    fi
  done
}

check_ingress() {
  local ing line
  ing="$(run 'kubectl get ingress --no-headers')"
  if [[ -z "$ing" ]]; then
    ko "kubectl get ingress: 없음"
    return
  fi
  ok "kubectl get ingress: $(grep -c . <<< "$ing")개"
  while IFS= read -r line; do
    info "ingress: $line"
  done <<< "$ing"
}

# 호스트 VM에서 요청해 응답 안의 pod 이름(<deploy>-<rs hash>-<id>)을 뽑는다. 인자: Host 헤더 (빈 값이면 IP만)
pod_of() {
  local args=(-s -m 5)
  [[ -n "$1" ]] && args+=(-H "Host: $1")
  curl "${args[@]}" "http://${SERVER_IP}/" 2>/dev/null | grep -oE 'app[123]-[a-z0-9]+-[a-z0-9]+' | head -n 1
}

# Traefik이 준비되기 전에는 연결 실패나 404가 나므로 기대한 app이 나올 때까지 재시도한다
# 인자: Host 헤더(빈 값이면 IP만), 기대 app, 표시 이름
check_route() {
  local host="$1" want="$2" label="$3" deadline=$((SECONDS + CURL_WAIT_SEC)) pod
  pod="$(pod_of "$host")"
  until [[ "$pod" == "${want}-"* ]] || (( SECONDS >= deadline )); do
    sleep "$RETRY_SEC"
    pod="$(pod_of "$host")"
  done
  if [[ "$pod" == "${want}-"* ]]; then
    ok "$label → $pod"
  else
    ko "$label → expected ${want}, got '${pod:-응답 없음}' (${CURL_WAIT_SEC}초 재시도)"
  fi
}

check_route_app1()  { check_route "app1.com" app1 "Host: app1.com"; }
check_route_app2()  { check_route "app2.com" app2 "Host: app2.com"; }
check_route_other() { check_route "foo.com"  app3 "Host: foo.com"; }
check_route_ip()    { check_route ""         app3 "Host 없이 IP만 ($SERVER_IP)"; }

check_app2_spread() {
  # replicas 분산 확인. Traefik 부하 분산 방식에 따라 다를 수 있어 1개면 FAIL이 아니라 INFO
  local i pods uniq n
  pods="$(for ((i = 0; i < APP2_CALLS; i++)); do pod_of "app2.com"; done)"
  uniq="$(grep . <<< "$pods" | sort -u)"
  n="$(grep -c . <<< "$uniq")"
  if (( n >= 2 )); then
    ok "app2.com ${APP2_CALLS}회 호출, 응답 pod ${n}개: $(paste -sd ' ' - <<< "$uniq")"
  else
    info "app2.com ${APP2_CALLS}회 호출, 응답 pod ${n}개: $(paste -sd ' ' - <<< "$uniq")"
  fi
}

show_kube_system() {
  # 기록용, PASS/FAIL 아님
  local pods line
  pods="$(run 'kubectl get pods -n kube-system --no-headers' | awk '{print $1, $2, $3}')"
  if [[ -z "$pods" ]]; then
    info "kube-system pod: (없음 또는 조회 실패)"
    return
  fi
  while IFS= read -r line; do
    info "kube-system pod: $line"
  done <<< "$pods"
}

show_release() {
  # 기록용, PASS/FAIL 아님
  info "release: $(run 'cat /etc/rocky-release 2>/dev/null || echo "(no /etc/rocky-release)"')"
}

show_free() {
  # 기록용, PASS/FAIL 아님
  info "free -m: $(run "free -m | awk '/^Mem:/ {print \"total \" \$2 \" used \" \$3 \" available \" \$7} /^Swap:/ {print \"swap \" \$2}' | paste -sd ' '")"
}

# ---------------------------------------------------------------
if [[ ! -f Vagrantfile ]]; then
  echo "p2 디렉터리(Vagrantfile 위치)에서 실행하세요" >&2
  exit 2
fi

# 호스트 VM에 없으면 항목이 '응답 없음' 등으로 FAIL해 원인이 가려지므로 먼저 확인한다
missing=()
for cmd in curl vagrant VBoxManage; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
  echo "호스트 VM에 없는 명령: ${missing[*]} (curl은 sudo apt install -y curl)" >&2
  exit 2
fi

echo "== $SERVER =="
for check in "${CHECKS[@]}"; do
  "$check"
done

echo
echo "결과: PASS $PASS / FAIL $FAIL"
[[ $FAIL -eq 0 ]]
