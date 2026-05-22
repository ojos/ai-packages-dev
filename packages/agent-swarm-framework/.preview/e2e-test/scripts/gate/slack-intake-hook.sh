#!/usr/bin/env bash
set -euo pipefail

# Slack intake runtime hook (phase-2 minimal integration)
# Input: JSON payload via stdin
# Output: normalized intake JSON via stdout

payload="$(cat)"

workspace_mode="$(printf '%s' "$payload" | jq -r '.source.workspace_mode // "dedicated"')"
channel_id="$(printf '%s' "$payload" | jq -r '.source.channel_id // empty')"
user_id="$(printf '%s' "$payload" | jq -r '.source.user_id // empty')"
raw_text="$(printf '%s' "$payload" | jq -r '.intake.raw_text // empty')"
command_text="$(printf '%s' "$payload" | jq -r '.intake.command_text // .intake.raw_text // empty')"
runner_available="$(printf '%s' "$payload" | jq -r '.runtime.runner_available // true')"
auth_validated="$(printf '%s' "$payload" | jq -r '.safety.auth_validated // false')"

if [[ -z "$channel_id" || -z "$user_id" ]]; then
  jq -cn '{status:"rejected", reason:"missing_channel_or_user", trace:{stage:"slack-hook"}}'
  exit 0
fi

if [[ "$auth_validated" != "true" ]]; then
  jq -cn --arg c "$channel_id" --arg u "$user_id" '{status:"rejected", reason:"auth_not_validated", source:{channel_id:$c,user_id:$u}, trace:{stage:"slack-hook"}}'
  exit 0
fi

if [[ "$runner_available" != "true" ]]; then
  jq -cn --arg mode "$workspace_mode" --arg c "$channel_id" --arg u "$user_id" --arg cmd "$command_text" '{status:"deferred", queue:"slack-intake", source:{channel_type:"slack",workspace_mode:$mode,channel_id:$c,user_id:$u}, intake:{command_text:$cmd}, trace:{stage:"slack-hook",reason:"runner_unavailable"}}'
  exit 0
fi

jq -cn --arg mode "$workspace_mode" --arg c "$channel_id" --arg u "$user_id" --arg raw "$raw_text" --arg cmd "$command_text" '{status:"dispatch", source:{channel_type:"slack",workspace_mode:$mode,channel_id:$c,user_id:$u}, intake:{raw_text:$raw,command_text:$cmd}, trace:{stage:"slack-hook"}}'
