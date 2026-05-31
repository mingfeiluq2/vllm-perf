#!/bin/bash
set -euo pipefail

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $msg"
        echo "        expected: '$expected'"
        echo "        got:      '$actual'"
    fi
}

assert_non_empty() {
    local value="$1" msg="$2"
    if [ -n "$value" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $msg (empty)"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $msg"
        echo "        '$needle' not found in '$haystack'"
    fi
}

# now_sec unchanged helper
now_sec() {
    date +%s.%N
}

# ---------- Simplified function implementations ----------

normalize_container_id() {
    local container_id="$1"
    container_id="${container_id#containerd://}"
    container_id="${container_id#cri-o://}"
    echo "${container_id}"
}

elapsed_since() {
    local start="$1"
    printf "%.2f" "$(awk "BEGIN {printf \"%.2f\", $(now_sec) - ${start}}")"
}

valid_pid() {
    local pid="$1"
    [ -n "${pid}" ] && [ "${pid}" -gt 1 ] 2>/dev/null && [ -d "/proc/${pid}" ]
}

get_pod_cgroup_from_pid() {
    local pid="$1"
    local cgroup_line
    cgroup_line=$(grep '^0::' "/proc/${pid}/cgroup" 2>/dev/null | head -1)
    if [ -z "${cgroup_line}" ]; then
        echo "错误: 无法读取 /proc/${pid}/cgroup 或非 cgroup v2" >&2
        return 1
    fi

    local full_path="${cgroup_line#0::}"
    if [ -z "${full_path}" ]; then
        echo "错误: 意外的 cgroup 格式: ${cgroup_line}" >&2
        return 1
    fi

    dirname "${full_path}"
}

# ---------- Tests ----------

test_normalize_container_id() {
    echo "test_normalize_container_id:"
    local result
    result=$(normalize_container_id "containerd://abc123")
    assert_eq "abc123" "$result" "strips containerd:// prefix"

    result=$(normalize_container_id "cri-o://xyz789")
    assert_eq "xyz789" "$result" "strips cri-o:// prefix"

    result=$(normalize_container_id "plain-id")
    assert_eq "plain-id" "$result" "preserves plain id"

    result=$(normalize_container_id "")
    assert_eq "" "$result" "handles empty string"
}

test_elapsed_since() {
    echo "test_elapsed_since:"
    local start result
    start=$(now_sec)
    sleep 0.1
    result=$(elapsed_since "$start")
    assert_non_empty "$result" "returns non-empty value"

    start=100.00
    result=$(elapsed_since "$start")
    assert_non_empty "$result" "returns value for past timestamp"
}

test_valid_pid() {
    echo "test_valid_pid:"
    assert_eq "0" "$(valid_pid $$ && echo 0 || echo 1)" "current pid $$ is valid"
    assert_eq "1" "$(valid_pid 99999999 && echo 0 || echo 1)" "large pid is invalid"
    assert_eq "1" "$(valid_pid "" && echo 0 || echo 1)" "empty string is invalid"
    assert_eq "1" "$(valid_pid 0 && echo 0 || echo 1)" "pid 0 is invalid"
}

test_get_pod_cgroup_from_pid() {
    echo "test_get_pod_cgroup_from_pid:"
    if [ -f "/proc/$$/cgroup" ]; then
        local result
        result=$(get_pod_cgroup_from_pid $$ 2>/dev/null || echo "__err__")
        if [ "$result" != "__err__" ]; then
            assert_non_empty "$result" "returns path for valid pid"
            assert_contains "$result" "/" "path contains slash"
        fi
    fi

    local err
    err=$(get_pod_cgroup_from_pid 99999999 2>/dev/null || echo "__err__")
    assert_eq "__err__" "$err" "fails on nonexistent pid"
}

# ---------- Main ----------

echo "=== testing simplified functions ==="
echo ""

test_normalize_container_id
echo ""
test_elapsed_since
echo ""
test_valid_pid
echo ""
test_get_pod_cgroup_from_pid

echo ""
echo "=== $TESTS_PASSED passed, $TESTS_FAILED failed ==="
[ "$TESTS_FAILED" -eq 0 ]
