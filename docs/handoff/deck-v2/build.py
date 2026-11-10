import html, json, os, re

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "project", "slides")
os.makedirs(OUT, exist_ok=True)

BG, CARD, LINE = "#0B1020", "#141C33", "#2A3558"
TXT, MUTED, DIM = "#EEF1F8", "#A3AFCB", "#7F8BAA"
AMBER, CYAN, DARK = "#FFB800", "#36E0F0", "#111A33"
SG = "font-family:'Space Grotesk', Arial, sans-serif"
MONO = "font-family:'JetBrains Mono', 'Courier New', monospace"

IMG = {
    "planner": "/_blob/305379c8d8518df981a15c9acbcccaf4",
    "street": "/_blob/1ba381b2d4ce417f34ff75f442726765",
    "sheet": "/_blob/e6f1fce855faf2697c1e7fd1fd926036",
    "robot": "/_blob/7a2f4de7c66a0c670d6c0c325dd33772",
    "hero": "/_blob/e8ae7b52749c953a0ae7fb33c857417c",
    "posters": "/_blob/4cd7c100ae9a8a7da5d2e9a3d8d17de7",
    "web": "/_blob/adb2e6c677bbd23d6690fcae77d26e4e",
    "argon": "/_blob/eb01cddc82bde0d8947db8f5179c783b",
    "deepseek": "/_blob/6c425b3cecc46e6f42daac0bf5d85c22",
    "kimi": "/_blob/74446904b223e46cd662ed62e46a0d50",
    "qwen": "/_blob/0746f1fce6353f0410b043f2e96ccf46",
    "grok": "/_blob/a3eb22804d151415300c2a3ddfc8aa5a",
}


def logo(name, h):
    """Official GMI Cloud / Factory wordmarks (white SVG from each company's own site), inline at height h."""
    t = open(os.path.join(ROOT, "img", name + "-logo.svg")).read()
    vb = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', t)
    w = round(h * float(vb.group(1)) / float(vb.group(2)))
    label = {"gmi": "GMI Cloud", "factory": "Factory"}[name]
    return t.replace("<svg ", f'<svg role="img" aria-label="{label}" width="{w}" height="{h}" ', 1)


def lockup(hg=52, hf=38, gap=36):
    return (f'<div style="display:flex;flex-direction:row;align-items:center;gap:{gap}px">{logo("gmi", hg)}'
            f'<div style="width:2px;height:{hg}px;background:{LINE}"></div>{logo("factory", hf)}</div>')


def section(sid, body, notes, footer=None):
    foot = ""
    if footer:
        foot = (f'<p style="position:absolute;left:128px;bottom:64px;width:1664px;'
                f'font-size:24px;color:{DIM}">{html.escape(footer)}</p>\n')
    s = (f'<section id="{sid}" data-transition="fade" style="background:{BG};color:{TXT};'
         f"font-family:'IBM Plex Sans', Arial, sans-serif;padding:128px 128px 160px;"
         f'display:flex;flex-direction:column;gap:40px">\n{body}\n{foot}'
         f'<aside>{html.escape(notes)}</aside>\n</section>\n')
    assert len(notes) <= 4000, (sid, len(notes))
    with open(os.path.join(OUT, sid + ".html"), "w") as f:
        f.write(s)


def head(eyebrow, title):
    return (f'<div style="display:flex;flex-direction:column;gap:16px">\n'
            f'<p style="{MONO};font-size:24px;font-weight:500;letter-spacing:3px;'
            f'text-transform:uppercase;color:{AMBER}">{eyebrow}</p>\n'
            f'<h2 style="{SG};font-size:72px;font-weight:700;line-height:1.1;color:{TXT}">{title}</h2>\n</div>')


def img(key, w, h, alt, fit="cover", radius=12, bg=None):
    b = f";background:{bg}" if bg else ""
    return (f'<img src="{IMG[key]}" alt="{html.escape(alt)}" style="width:{w}px;height:{h}px;'
            f'object-fit:{fit};border-radius:{radius}px{b}">')


def p(text, size=28, color=TXT, weight=None, lh=1.3, extra=""):
    w = f";font-weight:{weight}" if weight else ""
    return f'<p style="font-size:{size}px;line-height:{lh};color:{color}{w}{extra}">{text}</p>'


def amber(t):
    return f'<span style="color:{AMBER}"><b>{t}</b></span>'


# ---------------------------------------------------------------- whatis
body = head("The game", "What is GridFall?") + "\n" + p(
    "Five AI mayors, each a different model on GMI Cloud, run one city. "
    "You can watch it from above, or walk its streets.", 30, MUTED) + f"""
<div style="display:flex;flex-direction:row;gap:64px">
<div style="display:flex;flex-direction:column;gap:12px">
{img("planner", 800, 450, "The city from above: a map with five mayor cards along the bottom and a Chaos Director warning at the top")}
{p("From above: the Planner view. Five cards, five mayors.", 24, MUTED)}
</div>
<div style="display:flex;flex-direction:column;gap:12px">
{img("street", 800, 450, "On the street in first person: the player walks toward a fire while an activity panel shows which AI model decided what")}
{p("On the street: first person. Walk it and talk to residents.", 24, MUTED)}
</div>
</div>"""
section("whatis", body,
        "About 1 minute. Keep it simple: this is a city simulator, like SimCity, except you do not run it. Five AI mayors do. "
        "Each mayor is a different AI model hosted on GMI Cloud, so they really do make different decisions. "
        "Left picture: the view from above, which the game calls the Planner view. The five cards along the bottom are the five mayors, and the red banner at the top is the Chaos Director (another AI) bursting a sewage pipe. "
        "Right picture: the same city on foot, in first person. The panel on the right shows which AI decided what. "
        "The two views are not two cities. It is one city, and you press Tab to switch. Do not explain more than this yet; the next slides fill in who the mayors are and how it fits together.",
        )

