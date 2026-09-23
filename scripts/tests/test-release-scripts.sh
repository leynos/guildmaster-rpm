#!/usr/bin/env bash
# Offline tests for scripts/assemble-release.sh and scripts/release-evidence.sh.
#
# No network, no containers and no rpm binary: fake "RPM" files are arbitrary
# bytes, and manifest.tsv and evidence files are built by hand in the same
# shape the real build and test tiers write, with real sha256sum values so
# the scripts' own checksum checks are exercised for real.
#
# ASSEMBLE_SCRIPT and EVIDENCE_SCRIPT point the whole suite at a script under
# test; they default to the real scripts, and are also used at the end of
# this file to run the whole suite again against three deliberately broken
# mutant copies, to check that the suite actually catches their bugs.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
: "${ASSEMBLE_SCRIPT:=${repo_root}/scripts/assemble-release.sh}"
: "${EVIDENCE_SCRIPT:=${repo_root}/scripts/release-evidence.sh}"

scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

passed=0
failed=0
current=

# ok <message>: record a passing check for the current test.
ok() {
    passed=$((passed + 1))
    echo "ok: ${current}: $*"
}

# not_ok <message>: record a failing check for the current test.
not_ok() {
    failed=$((failed + 1))
    echo "FAIL: ${current}: $*" >&2
}

# assert_status <actual> <expected>: pass or fail on whether the two exit
# statuses match.
assert_status() {
    if [[ $1 -eq $2 ]]; then ok "exit status $2"; else not_ok "exit status $1, expected $2"; fi
}

# assert_contains <file> <needle> <message>: pass when <file> contains
# <needle>; otherwise fail and dump the file for diagnosis.
assert_contains() {
    if grep -qF -- "$2" "$1"; then ok "$3"; else
        not_ok "$3 (no '$2' in $1)"
        sed 's/^/    | /' "$1" >&2
    fi
}

# assert_lacks <file> <needle> <message>: pass when <file> does not contain
# <needle>.
assert_lacks() {
    if grep -qF -- "$2" "$1"; then not_ok "$3 (found '$2' in $1)"; else ok "$3"; fi
}

# --- fixture helpers ----------------------------------------------------------

# add_pkg <dir> <relative-filename> <name> <version> <release> <arch> [epoch]
# Writes an arbitrary-bytes file at <dir>/<relative-filename> and appends its
# manifest.tsv line, with a real sha256sum of the bytes written.
add_pkg() {
    local dir=$1 filename=$2 name=$3 version=$4 release=$5 arch=$6 epoch=${7:-'(none)'}
    local path=${dir}/${filename}
    mkdir -p "$(dirname "${path}")"
    printf 'rpm-bytes:%s:%s\n' "${filename}" "${RANDOM}${RANDOM}${RANDOM}" >"${path}"
    local sha
    sha=$(sha256sum "${path}" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${filename}" "${name}" "${epoch}" \
        "${version}" "${release}" "${arch}" "${sha}" >>"${dir}/manifest.tsv"
}

# build_target <dir> <dist> <version> <release> <arch>
# Writes a complete, valid four-package target directory: manifest.tsv plus
# the binary, debuginfo, debugsource and srpm packages it lists.
build_target() {
    local dir=$1 dist=$2 version=$3 release=$4 arch=$5
    mkdir -p "${dir}"
    : >"${dir}/manifest.tsv"
    local nvr="${version}-${release}.${dist}"
    add_pkg "${dir}" "guildmaster-${nvr}.${arch}.rpm" guildmaster "${version}" "${release}.${dist}" "${arch}"
    add_pkg "${dir}" "guildmaster-debuginfo-${nvr}.${arch}.rpm" guildmaster-debuginfo "${version}" "${release}.${dist}" "${arch}"
    add_pkg "${dir}" "guildmaster-debugsource-${nvr}.${arch}.rpm" guildmaster-debugsource "${version}" "${release}.${dist}" "${arch}"
    add_pkg "${dir}" "srpm/guildmaster-${nvr}.src.rpm" guildmaster "${version}" "${release}.${dist}" src
}

# build_spec <path> <commit> <snapshot> <upstream> <release>
# Writes only the four lines assemble-release.sh actually parses.
build_spec() {
    local path=$1 commit=$2 snapshot=$3 upstream=$4 release=$5
    cat >"${path}" <<EOF
%global commit          ${commit}
%global snapshotdate    ${snapshot}
%global upstream_version ${upstream}
Release:        ${release}%{?dist}
EOF
}

# The baseline spec fields, matching the real guildmaster.spec in shape (not
# in value, so a copy-paste mistake in the real spec would not mask a bug
# here).
commit=abcdef01234567890
snapshot=20260101
upstream=1.2
release=3
version="${upstream}^${snapshot}git${commit:0:7}"
dist_rocky=el10
dist_fedora=fc43
arch=x86_64
expected_tag="v${version/^/-}-${release}"
source_commit=deadbeefcafef00d

# new_assemble_scenario <name>: a scenario directory with the baseline spec
# in place; tests then add target directories and break one thing.
new_assemble_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    mkdir -p "${SCENARIO}/artefacts"
    build_spec "${SCENARIO}/spec" "${commit}" "${snapshot}" "${upstream}" "${release}"
}

