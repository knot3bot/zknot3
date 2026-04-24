#!/bin/sh
set -eu

render_if_template() {
  # If the compose mounts a template, render to a writable temp path
  if [ -f /etc/zknot3/config.template.json ]; then
    : "${ZKNOT3_ADMIN_TOKEN:=}"
    if [ -z "${ZKNOT3_ADMIN_TOKEN}" ]; then
      echo "ERROR: ZKNOT3_ADMIN_TOKEN is required when using /etc/zknot3/config.template.json" >&2
      exit 2
    fi
    mkdir -p /tmp/zknot3
    envsubst < /etc/zknot3/config.template.json > /tmp/zknot3/config.json
    echo "/tmp/zknot3/config.json"
    return 0
  fi
  echo ""
}

tmpl_path="$(render_if_template)"

if [ -n "${tmpl_path}" ]; then
  # Replace "-c <path>" if present, otherwise append "-c <rendered>"
  out_args=""
  skip_next=0
  saw_c=0
  for a in "$@"; do
    if [ "${skip_next}" -eq 1 ]; then
      out_args="${out_args} ${tmpl_path}"
      skip_next=0
      continue
    fi
    if [ "${a}" = "-c" ]; then
      saw_c=1
      out_args="${out_args} -c"
      skip_next=1
      continue
    fi
    out_args="${out_args} ${a}"
  done
  if [ "${saw_c}" -eq 0 ]; then
    out_args="${out_args} -c ${tmpl_path}"
  fi
  # shellcheck disable=SC2086
  exec /usr/local/bin/zknot3 ${out_args}
fi

exec /usr/local/bin/zknot3 "$@"