# ---------------------------------------------------------------- mayors
mayors = [
    ("argon", "Ada Okafor", "Argon-4", "Utility-first planner", "#FFB800"),
    ("deepseek", "Viktor Han", "DeepSeek-V4", "Systems engineer", "#4DA3FF"),
    ("kimi", "Mei Kimura", "Kimi-K3", "Coalition builder", "#C77DFF"),
    ("qwen", "Rosa Quintero", "Qwen-3.8", "Fiscal pragmatist", "#1DE98A"),
    ("grok", "Duke Granger", "Grok-4.5", "Growth maximalist", "#FF5A78"),
]
cols = ""
for key, name, model, trait, col in mayors:
    cols += f"""<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:14px">
{img(key, 280, 280, f"Portrait of {name}, the mayor run by {model}", radius=140)}
<p style="{SG};font-size:34px;font-weight:700;line-height:1.1;color:{TXT};text-align:center">{name}</p>
<p style="{MONO};font-size:26px;font-weight:500;color:{col};text-align:center">{model}</p>
<p style="font-size:26px;line-height:1.25;color:{MUTED};text-align:center">{trait}</p>
</div>
"""
body = head("The cast", "Five mayors, five AI models") + f"""
<div style="display:flex;flex-direction:row;gap:24px">
{cols}</div>
<div style="background:{AMBER};border-radius:16px;padding:28px 36px">
<p style="{SG};font-size:44px;font-weight:700;line-height:1.1;color:{DARK}">Same city. Different personalities. Nothing is scripted.</p>
</div>"""
section("mayors", body,
        "About 1 minute. Introduce the cast by person first, model second. Ada Okafor is run by Argon-4 and plans around utilities. Viktor Han runs on DeepSeek-V4 and thinks like a systems engineer. Mei Kimura runs on Kimi-K3 and builds coalitions. Rosa Quintero runs on Qwen-3.8 and watches the budget. Duke Granger runs on Grok-4.5 and wants growth. "
        "Once a game day each mayor looks at its district, thinks in private, posts a public message and asks for up to seven actions. The city checks every action and says why it refused one. "
        "That is the point of the project: the same city, five different models, and nobody can predict what happens. Around the mayors there are five more AI helpers (a newspaper, a council speaker, a disaster director, a power-grid operator and a street inspector), and every resident has a mind of their own. "
        "Say where the pictures came from: they are concept art drawn by GMI's image model, which comes back later in the story.",
        "Portraits drawn by GMI's image model, hy-image-v3.5-preview.")


# ---------------------------------------------------------------- lineup (GMI model cast)
def lcard(label, title, rows, col):
    items = ""
    for name, small in rows:
        items += f"""<div style="display:flex;flex-direction:column;gap:2px;padding:6px 0;border-top:1px solid {LINE}">
<p style="{SG};font-size:30px;font-weight:700;line-height:1.1;color:{TXT}">{name}</p>
<p style="font-size:20px;line-height:1.2;color:{MUTED}">{small}</p>
</div>"""
    return f"""<div style="flex:1;display:flex;flex-direction:column;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:28px 32px">
<p style="{MONO};font-size:22px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{col}">{label}</p>
<h3 style="{SG};font-size:40px;font-weight:700;line-height:1.1;color:{TXT};padding:6px 0 14px">{title}</h3>
{items}</div>"""


body = head("GMI Cloud", "One key. 14 models. 9 labs.") + f"""
<div style="display:flex;flex-direction:row;gap:24px">
{lcard("The mayors", "Five decision makers", [
    ("Gemini 4 Argon", "Google · Ada Okafor"),
    ("DeepSeek V4 Flash", "DeepSeek · Viktor Han"),
    ("Kimi K3", "Moonshot AI · Mei Kimura"),
    ("Qwen 3.8 Max", "Alibaba Qwen · Rosa Quintero"),
    ("Grok 4.5", "xAI · Duke Granger")], AMBER)}
{lcard("The city helpers", "Five who keep it lively", [
    ("MiMo V2.6 Flash", "Xiaomi · The Gazette newspaper"),
    ("GPT-6 Luna", "OpenAI · The council speaker"),
    ("DeepSeek V4 Pro", "DeepSeek · The chaos director"),
    ("Gemini 3.8 Flash", "Google · The power-grid operator"),
    ("MiniMax M3", "MiniMax · Citizens and street inspector")], CYAN)}
{lcard("The residents", "Six fast models", [
    ("DeepSeek V4.1 Flash", "DeepSeek"),
    ("Gemini 3.5 Flash Lite", "Google"),
    ("MiniMax M3", "MiniMax"),
    ("DeepSeek V4 Flash", "DeepSeek"),
    ("Qwen 3.8 Flash", "Alibaba Qwen"),
    ("GLM 5.3 Flash", "Z.ai")], "#1DE98A")}
</div>"""
section("lineup", body,
        "About 1 minute. This is the GMI Cloud slide, so say it with pride. Every thinking part of GridFall is a model on GMI Cloud, reached with one key and one endpoint. "
        "Fourteen different models from nine labs: Google, DeepSeek, Moonshot AI, Alibaba's Qwen, xAI, MiniMax, Xiaomi, OpenAI and Z.ai. "
        "Left column: the five mayors, each on a different model. Middle: the five city helpers, the newspaper, the council speaker, the disaster director, the power-grid operator, and the citizens and street inspector (those two share one model). "
        "Right: the residents. Each resident's daily plan and chat is answered by one of six fast, cheap models that take turns. "
        "The point for the audience: you can put a model from any lab into a role by changing one line, and compare them in the same live city. That is only practical because GMI puts them behind one door. "
        "Do not mix this up with the build story: the kimi-k3 that led the Droid mission ran through Droid, not GMI. The Kimi K3 here is a mayor, and it is called through GMI. "
        "Before you present, do one keyed run and check the game's startup line says all 14 models are available. The game prints it; in a test run on the owner's machine it timed out, so confirm it on the day. "
        "The image model is the fifteenth GMI model in the game; the next slides cover it.",
        "Plus hy-image-v3.5-preview, GMI's image model, for the concept art and the posters.")

