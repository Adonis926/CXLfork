#!/usr/bin/env bash
set -Eeuo pipefail

usage()
{
	cat >&2 <<'EOF'
Usage: export-openwhisk-five-system-core-csv.sh CAMPAIGN [OUTPUT.csv]

Export one compact table for the five standard OpenWhisk systems.  The input
campaign must already have summary/summary.csv and complete sequential and
throughput rows for every vCPU listed in manifest/vcpu-order.txt.
EOF
	exit 2
}

(($# == 1 || $# == 2)) || usage

campaign=$(realpath -e "$1")
input=$campaign/summary/summary.csv
environment=$campaign/manifest/environment.txt
vcpu_manifest=$campaign/manifest/vcpu-order.txt
output=${2:-$campaign/summary/five-system-core-metrics.csv}

[[ -r $input ]] || { echo "missing summary: $input" >&2; exit 1; }
[[ -r $environment ]] || { echo "missing campaign environment: $environment" >&2; exit 1; }
[[ -s $vcpu_manifest ]] || { echo "missing vCPU manifest: $vcpu_manifest" >&2; exit 1; }

reps=$(awk -F= '$1 == "reps" { print $2 }' "$environment")
sequential_requests=$(awk -F= '$1 == "sequential_requests" { print $2 }' "$environment")
[[ $reps =~ ^[1-9][0-9]*$ ]] || { echo "invalid reps in $environment" >&2; exit 1; }
[[ $sequential_requests =~ ^[1-9][0-9]*$ ]] || {
	echo "invalid sequential_requests in $environment" >&2; exit 1;
}

vcpus=$(paste -sd' ' "$vcpu_manifest")
systems='cohort no-tiering starfish native-cxl native-dram'
expected_sequential_samples=$((reps * sequential_requests))
output_dir=$(dirname "$output")
mkdir -p "$output_dir"
tmp=$(mktemp "$output_dir/.five-system-core.XXXXXX")
trap 'rm -f "$tmp"' EXIT

LC_ALL=C awk -F, \
	-v OFS=, \
	-v systems="$systems" \
	-v vcpus="$vcpus" \
	-v expected_reps="$reps" \
	-v expected_sequential_samples="$expected_sequential_samples" '
function fail(message) {
	print "ERROR: " message > "/dev/stderr"
	bad = 1
}
function allowed(value, values,    count, items, i) {
	count = split(values, items, " ")
	for (i = 1; i <= count; i++)
		if (value == items[i]) return 1
	return 0
}
function number(value) {
	return value ~ /^[0-9]+([.][0-9]+)?$/
}
NR == 1 {
	for (i = 1; i <= NF; i++) column[$i] = i
	required = "system vcpus mode scenario reps samples successes mean_ns p50_ns p95_ns p99_ns achieved_rps_mean"
	n = split(required, names, " ")
	for (i = 1; i <= n; i++)
		if (!(names[i] in column)) fail("missing input column " names[i])
	next
}
{
	sys = $(column["system"])
	vcpu = $(column["vcpus"])
	mode = $(column["mode"])
	scenario = $(column["scenario"])
	if (!allowed(sys, systems) || !allowed(vcpu, vcpus) || mode != "standard-cold") next
	if (scenario != "sequential" && scenario != "throughput") next
	key = vcpu SUBSEP sys SUBSEP scenario
	if (seen[key]++) { fail("duplicate row for " vcpu "/" sys "/" scenario); next }
	row_reps = $(column["reps"])
	samples = $(column["samples"])
	successes = $(column["successes"])
	if (row_reps != expected_reps)
		fail("wrong repetition count for " vcpu "/" sys "/" scenario)
	if (samples != successes || samples <= 0)
		fail("invalid success count for " vcpu "/" sys "/" scenario)
	if (scenario == "sequential") {
		if (samples != expected_sequential_samples)
			fail("wrong sequential sample count for " vcpu "/" sys)
		mean[key] = $(column["mean_ns"]) / 1000000
		p50[key] = $(column["p50_ns"]) / 1000000
		p95[key] = $(column["p95_ns"]) / 1000000
		p99_value = $(column["p99_ns"])
		p99[key] = number(p99_value) ? sprintf("%.3f", p99_value / 1000000) : "NA"
	} else {
		rps_value = $(column["achieved_rps_mean"])
		if (!number(rps_value)) fail("invalid throughput RPS for " vcpu "/" sys)
		rps[key] = rps_value
	}
}
END {
	print "vcpus", "system", "cold_e2e_mean_ms", "cold_e2e_p50_ms", "cold_e2e_p95_ms", "cold_e2e_p99_ms", "cold_throughput_rps"
	nv = split(vcpus, vcpu_list, " ")
	ns = split(systems, system_list, " ")
	for (vi = 1; vi <= nv; vi++) {
		for (si = 1; si <= ns; si++) {
			base = vcpu_list[vi] SUBSEP system_list[si]
			seq = base SUBSEP "sequential"
			throughput = base SUBSEP "throughput"
			if (!(seq in seen)) fail("missing sequential row for " vcpu_list[vi] "/" system_list[si])
			if (!(throughput in seen)) fail("missing throughput row for " vcpu_list[vi] "/" system_list[si])
			if ((seq in seen) && (throughput in seen))
				printf "%s,%s,%.3f,%.3f,%.3f,%s,%.3f\n", \
					vcpu_list[vi], system_list[si], mean[seq], p50[seq], p95[seq], p99[seq], rps[throughput]
		}
	}
	if (bad) exit 1
}
' "$input" >"$tmp"

mv "$tmp" "$output"
trap - EXIT
sha256sum "$output" >"$output.sha256"
printf 'CORE_CSV_OK output=%s rows=%s\n' "$output" "$(( $(wc -l <"$output") - 1 ))"
