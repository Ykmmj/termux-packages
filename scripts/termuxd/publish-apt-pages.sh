#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
	echo "Usage: $0 <repo-root> <packages-dir> <pages-repo-dir>" >&2
	exit 1
fi

repo_root="$(realpath "$1")"
packages_dir="$(realpath "$2")"
pages_repo_dir="$3"
pages_branch="${PAGES_BRANCH:-gh-pages}"
pages_remote_url="${PAGES_REMOTE_URL:-}"
pages_tmpdir="${PAGES_TMPDIR:-${repo_root}/.tmp-pages}"
apt_arch="${APT_ARCH:-aarch64}"
apt_suite="${APT_SUITE:-stable}"
apt_component="${APT_COMPONENT:-main}"
apt_merge_existing="${APT_MERGE_EXISTING:-true}"

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never

if [[ -z "${pages_remote_url}" ]]; then
	echo "PAGES_REMOTE_URL must point to the independent GitHub Pages package repository" >&2
	exit 1
fi

if [[ ! -d "${packages_dir}" ]]; then
	echo "packages directory does not exist: ${packages_dir}" >&2
	exit 1
fi

mkdir -p "${pages_tmpdir}"
tmpdir="$(mktemp -d "${pages_tmpdir%/}/publish-apt-pages.XXXXXX")"
publish_dir="${tmpdir}/publish"
staging_repo_dir="${tmpdir}/staged-repo"

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

mkdir -p "${publish_dir}/${pages_repo_dir}" "${staging_repo_dir}/pool/main"
touch "${publish_dir}/.nojekyll"

if [[ "${apt_merge_existing}" == "true" ]]; then
	find "${publish_dir}/${pages_repo_dir}/pool/main" -maxdepth 1 -name '*.deb' -exec cp {} "${staging_repo_dir}/pool/main/" \; 2>/dev/null || true
fi
find "${packages_dir}" -maxdepth 1 -name '*.deb' -exec cp {} "${staging_repo_dir}/pool/main/" \;

if ! find "${staging_repo_dir}/pool/main" -maxdepth 1 -name '*.deb' -print -quit | grep -q .; then
	echo "No deb packages available for publication" >&2
	exit 1
fi

binary_dir="${staging_repo_dir}/dists/${apt_suite}/${apt_component}/binary-${apt_arch}"
mkdir -p "${binary_dir}"

(
	cd "${staging_repo_dir}"
	dpkg-scanpackages --multiversion pool /dev/null > "${binary_dir}/Packages"
	gzip -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.gz"
	xz -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.xz"
	bzip2 -9 -c "${binary_dir}/Packages" > "${binary_dir}/Packages.bz2"
)

python3 - "${staging_repo_dir}" "${apt_suite}" "${apt_arch}" "${apt_component}" <<'PY'
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

rm -rf "${publish_dir:?}/${pages_repo_dir}"
mkdir -p "${publish_dir}/${pages_repo_dir}"
cp -a "${staging_repo_dir}/." "${publish_dir}/${pages_repo_dir}/"

(
	cd "${publish_dir}"
	git config user.name "$(git config --global --get user.name || echo 'termuxd builder')"
	git config user.email "$(git config --global --get user.email || echo 'termuxd-builder@users.noreply.github.com')"
	git add .nojekyll "${pages_repo_dir}"
	if git diff --cached --quiet; then
		echo "No apt pages changes to publish"
		exit 0
	fi
	git commit -m "Publish APT repo ${pages_repo_dir} for $(git -C "${repo_root}" rev-parse --short HEAD)"
	git push origin "${pages_branch}"
)

echo "Published APT repo path: ${pages_repo_dir}" >&2
