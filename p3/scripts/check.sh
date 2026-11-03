#!/usr/bin/env bash
# p3 검증 스크립트 (F-P3-01: 도구 버전, docker 권한
#                   F-P3-02: k3d 클러스터, 8888 매핑, ns argocd/dev, Argo CD
#                   F-P3-03/04: Application 설정·Synced/Healthy, dev 앱 버전, localhost:8888 응답)
# 사용법: ./check.sh v1|v2  (어느 디렉터리에서 실행해도 된다. 인자 = GitHub repo에 올라가 있는 이미지 태그)
#         WAIT_SEC=180 ./check.sh v2  (재시도 항목 전체 대기, 기본 90초)
# 결과: 항목별 PASS/FAIL, FAIL이 하나라도 있으면 exit 1. 사용법·사전 조건 오류는 exit 2
#
# 버전 기대값은 versions.env에서 읽는다. Docker는 버전을 고정하지 않아 sudo 없이 docker info 성공만 본다
# push 직후 바로 실행해도 되도록 앱 버전·응답·sync 상태는 WAIT_SEC 동안 재시도한다
# kubectl·docker·k3d·curl 호출마다 timeout을 둔다 (host 재부팅 후 클러스터 장애 중 check.sh가 끝나지 않은 적 있음)
# host 재부팅 후에는 ./clean.sh && ./setup.sh 로 다시 만든다 (node IP가 바뀌어 클러스터 내부 DNS가 깨진 사례, DECISIONS D9)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$SCRIPT_DIR/versions.env"

CLUSTER="iot-p3"
KCTX="k3d-${CLUSTER}"
ARGOCD_NS="argocd"
APP_NS="dev"
APP_NAME="wil-playground"   # Argo CD Application, Deployment 이름
APP_PORT=8888
APP_IMAGE="wil42/playground"
REPO_URL="https://github.com/KimTaebin-ai/taebkim-iot-p3.git"
REPO_PATH="manifests"
WAIT_SEC="${WAIT_SEC:-90}"
RETRY_SEC="${RETRY_SEC:-5}"
CALL_SEC=5        # kubectl·docker·k3d 호출 하나의 상한
LSREMOTE_SEC=20   # repo-server 안 git ls-remote 상한

CHECKS=(check_docker check_k3d_version check_kubectl_version
        check_cluster check_port check_api check_nodes check_node_version check_ns
        check_argocd_pods check_argocd_version check_reconciliation check_app_spec check_repo_access
        check_app_image check_app_pods check_curl check_app_status)
# Kubernetes API가 필요한 항목. check_api가 실패하면 하나씩 timeout을 기다리지 않고 생략한다
KUBE_CHECKS=(check_nodes check_node_version check_ns check_argocd_pods check_argocd_version check_reconciliation
             check_app_spec check_repo_access check_app_image check_app_pods check_app_status)

PASS=0
FAIL=0
RETRY_DEADLINE=""   # 재시도 항목이 공유하는 마감 시각 (첫 재시도 항목에서 정한다)
API_OK=1
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $1"; }

# 인자: 접두어, 여러 줄 문자열. 빈 줄은 건너뛴다
info_lines() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && info "$1$line"
  done <<< "$2"
}

# 다른 kubeconfig context가 있어도 이 클러스터만 본다
# --request-timeout은 API 요청에만 걸리므로 바깥에 timeout(1)도 둔다
k()  { timeout $((CALL_SEC + 2)) kubectl --context "$KCTX" --request-timeout="${CALL_SEC}s" "$@" 2>/dev/null; }
d()  { timeout "$CALL_SEC" docker "$@"; }
k3() { timeout "$CALL_SEC" k3d "$@"; }

needs_api() {
  local c
  for c in "${KUBE_CHECKS[@]}"; do
    [[ "$c" == "$1" ]] && return 0
  done
  return 1
}

# 인자: 판정 함수와 인자. RETRY_DEADLINE까지 RETRY_SEC 간격으로 다시 부른다
retry() {
  [[ -n "$RETRY_DEADLINE" ]] || RETRY_DEADLINE=$((SECONDS + WAIT_SEC))
  until "$@"; do
    (( SECONDS >= RETRY_DEADLINE )) && return 1
    sleep "$RETRY_SEC"
  done
}

