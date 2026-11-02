#!/usr/bin/env bash
# taebkimS provisioning (p2): K3s server + vagrant 사용자 kubectl + app1/app2/app3, Ingress 적용
# Vagrantfile env: SERVER_IP, K3S_TOKEN, K3S_VERSION, CONFS_DIR (file provisioner가 confs/를 올린 위치)
# vagrant provision 재실행 시: 같은 버전·인자로 동작 중이면 설치를 건너뛰고 kubeconfig 복사와 manifests 적용만 다시 한다

set -euo pipefail

TAG="[server.sh]"
log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*" >&2; exit 1; }

: "${SERVER_IP:?SERVER_IP 없음 (Vagrantfile env 확인)}"
: "${K3S_TOKEN:?K3S_TOKEN 없음 (Vagrantfile env 확인)}"
: "${K3S_VERSION:?K3S_VERSION 없음 (Vagrantfile env 확인)}"
: "${CONFS_DIR:?CONFS_DIR 없음 (Vagrantfile env 확인)}"

K3S=/usr/local/bin/k3s   # sudo secure_path에 /usr/local/bin이 없어 절대경로로 쓴다
READY_TIMEOUT=180
APPS_TIMEOUT=300   # 이미지 pull, Traefik helm 설치까지 포함한 대기 시간
APPS=(app1 app2 app3)
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')"   # K8s 노드 이름은 소문자
USER_NAME=vagrant
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

# ---------- 전용 interface: 이름을 하드코딩하지 않고 SERVER_IP로 찾는다 ----------
IFACE="$(ip -4 -o addr show | awk -v ip="$SERVER_IP" 'index($4, ip "/") == 1 {print $2}')"
[[ -n "$IFACE" ]] || die "$SERVER_IP 을 가진 interface 없음"
log "node-ip $SERVER_IP, flannel-iface $IFACE"

# ---------- Rocky Linux 10 대응 (https://docs.k3s.io/installation/requirements) ----------
# firewalld: 공식 문서 권장대로 비활성
if systemctl is-enabled --quiet firewalld 2>/dev/null || systemctl is-active --quiet firewalld 2>/dev/null; then
  log "firewalld 비활성"
  systemctl disable --now firewalld
fi

# RHEL 10: kernel-modules-extra 필요. 실행 중 커널과 같은 버전만 설치한다 (다른 버전은 reboot 전까지 모듈이 맞지 않음)
KMOD_PKG="kernel-modules-extra-$(uname -r)"
if ! rpm -q "$KMOD_PKG" >/dev/null 2>&1; then
  log "$KMOD_PKG 설치"
  if ! dnf install -y "$KMOD_PKG"; then
    log "uname -r: $(uname -r)"
    dnf list --showduplicates kernel-modules-extra || true
    die "$KMOD_PKG 설치 실패 (위 목록에 실행 중 커널 버전이 있는지 확인)"
  fi
fi

# SELinux: 끄지 않는다. k3s-selinux 정책은 설치 script가 설치하고, K3s는 --selinux로 실행 (https://docs.k3s.io/advanced#selinux-support)
log "SELinux: $(getenforce 2>/dev/null || echo 'getenforce 없음')"

# ---------- K3s server ----------
# 기본 구성요소를 끄지 않는다: Traefik이 Ingress controller, servicelb가 노드 IP의 80 포트를 연다
K3S_ARGS=(server --node-ip "$SERVER_IP" --flannel-iface "$IFACE" --selinux)
# 마지막으로 설치한 버전·인자 기록. 버전이나 인자가 바뀌면 다시 설치한다 (token은 기록하지 않음)
STAMP=/etc/rancher/k3s/provision.stamp
WANT="$K3S_VERSION ${K3S_ARGS[*]}"
# pipefail에서 `k3s --version | grep -q`는 grep이 먼저 끝나 SIGPIPE(141)로 실패하므로 출력을 변수로 받는다
have_version="$("$K3S" --version 2>/dev/null || true)"
if [[ "$have_version" == *"$K3S_VERSION"* && "$(cat "$STAMP" 2>/dev/null)" == "$WANT" ]] \
    && systemctl is-active --quiet k3s; then
  log "K3s $K3S_VERSION 같은 인자로 동작 중, 설치 건너뜀"
