#!/bin/bash
# Usage: tests/do_tofu_version.sh [path to do_tofu]
set -uo pipefail

DO_TOFU="${1:-sqs/scripts/aws/do_tofu}"
CACHE_ROOT="/tmp/np-tofu-bin"
CACHE_BACKUP=""
PASS=0
FAIL=0

if [ ! -f "$DO_TOFU" ]; then
	echo "not found: $DO_TOFU" >&2
	exit 1
fi

PINNED="$(sed -n 's/^[[:space:]]*TOFU_VERSION="\([0-9.]*\)".*/\1/p' "$DO_TOFU" | head -1)"
if [ -z "$PINNED" ]; then
	echo "no TOFU_VERSION pin found in $DO_TOFU" >&2
	exit 1
fi
echo "pin del script: v${PINNED}"
echo

if [ -e "$CACHE_ROOT" ]; then
	CACHE_BACKUP="$(mktemp -d)/np-tofu-bin"
	mv "$CACHE_ROOT" "$CACHE_BACKUP"
fi

restore_cache() {
	if [ -n "$CACHE_BACKUP" ] && [ -e "$CACHE_BACKUP" ]; then
		rm -rf "$CACHE_ROOT"
		mv "$CACHE_BACKUP" "$CACHE_ROOT"
	fi
}
trap restore_cache EXIT

make_fake_tofu() {
	local dest="$1" version="$2"
	mkdir -p "$(dirname "$dest")"
	cat > "$dest" <<EOS
#!/bin/bash
if [ "\$1" = "version" ]; then
  echo "OpenTofu v${version}"
  echo "on linux_amd64"
  exit 0
fi
echo "FAKE_TOFU_RAN version=${version} cmd=\$*" >> "\$TOFU_CALL_LOG"
exit 0
EOS
	chmod +x "$dest"
}

setup_sandbox() {
	SANDBOX="$(mktemp -d)"
	export TOFU_CALL_LOG="$SANDBOX/calls.log"
	: > "$TOFU_CALL_LOG"

	mkdir -p "$SANDBOX/bin" "$SANDBOX/mod" "$SANDBOX/out"
	echo 'terraform { backend "s3" {} }' > "$SANDBOX/mod/backend.tf"

	cat > "$SANDBOX/bin/curl" <<'EOS'
#!/bin/bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
echo "CURL_CALLED" >> "$TOFU_CALL_LOG"
if [ -n "$out" ]; then echo "fake-zip" > "$out"; fi
exit 0
EOS

	cat > "$SANDBOX/bin/unzip" <<'EOS'
#!/bin/bash
dest=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then dest="$a"; fi
  prev="$a"
done
mkdir -p "$dest"
cat > "$dest/tofu" <<INNER
#!/bin/bash
if [ "\$1" = "version" ]; then echo "OpenTofu v${INSTALLED_VERSION}"; exit 0; fi
echo "FAKE_TOFU_RAN version=${INSTALLED_VERSION} cmd=\$*" >> "\$TOFU_CALL_LOG"
exit 0
INNER
chmod +x "$dest/tofu"
exit 0
EOS

	chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/unzip"

	rm -rf "${CACHE_ROOT:?}"

	export OUTPUT_DIR="$SANDBOX/out"
	export TOFU_MODULE_DIR="$SANDBOX/mod"
	export TOFU_INIT_VARIABLES="-backend-config=bucket=b -backend-config=use_lockfile=true"
	export TOFU_VARIABLES="-var=x=1"
	export TOFU_ACTION="apply"
	export INSTALLED_VERSION="$PINNED"
}

teardown_sandbox() {
	rm -rf "${SANDBOX:?}"
	rm -rf "${CACHE_ROOT:?}"
}

run_do_tofu() {
	PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$DO_TOFU" 2>&1
}

check() {
	local name="$1" verdict="$2" detail="${3:-}"
	if [ "$verdict" = "ok" ]; then
		echo "  PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $name"
		if [ -n "$detail" ]; then echo "        $detail"; fi
		FAIL=$((FAIL + 1))
	fi
}

versions_that_ran() {
	grep -o 'version=[0-9.]*' "$TOFU_CALL_LOG" 2>/dev/null | sed 's/version=//' | sort -u | tr '\n' ' '
}

