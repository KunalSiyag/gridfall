"""Benchmark fast GMI models on a batched GridFall resident-planning prompt (10 residents per call)."""
import json, os, sys, time, urllib.request, concurrent.futures as cf

def key():
    k = os.environ.get("GMI_API_KEY")
    if k:
        return k
    s = json.load(open(os.path.expanduser("~/.factory/settings.json")))
    def walk(o):
        if isinstance(o, dict):
            for kk, v in o.items():
                if isinstance(v, str) and kk.lower() in ("apikey", "api_key", "key") and "gmi" in json.dumps(o).lower():
                    return v
                r = walk(v)
                if r:
                    return r
        if isinstance(o, list):
            for v in o:
                r = walk(v)
                if r:
                    return r
    return walk(s)

EXTRAS = {
    "deepseek-ai/": {"thinking": {"type": "disabled"}},
    "moonshotai/kimi-k3": {"thinking": {"type": "disabled"}},
    "Qwen/": {"enable_thinking": False},
    "x-ai/": {"reasoning_effort": "low"},
    "zai-org/": {"thinking": {"type": "disabled"}},
    "openai/gpt-5": {"reasoning_effort": "low"},
    "stepfun-ai/": {"reasoning_effort": "low"},
}

SYS = ("You are the inner voices of residents of GridFall, a city. Each resident is a distinct real person with their own "
       "personality, job, money worries and memories. Decide for EACH resident independently, in character, what they do today. "
       "Reply with ONLY JSON: {\"residents\":[{\"id\":str,\"go_to_work\":bool,\"commute\":\"car|bus|train|walk|bike|none\","
       "\"spend\":int,\"spend_where\":\"local_shops|downtown|online|none\",\"evening\":\"home|shopping|park|stadium|visit_friend|volunteer|protest\","
       "\"mood\":0-100,\"mood_reason\":str,\"intent\":\"stay|considering_leaving|leaving\",\"recommend\":0-10,"
       "\"message_to_mayor\":str,\"thought\":str,\"say\":str}]}. Keep thought under 25 words, say under 12 words.")

people = []
jobs = ["electrician", "nurse", "teacher", "plumber", "shop owner", "factory worker", "software engineer", "bus driver", "retiree", "firefighter"]
for k in range(10):
    people.append({"id": "p%d" % k, "name": ["Ava","Ben","Chen","Dara","Eli","Fatima","Gus","Hana","Ivan","Jade"][k], "age": 24 + k * 5,
        "job": jobs[k], "traits": ["anxious","frugal","sociable","stubborn","optimistic","proud","lazy","caring","grumpy","brave"][k],
        "savings": 40 + k * 30, "wage_per_day": 4, "home": {"powered": k % 3 != 0, "water": True, "pollution": 0.2 + k * 0.05,
        "crime": 0.1, "commute_traffic": 0.6, "tax_rate": 9}, "memory": ["Day 3: power went out for 2 hours", "Day 4: mayor raised taxes"],
        "nearby_incidents": ["Power Plant Failure at (9,9), 40% repaired"] if k % 3 == 0 else []})
USER = json.dumps({"day": 5, "city": {"mayor_post": "We will fix the grid by tomorrow!", "headline": "Blackout hits Civic Campus", "shop_prices": "normal"}, "residents": people})

def call(model):
    body = {"model": model, "messages": [{"role": "system", "content": SYS}, {"role": "user", "content": USER}], "max_tokens": 2600, "temperature": 0.8}
    for pre, ex in EXTRAS.items():
        if model.startswith(pre):
            body.update(ex)
    req = urllib.request.Request("https://api.gmi-serving.com/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + K, "Content-Type": "application/json", "User-Agent": "gridfall/1.0"})
    t = time.time()
    try:
        d = json.load(urllib.request.urlopen(req, timeout=90))
        c = d["choices"][0]["message"].get("content") or ""
        s, e = c.find("{"), c.rfind("}")
        n = len(json.loads(c[s:e + 1]).get("residents", [])) if s >= 0 else 0
        return model, round(time.time() - t, 1), n, d.get("usage", {}).get("completion_tokens"), c[:160].replace("\n", " ")
    except Exception as ex:
        return model, round(time.time() - t, 1), -1, None, str(ex)[:160]

K = key()
models = sys.argv[1:]
with cf.ThreadPoolExecutor(len(models)) as pool:
    for r in pool.map(call, models):
        print(json.dumps(r))
