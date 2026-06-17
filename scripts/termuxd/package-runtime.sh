#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

TERMUXD_BIONIC_OUTPUT_DIR="${TERMUXD_BIONIC_OUTPUT_DIR:-${TERMUXD_OUTPUT_DIR}}"
TERMUXD_GLIBC_OUTPUT_DIR="${TERMUXD_GLIBC_OUTPUT_DIR:-${TERMUXD_GLIBC_PACKAGES_WORK_DIR}/output}"
stage_dir="${TERMUXD_STAGE_DIR:-${TERMUXD_REPO_ROOT}/build/termuxd-runtime-staging}"
runtime_debs_file="${stage_dir}/runtime-debs.txt"
read -r -a runtime_roots <<< "${TERMUXD_BIONIC_ROOT_PACKAGES}"

rm -rf "${stage_dir}" "${TERMUXD_DIST_DIR}"
mkdir -p "${stage_dir}/extract-root" "${stage_dir}/packages" "${TERMUXD_DIST_DIR}"

python3 - "${TERMUXD_BIONIC_OUTPUT_DIR}" "${TERMUXD_GLIBC_OUTPUT_DIR}" "${runtime_debs_file}" "${runtime_roots[@]}" <<'PY'
import os
import re
import subprocess
import sys

deb_dirs = sys.argv[1:3]
runtime_selected_path = sys.argv[3]
runtime_roots = sys.argv[4:]

if not runtime_roots:
    raise SystemExit("no runtime packages requested")

def control_fields(deb):
    raw = subprocess.check_output(["dpkg-deb", "-f", deb], text=True)
    fields = {}
    current = None
    for line in raw.splitlines():
        if not line:
            continue
        if line[0].isspace() and current:
            fields[current] += "\n" + line
            continue
        key, _, value = line.partition(":")
        current = key
        fields[key] = value.strip()
    return fields

def split_dep_groups(value):
    groups = []
    current = []
    depth = 0
    for char in value:
        if char == "(":
            depth += 1
        elif char == ")" and depth:
            depth -= 1
        elif char == "," and depth == 0:
            groups.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    if current:
        groups.append("".join(current).strip())
    return [group for group in groups if group]

def dep_name(value):
    value = re.sub(r"\([^)]*\)", "", value).strip()
    value = value.split()[0]
    return value.split(":", 1)[0]

package_candidates = {}
for priority, deb_dir in enumerate(deb_dirs):
    if not os.path.isdir(deb_dir):
        continue
    for entry in sorted(os.listdir(deb_dir)):
        if not entry.endswith(".deb"):
            continue
        deb = os.path.join(deb_dir, entry)
        fields = control_fields(deb)
        name = fields.get("Package")
        arch = fields.get("Architecture")
        if not name or name.endswith("-static"):
            continue
        if arch not in {"aarch64", "all"}:
            continue
        package_candidates.setdefault(name, []).append(
            {"path": deb, "fields": fields, "priority": priority}
        )

def select_candidate(name):
    candidates = package_candidates.get(name)
    if not candidates:
        raise SystemExit(f"required runtime package not found: {name}")
    return min(
        candidates,
        key=lambda item: (
            0 if item["fields"].get("Architecture") == "aarch64" else 1,
            item["priority"],
            item["path"],
        ),
    )

selected_names = []
seen = set()
queue = list(runtime_roots)
while queue:
    name = queue.pop(0)
    if name in seen:
        continue
    package = select_candidate(name)
    seen.add(name)
    selected_names.append(name)
    fields = package["fields"]
    dependencies = []
    for field_name in ("Pre-Depends", "Depends"):
        if fields.get(field_name):
            dependencies.extend(split_dep_groups(fields[field_name]))
    for group in dependencies:
        alternatives = [dep_name(part) for part in group.split("|")]
        chosen = next((alt for alt in alternatives if alt in package_candidates), None)
        if chosen is None:
            raise SystemExit(f"{name} dependency not found: {group}")
        if chosen not in seen:
            queue.append(chosen)

with open(runtime_selected_path, "w", encoding="utf-8") as handle:
    for name in sorted(selected_names):
        handle.write(select_candidate(name)["path"] + "\n")
PY