# ---------------------------------------------------------------- cast (mayors + all 14 GMI models, one slide)
labs = {"argon": "Google", "deepseek": "DeepSeek", "kimi": "Moonshot AI", "qwen": "Alibaba Qwen", "grok": "xAI"}
mnames = {"argon": "Gemini 4 Argon", "deepseek": "DeepSeek V4 Flash", "kimi": "Kimi K3", "qwen": "Qwen 3.8 Max", "grok": "Grok 4.5"}
mcols = ""
for key, name, model, trait, col in mayors:
    mcols += f"""<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:6px">
{img(key, 130, 130, f"Portrait of {name}, the mayor run by {mnames[key]}", radius=65)}
<p style="{SG};font-size:28px;font-weight:700;line-height:1.1;color:{TXT};text-align:center">{name}</p>
<p style="{MONO};font-size:24px;font-weight:500;color:{col};text-align:center">{mnames[key]}</p>
<p style="font-size:22px;line-height:1.2;color:{MUTED};text-align:center">{labs[key]}</p>
</div>
"""
helpers = [("MiMo V2.6 Flash", "Xiaomi", "the Gazette newspaper"), ("GPT-6 Luna", "OpenAI", "the council speaker"),
           ("DeepSeek V4 Pro", "DeepSeek", "the disaster director"), ("Gemini 3.8 Flash", "Google", "the power-grid operator"),
           ("MiniMax M3", "MiniMax", "citizens and street inspector")]
hl = "".join(f'<p style="font-size:24px;line-height:1.25;color:{TXT};padding:4px 0"><b>{m}</b> <span style="color:{MUTED}">· {lab} · {role}</span></p>' for m, lab, role in helpers)
residents = ["DeepSeek V4.1 Flash", "Gemini 3.5 Flash Lite", "MiniMax M3", "DeepSeek V4 Flash", "Qwen 3.8 Flash", "GLM 5.3 Flash"]
rl = "".join(f'<p style="font-size:24px;line-height:1.25;color:{TXT};padding:4px 0"><b>{m}</b></p>' for m in residents)
body = head("GMI Cloud", "One key. 14 models. 9 labs.") + f"""
<div style="display:flex;flex-direction:row;gap:24px">
{mcols}</div>
<div style="display:flex;flex-direction:row;gap:24px;flex:1">
<div style="flex:1;display:flex;flex-direction:column;gap:8px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:24px 32px">
<p style="{MONO};font-size:22px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{CYAN}">Five city helpers</p>
{hl}</div>
<div style="width:700px;display:flex;flex-direction:column;gap:8px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:24px 32px">
<p style="{MONO};font-size:22px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:#1DE98A">Residents: six fast models take turns</p>
<div style="display:grid;grid-template-columns:1fr 1fr;column-gap:24px">{rl}</div>
<p style="font-size:22px;line-height:1.25;color:{MUTED};padding-top:6px">Google, DeepSeek, MiniMax, Alibaba Qwen and Z.ai.</p>
</div>
</div>"""
section("cast", body,
        "About 2 minutes. This is the GMI Cloud slide, so say it with pride. Every thinking part of GridFall is a model on GMI Cloud, reached with one key and one endpoint. Fourteen different models from nine labs: Google, DeepSeek, Moonshot AI, Alibaba's Qwen, xAI, MiniMax, Xiaomi, OpenAI and Z.ai. "
        "Top row, the five mayors, person first and model second. Ada Okafor runs on Gemini 4 Argon and plans around utilities. Viktor Han runs on DeepSeek V4 Flash and thinks like a systems engineer. Mei Kimura runs on Kimi K3 and builds coalitions. Rosa Quintero runs on Qwen 3.8 Max and watches the budget. Duke Granger runs on Grok 4.5 and wants growth. Once a game day each mayor looks at its district, thinks in private, posts a public message and asks for up to seven actions. The city checks every action and says why it refused one. "
        "Bottom left, the five city helpers: a newspaper, a council speaker, a disaster director, a power-grid operator, and the citizens and street inspector, which share one model. Bottom right, the residents: each resident's daily plan and chat is answered by one of six fast, cheap models taking turns. "
        "Why these models [confirm in your own words]: the mayors and the bigger helpers get stronger models because each turn is a big decision, and the residents get fast ones because there are many of them. Spreading the roles across nine labs is the point: the same city shows how different models behave. Changing a role's model is a one-line change, and that is only practical because GMI puts all of them behind one door. "
        "Do not mix this up with the build story: the kimi-k3 that led the Droid mission ran through Droid, not GMI. The Kimi K3 mayor is called through GMI. "
        "Before you present, do one keyed run and check the game's startup line reports all 14 models available; in an earlier test run on your machine it timed out, so confirm it on the day.",
        "The portraits were drawn by GMI's image model, hy-image-v3.5-preview.")

# ---------------------------------------------------------------- arch
def arch_card(label, title, text):
    return f"""<div style="width:458px;display:flex;flex-direction:column;gap:20px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:36px">
<p style="{MONO};font-size:24px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{AMBER}">{label}</p>
<h3 style="{SG};font-size:60px;font-weight:700;line-height:1.1;color:{TXT}">{title}</h3>
<p style="font-size:34px;line-height:1.3;color:{MUTED}">{text}</p>
</div>"""


def arch_arrow(label):
    return f"""<div style="width:145px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px">
<p style="{SG};font-size:72px;font-weight:700;line-height:1;color:{AMBER}">→</p>
<p style="font-size:24px;line-height:1.2;color:{MUTED};text-align:center">{label}</p>
</div>"""


body = head("How it fits together", "One city, many brains, two views") + f"""
<div style="display:flex;flex-direction:row;align-items:stretch">
{arch_card("GMI Cloud", "The brains", "Five mayors, five city helpers and the residents are all AI models.")}
{arch_arrow("decisions")}
{arch_card("The simulation", "The city", "One city that checks every decision and keeps the rules fair.")}
{arch_arrow("what happened")}
{arch_card("Two windows", "The views", "Watch from above, or walk the streets. Same city, same moment.")}
</div>
<div style="display:flex;flex-direction:row;align-items:center;justify-content:space-between;gap:32px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:28px 36px">
<p style="font-size:30px;line-height:1.3;color:{TXT}">No key, or a model is down? Recorded answers keep the city moving.</p>
<p style="{SG};font-size:40px;font-weight:700;line-height:1.1;color:{AMBER}">The city never stops.</p>
</div>"""
section("arch", body,
        "About 45 seconds. This is the only architecture slide, so keep it to three boxes, and let the demo show how it works. "
        "Left, the brains: every decision in the game comes from an AI model on GMI Cloud, the five mayors, five city helpers and the residents. "
        "Middle, the city: a normal program that holds the real state of the city. The AI asks for things, the city checks them and says yes or no, which keeps the game fair and stops a model from breaking the rules. "
        "Right, the views: the view from above and the street view are two windows onto the same city. "
        "Bottom, the safety net: if there is no key, or a model is slow or down, the game replays recorded answers and then falls back to simple rules, so the city never freezes. That is why the demo works even with no internet. "
        "If someone asks for more depth, point them to the GitHub project at the end.")

