#!/usr/bin/env bash
# Minimal assertion helpers for shell script tests.

assert_file_exists() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file to exist: $f" >&2
    exit 1
  fi
}

assert_file_contains() {
  local f="$1" pattern="$2"
  if ! grep -qF -- "$pattern" "$f"; then
    echo "FAIL: expected '$f' to contain: $pattern" >&2
    echo "--- actual content of $f ---" >&2
    cat "$f" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local f="$1" pattern="$2"
  if grep -qF -- "$pattern" "$f"; then
    echo "FAIL: expected '$f' NOT to contain: $pattern" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-values differ}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $msg (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

pass() {
  echo "PASS: $1"
}
