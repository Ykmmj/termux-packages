#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

packages_dir="${TERMUXD_BIONIC_OUTPUT_DIR:-${TERMUXD_OUTPUT_DIR}}"
filter_tmp_parent="${PAGES_TMPDIR:-${TERMUXD_REPO_ROOT}/.tmp-pages}"
mkdir -p "${filter_tmp_parent}"
filtered_dir="$(mktemp -d "${filter_tmp_parent%/}/bionic-filter.XXXXXX")"
read -r -a runtime_roots <<< "${TERMUXD_BIONIC_ROOT_PACKAGES}"

cleanup() {
	rm -rf "${filtered_dir}"
}
trap cleanup EXIT

python3 - "${packages_dir}" "${filtered_dir}" "${runtime_roots[@]}" <<'PY'
import os
import re
import shutil
import subprocess
import sys

packages_dir = sys.argv[1]
filtered_dir = sys.argv[2]
runtime_roots = sys.argv[3:]

if not runtime_roots:
    raise SystemExit("no bionic runtime packages requested")

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
for entry in sorted(os.listdir(packages_dir)):
    if not entry.endswith(".deb"):
        continue
    deb = os.path.join(packages_dir, entry)
    fields = control_fields(deb)
    name = fields.get("Package")
    arch = fields.get("Architecture")
    if not name:
        continue
    if name == "glibc" or name.startswith("glibc-") or name == "glibc32":
        continue
    if name.endswith("-glibc") or name.endswith("-glibc-static") or name.endswith("-static"):
        continue
    if arch not in {"aarch64", "all"}:
        continue
    package_candidates.setdefault(name, []).append({"path": deb, "fields": fields})

def select_candidate(name):
    candidates = package_candidates.get(name)
    if not candidates:
        raise SystemExit(f"required bionic package not found: {name}")
    return min(
        candidates,
        key=lambda item: (
            0 if item["fields"].get("Architecture") == "aarch64" else 1,
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

for name in sorted(selected_names):
    source = select_candidate(name)["path"]
    shutil.copy2(source, os.path.join(filtered_dir, os.path.basename(source)))

print(f"Selected {len(selected_names)} bionic runtime packages for publication", file=sys.stderr)
PY

APT_MERGE_EXISTING="${APT_MERGE_EXISTING:-true}" exec "${script_dir}/publish-apt-pages.sh" \
	"${TERMUXD_REPO_ROOT}" \
	"${filtered_dir}" \
	"${PAGES_REPO_DIR:-apt/bionic}"
