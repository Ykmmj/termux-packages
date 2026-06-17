#!/usr/bin/env bash
set -euo pipefail

TERMUXD_INVOCATION_DIR="${PWD}"
TERMUXD_BUILD_LOG="${TERMUXD_BUILD_LOG:-${TERMUXD_INVOCATION_DIR}/termuxd-glibc-build-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "${TERMUXD_BUILD_LOG}")"
touch "${TERMUXD_BUILD_LOG}"
echo "Writing build log to ${TERMUXD_BUILD_LOG}"
exec > >(tee -a "${TERMUXD_BUILD_LOG}") 2>&1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

read -r -a glibc_packages <<< "${TERMUXD_GLIBC_PACKAGES}"
read -r -a seed_packages <<< "${TERMUXD_GLIBC_SEED_PACKAGES}"
if [[ ${#glibc_packages[@]} -eq 0 ]]; then
	echo "TERMUXD_GLIBC_PACKAGES is empty" >&2
	exit 1
fi

if [[ ! -d "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}/.git" ]]; then
	echo "glibc-packages checkout not found: ${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}" >&2
	exit 1
fi

if [[ ! -d "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}/gpkg" ]]; then
	echo "glibc gpkg recipes not found: ${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}/gpkg" >&2
	exit 1
fi

source_abs="$(realpath "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}")"
work_abs="$(realpath -m "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}")"
if [[ "${source_abs}" == "${work_abs}" ]]; then
	echo "glibc source and generated workdir must be different: ${source_abs}" >&2
	exit 1
fi

if [[ -e "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}" ]]; then
	if [[ ! -f "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}/.termuxd-generated-workdir" ]]; then
		echo "refusing to remove unmarked glibc workdir: ${TERMUXD_GLIBC_PACKAGES_WORK_DIR}" >&2
		exit 1
	fi
	rm -rf "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}"
fi

mkdir -p "$(dirname "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}")"
source_head="$(git -C "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}" rev-parse HEAD)"
git clone -q --shared "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR}" "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}"
git -C "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}" checkout -q --detach "${source_head}"
touch "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}/.termuxd-generated-workdir"

build_system_paths=(
	build-package.sh
	clean.sh
	packages
	x11-packages
	root-packages
	scripts
	ndk-patches
)

for path in "${build_system_paths[@]}"; do
	rm -rf "${TERMUXD_GLIBC_PACKAGES_WORK_DIR:?}/${path}"
done

git -C "${TERMUXD_REPO_ROOT}" archive HEAD "${build_system_paths[@]}" \
	| tar -x -C "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}"

cd "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}"
if [[ ${#seed_packages[@]} -gt 0 ]]; then
	if termuxd_should_seed_glibc_prefix \
		"${TERMUXD_GLIBC_APT_REPO_URL}" \
		"${TERMUXD_GLIBC_APT_REPO_DISTRIBUTION}" \
		"${TERMUXD_GLIBC_APT_REPO_COMPONENT}" \
		"${TERMUXD_RUNTIME_ABI}"; then
		echo "Seeding glibc build prefix from APT repo: ${TERMUXD_GLIBC_APT_REPO_URL}"
		if [[ "${TERMUXD_USE_DOCKER}" == "true" ]]; then
			termuxd_prepare_docker_env_args
			env \
				CONTAINER_NAME="${TERMUXD_GLIBC_CONTAINER_NAME}" \
				TERMUX_DOCKER_RUN_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS}" \
				TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS}" \
				./scripts/run-docker.sh \
				bash scripts/termuxd/seed-glibc-apt-build-prefix.sh "${seed_packages[@]}"
		else
			SEED_ROOT_DIR="/" \
			TERMUX_BUILT_PACKAGES_DIRECTORY="/data/data/.built-packages" \
				bash scripts/termuxd/seed-glibc-apt-build-prefix.sh "${seed_packages[@]}"
		fi
	else
		echo "Skipping glibc build prefix seed; remote package index is empty or unavailable: ${TERMUXD_GLIBC_APT_REPO_URL}"
	fi
fi

build_package_args=()
termuxd_resolve_build_package_args \
	"${TERMUXD_GLIBC_APT_REPO_URL}" \
	"${TERMUXD_GLIBC_APT_REPO_DISTRIBUTION}" \
	build_package_args
args=(-a "${TERMUXD_RUNTIME_ABI}")
if [[ -n "${TERMUXD_BUILD_JOBS}" ]]; then
	args+=(-j "${TERMUXD_BUILD_JOBS}")
fi
args+=("${build_package_args[@]}")
args+=(--format debian --library glibc -L)

echo "Building termuxd glibc packages: ${glibc_packages[*]}"
echo "CGCT_APP_PREFIX target: ${TERMUXD_GLIBC_PREFIX_PATH}"
echo "Requested build package mode: ${TERMUXD_BUILD_PACKAGE_MODE}"
echo "Build jobs: ${TERMUXD_BUILD_JOBS:-build-package default}"
if [[ ${#build_package_args[@]} -gt 0 ]]; then
	echo "Resolved build package args: ${build_package_args[*]}"
else
	echo "Resolved build package args: <none>"
fi

if [[ "${TERMUXD_USE_DOCKER}" == "true" ]]; then
	termuxd_prepare_docker_env_args
	if [[ "${TERMUXD_REBUILD_ROOT_PACKAGES}" == "true" ]]; then
		env \
			CONTAINER_NAME="${TERMUXD_GLIBC_CONTAINER_NAME}" \
			TERMUX_DOCKER_RUN_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS}" \
			TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS}" \
			./scripts/run-docker.sh bash -lc '
				set -euo pipefail
				mkdir -p /data/data/.built-packages
				for package_name in "$@"; do
					rm -f "/data/data/.built-packages/${package_name}"
				done
			' bash "${glibc_packages[@]}"
	fi
	exec env \
		CONTAINER_NAME="${TERMUXD_GLIBC_CONTAINER_NAME}" \
		TERMUX_DOCKER_RUN_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS}" \
		TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS}" \
		./scripts/run-docker.sh ./build-package.sh "${args[@]}" "${glibc_packages[@]}"
fi

termuxd_clear_built_markers "${glibc_packages[@]}"
exec ./build-package.sh "${args[@]}" "${glibc_packages[@]}"