# ---------------------------------------------------------------
check_docker() {
  # root가 아닌 사용자로 성공하면 docker 그룹 권한이 적용된 것
  if d info >/dev/null 2>&1; then
    ok "sudo 없이 docker info"
  else
    ko "docker info 실패 (docker 그룹 추가 후 재로그인했는지 id -nG 확인, dockerd 동작 확인)"
  fi
  info "$(d --version 2>/dev/null || echo 'docker --version 실패')"
}

check_k3d_version() {
  local got
  got="$(k3 version 2>/dev/null | sed -n 's/^k3d version //p' | head -n 1)"
  if [[ "$got" == "$K3D_VERSION" ]]; then ok "k3d $got"; else ko "k3d: expected $K3D_VERSION, got '${got:-없음}'"; fi
}

check_kubectl_version() {
  local got
  got="$(timeout "$CALL_SEC" kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if [[ "$got" == "$KUBECTL_VERSION" ]]; then ok "kubectl client $got"; else ko "kubectl client: expected $KUBECTL_VERSION, got '${got:-없음}'"; fi
}

check_cluster() {
  if k3 cluster list --no-headers 2>/dev/null | awk -v c="$CLUSTER" '$1 == c {f = 1} END {exit !f}'; then
    ok "k3d cluster $CLUSTER"
  else
    ko "k3d cluster $CLUSTER 없음 (setup.sh 실행)"
  fi
}

check_port() {
  # docker port 출력 예: "8888/tcp -> 0.0.0.0:8888" (IPv6 "[::]:8888" 줄이 같이 나올 수 있다)
  local lb="k3d-${CLUSTER}-serverlb" ports
  ports="$(d port "$lb" 2>/dev/null)"
  if grep -q "^${APP_PORT}/tcp -> 0\.0\.0\.0:${APP_PORT}\$" <<< "$ports"; then
    ok "$lb ${APP_PORT}/tcp -> 0.0.0.0:${APP_PORT}"
  else
    ko "$lb 에 ${APP_PORT}/tcp -> 0.0.0.0:${APP_PORT} 매핑 없음"
    info_lines "docker port: " "${ports:-(출력 없음)}"
  fi
}

check_api() {
  if [[ "$(k get --raw=/readyz)" == "ok" ]]; then
    ok "Kubernetes API 응답 (/readyz)"
  else
    API_OK=0
    ko "Kubernetes API 응답 없음 (${CALL_SEC}초) → kubectl 항목 생략. host 재부팅 후라면 ./clean.sh && ./setup.sh"
  fi
}

check_nodes() {
  local nodes
  nodes="$(k get nodes --no-headers)"
  if awk 'NF { n++; if ($2 == "Ready") r++ } END { exit !(n > 0 && n == r) }' <<< "$nodes"; then
    ok "노드 $(grep -c . <<< "$nodes")개 전부 Ready"
  else
    ko "노드 Ready 아님: $(awk 'NF {printf "%s=%s ", $1, $2}' <<< "$nodes")"
  fi
}

check_node_version() {
  local tag want got
  if [[ -z "${K3S_IMAGE:-}" ]]; then
    info "K3S_IMAGE 비어 있음, 노드 버전 비교 생략: $(k get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}')"
    return
  fi
  # rancher/k3s:v1.36.5-k3s1 → v1.36.5+k3s1 (docker 태그는 + 대신 -)
  tag="${K3S_IMAGE##*:}"
  want="${tag/-k3s/+k3s}"
  got="$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u | paste -sd ' ' -)"
  if [[ "$got" == "$want" ]]; then ok "노드 kubelet $got"; else ko "노드 kubelet: expected $want, got '${got:-없음}'"; fi
}

check_ns() {
  local ns got
  for ns in "$ARGOCD_NS" "$APP_NS"; do
    got="$(k get ns "$ns" -o jsonpath='{.status.phase}')"
    if [[ "$got" == "Active" ]]; then ok "namespace $ns Active"; else ko "namespace $ns: '${got:-없음}'"; fi
  done
}

# 인자: kubectl get pods --no-headers 출력. Terminating을 빼고 1개 이상이며 전부 Running, READY a/a
pods_ready() {
  awk '
    NF && $3 != "Terminating" {
      n++
      split($2, r, "/")
      if ($3 == "Running" && r[1] == r[2]) ok++
    }
    END { exit !(n > 0 && n == ok) }' <<< "$1"
}

