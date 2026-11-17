"""Transcribe a file with the official OpenAI Python SDK, pointed at Hark Server.

    uv run --with openai examples/openai_sdk.py meeting.m4a ja
"""
import sys

from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8082/v1", api_key="not-needed")

path = sys.argv[1]
language = sys.argv[2] if len(sys.argv) > 2 else "en"

with open(path, "rb") as audio:
    result = client.audio.transcriptions.create(
        model="apple-on-device",  # any value works; Hark always uses the on-device model
        file=audio,
        language=language,
        response_format="verbose_json",
    )

for segment in result.segments:
    print(f"[{segment.start:7.2f}s → {segment.end:7.2f}s] {segment.text}")
