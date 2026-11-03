#!/usr/bin/env bash
# p3 클러스터 구성 스크립트 (F-P3-02/03)
#   k3d 클러스터 → ns argocd/dev → Argo CD 설치 → reconciliation 주기 단축 → Application apply → Synced/Healthy 대기
# 사용법: install.sh 후 재로그인한 셸에서 일반 사용자로 ./setup.sh (sudo 안 씀)
# 결과: 성공 exit 0, 대기 실패 exit 1 (진단 출력), 사전 조건 실패 exit 2
#
# 다시 실행해도 된다: 같은 이름 클러스터가 있고 K3s 이미지·8888 매핑이 맞으면 재사용하고 이후 단계를 다시 적용한다
#   (디펜스 중 대기가 timeout 나도 처음부터 다시 만들지 않고 이어서 진행). 맞지 않으면 clean.sh 후 다시 실행하라고 안내
# 앱 manifests 원본은 GitHub repo(taebkim-iot-p3/manifests)다. 이 script는 p3/confs/application.yaml만 apply한다
#   (p3/confs/manifests는 평가자 참고용 v1 사본, apply 안 함)
# 앱 접근: curl localhost:8888 (k3d loadbalancer 8888 → K3s ServiceLB → Service type LoadBalancer). port-forward 안 씀
# host VM 재부팅 후에는 재사용하지 말고 ./clean.sh && ./setup.sh (node IP가 바뀌어 클러스터 내부 DNS가 깨진 사례, DECISIONS D9)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$SCRIPT_DIR/versions.env"
APP_YAML="$SCRIPT_DIR/../confs/application.yaml"

CLUSTER="iot-p3"
KCTX="k3d-${CLUSTER}"
SERVER="k3d-${CLUSTER}-server-0"
LB="k3d-${CLUSTER}-serverlb"
ARGOCD_NS="argocd"
APP_NS="dev"
APP_NAME="wil-playground"   # p3/confs/application.yaml의 metadata.name
APP_PORT=8888
CLUSTER_TIMEOUT="180s"
NODE_TIMEOUT="120s"
ARGOCD_TIMEOUT="600s"   # 첫 설치는 quay.io에서 이미지를 받느라 오래 걸린다
RESTART_TIMEOUT="300s"
SYNC_WAIT_SEC=300
RETRY_SEC=5

TAG="[setup.sh]"
log() { echo "$TAG $*"; }
# 사전 조건 실패: 아무것도 바꾸지 않고 끝낸다
pre() { echo "$TAG $*" >&2; exit 2; }

# 다른 kubeconfig context가 있어도 이 클러스터만 건드린다
k() { kubectl --context "$KCTX" "$@"; }

diag() {
  echo
  log "== 진단 =="
  k3d cluster list
  docker ps -a --filter "name=k3d-${CLUSTER}" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
  k get pods -A -o wide
  k get events -A --sort-by=.lastTimestamp | tail -n 30
  k get application -n "$ARGOCD_NS"
  k describe application "$APP_NAME" -n "$ARGOCD_NS" | tail -n 40
}
fail() { log "FAIL: $*"; diag; exit 1; }

cluster_exists() { k3d cluster list --no-headers 2>/dev/null | awk -v c="$CLUSTER" '$1 == c {f = 1} END {exit !f}'; }

# 멈춘 컨테이너도 볼 수 있게 docker port 대신 HostConfig에서 읽는다. 출력: "8888/tcp 8888" 형식
lb_bindings() {
  docker inspect --format '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}} {{.HostPort}}{{"\n"}}{{end}}{{end}}' "$LB" 2>/dev/null
}

