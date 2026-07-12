#!/usr/bin/env bash
set -euo pipefail

SUPABASE="${SUPABASE_BIN:-supabase}"
eval "$("$SUPABASE" status --output env)"

api() {
  curl --fail-with-body --silent --show-error "$@"
}

anonymous_token() {
  api \
    --request POST \
    "$API_URL/auth/v1/signup" \
    --header "apikey: $ANON_KEY" \
    --header "Content-Type: application/json" \
    --data '{}' |
    jq --exit-status --raw-output '.access_token'
}

function_call() {
  local name="$1"
  local token="$2"
  local body="$3"
  api \
    --request POST \
    "$FUNCTIONS_URL/$name" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $token" \
    --header "Content-Type: application/json" \
    --data "$body"
}

OWNER_TOKEN="$(anonymous_token)"
MEMBER_TOKEN="$(anonymous_token)"
OUTSIDER_TOKEN="$(anonymous_token)"

CREATE_RESPONSE="$(
  function_call create-pack "$OWNER_TOKEN" \
    '{"name":"Local E2E Pack","displayName":"Owner"}'
)"
PACK_ID="$(jq --exit-status --raw-output '.packId' <<<"$CREATE_RESPONSE")"
INVITE_TOKEN="$(jq --exit-status --raw-output '.invite.token' <<<"$CREATE_RESPONSE")"

[[ "${#INVITE_TOKEN}" -eq 43 ]]

JOIN_RESPONSE="$(
  function_call join-pack "$MEMBER_TOKEN" \
    "{\"token\":\"$INVITE_TOKEN\",\"displayName\":\"Member\"}"
)"
[[ "$(jq --exit-status --raw-output '.packId' <<<"$JOIN_RESPONSE")" == "$PACK_ID" ]]

MEMBER_PACKS="$(
  api \
    "$REST_URL/packs?id=eq.$PACK_ID&select=id" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $MEMBER_TOKEN"
)"
[[ "$(jq 'length' <<<"$MEMBER_PACKS")" -eq 1 ]]

OUTSIDER_PACKS="$(
  api \
    "$REST_URL/packs?id=eq.$PACK_ID&select=id" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $OUTSIDER_TOKEN"
)"
[[ "$(jq 'length' <<<"$OUTSIDER_PACKS")" -eq 0 ]]

MEMBER_ID="$(
  api \
    "$API_URL/auth/v1/user" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $MEMBER_TOKEN" |
    jq --exit-status --raw-output '.id'
)"
CLIENT_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
EVENT_BODY="$(
  jq --null-input --compact-output \
    --arg client "$CLIENT_ID" \
    --arg pack "$PACK_ID" \
    --arg user "$MEMBER_ID" \
    '{
      client_id: $client,
      pack_id: $pack,
      user_id: $user,
      occurred_at: "2026-07-12T12:00:00Z",
      sets: 1,
      reps: 30,
      streak: 1
    }'
)"

for _ in 1 2; do
  api \
    --request POST \
    "$REST_URL/workout_events?on_conflict=user_id,client_id" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $MEMBER_TOKEN" \
    --header "Content-Type: application/json" \
    --header "Prefer: resolution=ignore-duplicates" \
    --data "$EVENT_BODY" >/dev/null
done

EVENTS="$(
  api \
    "$REST_URL/workout_events?client_id=eq.$CLIENT_ID&select=id" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $MEMBER_TOKEN"
)"
[[ "$(jq 'length' <<<"$EVENTS")" -eq 1 ]]

function_call leave-pack "$MEMBER_TOKEN" \
  "{\"packId\":\"$PACK_ID\"}" |
  jq --exit-status '.left == true' >/dev/null

AFTER_LEAVE="$(
  api \
    "$REST_URL/packs?id=eq.$PACK_ID&select=id" \
    --header "apikey: $ANON_KEY" \
    --header "Authorization: Bearer $MEMBER_TOKEN"
)"
[[ "$(jq 'length' <<<"$AFTER_LEAVE")" -eq 0 ]]

function_call delete-pack "$OWNER_TOKEN" \
  "{\"packId\":\"$PACK_ID\"}" |
  jq --exit-status '.deleted == true' >/dev/null

echo "Supabase social Pack E2E passed"