# ---------------------------------------------------------------- story (sequence diagram)
lanes = {"me": 360, "dr": 650, "cc": 940, "gmi": 1230, "tool": 1520}
names = {"me": ("Me", "Kunal"), "dr": ("Droid", "Opus 5.5, kimi-k3"),
         "cc": ("Claude Code", "Opus, then Sonnet"),
         "gmi": ("GMI Cloud", "chat + image models"), "tool": ("Blender + Godot", "model and engine")}
svg = [f'<svg aria-label="Sequence diagram of how GridFall was built: Droid on Claude Opus 5.5, Claude Code when usage limits hit, a Droid Core model for the mission, then the browser build" '
       f'width="1664" height="630" viewBox="0 0 1664 630">']
for k, x in lanes.items():
    svg.append(f'<line x1="{x}" y1="84" x2="{x}" y2="626" stroke="{LINE}" stroke-width="3" stroke-dasharray="8 8"/>')
rows = [130 + 56 * i for i in range(9)]
bands = {3: "Droid limit hit: Claude Code (Opus 5.5) steps in",
         5: "Droid Core model kimi-k3 leads seven specialists",
         6: "Limit hit again: Claude Code (Sonnet 5.5)"}
for idx, text in bands.items():
    y = rows[idx]
    svg.append(f'<rect x="262" y="{y - 40}" width="1402" height="54" rx="12" fill="#1B2547" stroke="{AMBER}" stroke-opacity="0.5"/>')
    svg.append(f'<text x="1640" y="{y + 8}" text-anchor="end" font-size="24" font-weight="600" fill="{AMBER}">{text}</text>')
msgs = [
    ("17 Oct", "me", "dr", "A city of AI mayors", "req"),
    ("", "dr", "gmi", "Mayors and art sketches", "req"),
    ("", "dr", "tool", "Model it in Blender", "req"),
    ("18–19 Oct", "me", "cc", "Let me walk the streets", "req"),
    ("19–25 Oct", "dr", "me", "46 reviewed changes", "ret"),
    ("25–30 Oct", "me", "dr", "Mission: finish it", "req"),
    ("30 Oct–2 Nov", "me", "cc", "Polish and web build", "req"),
    ("", "cc", "gmi", "Host the web build", "req"),
    ("2 Nov", "gmi", "me", "Playable in a browser", "ret"),
]
for (date, a_, b_, label, kind), y in zip(msgs, rows):
    x1, x2 = lanes[a_], lanes[b_]
    col = AMBER if kind == "req" else CYAN
    dash = ' stroke-dasharray="10 8"' if kind == "ret" else ""
    d = 1 if x2 > x1 else -1
    if date:
        svg.append(f'<text x="0" y="{y + 8}" font-size="24" font-weight="600" fill="{AMBER}">{date}</text>')
    svg.append(f'<line x1="{x1}" y1="{y}" x2="{x2 - d * 14}" y2="{y}" stroke="{col}" stroke-width="4"{dash}/>')
    svg.append(f'<polygon points="{x2},{y} {x2 - d * 18},{y - 9} {x2 - d * 18},{y + 9}" fill="{col}"/>')
    svg.append(f'<text x="{(x1 + x2) // 2}" y="{y - 12}" text-anchor="middle" font-size="24" fill="{TXT}" '
               f'stroke="{BG}" stroke-width="6" paint-order="stroke">{label}</text>')
for k, x in lanes.items():
    n, s_ = names[k]
    svg.append(f'<rect x="{x - 135}" y="0" width="270" height="84" rx="12" fill="{CARD}" stroke="{LINE}"/>')
    svg.append(f'<text x="{x}" y="34" text-anchor="middle" font-size="28" font-weight="700" fill="{TXT}">{n}</text>')
    svg.append(f'<text x="{x}" y="66" text-anchor="middle" font-size="24" fill="{MUTED}">{s_}</text>')
svg.append("</svg>")
body = head("The story", "How it was built, in order") + "\n" + "\n".join(svg)
section("story", body,
        "About 2 minutes. Read it top to bottom like a conversation: amber arrows are requests, cyan dashed arrows are answers. "
        "I built GridFall with two coding tools, Factory Droid and Claude Code, and the switches were driven by usage limits. "
        "17 October: I describe the game to Droid, running Claude Opus 5.5. It connects the five mayors to GMI Cloud, asks GMI's image model for concept art, and uses Blender and the Godot engine to build the city and its models. "
        "18 and 19 October: the first-person layer, walking the streets, was built in Claude Code on Opus 5.5 after a Droid usage limit, with many agents working in parallel from written specs. "
        "19 to 25 October: back on Droid with Opus 5.5, delivering the game one feature at a time as 46 reviewed changes. "
        "25 to 30 October, the Droid mission: to get more usage we moved to a Droid Core model, kimi-k3, which goes further on the same allowance. A lead agent split my complaints between seven specialists and ran for five days. "
        "30 October to 2 November: the mission hit its limit too, so Claude Code on Sonnet 5.5 finished the polish and the web build for GMI AgentBox. "
        "The point for the audience: everything is written down (specs, notes, tests), so the work could move between tools when a limit hit. "
        "[Check the first hand-over on 18 and 19 October and the Droid Core wording against your own memory before you present.]",
        "Dates are 2026. Sources: git history and the Droid session logs; the reasons for the hand-overs are the builder's account.")

# ---------------------------------------------------------------- people
def panel_caption(step, text):
    return (f'<p style="{MONO};font-size:24px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{AMBER}">{step}</p>\n'
            + p(text, 28, TXT, lh=1.25))