prefix_relative="${TERMUXD_PREFIX_PATH#/}"
runtime_relative="${TERMUXD_RUNTIME_PATH#/}"
stage_prefix_dir="${stage_dir}/extract-root/${prefix_relative}"
dpkg_info_dir="${stage_prefix_dir}/var/lib/dpkg/info"
dpkg_status_file="${stage_prefix_dir}/var/lib/dpkg/status"

mkdir -p \
	"${dpkg_info_dir}" \
	"${stage_prefix_dir}/var/lib/dpkg/triggers" \
	"${stage_prefix_dir}/var/lib/dpkg/updates" \
	"${stage_prefix_dir}/var/log/apt"
touch "${stage_prefix_dir}/var/lib/dpkg/available" "${dpkg_status_file}"

while IFS= read -r deb; do
	current_package_name="$(dpkg-deb -f "${deb}" Package)"
	package_tmpdir="${stage_dir}/packages/${current_package_name}"
	rm -rf "${package_tmpdir}"
	mkdir -p "${package_tmpdir}"

	(
		cd "${package_tmpdir}"
		ar x "${deb}"
		data_archive="$(find . -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
		control_archive="$(find . -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
		tar xf "${data_archive}" -C "${stage_dir}/extract-root"
		tar tf "${data_archive}" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${dpkg_info_dir}/${current_package_name}.list"
		tar xf "${data_archive}"
		find . -type f -print0 | xargs -0 -r md5sum | sed 's@  \./@  @' > "${dpkg_info_dir}/${current_package_name}.md5sums"
		tar xf "${control_archive}"
		{
			cat control
			echo "Status: install ok installed"
			echo
		} >> "${dpkg_status_file}"
		for control_file in conffiles postinst postrm preinst prerm; do
			if [[ -f "${control_file}" ]]; then
				cp "${control_file}" "${dpkg_info_dir}/${current_package_name}.${control_file}"
			fi
		done
	)
done < "${runtime_debs_file}"

extracted_runtime_dir="${stage_dir}/extract-root/${runtime_relative}"
if [[ ! -d "${extracted_runtime_dir}" ]]; then
	echo "extracted runtime path not found: ${extracted_runtime_dir}" >&2
	exit 1
fi

mkdir -p "${stage_dir}/runtime"
cp -a "${extracted_runtime_dir}/." "${stage_dir}/runtime/"

prefix_under_runtime="${TERMUXD_PREFIX_PATH#${TERMUXD_RUNTIME_PATH}/}"
stage_runtime_prefix="${stage_dir}/runtime/${prefix_under_runtime}"
mkdir -p \
	"${stage_runtime_prefix}/etc/apt/apt.conf.d" \
	"${stage_runtime_prefix}/etc/apt/preferences.d" \
	"${stage_runtime_prefix}/etc/apt/sources.list.d" \
	"${stage_runtime_prefix}/etc/profile.d" \
	"${stage_runtime_prefix}/var/lib/apt/lists/partial" \
	"${stage_runtime_prefix}/var/cache/apt/archives/partial" \
	"${stage_runtime_prefix}/var/log/apt" \
	"${stage_runtime_prefix}/tmp"

cat > "${stage_runtime_prefix}/etc/apt/sources.list" <<EOF
${TERMUXD_BIONIC_APT_SOURCE}
EOF
cat > "${stage_runtime_prefix}/etc/apt/sources.list.d/glibc.list" <<EOF
${TERMUXD_GLIBC_APT_SOURCE}
EOF
cat > "${stage_runtime_prefix}/etc/apt/apt.conf.d/99termuxd-local" <<EOF
Dir::Cache "${TERMUXD_CACHE_PATH}/apt";
Dir::Cache::archives "${TERMUXD_CACHE_PATH}/apt/archives";
Acquire::Languages "none";
EOF
cat > "${stage_runtime_prefix}/etc/profile.d/00-termuxd.sh" <<EOF
export TERMUXD_ROOT="${TERMUXD_ROOT_PATH}"
export TERMUXD_RUNTIME="${TERMUXD_RUNTIME_PATH}"
export PREFIX="${TERMUXD_PREFIX_PATH}"
export TERMUX_PREFIX="${TERMUXD_PREFIX_PATH}"
export TMPDIR="${TERMUXD_PREFIX_PATH}/tmp"
export HOME="\${HOME:-${TERMUXD_RUNTIME_PATH}/home}"
case ":\${PATH:-}:" in
	*:"${TERMUXD_PREFIX_PATH}/bin":*) ;;
	*) export PATH="${TERMUXD_PREFIX_PATH}/bin:\${PATH:-/system/bin}" ;;
