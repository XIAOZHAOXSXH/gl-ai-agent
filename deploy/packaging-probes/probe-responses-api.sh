#!/bin/sh
# Probe the OpenAI Responses API shape from the router itself.
KEY='sk-vACd7jPqzXIQohymNxsJbJJc9LEVZ0Fz7LgPJCuu7huSlkck'
BASE='https://api.moleapi.com/v1'

echo "===== 1. non-streaming /responses ====="
printf '%s' '{"model":"gpt-5.6-luna","input":"Say OK"}' > /tmp/rq.json
curl -s --max-time 60 -X POST "$BASE/responses" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/rq.json | head -c 700
echo

echo
echo "===== 2. streaming /responses (event names) ====="
printf '%s' '{"model":"gpt-5.6-luna","input":"Say OK","stream":true}' > /tmp/rs.json
curl -sN --max-time 60 -X POST "$BASE/responses" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/rs.json | head -40
echo
echo "===== 3. done ====="
rm -f /tmp/rq.json /tmp/rs.json