def arrow_col():
    return (f'<div style="width:76px;height:420px;display:flex;align-items:center;justify-content:center">'
            f'<p style="{SG};font-size:64px;font-weight:700;line-height:1;color:{AMBER}">→</p></div>')


body = head("GMI's image model", "From a sketch to a character") + f"""
<div style="display:flex;flex-direction:row;align-items:flex-start;justify-content:space-between">
<div style="width:720px;display:flex;flex-direction:column;gap:10px">
{img("sheet", 720, 420, "Concept sheet drawn by the image model: five armoured mayor avatars in gold, blue, violet, green and red", bg=CARD)}
{panel_caption("1 · The sketch", "GMI's image model drew five mayor avatars.")}
</div>
{arrow_col()}
<div style="width:420px;display:flex;flex-direction:column;gap:10px">
{img("robot", 420, 420, "A simple blocky robot with a halo, rendered in Blender")}
{panel_caption("2 · The model", "Blender turned the idea into a simple robot.")}
</div>
{arrow_col()}
<div style="width:360px;display:flex;flex-direction:column;gap:10px">
{img("hero", 360, 420, "The player character in the shipped game: a realistic person in a red sweater walking down a city street")}
{panel_caption("3 · The game", "Realistic people took over, one fitted to each job.")}
</div>
</div>"""
section("people", body,
        "About 2 minutes. This is the image-model story. First the character, in three pictures. "
        "One, the sketch: before any 3D work I asked GMI's image model, hy-image-v3.5-preview, for a concept sheet of the five mayors as armoured characters. That gave us a look and a colour for each mayor: gold, blue, violet, green and red. "
        "Two, the model: a script in Blender, running with no window, built a simple robot from that idea, plus the crisis landmark buildings, which were sketched the same way. This picture is a fresh Blender render of that robot, a stand-in that proved the pipeline. "
        "Three, the game: for the street view we wanted real people, so the robots were replaced by forty realistic bodies (Microsoft Rocketbox, free to use) with animations from Quaternius, a free animation pack. A nurse looks like a nurse and a builder wears a hard hat, and a resident always gets the same body, even after you save and reload. This last picture is the real player character in the game. "
        "Be plain about it: the image model gave us the sketches and the direction, Blender turned them into the first models, and the final people come from free character packs. "
        "Then the posters, in one breath. The same image model made 28 posters that the game shows on billboards, bus shelters and shop fronts; the game draws the words on top, so the text is crisp. A mayor's slogan comes from their latest public post and the Gazette poster follows the latest headline. With a GMI key on the desktop build, a mayor's campaign poster is printed live by the image model, at most once every three game days, when the district's mood shifts (about 20 seconds; the pre-made one stays up meanwhile). No key or offline: only the pre-made set. Live posters are listed as desktop only and untested in the browser build. If you have a real in-game screenshot of a billboard, add it here.",
        "The same image model prints the game's posters: 28 pre-made, plus live campaign posters when you play with a key.")

# ---------------------------------------------------------------- droidkit
def drow(title, text, stat):
    return f"""<div style="flex:1;display:flex;flex-direction:column;justify-content:space-between;gap:12px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:28px 32px">
<h3 style="{SG};font-size:44px;font-weight:700;line-height:1.1;color:{TXT}">{title}</h3>
<p style="font-size:30px;line-height:1.3;color:{MUTED}">{text}</p>
<p style="{MONO};font-size:24px;font-weight:500;color:{AMBER}">{stat}</p>
</div>"""


def tile(big, small):
    return f"""<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:18px;background:#1B2547;border:1px solid {AMBER};border-radius:16px;padding:18px 24px">
<p style="{SG};font-size:56px;font-weight:700;line-height:1;color:{AMBER}">{big}</p>
<p style="font-size:24px;line-height:1.2;color:{TXT}">{small}</p>
</div>"""


body = head("Factory Droid", "What Droid made possible") + f"""
<div style="display:flex;flex-direction:row;gap:24px">
{tile("140+", "pull requests merged")}
{tile("56", "merged in one day")}
{tile("7", "agents working at once")}
{tile("265 h", "of agent work")}
</div>
<div style="display:flex;flex-direction:column;gap:24px;flex:1">
<div style="display:flex;flex-direction:row;gap:24px;flex:1">
{drow("Any model", "Pick the model per task: Claude Opus 5.5 built the game, and Droid Core's kimi-k3 led the mission.", "Limits hit? Claude Code stepped in.")}
{drow("Missions", "A lead agent splits a big goal between specialists and checks their work.", "7 specialists · 36 sessions · 5 days")}
</div>
<div style="display:flex;flex-direction:row;gap:24px;flex:1">
{drow("Skills", "Short how-to notes agents read: add a feature, run the tests.", "3 skills · used about 200 times")}
{drow("MCP", "A plug that lets an agent drive Blender and the game engine, and look at the result.", "Blender + Godot")}
</div>
</div>"""
section("droidkit", body,
        "About 1 minute 45. This is the Factory Droid slide, so lead with the numbers and then the four features. "
        "The numbers: more than a hundred and forty pull requests merged. Fifty-six of them in a single day, the busiest day of the mission. Seven agents working at the same time. About two hundred and sixty-five hours of agent work in about two weeks. Those hours are the agents' active time, so they overlap; do not describe them as one person's working week. "
        "Any model: Droid lets you pick the model per task. The first game and the 46 changes after it ran on Claude Opus 5.5 inside Droid. For the long mission we moved to a Droid Core model, kimi-k3, which goes further on the same allowance. When the Opus allowance ran out between those steps, Claude Code carried on, and the notes the agents had written let it pick up where they stopped. "
        "Missions: a Droid mission is for goals too big for one conversation. A lead agent splits the work between specialists. Ours had seven specialists (wildlife, vehicles, hit impact, collisions, skyline, determinism and the web deploy) and ran for five days. "
        "Skills: short how-to notes that agents read when they need them. We wrote three: how to add assets, how to add a first-person feature, and how to run the tests. They were used about two hundred times. "
        "MCP: a way to plug outside tools into the agent. We connected Blender and the Godot engine, so an agent could build a model or run the game and look at a screenshot. "
        "Droid also offers more than we used here; do not claim anything beyond these four. Check the Droid Core wording against Factory's own page before you present.",
        "Source: Droid session logs and git history, 17 to 30 October 2026. Hours are agent active time, so they overlap.")