else
  log "K3s $K3S_VERSION server 설치: ${K3S_ARGS[*]}"
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$K3S_TOKEN" sh -s - "${K3S_ARGS[@]}"
  mkdir -p "$(dirname "$STAMP")"
  echo "$WANT" > "$STAMP"
fi

# ---------- node Ready 대기 ----------
deadline=$((SECONDS + READY_TIMEOUT))
until [[ "$("$K3S" kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | awk '{print $2}')" == "Ready" ]]; do
  if (( SECONDS >= deadline )); then
    journalctl -u k3s -n 50 --no-pager || true
    die "node $NODE_NAME 이 ${READY_TIMEOUT}초 안에 Ready 되지 않음"
  fi
  sleep 5
done
log "node $NODE_NAME Ready"

# ---------- vagrant 사용자 kubectl (sudo 없이) ----------
# 원본 k3s.yaml은 root 0600 유지, vagrant 전용 사본을 0600으로 둔다 (매 provision마다 갱신)
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.kube"
install -m 600 -o "$USER_NAME" -g "$USER_NAME" /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
# k3s kubectl은 KUBECONFIG가 없으면 /etc/rancher/k3s/k3s.yaml을 읽으므로 사본 경로를 지정한다
# shellcheck disable=SC2016  # $HOME은 .bashrc 안에서 펼쳐져야 한다
EXPORT_LINE='export KUBECONFIG="$HOME/.kube/config"'
grep -qxF "$EXPORT_LINE" "$USER_HOME/.bashrc" 2>/dev/null || echo "$EXPORT_LINE" >> "$USER_HOME/.bashrc"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/.bashrc"

# ---------- manifests 적용 (매 provision, apply는 멱등) ----------
kc() { "$K3S" kubectl "$@"; }

# 실패 시 진단 출력 후 종료
dump_diag() {
  kc get pods -A -o wide || true
  kc get deploy,svc,endpointslices,ingress -A || true
  kc describe ingress || true
  kc -n kube-system logs deploy/traefik --tail=50 || true
  kc get events -A --sort-by=.lastTimestamp | tail -n 30 || true
  free -m || true
}

fail() { dump_diag; die "$*"; }

shopt -s nullglob
manifests=("$CONFS_DIR"/*.yaml)
shopt -u nullglob
(( ${#manifests[@]} > 0 )) || die "$CONFS_DIR 에 *.yaml 없음 (Vagrantfile file provisioner 확인)"
log "manifests 적용: ${manifests[*]}"
kc apply -f "$CONFS_DIR" || fail "kubectl apply 실패"

# ---------- 앱, Traefik Ready 대기 (공통 deadline) ----------
deadline=$((SECONDS + APPS_TIMEOUT))
remaining() { echo $((deadline - SECONDS > 0 ? deadline - SECONDS : 1)); }

# rollout status는 없는 리소스에 바로 실패하므로 생길 때까지 기다린다. 인자: namespace, kind, 이름 접두어
# 찾은 이름(kind/name)을 출력한다
wait_exists() {
  local ns="$1" kind="$2" prefix="$3" found
  while :; do
    found="$(kc -n "$ns" get "$kind" -o name 2>/dev/null | grep -m 1 "^[^/]*/${prefix}" || true)"
    [[ -n "$found" ]] && { echo "$found"; return 0; }
    (( SECONDS >= deadline )) && return 1
    sleep 5
  done
}

rollout() {
  local ns="$1" res="$2"
  kc -n "$ns" rollout status "$res" --timeout="$(remaining)s" \
    || fail "$ns $res 이 ${APPS_TIMEOUT}초 안에 준비되지 않음"
}

for app in "${APPS[@]}"; do
  rollout default "deployment/$app"
done

# traefik deployment는 helm-install-traefik job이 만든다
traefik="$(wait_exists kube-system deployment traefik)" || fail "kube-system deployment traefik 이 생기지 않음"
rollout kube-system "$traefik"
# servicelb DaemonSet 이름에는 hash가 붙는다 (svclb-traefik-xxxx)
svclb="$(wait_exists kube-system daemonset svclb-traefik)" || fail "kube-system daemonset svclb-traefik* 가 생기지 않음"
rollout kube-system "$svclb"
log "app1/app2/app3, Traefik Ready"

kc get nodes -o wide
kc get all,ingress
log "완료"