# Builds both targets validly, as a base every assemble scenario can start
# from and then break.
build_valid_targets() {
    build_target "${SCENARIO}/artefacts/rocky-10" "${dist_rocky}" "${version}" "${release}" "${arch}"
    build_target "${SCENARIO}/artefacts/fedora-43" "${dist_fedora}" "${version}" "${release}" "${arch}"
}

# run_assemble [extra env assignments...]: run assemble-release.sh against
# the current scenario; output in ${SCENARIO}/stdout and .../stderr, status
# in $status.
run_assemble() {
    status=0
    env SPEC="${SCENARIO}/spec" SOURCE_COMMIT="${source_commit}" "$@" \
        "${ASSEMBLE_SCRIPT}" "${tag:-${expected_tag}}" "${SCENARIO}/artefacts" "${SCENARIO}/assets" \
        >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# Asserts the common failure shape: the run failed, and left neither an asset
# directory nor a stray .assets.* staging directory next to it.
assert_clean_failure() {
    assert_status "${status}" 1
    if [[ ! -e ${SCENARIO}/assets ]]; then ok 'no asset directory is left'; else not_ok 'asset directory left behind'; fi
    if [[ -z $(find "${SCENARIO}" -maxdepth 1 -name '.assets.*') ]]; then
        ok 'no .assets.* staging directory is left'
    else
        not_ok '.assets.* staging directory left behind'
    fi
}

# --- assemble-release.sh: accept ---------------------------------------------

new_assemble_scenario assemble_accept
build_valid_targets
mkdir -p "${SCENARIO}/evidence"
echo 'container evidence body' >"${SCENARIO}/evidence/a.txt"
echo 'aggregate record that repeats every tier' >"${SCENARIO}/evidence/release-candidate.txt"
run_assemble EVIDENCE_DIR="${SCENARIO}/evidence"
assert_status "${status}" 0
assert_lacks "${SCENARIO}/assets/release-notes.md" 'aggregate record that repeats every tier' \
    'release-candidate.txt is not embedded, so no evidence appears twice'
if [[ $(find "${SCENARIO}/assets" -name '*.rpm' | wc -l) -eq 8 ]]; then
    ok 'exactly 8 RPMs are written'
else not_ok "wrong RPM count: $(find "${SCENARIO}/assets" -name '*.rpm' | wc -l)"; fi
if [[ -f ${SCENARIO}/assets/SHA256SUMS && -f ${SCENARIO}/assets/release-notes.md ]]; then
    ok 'SHA256SUMS and release-notes.md are written'
else not_ok 'SHA256SUMS or release-notes.md missing'; fi
find "${SCENARIO}/assets" -maxdepth 1 -type f -printf '%f\n' >"${SCENARIO}/asset-names"
assert_lacks "${SCENARIO}/asset-names" '^' 'no asset name contains a caret'
if (cd "${SCENARIO}/assets" && sha256sum -c --status SHA256SUMS); then
    ok 'sha256sum -c SHA256SUMS passes inside the asset directory'
else not_ok 'SHA256SUMS does not verify'; fi
if grep -q '/' "${SCENARIO}/assets/SHA256SUMS"; then
    not_ok 'SHA256SUMS names are not release-relative'
else ok 'SHA256SUMS names are bare, release-relative names'; fi
assert_contains "${SCENARIO}/assets/release-notes.md" "${source_commit}" 'the release notes mention the packaging commit'
assert_contains "${SCENARIO}/assets/release-notes.md" "${expected_tag}" 'the release notes mention the tag'
assert_contains "${SCENARIO}/assets/release-notes.md" 'unsigned' 'the release notes mention the packages are unsigned'
assert_contains "${SCENARIO}/assets/release-notes.md" '0001-add-tokens-option.patch' 'the release notes mention the downstream patch'
assert_contains "${SCENARIO}/assets/release-notes.md" 'container evidence body' 'the evidence directory content is embedded in the notes'

# --- assemble-release.sh: tag/spec mismatch ----------------------------------

new_assemble_scenario assemble_wrong_release
build_valid_targets
build_spec "${SCENARIO}/spec" "${commit}" "${snapshot}" "${upstream}" 9
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'does not match the spec' 'a release number mismatch is refused'

new_assemble_scenario assemble_wrong_version
build_valid_targets
build_spec "${SCENARIO}/spec" "${commit}" "${snapshot}" 9.9 "${release}"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'does not match the spec' 'a version mismatch is refused'

# --- assemble-release.sh: missing target directory / manifest ---------------

new_assemble_scenario assemble_missing_target_dir
build_valid_targets
rm -rf "${SCENARIO}/artefacts/fedora-43"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'no artefact directory' 'a missing target directory is refused'

new_assemble_scenario assemble_missing_manifest
build_valid_targets
rm -f "${SCENARIO}/artefacts/fedora-43/manifest.tsv"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'no manifest.tsv' 'a missing manifest is refused'

# --- assemble-release.sh: one package missing from manifest and directory ---

for kind in binary debuginfo debugsource srpm; do
    new_assemble_scenario "assemble_missing_${kind}"
    build_valid_targets
    dir=${SCENARIO}/artefacts/rocky-10
    nvr="${version}-${release}.${dist_rocky}"
    case ${kind} in
    binary) victim="guildmaster-${nvr}.${arch}.rpm" ;;
    debuginfo) victim="guildmaster-debuginfo-${nvr}.${arch}.rpm" ;;
    debugsource) victim="guildmaster-debugsource-${nvr}.${arch}.rpm" ;;
    srpm) victim="srpm/guildmaster-${nvr}.src.rpm" ;;
    esac
    rm -f "${dir}/${victim}"
    grep -vF "$(printf '%s\t' "${victim}")" "${dir}/manifest.tsv" >"${dir}/manifest.tsv.new"
    mv "${dir}/manifest.tsv.new" "${dir}/manifest.tsv"
    run_assemble
    assert_clean_failure
    assert_contains "${SCENARIO}/stderr" 'does not list exactly the expected packages' \
        "a missing ${kind} package is refused"