# ---------------------------------------------------------------- gmikit
def grow(title, text, last=False):
    bb = f";border-bottom:1px solid {LINE}" if last else ""
    return f"""<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:28px;border-top:1px solid {LINE}{bb}">
<h3 style="width:190px;flex:none;{SG};font-size:36px;font-weight:700;line-height:1.1;color:{AMBER}">{title}</h3>
<p style="flex:1;font-size:28px;line-height:1.3;color:{TXT}">{text}</p>
</div>"""


body = head("GMI Cloud", "What GMI Cloud brought to GridFall") + f"""
<div style="display:flex;flex-direction:row;gap:56px;flex:1">
<div style="width:880px;display:flex;flex-direction:column">
{grow("One door", "14 chat models from 9 labs behind one key. Swapping a mayor's model is a one-line change.")}
{grow("The artist", "The image model sketched the look we built from. In the game it prints posters for billboards, bus shelters and shops.")}
{grow("The home", "AgentBox hosts the web build. Players bring their own key.", last=True)}
</div>
<div style="width:728px;display:flex;flex-direction:column;gap:14px">
{img("posters", 728, 460, "Six posters made by the image model: aerial and street views of a modern city at golden hour", radius=12)}
{p("The pre-made poster set. With a key, campaign posters print live.", 24, MUTED)}
</div>
</div>"""
section("gmikit", body,
        "About 1 minute. What GMI Cloud brought to GridFall, in three jobs. "
        "One door: fourteen different chat models from nine labs, all through one connection and one key. Each mayor has its own model, and so do the five city helpers and the residents. Changing which model plays a mayor is a one-line change, which is what makes the side-by-side comparison practical. "
        "The artist: GMI's image model, hy-image-v3.5-preview, did two jobs. Before the game existed it drew the concept sheets that the Blender models were built from. Second, the posters. The game ships with 28 pre-made posters, drawn once with the image model. It shows them on each mayor's campaign billboards in their own district, the Gazette front page at bus shelters, shop adverts named after the real businesses, 'coming soon' hoardings at construction sites and warning notices near incidents. The game draws the words on top (slogans, headlines, shop names), so the text is always crisp. What they show is dynamic: a mayor's slogan comes from their latest public post and the Gazette poster follows the latest headline. The picture can be live too: with a GMI key on the desktop build, a mayor's campaign poster is printed by the image model, at most once every three game days per mayor, when the district's mood shifts. It takes about 20 seconds; the pre-made poster stays up meanwhile and is swapped when the new one arrives. With no key, or offline, only the pre-made set is used, and the same city always shows the same posters. In the browser build expect the pre-made set: live printing is listed as desktop only and has not been tested in a browser. The picture on the right is the pre-made set; swap in a real in-game screenshot when you have one. "
        "The home: GMI AgentBox runs the web build as a small container. Players use their own GMI key in their browser, so the server never holds a key. "
        "Also on the GMI platform and worth a look: video and audio models, dedicated endpoints and GPU compute. We did not use those here. Check that list against GMI's own page before you present.",
        "More to explore on GMI: video and audio models, dedicated endpoints, GPU compute.")

# ---------------------------------------------------------------- web
def wrow(n, text, last=False, hl=False):
    bb = f";border-bottom:1px solid {LINE}" if last else ""
    if hl:
        return f"""<div style="display:flex;flex-direction:row;align-items:center;gap:28px;background:{AMBER};border-radius:16px;padding:28px 32px">
<p style="width:64px;flex:none;{SG};font-size:64px;font-weight:700;line-height:1;color:{DARK}">{n}</p>
<p style="flex:1;font-size:32px;font-weight:600;line-height:1.25;color:{DARK}">{text}</p>
</div>"""
    return f"""<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:28px;border-top:1px solid {LINE}{bb}">
<p style="width:64px;flex:none;{SG};font-size:64px;font-weight:700;line-height:1;color:{AMBER}">{n}</p>
<p style="flex:1;font-size:30px;line-height:1.3;color:{TXT}">{text}</p>
</div>"""


body = head("In the browser", "Open it in a browser tab") + f"""
<div style="display:flex;flex-direction:row;gap:56px;flex:1">
<div style="width:728px;display:flex;flex-direction:column;gap:20px">
<div style="flex:1;display:flex;flex-direction:column">
{wrow(1, "No install: a full 3D city in a tab.")}
{wrow(2, "Hosted on GMI AgentBox.")}
{wrow(3, "About 95 MB on the first load.", last=True)}
</div>
{wrow(4, "Your key stays in your browser.", hl=True)}
</div>
<div style="width:880px;display:flex;flex-direction:column;justify-content:center;gap:14px">
{img("web", 880, 480, "The first-person street in the web build: the player stands in front of City Hall in light rain")}
{p("The street in the browser, at Low quality.", 24, MUTED)}
</div>
</div>"""
section("web", body,
        "About 30 seconds. The game also runs in a normal browser tab with nothing to install. We exported it from the Godot engine, shrank it (the first load is about 95 megabytes), and put it in a small container on GMI AgentBox. "
        "The key idea: the web server never holds a key. Each player pastes their own GMI key into their browser, and their browser talks to GMI directly. With no key the game still runs on recorded answers. "
        "Be honest about the picture: it is a screenshot from a software-rendered test browser at the Low quality setting, so it looks flatter than it does on a real graphics card. The new build has not been measured for frame rate in a real browser yet, so do not quote a frame rate.",
        "Screenshot: web build at Low quality, software-rendered, so it looks flatter than on a real graphics card.")

# ---------------------------------------------------------------- demo
def dcard(word, text, hint):
    return f"""<div style="flex:1;display:flex;flex-direction:column;justify-content:space-between;gap:20px;background:{CARD};border:1px solid {LINE};border-radius:16px;padding:36px">
<h3 style="{SG};font-size:64px;font-weight:700;line-height:1.1;color:{AMBER}">{word}</h3>
<p style="font-size:32px;line-height:1.3;color:{TXT}">{text}</p>
<p style="{MONO};font-size:24px;font-weight:500;color:{MUTED}">{hint}</p>
</div>"""