check_argocd_pods() {
  local pods
  pods="$(k get pods -n "$ARGOCD_NS" --no-headers)"
  if pods_ready "$pods"; then
    ok "argocd pod $(grep -c . <<< "$pods")개 Running·Ready"
  else
    ko "argocd pod 중 Running·Ready 아님"
    info_lines "argocd pod: " "$(awk '{print $1, $2, $3}' <<< "$pods")"
  fi
}

check_argocd_version() {
  local img
  img="$(k get deploy argocd-server -n "$ARGOCD_NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  if [[ "$img" == *":${ARGOCD_VERSION}" ]]; then ok "argocd-server $img"; else ko "argocd-server image: expected *:$ARGOCD_VERSION, got '${img:-없음}'"; fi
}

check_reconciliation() {
  local got jit
  got="$(k get cm argocd-cm -n "$ARGOCD_NS" -o jsonpath='{.data.timeout\.reconciliation}')"
  jit="$(k get cm argocd-cm -n "$ARGOCD_NS" -o jsonpath='{.data.timeout\.reconciliation\.jitter}')"
  if [[ "$got" == "$ARGOCD_RECONCILIATION" && "$jit" == "$ARGOCD_RECONCILIATION_JITTER" ]]; then
    ok "argocd-cm timeout.reconciliation $got, jitter $jit"
  else
    ko "argocd-cm: expected $ARGOCD_RECONCILIATION / $ARGOCD_RECONCILIATION_JITTER, got '${got:-없음}' / '${jit:-없음}'"
  fi
}

check_app_spec() {
  local spec want
  spec="$(k get application "$APP_NAME" -n "$ARGOCD_NS" \
    -o jsonpath='{.spec.source.repoURL} {.spec.source.path} {.spec.destination.namespace} {.spec.syncPolicy.automated.prune} {.spec.syncPolicy.automated.selfHeal}')"
  want="$REPO_URL $REPO_PATH $APP_NS true true"
  if [[ "$spec" == "$want" ]]; then
    ok "Application $APP_NAME: $REPO_URL path=$REPO_PATH → $APP_NS, prune·selfHeal"
  else
    ko "Application $APP_NAME spec: expected '$want', got '${spec:-없음}'"
  fi
}

check_repo_access() {
  # repo-server가 실제로 GitHub에 닿는지. Application이 Unknown이면 auto-sync가 건너뛰어져 v2를 기다려도 소용없다
  local out head
  out="$(timeout $((LSREMOTE_SEC + 5)) kubectl --context "$KCTX" -n "$ARGOCD_NS" exec deploy/argocd-repo-server -- \
    timeout "$LSREMOTE_SEC" git ls-remote "$REPO_URL" HEAD 2>&1)"
  head="$(grep -E $'^[0-9a-f]{40}\tHEAD$' <<< "$out" | head -n 1)"
  if [[ -n "$head" ]]; then
    ok "repo-server → $REPO_URL HEAD ${head:0:7}"
  else
    ko "repo-server에서 $REPO_URL 접근 실패 (클러스터 내부 DNS/네트워크 장애 추정, host 재부팅 후 흔함) → ./clean.sh && ./setup.sh"
    info "git ls-remote: $(grep . <<< "$out" | tail -n 1)"
    # sync가 안 되는 상태라 재시도 항목은 기다리지 않고 한 번만 본다
    RETRY_DEADLINE=$SECONDS
  fi
}

app_image_is() { [[ "$(k get deploy "$APP_NAME" -n "$APP_NS" -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$1" ]]; }

check_app_image() {
  local want="${APP_IMAGE}:${WANT}"
  if retry app_image_is "$want"; then
    ok "deploy $APP_NAME image $want"
  else
    ko "deploy $APP_NAME image: expected $want, got '$(k get deploy "$APP_NAME" -n "$APP_NS" -o jsonpath='{.spec.template.spec.containers[0].image}')'"
  fi
}

app_pods_ready() { pods_ready "$(k get pods -n "$APP_NS" --no-headers)"; }

check_app_pods() {
  if retry app_pods_ready; then
    ok "dev pod Running·Ready: $(k get pods -n "$APP_NS" --no-headers | awk '$3 != "Terminating" {print $1}' | paste -sd ' ' -)"
  else
    ko "dev pod 중 Running·Ready 아님"
    info_lines "dev pod: " "$(k get pods -n "$APP_NS" --no-headers | awk '{print $1, $2, $3}')"
  fi
}