done

# --- assemble-release.sh: extra files / extra manifest line -----------------

new_assemble_scenario assemble_extra_rpm_file
build_valid_targets
dir=${SCENARIO}/artefacts/rocky-10
nvr="${version}-${release}.${dist_rocky}"
echo 'unexpected devel package bytes' >"${dir}/guildmaster-devel-${nvr}.${arch}.rpm"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'unexpected or missing files' 'an unlisted extra rpm file is refused'

new_assemble_scenario assemble_extra_stray_file
build_valid_targets
echo 'not an rpm at all' >"${SCENARIO}/artefacts/rocky-10/notes.txt"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'unexpected or missing files' 'an unlisted stray non-rpm file is refused'

new_assemble_scenario assemble_extra_manifest_line
build_valid_targets
dir=${SCENARIO}/artefacts/rocky-10
nvr="${version}-${release}.${dist_rocky}"
add_pkg "${dir}" "guildmaster-devel-${nvr}.${arch}.rpm" guildmaster-devel "${version}" "${release}.${dist_rocky}" "${arch}"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'does not list exactly the expected packages' 'an extra manifest line is refused'

# --- assemble-release.sh: dist tag, arch and epoch checks --------------------

new_assemble_scenario assemble_wrong_dist_tag
build_valid_targets
rm -rf "${SCENARIO}/artefacts/fedora-43"
# fedora-43 is expected to carry fc43 files; give it el10 files instead.
build_target "${SCENARIO}/artefacts/fedora-43" "${dist_rocky}" "${version}" "${release}" "${arch}"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'does not list exactly the expected packages' \
    'files carrying the wrong distribution tag are refused'