body = head("Live demo", "Watch, walk, break it") + f"""
<div style="display:flex;flex-direction:row;gap:32px;flex:1">
{dcard("Watch", "From above, speed up the days and read what a mayor is thinking.", "Tab · ] speeds up time")}
{dcard("Walk", "On the street, talk to a resident and ask about the mayors.", "E to talk")}
{dcard("Break it", "Burst a pipe from the Disasters tab and see who reacts.", "Disasters tab")}
</div>"""
section("demo", body,
        "About 3 minutes live. Before you start: decide live or replay. Live needs your GMI key pasted in Settings before you share the screen, and never typed on screen. Replay (offline) uses the recorded answers and always works. "
        "Watch: press Tab to be above the city, speed up the days with the right-bracket key, open a mayor card and read its private thought and public post. "
        "Walk: Tab back to the street, walk to a resident, press E and ask about the mayors. Every spoken line is one model call. "
        "Break it: open the Disasters tab, arm a sewage main burst and click the map. Then walk toward it and watch the residents and the news react. "
        "If anything misbehaves, say so and move on; the point of the game is that the world is not scripted.",
        "No key? The demo still runs on recorded answers.")

# ---------------------------------------------------------------- lessons
def lrow(n, head_t, text, last=False):
    bb = f";border-bottom:1px solid {LINE}" if last else ""
    return f"""<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:32px;border-top:1px solid {LINE}{bb}">
<p style="width:64px;flex:none;{SG};font-size:64px;font-weight:700;line-height:1;color:{AMBER}">{n}</p>
<div style="flex:1;display:flex;flex-direction:column;gap:6px">
<p style="{SG};font-size:40px;font-weight:700;line-height:1.1;color:{TXT}">{head_t}</p>
<p style="font-size:28px;line-height:1.3;color:{MUTED}">{text}</p>
</div>
</div>"""


body = head("Lessons", "Four things I would repeat") + f"""
<div style="display:flex;flex-direction:column;flex:1">
{lrow(1, "Write the rules and the tests first.", "Agents move fast. A test gate keeps them honest.")}
{lrow(2, "Give each agent its own area.", "Seven specialists shared one project without stepping on each other.")}
{lrow(3, "Write things down.", "Notes and plans let us move between Droid and Claude Code when limits hit.")}
{lrow(4, "Keep a person on the deploy.", "Nothing ships until someone decides.", last=True)}
</div>"""
section("lessons", body,
        "About 45 seconds. Four lessons, one sentence each. "
        "One: write the rules and the tests first. The project had a rules file for agents and one command that runs every test, and every change had to pass it. "
        "Two: give each agent its own area. In the mission each specialist owned its own files, so seven of them could work in one project at once. "
        "Three: write things down. When an agent session ends, only the documents remain, so plans, measurements and decisions went into notes the next agent could read. "
        "Four: keep a person on the deploy. Agents prepared everything, but a human decided what went live. "
        "One practical extra if there is time: usage limits ran out several times during the long mission, so save your state early.")

# ---------------------------------------------------------------- credits
def ccard(title, text, hot=False):
    bg = "#1B2547" if hot else CARD
    bd = AMBER if hot else LINE
    return f"""<div style="flex:1;display:flex;flex-direction:column;gap:14px;background:{bg};border:1px solid {bd};border-radius:16px;padding:32px 36px">
<h3 style="{SG};font-size:44px;font-weight:700;line-height:1.1;color:{AMBER if hot else TXT}">{title}</h3>
<p style="font-size:28px;line-height:1.3;color:{MUTED if not hot else TXT}">{text}</p>
</div>"""


body = head("Thank you", "What went into GridFall") + f"""
<div style="display:flex;flex-direction:column;gap:24px;flex:1">
<div style="display:flex;flex-direction:row;gap:24px;flex:1">
{ccard("GMI Cloud", "14 chat models, the hy-image-v3.5-preview image model and AgentBox web hosting.", True)}
{ccard("Factory Droid", "Droid and Droid Core, with missions, skills and MCP.", True)}
{ccard("Claude", "Opus 5.5 in Droid and Claude Code, then Sonnet 5.5 in Claude Code.")}
</div>
<div style="display:flex;flex-direction:row;gap:24px;flex:1">
{ccard("Godot and Blender", "Godot 4.7 runs the game. Blender 5.2 shaped the first models. Docker packs the web build.")}
{ccard("People and motion", "Microsoft Rocketbox characters and Quaternius animations, free and openly licensed.")}
{ccard("World and sound", "Kenney and Poly Haven kits, textures and skies. Music made locally with ACE-Step 1.5.")}
</div>
</div>"""
section("credits", body,
        "About 45 seconds. Thank the people and tools, brands first. The top row is what this talk is about: GMI Cloud gave the game its brains, its artist and its home, and Factory Droid gave the team its hands. "
        "Claude models did a lot of the writing inside Droid and Claude Code. "
        "The bottom row is the open-source and free-asset world that GridFall stands on: the Godot engine, Blender, Docker, Microsoft's Rocketbox characters, Quaternius animations and animals, Kenney city kits, Poly Haven textures and skies. The music was made on the owner's own laptop with ACE-Step 1.5, not on GMI. "
        "Then go straight into the live demo, or move to the closing slide if you demo first.")