# ---------------------------------------------------------------
check_pre() {
  local var cmd missing=()
  [[ $EUID -ne 0 ]] || pre "일반 사용자로 실행하세요 (sudo 없이 docker를 쓰는지 확인하려는 것)"
  [[ -f "$VERSIONS_ENV" ]] || pre "versions.env 없음: $VERSIONS_ENV"
  # shellcheck source-path=SCRIPTDIR source=versions.env
  source "$VERSIONS_ENV"
  for var in ARGOCD_VERSION ARGOCD_INSTALL_URL ARGOCD_RECONCILIATION ARGOCD_RECONCILIATION_JITTER; do
    [[ -n "${!var:-}" ]] || pre "versions.env에 $var 없음"
  done
  for cmd in docker k3d kubectl curl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || pre "없는 명령: ${missing[*]} (./install.sh 실행)"
  docker info >/dev/null 2>&1 \
    || pre "sudo 없이 docker 사용 불가. install.sh 후 재로그인했는지 확인 (id -nG 에 docker, systemctl is-active docker)"
  [[ -f "$APP_YAML" ]] || pre "Application manifest 없음: $APP_YAML"
}

create_or_reuse_cluster() {
  local args img running
  if ! cluster_exists; then
    # 이미 8888을 쓰는 프로세스가 있으면 loadbalancer 컨테이너가 뜨지 못한다
    if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :${APP_PORT}" | grep -q .; then
      pre "호스트 ${APP_PORT} 포트 사용 중: $(ss -Hltnp "sport = :${APP_PORT}" 2>/dev/null | head -n 1)"
    fi
    args=(cluster create "$CLUSTER" -p "${APP_PORT}:${APP_PORT}@loadbalancer" --wait --timeout "$CLUSTER_TIMEOUT")
    if [[ -n "${K3S_IMAGE:-}" ]]; then
      args+=(--image "$K3S_IMAGE")
    else
      log "versions.env K3S_IMAGE 비어 있음: k3d 기본 이미지로 생성"
    fi
    log "k3d ${args[*]}"
    k3d "${args[@]}" || fail "k3d cluster create"
  else
    log "클러스터 $CLUSTER 있음: 설정 확인 후 재사용"
    img="$(docker inspect --format '{{.Config.Image}}' "$SERVER" 2>/dev/null)"
    if [[ -n "${K3S_IMAGE:-}" && "$img" != "$K3S_IMAGE" ]]; then
      pre "기존 클러스터 이미지 '${img:-확인 불가}' ≠ versions.env '$K3S_IMAGE'. ./clean.sh 후 다시 실행"
    fi
    grep -qx "${APP_PORT}/tcp ${APP_PORT}" <<< "$(lb_bindings)" \
      || pre "기존 클러스터 $LB 에 ${APP_PORT}:${APP_PORT} 매핑 없음. ./clean.sh 후 다시 실행"
    running="$(docker inspect --format '{{.State.Running}}' "$SERVER" "$LB" 2>/dev/null | sort -u)"
    if [[ "$running" != "true" ]]; then
      log "멈춘 노드가 있어 k3d cluster start"
      k3d cluster start "$CLUSTER" --wait --timeout "$CLUSTER_TIMEOUT" || fail "k3d cluster start"
    fi
    # kubeconfig에 context가 없거나 다른 context가 선택돼 있을 수 있다
    k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null \
      || fail "k3d kubeconfig merge"
  fi
  log "K3s 이미지 (실제): $(docker inspect --format '{{.Config.Image}}' "$SERVER" 2>/dev/null)"
  k wait --for=condition=Ready node --all --timeout="$NODE_TIMEOUT" || fail "노드 Ready 대기"
}

create_namespaces() {
  local ns
  for ns in "$ARGOCD_NS" "$APP_NS"; do
    k create namespace "$ns" --dry-run=client -o yaml | k apply -f - || fail "namespace $ns"
  done
}