new_assemble_scenario assemble_noarch_binary
build_valid_targets
dir=${SCENARIO}/artefacts/rocky-10
nvr="${version}-${release}.${dist_rocky}"
sed -i "s/^\(guildmaster-${nvr}\.${arch}\.rpm\tguildmaster\t(none)\t[^\t]*\t[^\t]*\t\)${arch}\t/\1noarch\t/" \
    "${dir}/manifest.tsv"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" "has arch noarch, expected ${arch}" 'a noarch binary package entry is refused'

new_assemble_scenario assemble_nonempty_epoch
build_valid_targets
dir=${SCENARIO}/artefacts/rocky-10
nvr="${version}-${release}.${dist_rocky}"
sed -i "s/^\(guildmaster-${nvr}\.${arch}\.rpm\tguildmaster\t\)(none)\t/\10\t/" "${dir}/manifest.tsv"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'has epoch 0' 'a non-empty epoch is refused'

# --- assemble-release.sh: checksum mismatch ----------------------------------

new_assemble_scenario assemble_checksum_mismatch
build_valid_targets
dir=${SCENARIO}/artefacts/rocky-10
nvr="${version}-${release}.${dist_rocky}"
echo 'tampered bytes' >"${dir}/guildmaster-${nvr}.${arch}.rpm"
run_assemble
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'does not match its manifest checksum' 'a file with the wrong bytes is refused'

# --- assemble-release.sh: duplicate asset name across targets ---------------

new_assemble_scenario assemble_duplicate_asset_name
build_target "${SCENARIO}/artefacts/rocky-10" "${dist_rocky}" "${version}" "${release}" "${arch}"
run_assemble TARGETS='rocky-10 rocky-10'
assert_clean_failure
assert_contains "${SCENARIO}/stderr" 'occurs more than once across targets' \
    'the same target processed twice under TARGETS collides on asset name'

# --- assemble-release.sh: pre-existing asset directory -----------------------

new_assemble_scenario assemble_preexisting_asset_dir
build_valid_targets
mkdir -p "${SCENARIO}/assets"
echo 'sentinel' >"${SCENARIO}/assets/sentinel.txt"
run_assemble
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'already exists' 'a pre-existing asset directory is refused'
if [[ -f ${SCENARIO}/assets/sentinel.txt && $(find "${SCENARIO}/assets" -type f | wc -l) -eq 1 ]]; then
    ok 'the pre-existing asset directory is left untouched'
else not_ok 'the pre-existing asset directory was modified'; fi

# --- release-evidence.sh -----------------------------------------------------

# add_manifest_pkg <dir> <name-token> writes one manifest.tsv line for a
# fictitious package, with a real sha256sum of its (also fictitious) bytes.
add_manifest_pkg() {
    local dir=$1 token=$2
    add_pkg "${dir}" "guildmaster-${token}.rpm" "guildmaster" "1.0" "1.el10" x86_64
}

# build_dist_manifest <dir> writes a small, fixed manifest.tsv that
# release-evidence.sh treats as the candidate package set for a target.
build_dist_manifest() {
    local dir=$1
    mkdir -p "${dir}"
    : >"${dir}/manifest.tsv"
    add_manifest_pkg "${dir}" bin
    add_manifest_pkg "${dir}" debuginfo
}

