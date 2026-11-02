#!/usr/bin/env bash
# taebkimS provisioning: K3s server (controller mode) + vagrant 사용자 kubectl
# Vagrantfile env: SERVER_IP, K3S_TOKEN, K3S_VERSION
# vagrant provision 재실행 시: 같은 버전이 이미 동작 중이면 설치를 건너뛰고 kubeconfig만 다시 복사한다

set -euo pipefail

TAG="[server.sh]"
log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*" >&2; exit 1; }

: "${SERVER_IP:?SERVER_IP 없음 (Vagrantfile env 확인)}"
: "${K3S_TOKEN:?K3S_TOKEN 없음 (Vagrantfile env 확인)}"
: "${K3S_VERSION:?K3S_VERSION 없음 (Vagrantfile env 확인)}"

K3S=/usr/local/bin/k3s   # sudo secure_path에 /usr/local/bin이 없어 절대경로로 쓴다
READY_TIMEOUT=180
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
if [[ -x "$K3S" ]] && "$K3S" --version | grep -qF "$K3S_VERSION" && systemctl is-active --quiet k3s; then
  log "K3s $K3S_VERSION 이미 동작 중, 설치 건너뜀"
else
  log "K3s $K3S_VERSION server 설치"
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$K3S_TOKEN" \
      sh -s - server --node-ip "$SERVER_IP" --flannel-iface "$IFACE" --selinux
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

"$K3S" kubectl get nodes -o wide
log "완료"
