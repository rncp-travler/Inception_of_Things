#!/usr/bin/env bash
# p3 도구 설치 스크립트 (F-P3-01): Docker Engine, k3d, kubectl
# 사용법: 일반 사용자로 ./install.sh (sudo는 필요한 곳에서만 내부에서 부른다. 비밀번호를 물을 수 있음)
# 결과: 설치된 버전 출력 (판정은 check.sh). 성공 exit 0, 실패 exit 1
#
# 다시 실행하면 이미 있는 것은 건너뛴다: Docker는 docker-ce가 설치돼 있으면, k3d·kubectl은 versions.env와 같은 버전이면
# docker 그룹에 새로 추가되면 현재 셸에는 적용되지 않으므로 재로그인 후 setup.sh를 실행한다
# 설치하지 않는 것: Docker Desktop, docker compose·buildx plugin, GUI 도구, 클러스터 (setup.sh)
# 대상: Debian amd64 (sha256이 linux/amd64 바이너리 기준). 버전은 versions.env

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$SCRIPT_DIR/versions.env"

BIN_DIR="/usr/local/bin"
DOCKER_REPO="https://download.docker.com/linux/debian"
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
# Docker 공식 문서의 충돌 패키지 목록 (https://docs.docker.com/engine/install/debian/#uninstall-old-versions)
CONFLICT_PKGS=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)
# docker-ce-cli가 Recommends로 compose·buildx plugin을 끌어오므로 --no-install-recommends로 설치한다
# docker-ce Recommends 중 apparmor는 Debian 기본 AppArmor 환경에서 컨테이너 실행에 필요할 수 있어 직접 넣는다
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io apparmor)
# git은 디펜스 중 GitHub repo에 v2를 push할 때 쓴다
BASE_PKGS=(ca-certificates curl git)

TAG="[install.sh]"
log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*" >&2; exit 1; }

apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -q "$@"; }
# shellcheck disable=SC2016  # ${Status}는 dpkg-query 형식 문자열
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
in_group() { tr ' ' '\n' <<< "$1" | grep -qx docker; }

