#!/bin/sh
# Isolate which request attribute the upstream gateway rejects.
KEY='sk-vACd7jPqzXIQohymNxsJbJJc9LEVZ0Fz7LgPJCuu7huSlkck'
URL='https://api.moleapi.com/v1/chat/completions'
M='gpt-5.6-luna'

try() {
    label="$1"; body="$2"
    printf '%s' "$body" > /tmp/tb.json
    code=$(curl -s -o /tmp/tr.json -w '%{http_code}' --max-time 60 -X POST "$URL" \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
        --data-binary @/tmp/tb.json)
    echo "--- $label  -> HTTP $code"
    head -c 260 /tmp/tr.json
    echo
}

MSG='[{"role":"user","content":"Say OK"}]'

try "1 minimal"            "{\"model\":\"$M\",\"messages\":$MSG}"
try "2 +temperature"       "{\"model\":\"$M\",\"messages\":$MSG,\"temperature\":0.2}"
try "3 +max_tokens"        "{\"model\":\"$M\",\"messages\":$MSG,\"max_tokens\":1024}"
try "4 +stream"            "{\"model\":\"$M\",\"messages\":$MSG,\"stream\":true}"
try "5 +system message"    "{\"model\":\"$M\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a router assistant.\"},{\"role\":\"user\",\"content\":\"Say OK\"}]}"
try "6 +one tool"          "{\"model\":\"$M\",\"messages\":$MSG,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_x\",\"description\":\"d\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}}}]}"

echo "--- 7 +tool without additionalProperties"
try "7 tool no addProps"   "{\"model\":\"$M\",\"messages\":$MSG,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_x\",\"description\":\"d\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]}"

rm -f /tmp/tb.json /tmp/tr.json
