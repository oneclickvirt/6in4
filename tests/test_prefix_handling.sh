#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/6in4.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$script"
}

die() { exit 1; }
say_error() { :; }
say_warn() { :; }

# shellcheck disable=SC1090 # The test intentionally loads isolated helpers.
source <(extract_function calculate_target_prefix)
# shellcheck disable=SC1090 # The test intentionally loads isolated helpers.
source <(extract_function derive_subnet_addresses)
# shellcheck disable=SC1090 # The test intentionally loads isolated helpers.
source <(extract_function allocate_subnet)

[[ "$(calculate_target_prefix 64 127)" == "127" ]] || {
    printf '%s\n' 'expected /127 point-to-point prefix to remain allocatable' >&2
    exit 1
}
[[ "$(calculate_target_prefix 38 54)" == "54" ]] || {
    printf '%s\n' 'expected non-byte-aligned delegated prefix to remain allocatable' >&2
    exit 1
}
if (calculate_target_prefix 64 128 >/dev/null 2>&1); then
    printf '%s\n' 'accepted /128 despite needing two tunnel endpoints' >&2
    exit 1
fi

endpoints=$(derive_subnet_addresses '2001:db8:1::/127')
[[ "$endpoints" == $'2001:db8:1::\n2001:db8:1::1' ]] || {
    printf 'unexpected /127 endpoints: %s\n' "$endpoints" >&2
    exit 1
}
if (derive_subnet_addresses '2001:db8:1::/128' >/dev/null 2>&1); then
    printf '%s\n' 'accepted /128 despite needing two tunnel endpoints' >&2
    exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
ALLOCATIONS_FILE="$tmp_dir/allocations.tsv"
printf 'created_at\tname\tos_family\tmode\tclient_ipv4\tsubnet\tserver_ipv6\tclient_ipv6\tmtu\tmss\tstatus\tdeleted_at\n' >"$ALLOCATIONS_FILE"

ipv6_address='2001:db8:1::1'
ipv6_prefixlen=64
target_mask=112
candidate=$(allocate_subnet)
[[ "$candidate" == '2001:db8:1::1:0/112' ]] || {
    printf 'unexpected first /112 candidate: %s\n' "$candidate" >&2
    exit 1
}

# A historical /112 reservation must advance to the next /112 without a pool
# scan, while a wider reservation must exclude all of its smaller children.
printf 'now\ttunnel-1\tlinux\tsit\t198.51.100.1\t2001:db8:1::1:0/112\t\t\t\t\tactive\t\n' >>"$ALLOCATIONS_FILE"
candidate=$(allocate_subnet)
[[ "$candidate" == '2001:db8:1::2:0/112' ]] || {
    printf 'unexpected candidate after active /112: %s\n' "$candidate" >&2
    exit 1
}
printf 'now\ttunnel-2\tlinux\tsit\t198.51.100.2\t2001:db8:1::/80\t\t\t\t\tactive\t\n' >>"$ALLOCATIONS_FILE"
candidate=$(allocate_subnet)
[[ "$candidate" == '2001:db8:1:0:1::/112' ]] || {
    printf 'unexpected candidate after active /80: %s\n' "$candidate" >&2
    exit 1
}

: >"$ALLOCATIONS_FILE"
ipv6_address='2001:db8:2::1'
ipv6_prefixlen=64
target_mask=127
candidate=$(allocate_subnet)
[[ "$candidate" == '2001:db8:2::2/127' ]] || {
    printf 'unexpected /127 candidate: %s\n' "$candidate" >&2
    exit 1
}

ipv6_address='2a14:7c0:1002:10f8::1'
# shellcheck disable=SC2034 # Loaded by the isolated allocation helper above.
ipv6_prefixlen=38
# shellcheck disable=SC2034 # Loaded by the isolated allocation helper above.
target_mask=54
candidate=$(allocate_subnet)
python3 - "$candidate" "$ipv6_address" <<'PY' || {
import ipaddress
import sys

subnet = ipaddress.IPv6Network(sys.argv[1])
host = ipaddress.IPv6Address(sys.argv[2])
sys.exit(0 if subnet.prefixlen == 54 and host not in subnet else 1)
PY
    printf 'non-byte-aligned allocation was invalid or included the host: %s\n' "$candidate" >&2
    exit 1
}

printf '%s\n' '6in4 IPv6 prefix handling tests passed'