TMP_DIR=""
cleanup() { [[ -n "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------
install_base() {
  local pkg missing=()
  for pkg in "${BASE_PKGS[@]}"; do
    installed "$pkg" || missing+=("$pkg")
  done
  if (( ${#missing[@]} == 0 )); then
    log "기본 패키지 있음 (${BASE_PKGS[*]})"
    return
  fi
  log "기본 패키지 설치: ${missing[*]}"
  apt_get update || die "apt-get update 실패"
  apt_get install "${missing[@]}" || die "기본 패키지 설치 실패"
}

install_docker() {
  local pkg found=() codename
  if installed docker-ce; then
    log "docker-ce 설치돼 있음, 건너뜀"
  else
    for pkg in "${CONFLICT_PKGS[@]}"; do
      installed "$pkg" && found+=("$pkg")
    done
    if (( ${#found[@]} > 0 )); then
      log "충돌 패키지 제거: ${found[*]}"
      apt_get remove "${found[@]}" || die "충돌 패키지 제거 실패"
    fi
    # shellcheck source=/dev/null
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "$codename" ]] || die "/etc/os-release에 VERSION_CODENAME 없음"
    log "Docker apt repo 등록 ($codename)"
    sudo install -m 0755 -d "$(dirname "$DOCKER_KEYRING")" || die "keyring 디렉터리 생성 실패"
    sudo curl -fsSL "$DOCKER_REPO/gpg" -o "$DOCKER_KEYRING" || die "Docker GPG key 다운로드 실패"
    sudo chmod a+r "$DOCKER_KEYRING"
    sudo tee "$DOCKER_SOURCES" >/dev/null <<EOF || die "$DOCKER_SOURCES 작성 실패"
Types: deb
URIs: $DOCKER_REPO
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_KEYRING
EOF
    apt_get update || die "apt-get update 실패 (Docker repo)"
    log "Docker Engine 설치: ${DOCKER_PKGS[*]}"
    apt_get install --no-install-recommends "${DOCKER_PKGS[@]}" || die "Docker Engine 설치 실패"
  fi
  sudo systemctl enable --now docker || die "docker 서비스 시작 실패"
}

NEED_RELOGIN=0
add_docker_group() {
  local user
  user="$(id -un)"
  if in_group "$(id -nG "$user")"; then
    log "$user 는 이미 docker 그룹"
  else
    log "$user 를 docker 그룹에 추가"
    sudo usermod -aG docker "$user" || die "usermod 실패"
  fi
  # 그룹 변경은 새 로그인 세션부터 적용된다
  in_group "$(id -nG)" || NEED_RELOGIN=1
}

# 인자: 바이너리 경로. 버전 문자열(v...)을 출력한다
k3d_version_of()     { "$1" version 2>/dev/null | sed -n 's/^k3d version //p' | head -n 1; }
kubectl_version_of() { "$1" version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'; }

# 인자: 이름, 원하는 버전, 다운로드 URL, sha256. 같은 버전이 BIN_DIR에 있으면 건너뛴다
install_bin() {
  local name="$1" want="$2" url="$3" sha="$4" dest="$BIN_DIR/$1" got="" file
  [[ -x "$dest" ]] && got="$("${name}_version_of" "$dest")"
  if [[ "$got" == "$want" ]]; then
    log "$name $want 설치돼 있음, 건너뜀"
  else
    log "$name ${got:-없음} → $want 설치"
    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
    file="$TMP_DIR/$name"
    curl -fsSL -o "$file" "$url" || die "$name 다운로드 실패: $url"
    echo "$sha  $file" | sha256sum --check --quiet || die "$name sha256 불일치 (versions.env 값과 다름)"
    sudo install -o root -g root -m 0755 "$file" "$dest" || die "$name 설치 실패"
  fi
  # PATH 앞쪽에 다른 바이너리가 있으면 check.sh가 그 버전을 보게 된다
  if [[ "$(command -v "$name")" != "$dest" ]]; then
    log "WARN: PATH의 $name 이 $(command -v "$name") (설치 위치 $dest 와 다름)"
  fi
}

# ---------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "일반 사용자로 실행하세요 (docker 그룹에 넣을 사용자 기준, sudo는 내부에서 부름)"
[[ -f /etc/os-release ]] || die "/etc/os-release 없음"
# shellcheck source=/dev/null
os_id="$(. /etc/os-release && echo "${ID:-}")"
[[ "$os_id" == "debian" ]] || die "Debian 전용입니다 (ID=$os_id)"
command -v dpkg >/dev/null 2>&1 || die "dpkg 없음"
arch="$(dpkg --print-architecture)"
[[ "$arch" == "amd64" ]] || die "amd64 전용입니다 (sha256이 linux/amd64 기준, 현재 $arch)"
[[ -f "$VERSIONS_ENV" ]] || die "versions.env 없음: $VERSIONS_ENV"
# shellcheck source-path=SCRIPTDIR source=versions.env
source "$VERSIONS_ENV"
for var in K3D_VERSION K3D_SHA256 KUBECTL_VERSION KUBECTL_SHA256; do
  [[ -n "${!var:-}" ]] || die "versions.env에 $var 없음"
done
command -v sudo >/dev/null 2>&1 || die "sudo 없음"
sudo -v || die "sudo 권한 필요"

install_base
install_docker
add_docker_group
install_bin k3d "$K3D_VERSION" \
  "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" "$K3D_SHA256"
install_bin kubectl "$KUBECTL_VERSION" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$KUBECTL_SHA256"

# 보여주기만 한다. versions.env와 비교·판정은 check.sh
echo
log "설치된 버전 (판정은 check.sh)"
docker --version
k3d version
kubectl version --client

echo
if (( NEED_RELOGIN )); then
  log "docker 그룹이 현재 셸에 아직 적용되지 않았습니다. 로그아웃 후 재로그인하고 ./setup.sh 를 실행하세요"
  log "  재로그인 확인: id -nG 에 docker, docker run --rm hello-world 가 sudo 없이 성공"
else
  log "완료. 다음: ./setup.sh"
fi
