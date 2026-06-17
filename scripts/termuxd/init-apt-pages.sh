#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

pages_branch="${PAGES_BRANCH:-gh-pages}"
pages_remote_url="${PAGES_REMOTE_URL:-}"
pages_tmpdir="${PAGES_TMPDIR:-${TERMUXD_REPO_ROOT}/.tmp-pages}"
apt_arch="${APT_ARCH:-${TERMUXD_RUNTIME_ABI}}"
apt_suite="${APT_SUITE:-stable}"
apt_component="${APT_COMPONENT:-main}"

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never

if [[ -z "${pages_remote_url}" ]]; then
	echo "PAGES_REMOTE_URL must point to the independent GitHub Pages package repository" >&2
	exit 1
fi

if [[ "$#" -gt 0 ]]; then
	repo_paths=("$@")
else
	repo_paths=(apt/bionic apt/glibc)
fi

mkdir -p "${pages_tmpdir}"
tmpdir="$(mktemp -d "${pages_tmpdir%/}/init-apt-pages.XXXXXX")"
publish_dir="${tmpdir}/publish"

cleanup() {
	rm -rf "${tmpdir}"
}
trap cleanup EXIT

if git ls-remote --exit-code --heads "${pages_remote_url}" "${pages_branch}" >/dev/null 2>&1; then
	git clone --branch "${pages_branch}" --single-branch "${pages_remote_url}" "${publish_dir}"
else
	git clone "${pages_remote_url}" "${publish_dir}"
	(
		cd "${publish_dir}"
		git checkout --orphan "${pages_branch}"
		git rm -rf . >/dev/null 2>&1 || true
		find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
	)
fi

write_release() {
	local repo_root="$1"
	local suite="$2"
	local arch="$3"
	local component="$4"

	python3 - "${repo_root}" "${suite}" "${arch}" "${component}" <<'PY'
from email.utils import formatdate
from hashlib import md5, sha1, sha256, sha512
from pathlib import Path
import sys

repo_root = Path(sys.argv[1])
suite = sys.argv[2]
arch = sys.argv[3]
component = sys.argv[4]
suite_dir = repo_root / "dists" / suite
release_path = suite_dir / "Release"
files = [
    path
    for path in sorted(suite_dir.rglob("*"))
    if path.is_file() and path.name != "Release"
]

with release_path.open("w", encoding="utf-8") as handle:
    handle.write("Origin: termuxd\n")
    handle.write("Label: termuxd\n")
    handle.write(f"Suite: {suite}\n")
    handle.write(f"Codename: {suite}\n")
    handle.write(f"Architectures: {arch}\n")
    handle.write(f"Components: {component}\n")
    handle.write(f"Date: {formatdate(usegmt=True)}\n")
    for label, factory in (
        ("MD5Sum", md5),
        ("SHA1", sha1),
        ("SHA256", sha256),
        ("SHA512", sha512),
    ):
        handle.write(f"{label}:\n")
        for path in files:
            data = path.read_bytes()
            rel = path.relative_to(suite_dir)
            handle.write(f" {factory(data).hexdigest()} {len(data)} {rel.as_posix()}\n")
PY
}

touch "${publish_dir}/.nojekyll"
for repo_path in "${repo_paths[@]}"; do
	repo_root="${publish_dir}/${repo_path}"
	binary_dir="${repo_root}/dists/${apt_suite}/${apt_component}/binary-${apt_arch}"
	mkdir -p "${binary_dir}" "${repo_root}/pool/main"

	if [[ ! -f "${binary_dir}/Packages" ]]; then
		: > "${binary_dir}/Packages"
	fi

	gzip -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.gz"
	xz -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.xz"
	bzip2 -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.bz2"
	write_release "${repo_root}" "${apt_suite}" "${apt_arch}" "${apt_component}"
done

(
	cd "${publish_dir}"
	git config user.name "$(git config --global --get user.name || echo 'termuxd builder')"
	git config user.email "$(git config --global --get user.email || echo 'termuxd-builder@users.noreply.github.com')"
	git add .nojekyll "${repo_paths[@]}"
	if git diff --cached --quiet; then
		echo "No apt pages initialization changes to publish"
		exit 0
	fi
	git commit -m "Initialize termuxd APT pages"
	git push origin "${pages_branch}"
)

printf 'Initialized APT repo paths: %s\n' "${repo_paths[*]}" >&2
