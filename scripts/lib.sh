# Shared helpers. Sourced, not executed.

# Reads one top-level key out of a vault-encrypted yaml file.
vault_get() {
  ansible-vault view --vault-password-file secrets/.vault-pass "$1" \
    | sed -n "s/^$2: *//p"
}

# vault_get, but fails loudly when the key is missing.
vault_require() {
  local value
  value="$(vault_get "$1" "$2")"
  [ -n "$value" ] || {
    echo "no $2 in $1 -- see bootstrap/README.md" >&2
    exit 1
  }
  printf '%s' "$value"
}
