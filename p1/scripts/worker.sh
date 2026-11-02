#!/usr/bin/env bash
# taebkimSW provisioning: K3s agent, https://SERVER_IP:6443 으로 join
# Vagrantfile env: SERVER_IP, WORKER_IP, K3S_TOKEN, K3S_VERSION
# vagrant provision 재실행 시: 같은 버전이 이미 동작 중이면 설치를 건너뛴다

set -euo pipefail

TAG="[worker.sh]"
log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*" >&2; exit 1; }

: "${SERVER_IP:?SERVER_IP 없음 (Vagrantfile env 확인)}"
: "${WORKER_IP:?WORKER_IP 없음 (Vagrantfile env 확인)}"
: "${K3S_TOKEN:?K3S_TOKEN 없음 (Vagrantfile env 확인)}"
: "${K3S_VERSION:?K3S_VERSION 없음 (Vagrantfile env 확인)}"

K3S=/usr/local/bin/k3s   # sudo secure_path에 /usr/local/bin이 없어 절대경로로 쓴다
SERVER_URL="https://${SERVER_IP}:6443"
WAIT_TIMEOUT=300

# ---------- 전용 interface: 이름을 하드코딩하지 않고 WORKER_IP로 찾는다 ----------
IFACE="$(ip -4 -o addr show | awk -v ip="$WORKER_IP" 'index($4, ip "/") == 1 {print $2}')"
[[ -n "$IFACE" ]] || die "$WORKER_IP 을 가진 interface 없음"
log "node-ip $WORKER_IP, flannel-iface $IFACE"

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

# ---------- server 6443 대기 ----------
deadline=$((SECONDS + WAIT_TIMEOUT))
until timeout 2 bash -c "</dev/tcp/${SERVER_IP}/6443" 2>/dev/null; do
  (( SECONDS < deadline )) || die "server ${SERVER_IP}:6443 응답 없음 (${WAIT_TIMEOUT}s). taebkimS의 k3s 상태 확인"
  sleep 5
done
log "server ${SERVER_IP}:6443 열림"

# ---------- K3s agent ----------
if [[ -x "$K3S" ]] && "$K3S" --version | grep -qF "$K3S_VERSION" && systemctl is-active --quiet k3s-agent; then
  log "K3s $K3S_VERSION agent 이미 동작 중, 설치 건너뜀"
else
  log "K3s $K3S_VERSION agent 설치, join $SERVER_URL"
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_URL="$SERVER_URL" K3S_TOKEN="$K3S_TOKEN" \
      sh -s - agent --node-ip "$WORKER_IP" --flannel-iface "$IFACE" --selinux
fi

systemctl is-active --quiet k3s-agent || {
  journalctl -u k3s-agent -n 50 --no-pager || true
  die "k3s-agent 가 active 아님"
}
log "완료 (Ready 여부는 taebkimS에서 kubectl get nodes로 확인)"