# 응답 예: {"status":"ok", "message": "v1"}
LAST_BODY=""
curl_message_is() {
  LAST_BODY="$(curl -s --connect-timeout 3 --max-time 5 "http://localhost:${APP_PORT}/" 2>/dev/null)"
  [[ "$(sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' <<< "$LAST_BODY")" == "$1" ]]
}

check_curl() {
  if retry curl_message_is "$WANT"; then
    ok "curl localhost:${APP_PORT} → $LAST_BODY"
  else
    ko "curl localhost:${APP_PORT}: expected message $WANT, got '${LAST_BODY:-응답 없음}'"
  fi
}

app_status_ok() { [[ "$(k get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status} {.status.health.status}')" == "Synced Healthy" ]]; }

check_app_status() {
  # 새 버전이 반영된 뒤에 본다 (push 직후에는 이전 revision 기준으로 Synced일 수 있다)
  if retry app_status_ok; then
    ok "Application $APP_NAME Synced Healthy (revision $(k get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.revision}' | cut -c1-7))"
  else
    ko "Application $APP_NAME: $(k get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status} {.status.health.status}')"
  fi
}

diag() {
  # FAIL이 있을 때만, 원인 추적용
  echo
  echo "== 진단 =="
  if (( ! API_OK )); then
    info_lines "docker: " "$(d ps -a --filter "name=k3d-${CLUSTER}" --format '{{.Names}} {{.Status}}' 2>/dev/null)"
    return
  fi
  info_lines "app: " "$(k get application "$APP_NAME" -n "$ARGOCD_NS" \
    -o jsonpath='sync={.status.sync.status} health={.status.health.status} revision={.status.sync.revision} op={.status.operationState.phase} {.status.operationState.message}')"
  info_lines "app condition: " "$(k get application "$APP_NAME" -n "$ARGOCD_NS" \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}')"
  info_lines "coredns: " "$(k get pods -n kube-system -l k8s-app=kube-dns -o wide --no-headers)"
  info_lines "dev: " "$(k get pods,svc -n "$APP_NS" -o wide)"
  info_lines "dev event: " "$(k get events -n "$APP_NS" --sort-by=.lastTimestamp | tail -n 10)"
}

# ---------------------------------------------------------------
WANT="${1:-}"
if [[ $# -ne 1 || ( "$WANT" != "v1" && "$WANT" != "v2" ) ]]; then
  echo "사용법: $0 v1|v2  (GitHub repo에 올라가 있는 이미지 태그)" >&2
  exit 2
fi
if [[ $EUID -eq 0 ]]; then
  echo "일반 사용자로 실행하세요 (root면 docker 권한 확인이 의미 없음)" >&2
  exit 2
fi
if [[ ! -f "$VERSIONS_ENV" ]]; then
  echo "versions.env 없음: $VERSIONS_ENV" >&2
  exit 2
fi
# shellcheck source-path=SCRIPTDIR source=versions.env
source "$VERSIONS_ENV"
for var in K3D_VERSION KUBECTL_VERSION ARGOCD_VERSION ARGOCD_RECONCILIATION ARGOCD_RECONCILIATION_JITTER; do
  if [[ -z "${!var:-}" ]]; then
    echo "versions.env에 $var 없음" >&2
    exit 2
  fi
done

# 도구가 없으면 항목이 '없음'으로 FAIL해 원인이 가려지므로 먼저 확인한다
missing=()
for cmd in docker k3d kubectl curl timeout; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
  echo "없는 명령: ${missing[*]} (install.sh 실행)" >&2
  exit 2
fi

echo "== p3: cluster $CLUSTER, 기대 앱 버전 $WANT =="
skipped=()
for check in "${CHECKS[@]}"; do
  if (( ! API_OK )) && needs_api "$check"; then
    skipped+=("$check")
    continue
  fi
  "$check"
done
(( ${#skipped[@]} > 0 )) && info "API 응답 없음으로 생략: ${skipped[*]}"

(( FAIL > 0 )) && diag
echo
echo "결과: PASS $PASS / FAIL $FAIL"
[[ $FAIL -eq 0 ]]