# ---------------------------------------------------------------- cover and close (rebuilt with the partner logos)
def cover():
    pill = f"background:{AMBER};color:{DARK};font-size:24px;font-weight:600;padding:12px 28px;border-radius:999px"
    body = f"""<img src="/_blob/19deb90578a509550a5a61ebe9653d95" alt="GridFall at dusk seen from above: a lit street, apartment blocks and a river" style="position:absolute;left:0;top:0;width:1920px;height:1080px;object-fit:cover">
<div style="position:absolute;left:0;top:0;width:1920px;height:1080px;background:linear-gradient(to right, rgba(11,16,32,0.95) 0%, rgba(11,16,32,0.90) 36%, rgba(11,16,32,0.62) 47%, rgba(11,16,32,0.20) 57%, rgba(11,16,32,0) 65%)"></div>
<div style="position:relative">{lockup(60, 44, 40)}</div>
<div style="flex:1"></div>
<div style="position:relative;display:flex;flex-direction:column;gap:32px">
<p style="{MONO};font-size:26px;font-weight:500;letter-spacing:3px;text-transform:uppercase;color:{AMBER}">Building multi-model agents with Droid</p>
<h1 style="{SG};font-size:160px;font-weight:700;line-height:1;color:{TXT}">GridFall</h1>
<p style="width:880px;{SG};font-size:48px;font-weight:500;line-height:1.2;color:{TXT}">A city run by five AI mayors,<br>on 14 models from GMI Cloud</p>
<p style="font-size:28px;line-height:1.3;color:{MUTED}"><b style="color:{TXT}">Kunal Siyag</b> · GMI Cloud Ambassador · Factory Guild member</p>
<p style="{MONO};font-size:22px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{DIM}">Thursday 12 November · GMI Cloud x Factory</p>
</div>"""
    s = (f'<section id="cover" data-transition="fade" style="background:{BG};color:{TXT};'
         f"font-family:'IBM Plex Sans', Arial, sans-serif;padding:128px;display:flex;flex-direction:column\">\n{body}\n"
         f'<aside>{html.escape(NOTES_COVER)}</aside>\n</section>\n')
    open(os.path.join(OUT, "cover.html"), "w").write(s)


NOTES_COVER = ("About 30 seconds. Welcome, and the one-line promise. This is the Factory x GMI Cloud session on building multi-model agents with Droid, and I am Kunal, a GMI Cloud ambassador and Factory Guild member. "
               "In the next 15 minutes you will see a city that five different language models run, which models and why, how I built it with Droid, and then a live demo. "
               "[Your own opening line here: why a city builder, why GMI Cloud, why Droid.] "
               "Logos: the official GMI Cloud and Factory wordmarks, taken from each company's own website. Background: the Planner view of the city at dusk, a screenshot from the game.")
cover()


def close():
    body = f"""<img src="/_blob/7473d0d1fc00d727a4c22075f213fe64" alt="GRID FALL concept art: a city block with a nominal grid on the left and a stage 3 blackout crisis on the right" style="position:absolute;left:960px;top:128px;width:960px;height:688px;object-fit:cover;border-radius:12px 0 0 12px">
<div style="display:flex;flex-direction:column;justify-content:space-between;width:800px;height:688px">
<p style="{MONO};font-size:24px;font-weight:500;letter-spacing:3px;text-transform:uppercase;color:{AMBER}">Thank you</p>
<div style="display:flex;flex-direction:column;gap:40px">
<h2 style="{SG};font-size:144px;font-weight:700;line-height:1;white-space:nowrap;color:{TXT}">Questions?</h2>
{lockup(60, 44, 40)}
<p style="font-size:26px;line-height:1.35;color:{MUTED}">Also built with Godot, Blender, Claude, Microsoft Rocketbox, Quaternius, Kenney, Poly Haven and ACE-Step.</p>
</div>
</div>
<div style="display:flex;flex-direction:row;justify-content:space-between;align-items:center;border-top:1px solid {LINE};padding:36px 0 0 0;flex:1">
<p style="{MONO};font-size:44px;font-weight:500;color:{CYAN}">github.com/KunalSiyag/gridfall</p>
<p style="font-size:28px;line-height:1.3;text-align:right;color:{MUTED}"><b style="color:{TXT}">Kunal Siyag</b> · GMI Cloud Ambassador<br>Factory Guild member</p>
</div>"""
    s = (f'<section id="close" data-transition="fade" style="background:{BG};color:{TXT};'
         f"font-family:'IBM Plex Sans', Arial, sans-serif;padding:128px;display:flex;flex-direction:column;gap:48px\">\n{body}\n"
         f'<aside>{html.escape(NOTES_CLOSE)}</aside>\n</section>\n')
    open(os.path.join(OUT, "close.html"), "w").write(s)


NOTES_CLOSE = ("About 30 seconds, then questions. Thank GMI Cloud and Factory, brands first: GMI Cloud gave the game its brains, its artist and its home, and Factory Droid gave the team its hands. Claude models did much of the writing inside Droid and Claude Code. "
               "The small line is the free and open-source world GridFall stands on: Godot, Blender, Microsoft's Rocketbox characters, Quaternius animations, Kenney city kits, Poly Haven textures and skies; the music was made on my own laptop with ACE-Step, not on GMI. "
               "Close on the concept art: the calm grid on the left and the blackout crisis on the right are the story of the game in one picture. "
               "Likely questions: which models run the mayors and why (the cast slide); what happens with no key or a model outage (the architecture slide: recorded answers, then simple rules); how it was built (the story and Droid slides); what it cost (not measured here, the mission's credit counters have no known unit, so do not quote dollars). "
               "[Add the real links and any QR code for the live build here.] Then hand over to Aditya.")
close()

# ---------------------------------------------------------------- index
order = ["cover", "whatis", "cast", "arch", "story", "droidkit", "people", "demo", "lessons", "close"]
# Spare slides still built into project/slides but not in the order: mayors, lineup, gmikit, web, credits.
deck = {
    "v": 4,
    "createdOnFiles": {"v": 1, "at": "2026-11-02T19:45:00Z"},
    "lists": "css",
    "title": "GridFall: building multi-model agents with Droid (GMI Cloud x Factory)",
    "order": order,
    "sections": {
        "s1": {"description": "What GridFall is: a city run by five AI mayors.", "start": "cover"},
        "s2": {"description": "GMI Cloud: the 14 models behind the city, and how it fits together.", "start": "cast"},
        "s3": {"description": "How it was built with Factory Droid, Blender and GMI's image model.", "start": "story"},
        "s4": {"description": "Live demo, lessons and questions.", "start": "demo"},
    },
    "faces": {
        "space-grotesk": {"family": "Space Grotesk", "href": "https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&display=swap"},
        "ibm-plex-sans": {"family": "IBM Plex Sans", "href": "https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;600&display=swap"},
        "jetbrains-mono": {"family": "JetBrains Mono", "href": "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@500&display=swap"},
    },
    "designSystems": [],
}
with open(os.path.join(ROOT, "project", "deck.json"), "w") as f:
    json.dump(deck, f, indent=2, ensure_ascii=False)
print("ok", len(order), "slides")