# evidence_rpms_block <manifest> renders the "rpms:" block release-evidence.sh
# expects, in the same shape write_evidence in systemd-fixture.sh and
# cuse-guest.sh produce it.
evidence_rpms_block() {
    cut -f1,7 "$1" | sed 's/^/  /'
}

# write_container_evidence <path> <target> <result> <commit> <dirty> <manifest>
write_container_evidence() {
    local path=$1 target=$2 result=$3 commit=$4 dirty=$5 manifest=$6
    {
        echo "tier: rootless systemd container"
        echo "target: ${target}"
        echo "plan: full"
        echo "result: ${result}"
        echo "source_commit: ${commit}"
        echo "source_tree_dirty: ${dirty}"
        echo "base_image: fake"
        echo "fixture_image: fake"
        echo "host_kernel: fake"
        echo "container_coverage: 100"
        echo "podman_version: fake"
        echo "tmt_version: fake"
        echo "rpms:"
        evidence_rpms_block "${manifest}"
    } >"${path}"
}

# write_cuse_evidence <path> <target> <result> <commit> <dirty> <manifest>
write_cuse_evidence() {
    local path=$1 target=$2 result=$3 commit=$4 dirty=$5 manifest=$6
    {
        echo "tier: fresh-guest CUSE acceptance"
        echo "kind: candidate"
        echo "target: ${target}"
        echo "plan: full"
        echo "result: ${result}"
        echo "source_commit: ${commit}"
        echo "source_tree_dirty: ${dirty}"
        echo "image: fake.qcow2"
        echo "image_sha256: fake"
        echo "image_unchanged_after_run: yes"
        echo "guest_memory_mib: 2048"
        echo "guest_cpus: 2"
        echo "tmt_version: fake"
        echo "rpms:"
        evidence_rpms_block "${manifest}"
        echo "guest_facts:"
        echo "  kernel: fake"
    } >"${path}"
}

# new_evidence_scenario <name>: a scenario directory with dist manifests for
# both targets in place; tests then write evidence and break one thing.
new_evidence_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    mkdir -p "${SCENARIO}/dist/rocky-10" "${SCENARIO}/dist/fedora-43" "${SCENARIO}/evidence"
    build_dist_manifest "${SCENARIO}/dist/rocky-10"
    build_dist_manifest "${SCENARIO}/dist/fedora-43"
}

# Writes passing container and cuse evidence for both targets, agreeing with
# the dist manifests and the given commit; a good baseline every rejection
# scenario starts from and then breaks.
build_valid_evidence() {
    local commit=$1
    local target
    for target in rocky-10 fedora-43; do
        write_container_evidence "${SCENARIO}/evidence/container-${target}.txt" \
            "${target}" passed "${commit}" no "${SCENARIO}/dist/${target}/manifest.tsv"
        write_cuse_evidence "${SCENARIO}/evidence/cuse-${target}-candidate.txt" \
            "${target}" passed "${commit}" no "${SCENARIO}/dist/${target}/manifest.tsv"
    done
}