esac
EOF

cat > "${stage_dir}/runtime/termuxd-shell" <<EOF
#!/system/bin/sh
export TERMUXD_ROOT="${TERMUXD_ROOT_PATH}"
export TERMUXD_RUNTIME="${TERMUXD_RUNTIME_PATH}"
export PREFIX="${TERMUXD_PREFIX_PATH}"
export TERMUX_PREFIX="${TERMUXD_PREFIX_PATH}"
export TMPDIR="${TERMUXD_PREFIX_PATH}/tmp"
export HOME="\${HOME:-${TERMUXD_RUNTIME_PATH}/home}"
case ":\${PATH:-}:" in
	*:"${TERMUXD_PREFIX_PATH}/bin":*) ;;
	*) export PATH="${TERMUXD_PREFIX_PATH}/bin:\${PATH:-/system/bin}" ;;
esac
mkdir -p "\${HOME}" "\${TMPDIR}" "${TERMUXD_CACHE_PATH}/apt/archives/partial" 2>/dev/null || true

if [ "\$#" -eq 0 ]; then
	exec "${TERMUXD_PREFIX_PATH}/bin/bash" -l
fi

exec "${TERMUXD_PREFIX_PATH}/bin/bash" -lc "\$*"
EOF
chmod 755 "${stage_dir}/runtime/termuxd-shell"

if [[ ! -e "${stage_runtime_prefix}/bin/sh" && -x "${stage_runtime_prefix}/bin/bash" ]]; then
	ln -s bash "${stage_runtime_prefix}/bin/sh"
fi

tar --sort=name --owner=0 --group=0 --numeric-owner -C "${stage_dir}" -cf - runtime \
	| zstd -19 -T0 -o "${TERMUXD_DIST_DIR}/runtime-image.tar.zst" >/dev/null

runtime_sha="$(sha256sum "${TERMUXD_DIST_DIR}/runtime-image.tar.zst" | awk '{print $1}')"
termux_packages_revision="$(git -C "${TERMUXD_REPO_ROOT}" rev-parse HEAD)"

python3 - \
	"${TERMUXD_DIST_DIR}/manifest.json" \
	"${stage_runtime_prefix}/var/lib/dpkg/status" \
	"${termux_packages_revision}" \
	"${runtime_sha}" \
	"${TERMUXD_ROOT_PATH}" \
	"${TERMUXD_RUNTIME_PATH}" \
	"${TERMUXD_PREFIX_PATH}" \
	"${TERMUXD_BIONIC_APT_SOURCE}" \
	"${TERMUXD_GLIBC_APT_SOURCE}" <<'PY'
import json
import sys

(
    manifest_path,
    status_path,
    revision,
    runtime_sha,
    root_path,
    rootfs_path,
    prefix_path,
    bionic_source,
    glibc_source,
) = sys.argv[1:]
packages = []
current = {}
with open(status_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            if current.get("Package"):
                packages.append(current["Package"])
            current = {}
            continue
        if ": " in line:
            key, value = line.split(": ", 1)
            current[key] = value
if current.get("Package"):
    packages.append(current["Package"])

manifest = {
    "schema_version": 2,
    "abi": "aarch64",
    "android_api": 31,
    "root": root_path,
    "rootfs": rootfs_path,
    "prefix": prefix_path,
    "build_revision": f"termux-packages:{revision}",
    "package_set": sorted(set(packages)),
    "apt_sources": [line for line in (bionic_source, glibc_source) if line],
    "artifacts": {
        "runtime-image.tar.zst": {"sha256": runtime_sha},
    },
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

sha256sum "${TERMUXD_DIST_DIR}/runtime-image.tar.zst" "${TERMUXD_DIST_DIR}/manifest.json" \
	> "${TERMUXD_DIST_DIR}/SHA256SUMS"

echo "Packaged runtime artifacts in ${TERMUXD_DIST_DIR}"
