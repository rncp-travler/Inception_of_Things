#!/usr/bin/env bash
# p1 테스트 스크립트
# 사용법: p1 디렉터리(Vagrantfile 위치)에서 ./scripts/test.sh
#         LOGIN=다른로그인 ./scripts/test.sh  (기본값: taebkim)
#         ./scripts/test.sh --k3s            (K3s 노드 체크까지 실행)

set -u

LOGIN="${LOGIN:-taebkim}"
SERVER="${LOGIN}S"
WORKER="${LOGIN}SW"
declare -A IP=( ["$SERVER"]="192.168.56.110" ["$WORKER"]="192.168.56.111" )
MAX_MEM_MB=1024
CHECK_K3S=false
[[ "${1:-}" == "--k3s" ]] && CHECK_K3S=true

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
run()  { vagrant ssh "$1" -c "$2" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------
check_running() {
  local name="$1"
  if vagrant status "$name" --machine-readable 2>/dev/null | grep -q ",state,running"; then
    ok "$name running"
  else
    ko "$name not running"
  fi
}

check_hostname() {
  local name="$1" got
  got="$(run "$name" 'hostname')"
  [[ "$got" == "$name" ]] && ok "hostname = $got" || ko "hostname: expected $name, got '$got'"
}

check_ip() {
  local name="$1" want="${IP[$1]}"
  if run "$name" 'ip -4 -o addr show' | grep -q "inet ${want}/"; then
    ok "ip $want 존재"
  else
    ko "ip $want 없음"
  fi
}

check_ssh_nopass() {
  # vagrant ssh 대신 일반 ssh + BatchMode로 비밀번호 프롬프트가 없는지 확인
  local name="$1" cfg
  cfg="$(mktemp)"
  vagrant ssh-config "$name" > "$cfg" 2>/dev/null
  if ssh -F "$cfg" -o BatchMode=yes -o ConnectTimeout=5 "$name" true 2>/dev/null; then
    ok "비밀번호 없이 ssh 접속"
  else
    ko "비밀번호 없는 ssh 실패"
  fi
  rm -f "$cfg"
}

check_resources() {
  local name="$1" cpu mem
  cpu="$(run "$name" 'nproc')"
  mem="$(run "$name" "free -m | awk '/^Mem:/ {print \$2}'")"
  [[ "$cpu" == "1" ]] && ok "CPU = $cpu" || ko "CPU: expected 1, got '$cpu'"
  # free -m 은 커널 예약분 때문에 설정값보다 조금 작게 나옴
  if [[ -n "$mem" && "$mem" -le "$MAX_MEM_MB" ]]; then
    ok "RAM = ${mem}MB (<= ${MAX_MEM_MB})"
  else
    ko "RAM: '${mem}'MB (> ${MAX_MEM_MB} 또는 확인 불가)"
  fi
}

check_k3s() {
  # TODO: 태빈님 K3s 스크립트 머지 후 기준 맞추기
  local out
  out="$(run "$SERVER" 'kubectl get nodes -o wide --no-headers')"
  if [[ -z "$out" ]]; then
    ko "kubectl get nodes 실패 (kubectl 미설치 또는 K3s 미동작)"
    return
  fi
  for name in "$SERVER" "$WORKER"; do
    local node="${name,,}"   # K8s 노드 이름은 소문자
    if echo "$out" | awk -v n="$node" -v ip="${IP[$name]}" \
        '$1==n && $2=="Ready" && $6==ip {found=1} END {exit !found}'; then
      ok "node $node Ready, INTERNAL-IP ${IP[$name]}"
    else
      ko "node $node: Ready/INTERNAL-IP ${IP[$name]} 아님"
    fi
  done
}

# ---------------------------------------------------------------
for name in "$SERVER" "$WORKER"; do
  echo "== $name =="
  check_running "$name"
  check_hostname "$name"
  check_ip "$name"
  check_ssh_nopass "$name"
  check_resources "$name"
done

if $CHECK_K3S; then
  echo "== K3s =="
  check_k3s
fi

echo
echo "결과: PASS $PASS / FAIL $FAIL"
[[ $FAIL -eq 0 ]]
