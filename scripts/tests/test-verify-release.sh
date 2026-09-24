#!/usr/bin/env bash
# Offline tests for scripts/verify-release.sh.
#
# No network and no real gh, rpm or sha256sum: GH, RPM and SHA256SUM are
# stubs that record their calls and answer from a per-test scenario
# directory. gh's "release download" copies fixed scenario assets into the
# requested directory; rpm's "-qp --qf" answers from a basename-keyed table;
# sha256sum delegates to the real binary (found once, at suite start, before
# any stub is on PATH), so checksum arithmetic in the script under test is
# exercised for real.
#
# SCRIPT_UNDER_TEST points the whole suite at a script under test; it
# defaults to the real script, and is also used at the end of this file to
# run the whole suite again against deliberately broken mutant copies, to
# check that the suite actually catches their bugs.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
: "${SCRIPT_UNDER_TEST:=${repo_root}/scripts/verify-release.sh}"
real_sha256sum=$(command -v sha256sum)

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

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

# gh stub: "downloads" the release by copying ${SCENARIO}/source-assets into
# the requested --dir.
cat >"${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${SCENARIO}/gh.log"
if [[ -f ${SCENARIO}/gh_fails ]]; then
    echo 'gh: release not found' >&2
    exit 1
fi
dir=
prev=
for arg in "$@"; do
    [[ ${prev} == --dir ]] && dir=${arg}
    prev=${arg}
done
mkdir -p "${dir}"
if [[ -d ${SCENARIO}/source-assets ]]; then
    cp "${SCENARIO}/source-assets/"* "${dir}/" 2>/dev/null || true
fi
STUB

