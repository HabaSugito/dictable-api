#!/bin/sh
# Quick tour of the HTTP API. Usage: ./examples/curl.sh meeting.m4a ja
FILE=${1:?usage: curl.sh <audio file> [language]}
LANG=${2:-en}
BASE=http://127.0.0.1:8082

curl -s $BASE/health; echo
curl -s $BASE/v1/locales; echo

# OpenAI-compatible: same fields as POST https://api.openai.com/v1/audio/transcriptions
curl -s $BASE/v1/audio/transcriptions -F file=@"$FILE" -F model=apple-on-device -F language="$LANG"; echo
curl -s $BASE/v1/audio/transcriptions -F file=@"$FILE" -F language="$LANG" -F response_format=srt
