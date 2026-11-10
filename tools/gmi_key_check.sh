#!/usr/bin/env bash
# Checks the GMI key in $GMI_API_KEY from your own shell. Prints only status codes, sizes and model
# names, never the key. Run it before a demo:
#   GMI_API_KEY="..." tools/gmi_key_check.sh
# 1. GET /v1/models: HTTP status, reply size (the game reads at most 8 MiB of it) and whether the 14
#    models GridFall uses are listed.
# 2. One tiny chat call to Kimi K3 with reasoning_effort low (the setting the game sends), HTTP
#    status only. About 16 tokens.
set -u
if [ -z "${GMI_API_KEY:-}" ]; then
	echo "Set GMI_API_KEY first: GMI_API_KEY=\"...\" tools/gmi_key_check.sh" >&2
	exit 2
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
auth() { printf 'header = "Authorization: Bearer %s"\n' "$GMI_API_KEY"; }

res=$(curl -s -m 40 -K <(auth) -o "$tmp/models.json" -w '%{http_code} %{size_download} %{time_total}' \
	https://api.gmi-serving.com/v1/models)
read -r code size secs <<<"$res"
echo "models list: HTTP $code, $size bytes in ${secs}s (the game's limit is 8388608 bytes)"
python3 - "$tmp/models.json" <<'PY'
import json, sys
WANT = [
    "google/gemini-4-argon", "deepseek-ai/DeepSeek-V4-Flash-0731", "moonshotai/kimi-k3",
    "Qwen/Qwen3.8-Max", "x-ai/grok-4.5", "MiniMaxAI/MiniMax-M3", "XiaomiMiMo/MiMo-V2.6-Flash",
    "openai/gpt-6-luna", "deepseek-ai/DeepSeek-V4-Pro", "google/gemini-3.8-flash",
    "deepseek-ai/DeepSeek-V4.1-Flash", "google/gemini-3.5-flash-lite", "Qwen/Qwen3.8-Flash",
    "zai-org/GLM-5.3-Flash",
]
try:
    data = json.load(open(sys.argv[1]))
    ids = {m.get("id") for m in data.get("data", [])}
except Exception as e:
    print("could not read the model list:", type(e).__name__)
    sys.exit(0)
missing = [m for m in WANT if m not in ids]
print(f"{len(ids)} models listed; GridFall's {len(WANT) - len(missing)}/{len(WANT)} are there")
if missing:
    print("missing:", ", ".join(missing))
PY

body='{"model":"moonshotai/kimi-k3","messages":[{"role":"user","content":"Reply with the word ok."}],"max_tokens":16,"reasoning_effort":"low"}'
res=$(curl -s -m 60 -K <(auth) -H 'Content-Type: application/json' -d "$body" -o "$tmp/chat.json" \
	-w '%{http_code}' https://api.gmi-serving.com/v1/chat/completions)
echo "Kimi K3 chat with reasoning_effort low: HTTP $res"
if [ "$res" != "200" ]; then
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(str(d)[:300])" "$tmp/chat.json" 2>/dev/null || true
fi