echo "=== a stale older binary in the shared cache is not reused ==="
setup_sandbox
make_fake_tofu "$CACHE_ROOT/tofu" "1.9.0"
out="$(run_do_tofu)"
ran="$(versions_that_ran)"
if echo "$ran" | grep -q '1\.9\.0'; then
	check "does not run tofu 1.9.0 from the cache" "bad" "ran: [$ran] | out: $(echo "$out" | head -3 | tr '\n' '|')"
else
	check "does not run tofu 1.9.0 from the cache" "ok"
fi
teardown_sandbox

echo "=== a tofu older than the pin on PATH is not used ==="
setup_sandbox
make_fake_tofu "$SANDBOX/bin/tofu" "1.7.3"
out="$(run_do_tofu)"
ran="$(versions_that_ran)"
if echo "$ran" | grep -q '1\.7\.3'; then
	check "does not run tofu 1.7.3 from PATH" "bad" "ran: [$ran] | out: $(echo "$out" | head -3 | tr '\n' '|')"
else
	check "does not run tofu 1.7.3 from PATH" "ok"
fi
teardown_sandbox

echo "=== a tofu newer than the pin on PATH is used without downloading ==="
setup_sandbox
make_fake_tofu "$SANDBOX/bin/tofu" "9.9.9"
out="$(run_do_tofu)"
ran="$(versions_that_ran)"
if echo "$ran" | grep -q '9\.9\.9'; then
	check "uses the newer tofu 9.9.9 from PATH" "ok"
else
	check "uses the newer tofu 9.9.9 from PATH" "bad" "ran: [$ran] | out: $(echo "$out" | head -5 | tr '\n' '|')"
fi
if grep -q CURL_CALLED "$TOFU_CALL_LOG"; then
	check "does not download when PATH tofu is new enough" "bad"
else
	check "does not download when PATH tofu is new enough" "ok"
fi
teardown_sandbox

echo "=== a warm cache of the pinned version is reused ==="
setup_sandbox
out="$(run_do_tofu)"
first_curl="$(grep -c CURL_CALLED "$TOFU_CALL_LOG")"
: > "$TOFU_CALL_LOG"
out="$(run_do_tofu)"
second_curl="$(grep -c CURL_CALLED "$TOFU_CALL_LOG")"
ran="$(versions_that_ran)"
if [ "$first_curl" -ge 1 ]; then
	check "cold start downloads tofu" "ok"
else
	check "cold start downloads tofu" "bad" "out: $(echo "$out" | head -5 | tr '\n' '|')"
fi
if [ "$second_curl" -eq 0 ] && echo "$ran" | grep -qF "$PINNED"; then
	check "warm start reuses the cache without downloading" "ok"
else
	check "warm start reuses the cache without downloading" "bad" "curl=$second_curl ran=[$ran]"
fi
teardown_sandbox

echo "=== a failed download aborts before tofu runs ==="
setup_sandbox
printf '#!/bin/bash\necho "curl: (22) simulated failure" >&2\nexit 22\n' > "$SANDBOX/bin/curl"
chmod +x "$SANDBOX/bin/curl"
out="$(run_do_tofu)"
rc=$?
ran="$(versions_that_ran)"
if [ "$rc" -ne 0 ]; then
	check "exits non-zero when the download fails" "ok"
else
	check "exits non-zero when the download fails" "bad" "rc=$rc out: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q 'curl: (22)'; then
	check "surfaces curl's own error, not a downstream symptom" "ok"
else
	check "surfaces curl's own error, not a downstream symptom" "bad" "out: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -qE 'unzip|chmod|mv:'; then
	check "does not run install steps after the download failed" "bad" "out: $(echo "$out" | tr '\n' '|')"
else
	check "does not run install steps after the download failed" "ok"
fi
if [ -n "$ran" ]; then
	check "never reaches tofu init or apply" "bad" "ran: [$ran]"
else
	check "never reaches tofu init or apply" "ok"
fi
leaked="$(find /tmp -maxdepth 1 -name 'np-tofu-install.*' 2>/dev/null | tr '\n' ' ')"
if [ -n "$leaked" ]; then
	check "leaves no staging directory behind" "bad" "$leaked"
else
	check "leaves no staging directory behind" "ok"
fi
teardown_sandbox

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
