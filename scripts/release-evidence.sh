#!/usr/bin/env bash
# Tie the evidence from every test tier to one set of candidate packages.
#
# Usage: scripts/release-evidence.sh
#
# Run as the last step of "make release-check". Each tier writes an evidence
# file under .build/evidence/ only when it passes. This script refuses to
# produce a release-candidate record unless, for every supported target:
#   - the container tier and the fresh-guest CUSE tier both left evidence;
#   - both name the current source commit;
#   - both list exactly the package checksums in dist/<target>/manifest.tsv.
# So a stale pass, a pass against other bytes, or a missing tier cannot be
# mistaken for release evidence. It then writes
# .build/evidence/release-candidate.txt, which the release procedure attaches.
#
# It does not run any test and makes no claim of its own beyond this
# cross-check.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
: "${CACHE_DIR:=${repo_root}/.build}"
: "${EVIDENCE_DIR:=${CACHE_DIR}/evidence}"
: "${DIST_DIR:=${repo_root}/dist}"
: "${TARGETS:=rocky-10 fedora-43}"
: "${SOURCE_COMMIT:=$(git -C "${repo_root}" rev-parse HEAD)}"

problems=0
# problem <message>: report a cross-check failure.
#
# Prints "release-evidence: <message>" to stderr and increments the shared
# "problems" counter. Always returns 0.
problem() {
    echo "release-evidence: $*" >&2
    problems=$((problems + 1))
}

# field <file> <name>: print the value of a "<name>: " field in <file>.
field() {
    sed -n "s/^$2: //p" "$1" | head -n 1
}

# The "rpms:" block of an evidence file, normalized for comparison.
#
# evidence_rpms <file>: print the sorted "rpms:" block of an evidence file.
evidence_rpms() {
    sed -n '/^rpms:$/,/^[a-z_]*:/{/^  /p}' "$1" | sed 's/^  //' | LC_ALL=C sort
}

for target in ${TARGETS}; do
    manifest=${DIST_DIR}/${target}/manifest.tsv
    if [[ ! -f ${manifest} ]]; then
        problem "${target}: no manifest at ${manifest}"
        continue
    fi
    expected=$(cut -f1,7 "${manifest}" | LC_ALL=C sort)
    for tier in container cuse; do
        case ${tier} in
        container) file=${EVIDENCE_DIR}/container-${target}.txt ;;
        cuse) file=${EVIDENCE_DIR}/cuse-${target}-candidate.txt ;;
        esac
        if [[ ! -f ${file} ]]; then
            problem "${target}: no passing ${tier} evidence (${file})"
            continue
        fi
        [[ $(field "${file}" result) == passed ]] ||
            problem "${target}: ${tier} evidence does not record a pass"
        [[ $(field "${file}" source_commit) == "${SOURCE_COMMIT}" ]] ||
            problem "${target}: ${tier} evidence is for commit $(field "${file}" source_commit), not ${SOURCE_COMMIT}"
        [[ $(field "${file}" source_tree_dirty) == no ]] ||
            problem "${target}: ${tier} evidence was produced from a modified working tree"
        [[ $(evidence_rpms "${file}") == "${expected}" ]] ||
            problem "${target}: ${tier} evidence is for different package bytes than dist/${target}"
    done
done

if [[ ${problems} -ne 0 ]]; then
    echo "release-evidence: ${problems} problem(s); no release-candidate record written" >&2
    exit 1
fi

record=${EVIDENCE_DIR}/release-candidate.txt
{
    echo "source_commit: ${SOURCE_COMMIT}"
    echo "targets: ${TARGETS}"
    for target in ${TARGETS}; do
        echo
        echo "== ${target}: candidate packages (sha256  file)"
        awk -F'\t' '{ print $7 "  " $1 }' "${DIST_DIR}/${target}/manifest.tsv"
        for file in "${EVIDENCE_DIR}/container-${target}.txt" \
            "${EVIDENCE_DIR}/cuse-${target}-candidate.txt"; do
            echo
            echo "-- $(basename "${file}")"
            cat "${file}"
        done
    done
} >"${record}"
echo "release-evidence: wrote ${record}"