# rpm stub: answers "-qp --nosignature --qf '...' <file>" from a
# basename-keyed table at ${SCENARIO}/rpm-table.tsv, one line per package:
#   basename<TAB>name<TAB>epoch<TAB>version<TAB>release<TAB>arch
cat >"${stub_dir}/rpm" <<'STUB'
#!/usr/bin/env bash
set -u
file=${!#}
base=$(basename "${file}")
row=$(awk -F'\t' -v b="${base}" '$1==b{print; found=1} END{exit !found}' "${SCENARIO}/rpm-table.tsv") || {
    echo "rpm: no table entry for ${base}" >&2
    exit 1
}
IFS=$'\t' read -r _ name epoch version release arch <<<"${row}"
printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${epoch}" "${version}" "${release}" "${arch}"
STUB

# sha256sum stub: records its invocation, then delegates to the real binary,
# so the script's own checksum arithmetic is exercised for real.
cat >"${stub_dir}/sha256sum" <<STUB
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >>"\${SCENARIO}/sha256sum.log"
exec "${real_sha256sum}" "\$@"
STUB
chmod +x "${stub_dir}"/*

tag='v0.1-20251202git463382b-1'
version='0.1^20251202git463382b'
release=1

# new_scenario <name>: a scenario directory with empty source assets, an
# empty rpm table and an empty gh log; tests then add assets and break one
# thing.
new_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/source-assets"
    : >"${SCENARIO}/rpm-table.tsv"
    : >"${SCENARIO}/gh.log"
}

# add_asset <basename> <name> <epoch> <version> <release> <arch> [content]
# Writes arbitrary bytes to ${SCENARIO}/source-assets/<basename> and a
# matching rpm-table.tsv row.
add_asset() {
    local basename=$1 name=$2 epoch=$3 version=$4 release=$5 arch=$6
    local content=${7:-"bytes:${basename}:${RANDOM}${RANDOM}${RANDOM}"}
    printf '%s\n' "${content}" >"${SCENARIO}/source-assets/${basename}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${basename}" "${name}" "${epoch}" \
        "${version}" "${release}" "${arch}" >>"${SCENARIO}/rpm-table.tsv"
}

# add_target_assets <dist> [version] [release]: the four packages a target
# needs, correctly named and reporting a matching NVR.
add_target_assets() {
    local dist=$1 ver=${2:-${version}} rel=${3:-${release}}
    add_asset "guildmaster-bin.${dist}.x86_64.rpm" guildmaster '(none)' "${ver}" "${rel}.${dist}" x86_64
    add_asset "guildmaster-debuginfo.${dist}.x86_64.rpm" guildmaster-debuginfo '(none)' "${ver}" "${rel}.${dist}" x86_64
    add_asset "guildmaster-debugsource.${dist}.x86_64.rpm" guildmaster-debugsource '(none)' "${ver}" "${rel}.${dist}" x86_64
    add_asset "guildmaster-src.${dist}.src.rpm" guildmaster '(none)' "${ver}" "${rel}.${dist}" src
}

# write_sha256sums: computes real checksums of everything currently in
# source-assets and writes SHA256SUMS alongside them, in the format
# "sha256sum" itself produces (so --check --strict accepts it unmodified).
write_sha256sums() {
    (cd "${SCENARIO}/source-assets" && "${real_sha256sum}" -- *.rpm >SHA256SUMS)
}

# run_verify [extra env assignments...]: run verify-release.sh against the
# current scenario; output in ${SCENARIO}/stdout and .../stderr, status in
# $status.
run_verify() {
    status=0
    env GH="${stub_dir}/gh" RPM="${stub_dir}/rpm" SHA256SUM="${stub_dir}/sha256sum" \
        REPOSITORY=leynos/guildmaster-rpm "$@" \
        "${SCRIPT_UNDER_TEST}" "${verify_tag:-${tag}}" "${SCENARIO}/out" \
        >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# --- accept: a valid two-target release --------------------------------------

new_scenario verify_accept
add_target_assets el10
add_target_assets fc43
write_sha256sums
run_verify
assert_status "${status}" 0
per_target_count=$(find "${SCENARIO}/out/rocky-10" "${SCENARIO}/out/fedora-43" -name '*.rpm' | wc -l)
if [[ ${per_target_count} -eq 8 ]]; then
    ok 'exactly 8 packages are laid out'
else not_ok "wrong package count: ${per_target_count}"; fi
for target_dist in 'rocky-10 el10' 'fedora-43 fc43'; do
    read -r target dist <<<"${target_dist}"
    if [[ -d ${SCENARIO}/out/${target}/srpm ]]; then
        ok "${target}: srpm/ subdirectory exists"
    else not_ok "${target}: no srpm/ subdirectory"; fi
    manifest=${SCENARIO}/out/${target}/manifest.tsv
    if [[ $(wc -l <"${manifest}") -eq 4 ]]; then
        ok "${target}: manifest has 4 lines"
    else not_ok "${target}: manifest has $(wc -l <"${manifest}") lines"; fi
    while IFS=$'\t' read -r relative name epoch mversion mrelease arch sha; do
        [[ -f ${SCENARIO}/out/${target}/${relative} ]] ||
            not_ok "${target}: manifest names ${relative}, which does not exist"
        [[ ${epoch} == '(none)' ]] || not_ok "${target}: manifest row for ${relative} has a non-empty epoch"
        [[ ${mversion} == "${version}" ]] || not_ok "${target}: manifest row for ${relative} has the wrong version"
        real_sha=$("${real_sha256sum}" <"${SCENARIO}/out/${target}/${relative}" | cut -d' ' -f1)
        [[ ${sha} == "${real_sha}" ]] || not_ok "${target}: manifest checksum for ${relative} does not match its bytes"
        [[ ${relative} != /* ]] || not_ok "${target}: manifest names an absolute path"
        [[ ${name} == guildmaster* ]] || not_ok "${target}: manifest row for ${relative} has an unexpected name"
        [[ -n ${mrelease}${arch} ]] || true
    done <"${manifest}"
    ok "${target}: manifest rows are well formed (relative, correct sha256, no epoch)"
    if [[ -f ${SCENARIO}/out/${target}/srpm/guildmaster-src.${dist}.src.rpm ]]; then
        ok "${target}: the SRPM is laid out under srpm/"
    else not_ok "${target}: SRPM not found under srpm/"; fi
done
assert_contains "${SCENARIO}/stdout" 'rocky-10: 4 packages verified' 'per-target package count is reported'
assert_contains "${SCENARIO}/stdout" "release ${tag} verified in ${SCENARIO}/out" 'a final success line is printed'

# --- accept: an SRPM reporting "src" ------------------------------------------

new_scenario verify_srpm_arch_src
add_target_assets el10
write_sha256sums
run_verify TARGETS=rocky-10
assert_status "${status}" 0
ok 'an SRPM reporting arch "src" is accepted'

# --- accept: an SRPM reporting the build architecture -------------------------

new_scenario verify_srpm_arch_native
add_asset guildmaster-bin.el10.x86_64.rpm guildmaster '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debuginfo.el10.x86_64.rpm guildmaster-debuginfo '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debugsource.el10.x86_64.rpm guildmaster-debugsource '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-src.el10.src.rpm guildmaster '(none)' "${version}" "${release}.el10" x86_64
write_sha256sums
run_verify TARGETS=rocky-10
assert_status "${status}" 0
ok 'an SRPM reporting the build architecture (not "src") is also accepted'

# --- reject: four files that are not the four packages ----------------------

new_scenario verify_duplicate_role
add_asset guildmaster-bin.el10.x86_64.rpm guildmaster '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debugsource.el10.x86_64.rpm guildmaster-debugsource '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debugsource-again.el10.x86_64.rpm guildmaster-debugsource '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-src.el10.src.rpm guildmaster '(none)' "${version}" "${release}.el10" src
write_sha256sums
run_verify TARGETS=rocky-10
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'does not hold exactly one of each package' \
    'a duplicate debugsource standing in for debuginfo is refused'

# --- reject: malformed tag ----------------------------------------------------

new_scenario verify_malformed_tag
verify_tag='not-a-tag' run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'is not of the form' 'a malformed tag is refused'
assert_lacks "${SCENARIO}/gh.log" 'release' 'and nothing is downloaded'

# --- reject: pre-existing output directory ------------------------------------

new_scenario verify_output_exists
mkdir -p "${SCENARIO}/out"
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'already exists' 'a pre-existing output directory is refused'

# --- reject: download failure -------------------------------------------------

new_scenario verify_download_fails
touch "${SCENARIO}/gh_fails"
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'could not download release' 'a gh download failure is reported'

# --- reject: missing SHA256SUMS -----------------------------------------------

new_scenario verify_missing_sha256sums
add_target_assets el10
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'has no SHA256SUMS' 'a release with no SHA256SUMS is refused'

# --- reject: an asset not matching SHA256SUMS ---------------------------------

new_scenario verify_checksum_mismatch
add_target_assets el10
write_sha256sums
# Tamper with one asset's bytes after the checksums were recorded.
echo tampered >>"${SCENARIO}/source-assets/guildmaster-bin.el10.x86_64.rpm"
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'does not match SHA256SUMS' 'a tampered asset is refused'

# --- reject: an RPM present but not listed in SHA256SUMS ---------------------
#
# sha256sum --check --strict only validates the entries SHA256SUMS lists, so
# an untracked extra .rpm passes that check; it is the later "listed exactly
# equals present" comparison that must catch it.

new_scenario verify_extra_unlisted_rpm
add_target_assets el10
write_sha256sums
add_asset guildmaster-extra.el10.x86_64.rpm guildmaster '(none)' "${version}" "${release}.el10" x86_64
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'does not list exactly the RPM assets' \
    'an RPM present but not listed in SHA256SUMS is refused'

# --- reject: SHA256SUMS lists a file that is not present ---------------------
#
# sha256sum --check --strict itself fails on an unreadable listed entry, so
# this is caught at the same checksum step as a tampered asset, and reported
# with the same diagnostic.

new_scenario verify_sha256sums_lists_missing_file
add_target_assets el10
write_sha256sums
printf '%s  guildmaster-ghost.el10.x86_64.rpm\n' \
    "$("${real_sha256sum}" <"${SCENARIO}/source-assets/guildmaster-bin.el10.x86_64.rpm" | cut -d' ' -f1)" \
    >>"${SCENARIO}/source-assets/SHA256SUMS"
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'does not match SHA256SUMS' \
    'a file listed in SHA256SUMS but not present is refused'

# --- reject: wrong version vs tag ---------------------------------------------

new_scenario verify_wrong_version
add_target_assets el10 9.9 "${release}"
write_sha256sums
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" "is 9.9-${release}.el10, not ${version}-${release}.el10" \
    'a package whose version does not match the tag is refused'

# --- reject: wrong release vs tag ---------------------------------------------

new_scenario verify_wrong_release
add_target_assets el10 "${version}" 9
write_sha256sums
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" "is ${version}-9.el10, not ${version}-${release}.el10" \
    'a package whose release does not match the tag is refused'

# --- reject: an epoch ----------------------------------------------------------

new_scenario verify_has_epoch
add_asset guildmaster-bin.el10.x86_64.rpm guildmaster 1 "${version}" "${release}.el10" x86_64
add_asset guildmaster-debuginfo.el10.x86_64.rpm guildmaster-debuginfo '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debugsource.el10.x86_64.rpm guildmaster-debugsource '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-src.el10.src.rpm guildmaster '(none)' "${version}" "${release}.el10" src
write_sha256sums
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'has an epoch' 'a package carrying an epoch is refused'

# --- reject: a noarch/wrong-arch binary -----------------------------------------

new_scenario verify_wrong_arch
add_asset guildmaster-bin.el10.x86_64.rpm guildmaster '(none)' "${version}" "${release}.el10" noarch
add_asset guildmaster-debuginfo.el10.x86_64.rpm guildmaster-debuginfo '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debugsource.el10.x86_64.rpm guildmaster-debugsource '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-src.el10.src.rpm guildmaster '(none)' "${version}" "${release}.el10" src
write_sha256sums
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'has arch noarch' 'a noarch binary package is refused'

# --- reject: a target with only 3 packages (one missing) ---------------------

new_scenario verify_missing_package
add_asset guildmaster-bin.el10.x86_64.rpm guildmaster '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-debuginfo.el10.x86_64.rpm guildmaster-debuginfo '(none)' "${version}" "${release}.el10" x86_64
add_asset guildmaster-src.el10.src.rpm guildmaster '(none)' "${version}" "${release}.el10" src
write_sha256sums
run_verify
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'expected 4 packages in the release, found 3' \
    'a target with fewer than 4 packages is refused'

# --- reject: an unknown target in TARGETS -------------------------------------

new_scenario verify_unknown_target
add_target_assets el10
write_sha256sums
run_verify TARGETS='rocky-10 debian-13'
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'unknown target debian-13' 'an unknown TARGETS entry is refused'

echo
echo "verify-release tests: ${passed} passed, ${failed} failed"
suite_status=0
[[ ${failed} -eq 0 ]] || suite_status=1

# --- non-vacuity: mutants must make this suite fail --------------------------
#
# Only run once, from the top-level invocation, and only once the suite has
# actually passed against the real script: a mutant is expected to break at
# least one of the assertions above, and there is no reason to trust that
# signal if the suite was not clean to start with.
if [[ ${MUTATION_CHECK:-0} -eq 0 && ${suite_status} -eq 0 ]]; then
    echo
    echo "non-vacuity: checking that mutants make this suite fail"
    mutant_dir=${scratch}/mutants
    mkdir -p "${mutant_dir}"

    # make_mutant <source> <fixed-string> <output>: copy <source> without the
    # one two-line check whose first line contains <fixed-string> and ends
    # in "||" (the second line being its "die" call). The pattern is
    # single-quoted on purpose: it is literal source text. Fails loudly when
    # the pattern matches no line, more than one line, or a line that is not
    # such a check, so a later edit to the script cannot silently turn a
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
            ! sed -n "$((line + 1))p" "${source}" | grep -Eq '^[[:space:]]*die '; then
            echo "FAIL: mutant pattern '${pattern}' in ${source} is not a two-line check" >&2
            exit 1
        fi
        sed "${line},$((line + 1))d" "${source}" >"${output}"
        chmod +x "${output}"
    }

    # shellcheck disable=SC2016
    # Mutant 1: verify-release.sh no longer checks downloaded assets against
    # SHA256SUMS.
    make_mutant "${repo_root}/scripts/verify-release.sh" \
        '"${SHA256SUM}" --check --strict SHA256SUMS) ||' "${mutant_dir}/no-checksum.sh"

    # Mutant 2: verify-release.sh no longer rejects a version/release
    # mismatch against the tag.
    # shellcheck disable=SC2016
    make_mutant "${repo_root}/scripts/verify-release.sh" \
        '${file_release} == "${release}.${dist}" ]] ||' "${mutant_dir}/no-nvr-check.sh"

    mutant_status=0

    # check_mutant <label> [extra env assignments...]: rerun this suite
    # against a mutant script and record whether it failed as expected.
    check_mutant() {
        local label=$1
        shift
        local out=${mutant_dir}/${label}.out
        local rc=0
        env MUTATION_CHECK=1 "$@" "$0" >"${out}" 2>&1 || rc=$?
        local summary
        summary=$(grep '^verify-release tests:' "${out}" | tail -n 1)
        if [[ ${rc} -ne 0 ]]; then
            echo "ok: mutant ${label}: suite failed as expected (${summary:-no summary line}), exit ${rc}"
        else
            echo "FAIL: mutant ${label}: suite still passed (${summary:-no summary line})" >&2
            mutant_status=1
        fi
    }

    check_mutant no-checksum SCRIPT_UNDER_TEST="${mutant_dir}/no-checksum.sh"
    check_mutant no-nvr-check SCRIPT_UNDER_TEST="${mutant_dir}/no-nvr-check.sh"

    [[ ${mutant_status} -eq 0 ]] || suite_status=1
fi

exit "${suite_status}"
