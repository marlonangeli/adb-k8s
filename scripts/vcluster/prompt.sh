# shellcheck shell=bash

# Adds current kubectl context (highlighting vCluster contexts) to PS1.
# Source this file from env.sh to keep prompts contextualized while switching clusters.

if [[ -n "${ADB_PROMPT_CTX_ENABLED:-}" ]]; then
  return 0
fi
export ADB_PROMPT_CTX_ENABLED=1

: "${PS1:=\\u@\\h:\\w\\$ }"
__ADB_PROMPT_BASE_PS1="${PS1}"

__adb_update_prompt() {
  local exit_code=$?
  local context label
  if command -v kubectl >/dev/null 2>&1; then
    context=$(kubectl config current-context 2>/dev/null || true)
  else
    context=""
  fi

  if [[ -n "${context}" ]]; then
    if [[ "${context}" == vcluster_* ]]; then
      label="[vcluster:${context#vcluster_}]"
    else
      label="[ctx:${context}]"
    fi
  else
    label="[ctx:none]"
  fi

  PS1="${__ADB_PROMPT_BASE_PS1% } ${label} "
  return "${exit_code}"
}

if [[ -n "${PROMPT_COMMAND:-}" ]]; then
  PROMPT_COMMAND="__adb_update_prompt;${PROMPT_COMMAND}"
else
  PROMPT_COMMAND="__adb_update_prompt"
fi
