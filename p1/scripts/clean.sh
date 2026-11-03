#!/usr/bin/env bash
# p1 VM 정리 스크립트: vagrant destroy -f만으로 남는 VirtualBox VM·폴더까지 지운다
# 사용법: p1 디렉터리(Vagrantfile 위치)에서 ./scripts/clean.sh
#         LOGIN=다른로그인 ./scripts/clean.sh  (기본값: taebkim)
#
# P1과 P2는 subject 요구상 같은 VM 이름(taebkimS)을 쓴다. 다른 Part에서 만든 같은 이름의 VM도 지운다
# 캠퍼스에서 겪은 경우:
#   - 재부팅 후 남은 VM 때문에 vagrant up이 "Could not rename ... temp_clone_... (VERR_ALREADY_EXISTS)"로 실패
#   - destroy는 "VM not created"인데 VBoxManage list vms에 남아 있음
#   - destroy 직후 list vms에 잠시 남아 보임 (VirtualBox 비동기 정리)
#
# 순서: vagrant destroy -f → 대상 VM이 사라질 때까지 대기 → 남은 대상 VM, temp_clone_* VM poweroff·unregister --delete
#       → 등록된 VM 없이 남은 대상 이름 폴더 삭제 → vagrant global-status --prune → VBoxManage list vms
# 건드리지 않는 것: vagrant box, linked clone 원본 VM(Rocky-Vagrant-Vbox_*), .vagrant/k3s-token
# 결과: 대상 VM이 모두 사라지면 exit 0, 남으면 exit 1

set -u

LOGIN="${LOGIN:-taebkim}"
TARGETS=("${LOGIN}S" "${LOGIN}SW")
GONE_WAIT_SEC=30
RETRY_SEC=2

TAG="[clean.sh]"
log() { echo "$TAG $*"; }

# VBoxManage list vms 한 줄: "name" {uuid}
list_vms() { VBoxManage list vms 2>/dev/null | sed -nE 's/^"(.*)" \{([0-9a-fA-F-]+)\}$/\2 \1/p'; }

# 인자: VM 이름. 등록된 같은 이름 VM의 uuid를 줄마다 출력
uuids_of() { list_vms | awk -v n="$1" '{ u = $1; sub(/^[^ ]+ /, ""); if ($0 == n) print u }'; }

targets_left() {
  local name
  for name in "${TARGETS[@]}"; do
    [[ -n "$(uuids_of "$name")" ]] && return 0
  done
  return 1
}

# 인자: uuid, 표시 이름. 실행 중이면 끄고 등록 해제 + 디스크 삭제
remove_vm() {
  local uuid="$1" name="$2" i
  if VBoxManage list runningvms 2>/dev/null | grep -q "{$uuid}"; then
    log "$name poweroff"
    VBoxManage controlvm "$uuid" poweroff < /dev/null || true
  fi
  # poweroff 직후에는 session lock이 남아 unregister가 실패할 수 있어 재시도한다
  for ((i = 0; i < 5; i++)); do
    if VBoxManage unregistervm "$uuid" --delete < /dev/null; then
      log "$name ($uuid) unregistervm --delete"
      return 0
    fi
    sleep "$RETRY_SEC"
  done
  log "WARN: $name ($uuid) unregistervm 실패"
  return 1
}

if [[ ! -f Vagrantfile ]]; then
  echo "p1 디렉터리(Vagrantfile 위치)에서 실행하세요" >&2
  exit 2
fi
for cmd in vagrant VBoxManage; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd 없음" >&2; exit 2; }
done

# 1. vagrant destroy (VM not created여도 계속 진행)
log "vagrant destroy -f"
vagrant destroy -f || log "vagrant destroy 실패, VBoxManage로 계속 정리"

# 2. VirtualBox 비동기 정리 대기
deadline=$((SECONDS + GONE_WAIT_SEC))
while targets_left && (( SECONDS < deadline )); do
  sleep "$RETRY_SEC"
done

# 3. 남은 대상 VM
for name in "${TARGETS[@]}"; do
  for uuid in $(uuids_of "$name"); do
    log "$name 이 ${GONE_WAIT_SEC}초 후에도 남아 있음"
    remove_vm "$uuid" "$name"
  done
done

# 4. vagrant linked clone 중간 산물 temp_clone_* (원본 Rocky-Vagrant-Vbox_*는 이름이 달라 대상 아님)
# 목록을 먼저 받아 돌린다 (remove_vm의 VBoxManage는 stdin을 /dev/null로 막아 목록을 읽지 않게 한다)
vms="$(list_vms)"
while read -r uuid name; do
  [[ "$name" == temp_clone_* ]] || continue
  remove_vm "$uuid" "$name"
done <<< "$vms"

# 5. 등록된 VM 없이 남은 대상 이름 폴더 (VM 폴더 위치는 VirtualBox 설정에서 읽는다)
vm_root="$(VBoxManage list systemproperties 2>/dev/null | sed -n 's/^Default machine folder: *//p')"
vm_root="${vm_root:-$HOME/VirtualBox VMs}"
[[ "$vm_root" == /* ]] || { log "VM 폴더 위치가 절대경로가 아님: '$vm_root'"; exit 1; }
for name in "${TARGETS[@]}"; do
  dir="$vm_root/$name"
  if [[ -d "$dir" && -z "$(uuids_of "$name")" ]]; then
    log "등록되지 않은 VM 폴더 삭제: $dir"
    rm -rf -- "$dir"
  fi
done

# 6. vagrant 전역 목록에서 없는 VM 제거
vagrant global-status --prune >/dev/null || true

# 7. 결과
echo
log "VBoxManage list vms:"
VBoxManage list vms
if targets_left; then
  log "FAIL: 남은 대상 VM 있음 (${TARGETS[*]})"
  exit 1
fi
log "완료: ${TARGETS[*]} 없음"
