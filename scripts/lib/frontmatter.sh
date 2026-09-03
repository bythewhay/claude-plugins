#!/usr/bin/env bash
# Read/write simple `key: value` frontmatter blocks delimited by `---` lines.

fm_get() {
  local file="$1" key="$2"
  local in_fm=0
  local line rest
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" -eq 0 ]; then
        in_fm=1
        continue
      else
        break
      fi
    fi
    if [ "$in_fm" -eq 1 ] && [[ "$line" == "$key":* ]]; then
      rest="${line#"$key":}"
      rest="${rest# }"
      printf '%s\n' "$rest"
      return 0
    fi
  done < "$file"
  printf '\n'
}

fm_set() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  local in_fm=0 fm_closed=0 key_written=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$fm_closed" -eq 0 ] && [ "$line" = "---" ]; then
      if [ "$in_fm" -eq 0 ]; then
        in_fm=1
        printf '%s\n' "$line" >> "$tmp"
        continue
      else
        if [ "$key_written" -eq 0 ]; then
          printf '%s: %s\n' "$key" "$value" >> "$tmp"
        fi
        fm_closed=1
        in_fm=0
        printf '%s\n' "$line" >> "$tmp"
        continue
      fi
    fi
    if [ "$in_fm" -eq 1 ] && [[ "$line" == "$key":* ]]; then
      printf '%s: %s\n' "$key" "$value" >> "$tmp"
      key_written=1
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$file"
  mv "$tmp" "$file"
}