# run_evidence [extra env assignments...]: run release-evidence.sh against
# the current scenario; output in ${SCENARIO}/stdout and .../stderr, status
# in $status.
# shellcheck disable=SC2120 # some scenarios pass extra env overrides, most do not
run_evidence() {
    status=0
    env SOURCE_COMMIT="${source_commit}" DIST_DIR="${SCENARIO}/dist" \
        EVIDENCE_DIR="${SCENARIO}/evidence" "$@" \
        "${EVIDENCE_SCRIPT}" >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# assert_no_record: pass when a rejected run wrote no release-candidate
# evidence.
assert_no_record() {
    if [[ ! -e ${SCENARIO}/evidence/release-candidate.txt ]]; then
        ok 'no release-candidate record is written'
    else
        not_ok 'a release-candidate record was written for a rejected run'
    fi
}

new_evidence_scenario evidence_accept
build_valid_evidence "${source_commit}"
run_evidence
assert_status "${status}" 0
if [[ -f ${SCENARIO}/evidence/release-candidate.txt ]]; then
    ok 'release-candidate.txt is written'
else not_ok 'release-candidate.txt is missing'; fi
assert_contains "${SCENARIO}/evidence/release-candidate.txt" \
    "$(cut -f7 "${SCENARIO}/dist/rocky-10/manifest.tsv" | head -n 1)" \
    "the record includes rocky-10's package checksums"
assert_contains "${SCENARIO}/evidence/release-candidate.txt" \
    "$(cut -f7 "${SCENARIO}/dist/fedora-43/manifest.tsv" | head -n 1)" \
    "the record includes fedora-43's package checksums"

new_evidence_scenario evidence_missing_container
build_valid_evidence "${source_commit}"
rm -f "${SCENARIO}/evidence/container-rocky-10.txt"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'no passing container evidence' 'missing container evidence is reported'

new_evidence_scenario evidence_missing_cuse
build_valid_evidence "${source_commit}"
rm -f "${SCENARIO}/evidence/cuse-rocky-10-candidate.txt"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'no passing cuse evidence' 'missing cuse evidence is reported'

new_evidence_scenario evidence_wrong_commit
build_valid_evidence "${source_commit}"
write_container_evidence "${SCENARIO}/evidence/container-rocky-10.txt" rocky-10 passed \
    "some-other-commit" no "${SCENARIO}/dist/rocky-10/manifest.tsv"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'not deadbeefcafef00d' 'evidence for a different commit is reported'

new_evidence_scenario evidence_dirty_tree
build_valid_evidence "${source_commit}"
write_cuse_evidence "${SCENARIO}/evidence/cuse-fedora-43-candidate.txt" fedora-43 passed \
    "${source_commit}" yes "${SCENARIO}/dist/fedora-43/manifest.tsv"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'modified working tree' 'evidence from a dirty tree is reported'

new_evidence_scenario evidence_result_not_passed
build_valid_evidence "${source_commit}"
write_container_evidence "${SCENARIO}/evidence/container-fedora-43.txt" fedora-43 failed \
    "${source_commit}" no "${SCENARIO}/dist/fedora-43/manifest.tsv"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'does not record a pass' 'evidence not recording a pass is reported'

new_evidence_scenario evidence_rpm_mismatch
build_valid_evidence "${source_commit}"
sed -i 's/^  \(guildmaster-bin\.rpm\t\).*/  \1wrongchecksum/' \
    "${SCENARIO}/evidence/cuse-rocky-10-candidate.txt"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'different package bytes' 'a checksum differing from the dist manifest is reported'

new_evidence_scenario evidence_missing_dist_manifest
build_valid_evidence "${source_commit}"
rm -f "${SCENARIO}/dist/fedora-43/manifest.tsv"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" 'no manifest at' 'a missing dist manifest is reported'

new_evidence_scenario evidence_two_problems
build_valid_evidence "${source_commit}"
rm -f "${SCENARIO}/evidence/container-rocky-10.txt"
write_cuse_evidence "${SCENARIO}/evidence/cuse-fedora-43-candidate.txt" fedora-43 passed \
    "${source_commit}" yes "${SCENARIO}/dist/fedora-43/manifest.tsv"
run_evidence
assert_status "${status}" 1
assert_no_record
assert_contains "${SCENARIO}/stderr" '2 problem(s)' 'two simultaneous problems are both counted and reported'

echo
echo "release script tests: ${passed} passed, ${failed} failed"
suite_status=0
[[ ${failed} -eq 0 ]] || suite_status=1

# --- non-vacuity: mutants must make this suite fail --------------------------
#
# Only run once, from the top-level invocation, and only once the suite has
# actually passed against the real scripts: a mutant is expected to break at
# least one of the assertions above, and there is no reason to trust that
# signal if the suite was not clean to start with.
if [[ ${MUTATION_CHECK:-0} -eq 0 && ${suite_status} -eq 0 ]]; then
    echo
    echo "non-vacuity: checking that mutants make this suite fail"
    mutant_dir=${scratch}/mutants
    mkdir -p "${mutant_dir}"

    # make_mutant <source> <fixed-string> <output>: copy <source> without the
    # one two-line check whose first line contains <fixed-string> and ends
    # in "||" (the second line being its "die" or "problem" call). The
    # patterns are single-quoted on purpose: they are literal source text.
    # Fails loudly when the
    # pattern matches no line, more than one line, or a line that is not
    # such a check, so a later edit to the scripts cannot silently turn a
    # mutant into a copy of the original.
    make_mutant() {
        local source=$1 pattern=$2 output=$3 matches line
        matches=$(grep -nF -- "${pattern}" "${source}" | cut -d: -f1)
        if [[ $(grep -c . <<<"${matches}") -ne 1 ]]; then
            echo "FAIL: mutant pattern '${pattern}' matches $(grep -c . <<<"${matches}") lines of ${source}" >&2
            exit 1
        fi
        line=${matches}
        if ! sed -n "${line}p" "${source}" | grep -q '||[[:space:]]*$' ||
            ! sed -n "$((line + 1))p" "${source}" | grep -Eq '^[[:space:]]*(die|problem) '; then
            echo "FAIL: mutant pattern '${pattern}' in ${source} is not a two-line check" >&2
            exit 1
        fi
        sed "${line},$((line + 1))d" "${source}" >"${output}"
        chmod +x "${output}"
    }

    # shellcheck disable=SC2016
    # Mutant 1: assemble-release.sh no longer checks a package's bytes
    # against its manifest checksum.
    make_mutant "${repo_root}/scripts/assemble-release.sh" \
        '"${SHA256SUM}" -c --status - ||' "${mutant_dir}/no-checksum.sh"

    # Mutant 2: assemble-release.sh no longer checks the tag against the
    # spec.
    # shellcheck disable=SC2016
    make_mutant "${repo_root}/scripts/assemble-release.sh" \
        '[[ ${tag} == "${expected_tag}" ]] ||' "${mutant_dir}/no-tag-check.sh"

    # Mutant 3: release-evidence.sh no longer rejects evidence from a dirty
    # working tree.
    make_mutant "${repo_root}/scripts/release-evidence.sh" \
        'source_tree_dirty) == no ]] ||' "${mutant_dir}/ignore-dirty.sh"

    mutant_status=0

    # check_mutant <label> [extra env assignments...]: rerun this suite
    # against a mutant script and record whether it failed as expected.
    #
    # Invoked via "bash", not "$0" alone: a mutant copy is chmod +x by
    # make_mutant, but running it bare would still let a harness crash or a
    # non-executable $0 (exit 126) masquerade as "mutant caught" purely from
    # a nonzero exit. The rerun's own summary line is parsed instead, and is
    # only accepted as a genuine catch when it reports at least one passed
    # and at least one failed assertion; a missing summary line (the rerun
    # never got that far) is itself a mutant-check failure, not a pass.
    check_mutant() {
        local label=$1
        shift
        local out=${mutant_dir}/${label}.out
        local rc=0
        env MUTATION_CHECK=1 "$@" bash "$0" >"${out}" 2>&1 || rc=$?
        local summary mpassed mfailed
        summary=$(grep '^release script tests:' "${out}" | tail -n 1)
        if [[ ${summary} =~ ^release\ script\ tests:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
            mpassed=${BASH_REMATCH[1]}
            mfailed=${BASH_REMATCH[2]}
        else
            echo "FAIL: mutant ${label}: no summary line was produced (exit ${rc})" >&2
            mutant_status=1
            return
        fi
        if [[ ${mfailed} -ge 1 && ${mpassed} -ge 1 ]]; then
            echo "ok: mutant ${label}: suite caught it (${summary}), exit ${rc}"
        else
            echo "FAIL: mutant ${label}: suite reported no failed assertions (${summary}), exit ${rc}" >&2
            mutant_status=1
        fi
    }

    check_mutant no-checksum ASSEMBLE_SCRIPT="${mutant_dir}/no-checksum.sh"
    check_mutant no-tag-check ASSEMBLE_SCRIPT="${mutant_dir}/no-tag-check.sh"
    check_mutant ignore-dirty EVIDENCE_SCRIPT="${mutant_dir}/ignore-dirty.sh"

    [[ ${mutant_status} -eq 0 ]] || suite_status=1
fi

exit "${suite_status}"
