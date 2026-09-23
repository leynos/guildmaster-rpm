#!/usr/bin/env bash
set -euo pipefail
state=${PODMAN_STUB_STATE}
mkdir -p "${state}/containers" "${state}/images"
slug() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }

sub=$1
shift
case ${sub} in
commit)
    : >"${state}/images/$(slug "$2")"
    exit 0
    ;;
rm)
    rm -f "${state}/containers/$(slug "${!#}")"
    exit 0
    ;;
rmi)
    rm -f "${state}/images/$(slug "${!#}")"
    exit 0
    ;;
esac

args=("$@")
name=
out=
mode=
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
    case ${args[i]} in
    --name)
        name=${args[i + 1]}
        i=$((i + 2))
        ;;
    --network=* | --rm) i=$((i + 1)) ;;
    -v)
        case ${args[i + 1]} in
        *:/out:z)
            out=${args[i + 1]%%:/out:z}
            mode=rw
            ;;
        *:/out:ro,z) mode=ro ;;
        esac
        i=$((i + 2))
        ;;
    *) break ;;
    esac
done

if [[ -n ${name} ]]; then
    : >"${state}/containers/$(slug "${name}")"
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == deps ]]; then
        echo "podman stub: simulated dependency failure" >&2
        exit 1
    fi
    exit 0
fi

if [[ ${mode} == ro ]]; then
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == rebuild ]]; then
        echo "podman stub: simulated rebuild failure" >&2
        exit 1
    fi
    exit 0
fi

if [[ -n ${PODMAN_STUB_STARTED_FIFO:-} ]]; then
    echo started >"${PODMAN_STUB_STARTED_FIFO}"
fi
if [[ -n ${PODMAN_STUB_WAIT_FIFO:-} ]]; then
    read -r _ <"${PODMAN_STUB_WAIT_FIFO}"
fi
if [[ ${PODMAN_STUB_FAIL_PHASE:-} == build ]]; then
    echo "podman stub: simulated build failure" >&2
    exit 1
fi

mkdir -p "${out}/srpm"
echo "${PODMAN_STUB_TAG}" >"${out}/@BASE@"
if [[ -z ${PODMAN_STUB_PARTIAL:-} ]]; then
    echo "${PODMAN_STUB_TAG}" >"${out}/@DEBUGINFO@"
    echo "${PODMAN_STUB_TAG}" >"${out}/@DEBUGSOURCE@"
    echo "${PODMAN_STUB_TAG}" >"${out}/@SRC@"
fi

: >"${out}/@MANIFEST@"
for f in "${out}"/*.rpm "${out}"/srpm/*.src.rpm; do
    [[ -e ${f} ]] || continue
    rel=${f#"${out}/"}
    stem=$(basename "${rel}")
    stem=${stem%.rpm}
    arch=${stem##*.}
    if [[ ${arch} == src ]]; then arch=@ARCH@; fi
    stem=${stem%.*}
    release=${stem##*-}
    name_ver=${stem%-*}
    version=${name_ver##*-}
    pkg=${name_ver%-*}
    sum=$(sha256sum "${f}" | cut -d' ' -f1)
    printf '%s\t%s\t(none)\t%s\t%s\t%s\t%s\n' "${rel}" "${pkg}" "${version}" "${release}" "${arch}" "${sum}" >>"${out}/@MANIFEST@"
done
