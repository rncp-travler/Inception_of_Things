#!/usr/bin/env bash
# p3 정리 스크립트: k3d 클러스터만 삭제한다
# 사용법: 일반 사용자로 ./clean.sh (sudo 안 씀)
# 결과: 클러스터가 없어지면 exit 0 (처음부터 없어도 0), 남으면 exit 1
#
# 건드리지 않는 것: Docker·k3d·kubectl (install.sh로 설치한 도구), docker 이미지, kubeconfig의 다른 context
#   (k3d가 자기 context k3d-<클러스터>는 지운다), P1/P2의 VirtualBox·Vagrant
# host VM 재부팅 후에는 ./clean.sh && ./setup.sh 로 클러스터를 다시 만든다 (node IP 변경 후 클러스터 내부 DNS 장애 사례)

set -u

CLUSTER="iot-p3"

TAG="[clean.sh]"
log() { echo "$TAG $*"; }

cluster_exists() { k3d cluster list --no-headers 2>/dev/null | awk -v c="$CLUSTER" '$1 == c {f = 1} END {exit !f}'; }

command -v k3d >/dev/null 2>&1 || { echo "k3d 없음" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "sudo 없이 docker 사용 불가 (재로그인했는지 id -nG 확인)" >&2; exit 1; }

if cluster_exists; then
  log "k3d cluster delete $CLUSTER"
  k3d cluster delete "$CLUSTER" || log "k3d cluster delete 실패"
else
  log "클러스터 $CLUSTER 없음"
fi

if cluster_exists; then
  log "FAIL: 클러스터 $CLUSTER 남아 있음"
  k3d cluster list
  exit 1
fi
log "완료: 클러스터 $CLUSTER 없음"