install_argocd() {
  # ApplicationSet CRD가 client-side apply의 annotation 크기 제한(262KB)을 넘어 server-side apply를 쓴다 (Argo CD getting started)
  log "Argo CD $ARGOCD_VERSION 설치: $ARGOCD_INSTALL_URL"
  k apply -n "$ARGOCD_NS" --server-side --force-conflicts -f "$ARGOCD_INSTALL_URL" >/dev/null || fail "Argo CD apply"
  log "Argo CD 대기 (최대 $ARGOCD_TIMEOUT)"
  k wait deploy --all -n "$ARGOCD_NS" --for=condition=Available --timeout="$ARGOCD_TIMEOUT" || fail "Argo CD deployment 대기"
  k rollout status sts/argocd-application-controller -n "$ARGOCD_NS" --timeout="$ARGOCD_TIMEOUT" \
    || fail "argocd-application-controller 대기"
}

# 인자: 워크로드 (deploy/x, sts/x). kubectl rollout restart가 남기는 pod template annotation
restarted_at() {
  k get "$1" -n "$ARGOCD_NS" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null
}

set_reconciliation() {
  # Git polling 주기 단축. 문서상 repo-server, application-controller를 재시작해야 적용된다
  local out w
  local workloads=(deploy/argocd-repo-server sts/argocd-application-controller)
  log "argocd-cm timeout.reconciliation=$ARGOCD_RECONCILIATION jitter=$ARGOCD_RECONCILIATION_JITTER"
  out="$(k patch configmap argocd-cm -n "$ARGOCD_NS" --type merge \
    -p "{\"data\":{\"timeout.reconciliation\":\"${ARGOCD_RECONCILIATION}\",\"timeout.reconciliation.jitter\":\"${ARGOCD_RECONCILIATION_JITTER}\"}}" 2>&1)" \
    || { echo "$out"; fail "argocd-cm patch"; }
  echo "$out"
  # 값이 그대로면 재시작을 생략한다. 단, 이전 실행이 patch 후 재시작 전에 끝났을 수 있어
  # 두 워크로드 모두 rollout restart 흔적(restartedAt)이 있을 때만 생략한다
  if [[ "$out" == *"(no change)"* && -n "$(restarted_at "${workloads[0]}")" && -n "$(restarted_at "${workloads[1]}")" ]]; then
    log "argocd-cm 변경 없음, 재시작 생략"
    return
  fi
  for w in "${workloads[@]}"; do
    k rollout restart "$w" -n "$ARGOCD_NS" || fail "$w restart"
  done
  for w in "${workloads[@]}"; do
    k rollout status "$w" -n "$ARGOCD_NS" --timeout="$RESTART_TIMEOUT" || fail "$w 재시작 대기"
  done
}

app_status() { k get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null; }

apply_application() {
  local deadline st last=""
  log "Application apply: $APP_YAML (repoURL $(awk '$1 == "repoURL:" {print $2; exit}' "$APP_YAML"))"
  k apply -f "$APP_YAML" || fail "Application apply"
  log "Synced Healthy 대기 (최대 ${SYNC_WAIT_SEC}초)"
  deadline=$((SECONDS + SYNC_WAIT_SEC))
  st="$(app_status)"
  until [[ "$st" == "Synced Healthy" ]]; do
    if [[ "$st" != "$last" ]]; then
      log "  Application: ${st:-(상태 없음)}"
      last="$st"
    fi
    (( SECONDS >= deadline )) && fail "Application $APP_NAME ${SYNC_WAIT_SEC}초 후 '${st:-상태 없음}'"
    sleep "$RETRY_SEC"
    st="$(app_status)"
  done
  log "  Application: $st"
}

summary() {
  echo
  log "== 결과 =="
  k get nodes -o wide
  k get ns
  k get pods -n "$ARGOCD_NS"
  k get pods,svc -n "$APP_NS"
  docker ps --filter "name=$LB" --format '{{.Names}}\t{{.Ports}}'
  echo
  log "완료. 다음: ./check.sh v1 (GitHub repo가 v2 상태면 v2), 앱: curl http://localhost:${APP_PORT}/"
}

# ---------------------------------------------------------------
check_pre
create_or_reuse_cluster
create_namespaces
install_argocd
set_reconciliation
apply_application
summary
