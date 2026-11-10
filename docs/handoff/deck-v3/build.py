"""GridFall webinar deck v3: GMI Cloud template look (black, lime, Figtree, Geist Mono, skull mascot, pixel dither),
partner logos on every slide and an ambassador-programme footer on every slide.
Run: python3 build.py            -> project/deck.json + project/slides/*.html (publish these to the Slides artifact)
     python3 build.py --preview  -> also prev/*.html with local images (screenshot with headless Chrome)
Speaker notes live in notes/<id>.txt. Image ids are the artifact's /_blob/ asset ids (see ID below)."""
import html, json, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "project", "slides")
os.makedirs(OUT, exist_ok=True)

BG, LIME, SOFT = "#000000", "#DDEA4D", "#F4F9BD"
CARD, PANEL, TXT, MUTED, DIM = "#1A1A1A", "#262626", "#FFFFFF", "#A8A8A8", "#6F6F6F"
EDGE = "rgba(221,234,77,0.55)"
FG = "font-family:'Figtree', Arial, sans-serif"
MONO = "font-family:'Geist Mono', 'Courier New', monospace"

ID = {
    # GridFall art and screenshots (uploaded earlier)
    "dusk": "19deb90578a509550a5a61ebe9653d95", "concept": "7473d0d1fc00d727a4c22075f213fe64",
    "planner": "305379c8d8518df981a15c9acbcccaf4", "street": "1ba381b2d4ce417f34ff75f442726765",
    "sheet": "e6f1fce855faf2697c1e7fd1fd926036", "robot": "7a2f4de7c66a0c670d6c0c325dd33772",
    "hero": "e8ae7b52749c953a0ae7fb33c857417c", "posters": "4cd7c100ae9a8a7da5d2e9a3d8d17de7",
    "crisis": "6a503f12e007731d219e221d7f93f299",
    "argon": "eb01cddc82bde0d8947db8f5179c783b", "deepseek": "6c425b3cecc46e6f42daac0bf5d85c22",
    "kimi": "74446904b223e46cd662ed62e46a0d50", "qwen": "0746f1fce6353f0410b043f2e96ccf46",
    "grok": "a3eb22804d151415300c2a3ddfc8aa5a",
    # GMI mascot cut-outs, textures, QR codes (uploaded 10 Nov)
    "skull_headphones": "33873fe56a3b22b5eb7565dbcf7a50e4", "skull_question": "2d349e451d6b136b136445932589f95c",
    "skull_sunglasses": "aedbd16e3ab1f343e355dc9d51073dab", "skull_star_l": "855308151a2c48d54c20c90c49b531f7",
    "skull_star_r": "98dd04cc24c4bbcab17529139e5071de", "trophy": "dfae3c989983dfa17a5bf57d38219f48",
    "skull_heart": "766b0769255534b2b4cd10ef3862afbd", "trophy_skull": "f7d12e3c497b39b9ff2e60235b6807f3",
    "ufo": "83a00033c7894bd84c030df7a484bbe5", "glow": "39dfc1fdaddb59fdc230bd32d1c44f0c",
    "dither": "9198b32fbb6e913205a0d10a3f4c81d4", "dither_dark": "70f84ad2783468239217e9a7f63e6751",
    "dither_bottom": "99af1e5265f7192fee54282aa9ce5954",
    "qr_gmi": "5492630941332f78d0ba0f70f25ee252", "qr_factory": "6bc4688f53881d02e2cc69fa4e730582",
    "qr_github": "0cffedb5ba6f15ecb8b20c396d1bda6f",
}


def A(k):
    return "/_blob/" + ID[k]


def note(sid):
    return open(os.path.join(ROOT, "notes", sid + ".txt")).read().strip()


def logo(name, h, color=TXT):
    t = open(os.path.join(ROOT, "img", name + "-logo.svg")).read()
    vb = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', t)
    w = round(h * float(vb.group(1)) / float(vb.group(2)))
    t = t.replace('<g fill="#fff"', f'<g fill="{color}"', 1).replace("#FFFFFF", color)
    label = {"gmi": "GMI Cloud", "factory": "Factory"}[name]
    return t.replace("<svg ", f'<svg role="img" aria-label="{label}" width="{w}" height="{h}" ', 1)


def lockup(hg=36, hf=27, color=TXT, gap=22, rule=LIME):
    return (f'<div style="display:flex;flex-direction:row;align-items:center;gap:{gap}px">{logo("gmi", hg, color)}'
            f'<div style="width:2px;height:{hg}px;background:{rule}"></div>{logo("factory", hf, color)}</div>')


def img(k, w, h, alt, fit="cover", radius=0, extra=""):
    return (f'<img src="{A(k)}" alt="{html.escape(alt)}" style="width:{w}px;height:{h}px;object-fit:{fit};'
            f'border-radius:{radius}px;display:block{(";" + extra) if extra else ""}">')


def abs_img(k, alt, style):
    return f'<img src="{A(k)}" alt="{html.escape(alt)}" style="position:absolute;{style}">'


def lead(a, b, size=72, color=TXT, lime=LIME, lh=1.05):
    return (f'<h2 style="{FG};font-size:{size}px;line-height:{lh};font-weight:700;color:{color}">'
            f'<span style="color:{lime};font-weight:300">{a}</span> {b}</h2>')


def eyebrow(t, color=LIME):
    return (f'<p style="{MONO};font-size:20px;font-weight:500;letter-spacing:2px;text-transform:uppercase;'
            f'color:{color}">{t}</p>')


def card(inner, pad="28px 32px", bg=CARD, border=EDGE, radius=16, extra=""):
    return (f'<div style="box-sizing:border-box;background:{bg};border:1px solid {border};border-radius:{radius}px;padding:{pad};{extra}">'
            f'{inner}</div>')


FOOT_L = "Become a GMI Clouder"
FOOT_LU = "gmicloud.ai/company/ambassador-program"
FOOT_R = "Join the Factory Guild"
FOOT_RU = "factory.com/ambassador"


def footer(dark=True):
    base = DIM if dark else "#3A3F10"
    ink = TXT if dark else "#000"
    accent = LIME if dark else "#000"
    line = PANEL if dark else "rgba(0,0,0,0.25)"
    return (f'<div style="position:absolute;left:96px;right:96px;bottom:0;height:64px;display:flex;flex-direction:row;'
            f'align-items:center;justify-content:space-between;border-top:1px solid {line};background:{"#000" if dark else LIME};{MONO};font-size:17px;font-weight:500">'
            f'<span style="color:{base}">KUNAL SIYAG · GRIDFALL</span>'
            f'<span style="display:flex;flex-direction:row;gap:44px">'
            f'<span style="color:{ink}">{FOOT_L} <span style="color:{accent}">▸ {FOOT_LU}</span></span>'
            f'<span style="color:{ink}">{FOOT_R} <span style="color:{accent}">▸ {FOOT_RU}</span></span></span></div>')


def slide(sid, inner, theme="dark", tag="", pad="128px 96px 120px", header=True, gap=0, notes=None, tagc=None):
    dark = theme == "dark"
    bg, fg = (BG, TXT) if dark else (LIME, "#000000")
    hdr = ""
    if header:
        hdr = (f'<div style="position:absolute;left:96px;top:44px">{lockup(36, 27, TXT if dark else "#000", rule=LIME if dark else "#000")}</div>'
               f'<p style="position:absolute;right:96px;top:54px;{MONO};font-size:18px;font-weight:500;letter-spacing:2px;'
               f'text-transform:uppercase;color:{tagc or (DIM if dark else "#3A3F10")}">{tag}</p>')
    s = (f'<section id="{sid}" data-transition="fade" style="background:{bg};color:{fg};{FG};padding:{pad};'
         f'display:flex;flex-direction:column;gap:{gap}px">\n{inner}\n{hdr}\n{footer(dark)}\n'
         f'<aside>{html.escape(notes if notes is not None else note(sid))}</aside>\n</section>\n')
    assert len(notes if notes is not None else note(sid)) <= 4000, sid
    with open(os.path.join(OUT, sid + ".html"), "w") as f:
        f.write(s)


def bullet(t, color=LIME, size=24, col=TXT):
    return (f'<p style="font-size:{size}px;line-height:1.3;color:{col};padding:4px 0 4px 22px;position:relative">'
            f'<span style="position:absolute;left:0;top:14px;width:8px;height:8px;border-radius:2px;background:{color}"></span>{t}</p>')


# ------------------------------------------------------------------ 1 cover
inner = f"""{abs_img("dusk", "GridFall at dusk seen from above: a lit street, apartment blocks and a river", "left:0;top:0;width:1920px;height:1080px;object-fit:cover")}
<div style="position:absolute;left:0;top:0;width:1920px;height:1080px;background:linear-gradient(90deg, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.88) 36%, rgba(0,0,0,0.5) 60%, rgba(0,0,0,0.12) 100%)"></div>
{abs_img("skull_headphones", "GMI skull mascot wearing headphones", "right:0;top:70px;height:930px")}
<div style="position:relative;display:flex;flex-direction:column;flex:1;justify-content:center;gap:34px">
{eyebrow("Building multi-model agents with Droid")}
<h1 style="{FG};font-size:128px;line-height:1.04;font-weight:700;color:{TXT}"><span style="color:{LIME};font-weight:300">A city run by</span><br>five AI mayors<br><span style="color:{LIME};font-weight:300">on</span> 14 models.</h1>
<p style="font-size:30px;line-height:1.3;color:{MUTED}"><b style="color:{TXT}">Kunal Siyag</b> · GMI Cloud Ambassador · Factory Guild member</p>
</div>"""
slide("cover", inner, tag="Thu 12 Nov · GMI Cloud x Factory", pad="128px 96px 120px", tagc="#D8D8D8")

# ------------------------------------------------------------------ 2 whatis
def row(n, t, d):
    return (f'<div style="display:flex;flex-direction:row;align-items:center;gap:28px;border-top:1px solid {PANEL};padding:22px 0">'
            f'<p style="{MONO};font-size:22px;font-weight:500;color:{LIME};width:44px">{n}</p>'
            f'<div style="flex:1"><p style="{FG};font-size:36px;font-weight:600;line-height:1.1;color:{TXT}">{t}</p>'
            f'<p style="font-size:26px;line-height:1.3;color:{MUTED};padding-top:6px">{d}</p></div></div>')


def frame(k, w, h, alt, pos=""):
    return (f'<div style="box-sizing:border-box;position:absolute;{pos}width:{w + 24}px;height:{h + 24}px;background:{LIME};border-radius:20px;'
            f'padding:12px;box-shadow:0 18px 40px rgba(0,0,0,0.5)">{img(k, w, h, alt, radius=10)}</div>')


inner = f"""{abs_img("dither", "", "right:0;top:0;width:720px;height:1080px")}
<div style="position:relative;width:880px;display:flex;flex-direction:column;gap:28px">
{eyebrow("The game")}
<h2 style="{FG};font-size:104px;line-height:1.02;font-weight:700;color:{TXT}"><span style="color:{LIME};font-weight:300">Two views.</span><br>One city.</h2>
<p style="font-size:32px;line-height:1.35;color:{MUTED}">Five AI mayors, each on a different model, run it. Watch from above, or walk the streets.</p>
<div style="display:flex;flex-direction:column;padding-top:8px">
{row("01", "Planner view", "The whole city, with a card for each mayor.")}
{row("02", "First person", "Walk it. Talk to residents. See who decided what.")}
</div></div>
{frame("planner", 740, 380, "The city from above: a map with five mayor cards along the bottom", "left:1084px;top:128px;")}
{frame("street", 740, 380, "On the street in first person: the player walks toward a fire while a panel shows which AI model decided what", "left:1084px;top:566px;")}"""
slide("whatis", inner, tag="")

# ------------------------------------------------------------------ 3 cast
mayors = [("argon", "Ada Okafor", "Gemini 4 Argon", "Google"), ("deepseek", "Viktor Han", "DeepSeek V4 Flash", "DeepSeek"),
          ("kimi", "Mei Kimura", "Kimi K3", "Moonshot AI"), ("qwen", "Rosa Quintero", "Qwen 3.8 Max", "Alibaba Qwen"),
          ("grok", "Duke Granger", "Grok 4.5", "xAI")]
mcards = ""
for k, name, model, lab in mayors:
    mcards += card(
        f'<div style="display:flex;flex-direction:column;align-items:center;gap:6px">'
        f'<div style="padding:4px;border:2px solid {LIME};border-radius:50%">{img(k, 132, 132, f"Portrait of {name}, the mayor run by {model}", radius=66)}</div>'
        f'<p style="{FG};font-size:30px;font-weight:700;line-height:1.1;color:{TXT};padding-top:8px">{name}</p>'
        f'<p style="{MONO};font-size:21px;font-weight:500;color:{LIME};text-align:center">{model}</p>'
        f'<p style="font-size:21px;color:{MUTED}">{lab}</p></div>', pad="24px 12px", extra="flex:1")
helpers = [("MiMo V2.6 Flash", "Xiaomi", "the Gazette newspaper"), ("GPT-6 Luna", "OpenAI", "the council speaker"),
           ("DeepSeek V4 Pro", "DeepSeek", "the disaster director"), ("Gemini 3.8 Flash", "Google", "the power-grid operator"),
           ("MiniMax M3", "MiniMax", "citizens and street inspector")]
hl = "".join(f'<p style="font-size:28px;line-height:1.3;color:{TXT};padding:6px 0"><b>{m}</b> <span style="color:{MUTED}">· {lab} · {role}</span></p>' for m, lab, role in helpers)
residents = ["DeepSeek V4.1 Flash", "Gemini 3.5 Flash Lite", "MiniMax M3", "DeepSeek V4 Flash", "Qwen 3.8 Flash", "GLM 5.3 Flash"]
rl = "".join(f'<p style="font-size:28px;line-height:1.3;color:{TXT};padding:6px 0"><b>{m}</b></p>' for m in residents)
inner = f"""{eyebrow("GMI Cloud")}
<div style="padding-top:8px">{lead("One key.", "14 models. 9 labs.", 76)}</div>
<p style="{MONO};font-size:18px;color:{MUTED};padding-top:14px">Google · DeepSeek · Moonshot AI · Alibaba Qwen · xAI · MiniMax · Xiaomi · OpenAI · Z.ai</p>
<div style="display:flex;flex-direction:row;gap:18px;padding-top:26px">{mcards}</div>
<div style="display:flex;flex-direction:row;gap:18px;padding-top:18px;flex:1">
{card(f'<p style="{MONO};font-size:19px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{LIME};padding-bottom:6px">Five city helpers</p>{hl}', pad="22px 30px", extra="flex:1")}
{card(f'<p style="{MONO};font-size:19px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{LIME};padding-bottom:6px">Residents · six fast models take turns</p><div style="display:grid;grid-template-columns:1fr 1fr;column-gap:20px">{rl}</div>', pad="22px 30px", extra="width:760px")}
</div>"""
slide("cast", inner, tag="GridFall · 02", pad="124px 96px 100px")

# ------------------------------------------------------------------ 4 arch
def acard(label, title, text):
    return card(f'<p style="{MONO};font-size:20px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{LIME}">{label}</p>'
                f'<h3 style="{FG};font-size:62px;font-weight:700;line-height:1.05;color:{TXT};padding:18px 0 16px">{title}</h3>'
                f'<p style="font-size:30px;line-height:1.35;color:{MUTED}">{text}</p>', pad="36px 36px", extra="width:500px;height:430px")


def aarrow(t):
    return (f'<div style="width:114px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;height:430px">'
            f'<p style="font-size:64px;font-weight:300;line-height:1;color:{LIME}">→</p><p style="{MONO};font-size:16px;color:{MUTED};text-align:center">{t}</p></div>')


inner = f"""{eyebrow("How it fits together")}
<div style="padding-top:8px">{lead("One city,", "many brains, two views.", 76)}</div>
<div style="display:flex;flex-direction:row;align-items:center;padding-top:56px">
{acard("GMI Cloud", "The brains", "Five mayors, five city helpers and the residents are all AI models.")}
{aarrow("decisions")}
{acard("The simulation", "The city", "One city that checks every decision and keeps the rules fair.")}
{aarrow("what happened")}
{acard("Two windows", "The views", "Watch from above, or walk the streets. Same city, same moment.")}
</div>
<div style="margin-top:40px;display:flex;flex-direction:row;align-items:center;justify-content:space-between;gap:32px;background:{LIME};border-radius:16px;padding:26px 36px">
<p style="font-size:30px;line-height:1.3;color:#000">No key, or a model is down? Recorded answers keep the city moving.</p>
<p style="{FG};font-size:44px;font-weight:700;line-height:1.1;color:#000;white-space:nowrap">The city never stops.</p>
</div>
{abs_img("ufo", "GMI skull mascot in a flying saucer", "left:1660px;top:236px;width:190px")}"""
slide("arch", inner, tag="GridFall · 03")

# ------------------------------------------------------------------ 5 story (sequence diagram)
lanes = {"me": 360, "dr": 650, "cc": 940, "gmi": 1230, "tool": 1520}
names = {"me": ("Me", "Kunal"), "dr": ("Droid", "Opus 5.5, kimi-k3"), "cc": ("Claude Code", "Opus, then Sonnet"),
         "gmi": ("GMI Cloud", "chat + image models"), "tool": ("Blender + Godot", "model and engine")}
sv = [f'<svg aria-label="Sequence diagram of how GridFall was built: Droid on Claude Opus 5.5, Claude Code when usage limits hit, a Droid Core model for the mission, then the browser build" '
      f'width="1728" height="640" viewBox="0 0 1728 640" style="font-family:Figtree, Arial, sans-serif">']
for x in lanes.values():
    sv.append(f'<line x1="{x + 32}" y1="84" x2="{x + 32}" y2="636" stroke="{PANEL}" stroke-width="3" stroke-dasharray="8 8"/>')
rows = [136 + 56 * i for i in range(9)]
bands = {3: "Droid limit hit: Claude Code (Opus 5.5) steps in", 5: "Droid Core model kimi-k3 leads seven specialists",
         6: "Limit hit again: Claude Code (Sonnet 5.5)"}
for idx, t in bands.items():
    y = rows[idx]
    sv.append(f'<rect x="294" y="{y - 40}" width="1434" height="54" rx="12" fill="{CARD}" stroke="{LIME}" stroke-opacity="0.55"/>')
    sv.append(f'<text x="1704" y="{y + 8}" text-anchor="end" font-size="24" font-weight="600" fill="{LIME}">{t}</text>')
msgs = [("17 Oct", "me", "dr", "A city of AI mayors", "req"), ("", "dr", "gmi", "Mayors and art sketches", "req"),
        ("", "dr", "tool", "Model it in Blender", "req"), ("18–19 Oct", "me", "cc", "Let me walk the streets", "req"),
        ("19–25 Oct", "dr", "me", "46 reviewed changes", "ret"), ("25–30 Oct", "me", "dr", "Mission: finish it", "req"),
        ("30 Oct–2 Nov", "me", "cc", "Polish and web build", "req"), ("", "cc", "gmi", "Host the web build", "req"),
        ("2 Nov", "gmi", "me", "Playable in a browser", "ret")]
for (date, a_, b_, label, kind), y in zip(msgs, rows):
    x1, x2 = lanes[a_] + 32, lanes[b_] + 32
    col = LIME if kind == "req" else TXT
    dash = ' stroke-dasharray="10 8"' if kind == "ret" else ""
    d = 1 if x2 > x1 else -1
    if date:
        sv.append(f'<text x="0" y="{y + 8}" font-size="23" font-weight="600" fill="{LIME}" style="font-family:\'Geist Mono\', monospace">{date}</text>')
    sv.append(f'<line x1="{x1}" y1="{y}" x2="{x2 - d * 14}" y2="{y}" stroke="{col}" stroke-width="4"{dash}/>')
    sv.append(f'<polygon points="{x2},{y} {x2 - d * 18},{y - 9} {x2 - d * 18},{y + 9}" fill="{col}"/>')
    sv.append(f'<text x="{(x1 + x2) // 2}" y="{y - 12}" text-anchor="middle" font-size="24" fill="{TXT}" stroke="{BG}" stroke-width="6" paint-order="stroke">{label}</text>')
for k, x in lanes.items():
    n, s_ = names[k]
    x += 32
    sv.append(f'<rect x="{x - 135}" y="0" width="270" height="84" rx="12" fill="{CARD}" stroke="{LIME}" stroke-opacity="0.55"/>')
    sv.append(f'<text x="{x}" y="35" text-anchor="middle" font-size="28" font-weight="700" fill="{TXT}">{n}</text>')
    sv.append(f'<text x="{x}" y="66" text-anchor="middle" font-size="22" fill="{MUTED}">{s_}</text>')
sv.append("</svg>")
inner = f"""{eyebrow("The story")}
<div style="padding-top:8px">{lead("How it was built,", "in order.", 76)}</div>
<div style="padding-top:34px">{"".join(sv)}</div>"""
slide("story", inner, tag="GridFall · 04", pad="124px 96px 100px")

# ------------------------------------------------------------------ 6 droid
def tile(big, small):
    return (f'<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:18px;background:{CARD};border:1px solid {EDGE};border-radius:16px;padding:18px 26px">'
            f'<p style="{FG};font-size:64px;font-weight:700;line-height:1;color:{LIME}">{big}</p>'
            f'<p style="font-size:24px;line-height:1.2;color:{TXT}">{small}</p></div>')


def dcard(n, title, text, stat):
    return card(f'<p style="{MONO};font-size:18px;font-weight:500;color:{LIME}">{n}</p>'
                f'<h3 style="{FG};font-size:46px;font-weight:700;line-height:1.1;color:{TXT};padding:8px 0 10px">{title}</h3>'
                f'<p style="font-size:28px;line-height:1.3;color:{MUTED}">{text}</p>'
                f'<p style="{MONO};font-size:19px;font-weight:500;color:{LIME};padding-top:14px">{stat}</p>', pad="26px 32px", extra="flex:1")


inner = f"""{eyebrow("Factory Droid")}
<div style="padding-top:8px">{lead("What Droid", "made possible.", 76)}</div>
<div style="display:flex;flex-direction:row;gap:18px;padding-top:30px">
{tile("140+", "pull requests merged")}{tile("56", "merged in one day")}{tile("7", "agents working at once")}{tile("265 h", "of agent work")}
</div>
<div style="display:flex;flex-direction:column;gap:18px;padding-top:18px;flex:1">
<div style="display:flex;flex-direction:row;gap:18px;flex:1">
{dcard("01", "Any model", "Pick the model per task: Claude Opus 5.5 built the game, and Droid Core's kimi-k3 led the mission.", "Limits hit? Claude Code stepped in.")}
{dcard("02", "Missions", "A lead agent splits a big goal between specialists and checks their work.", "7 specialists · 36 sessions · 5 days")}
</div>
<div style="display:flex;flex-direction:row;gap:18px;flex:1">
{dcard("03", "Skills", "Short how-to notes agents read: add a feature, run the tests.", "3 skills · used about 200 times")}
{dcard("04", "MCP", "A plug that lets an agent drive Blender and the game engine, and look at the result.", "Blender + Godot")}
</div></div>"""
slide("droidkit", inner, tag="GridFall · 05", pad="124px 96px 100px")

# ------------------------------------------------------------------ 7 people / image model
def pframe(k, w, h, alt, n, cap):
    return (f'<div style="width:{w}px;display:flex;flex-direction:column;gap:14px">'
            f'<div style="border:1px solid {EDGE};border-radius:16px;overflow:hidden;background:{CARD}">{img(k, w, h, alt)}</div>'
            f'<p style="{MONO};font-size:18px;font-weight:500;color:{LIME};letter-spacing:2px">{n}</p>'
            f'<p style="font-size:26px;line-height:1.25;color:{TXT}">{cap}</p></div>')


def parrow():
    return f'<p style="font-size:60px;font-weight:300;color:{LIME};height:380px;display:flex;align-items:center">→</p>'


inner = f"""{eyebrow("GMI's image model")}
<div style="padding-top:8px">{lead("From a sketch", "to a character.", 76)}</div>
<div style="display:flex;flex-direction:row;justify-content:space-between;align-items:flex-start;padding-top:30px">
{pframe("sheet", 700, 380, "Concept sheet drawn by the image model: five armoured mayor avatars in gold, blue, violet, green and red", "01 · THE SKETCH", "GMI's image model drew five mayor avatars.")}
{parrow()}
{pframe("robot", 380, 380, "A simple blocky robot with a halo, rendered in Blender", "02 · THE MODEL", "Blender turned the idea into a simple robot.")}
{parrow()}
{pframe("hero", 340, 380, "The player character in the shipped game: a realistic person in a red sweater walking down a city street", "03 · THE GAME", "Realistic people took over, one for each job.")}
</div>
<div style="margin-top:34px;display:flex;flex-direction:row;align-items:center;gap:28px;background:{CARD};border:1px solid {EDGE};border-radius:16px;padding:16px 28px 16px 16px">
{img("posters", 260, 108, "Posters made by the image model: aerial and street views of a modern city at golden hour", radius=10)}
<p style="font-size:28px;line-height:1.3;color:{TXT}">The same image model prints the game's <b style="color:{LIME}">posters</b>: 28 pre-made, plus live campaign posters when you play with a key.</p>
</div>"""
slide("people", inner, tag="GridFall · 06", pad="124px 96px 100px")

# ------------------------------------------------------------------ 8 demo (lime)
def dcardl(w, t, d, hint):
    return (f'<div style="box-sizing:border-box;width:{w}px;background:#000;border-radius:16px;padding:26px 30px;display:flex;flex-direction:column;gap:10px">'
            f'<p style="{FG};font-size:48px;font-weight:700;line-height:1;color:{LIME}">{t}</p>'
            f'<p style="font-size:26px;line-height:1.3;color:#fff">{d}</p>'
            f'<p style="{MONO};font-size:17px;font-weight:500;color:{MUTED}">{hint}</p></div>')


inner = f"""{abs_img("dither_bottom", "", "left:0;bottom:0;width:1920px;height:360px")}
{abs_img("skull_sunglasses", "GMI skull mascot in sunglasses", "left:-120px;top:150px;height:640px")}
{abs_img("skull_heart", "GMI skull mascot with a heart", "right:-150px;top:360px;height:540px")}
<div style="position:relative;display:flex;flex-direction:column;align-items:center;gap:30px;padding-top:30px">
<p style="background:#fff;color:#000;{FG};font-size:36px;font-weight:600;padding:12px 40px;border-radius:999px">Live demo</p>
<h2 style="{FG};font-size:150px;font-weight:700;line-height:1;color:#000;text-align:center">Watch. Walk.<br>Break it.</h2>
<div style="display:flex;flex-direction:row;gap:26px;padding-top:36px">
{dcardl(340, "Watch", "From above, speed up the days and read what a mayor is thinking.", "TAB · ] SPEEDS UP TIME")}
{dcardl(340, "Walk", "On the street, talk to a resident and ask about the mayors.", "E TO TALK")}
{dcardl(340, "Break it", "Burst a pipe from the Disasters tab and see who reacts.", "DISASTERS TAB")}
</div></div>"""
slide("demo", inner, theme="lime", tag="GridFall · 07", pad="128px 96px 120px")

# ------------------------------------------------------------------ 9 lessons
def lrow(n, t, d):
    return (f'<div style="flex:1;display:flex;flex-direction:row;align-items:center;gap:30px;border-top:1px solid {PANEL}">'
            f'<p style="{MONO};font-size:24px;font-weight:500;color:{LIME};width:56px">{n}</p>'
            f'<div style="flex:1"><p style="{FG};font-size:42px;font-weight:700;line-height:1.1;color:{TXT}">{t}</p>'
            f'<p style="font-size:26px;line-height:1.3;color:{MUTED};padding-top:8px">{d}</p></div></div>')


inner = f"""{abs_img("dither", "", "right:0;top:0;width:720px;height:1080px")}
<div style="position:relative;width:960px;display:flex;flex-direction:column;flex:1">
{eyebrow("How agents make good calls")}
<div style="padding-top:8px;padding-bottom:26px">{lead("Four things", "I'd repeat.", 76)}</div>
<div style="display:flex;flex-direction:column;flex:1">
{lrow("01", "Write the rules and the tests first.", "Agents move fast. A test gate keeps them honest.")}
{lrow("02", "Give each agent its own area.", "Seven specialists shared one project without stepping on each other.")}
{lrow("03", "Write things down.", "Notes and plans let us move between Droid and Claude Code when limits hit.")}
{lrow("04", "Keep a person on the deploy.", "Nothing ships until someone decides.")}
</div></div>
<div style="box-sizing:border-box;position:absolute;left:1088px;top:170px;width:736px;height:690px;background:{LIME};border-radius:22px;padding:12px;box-shadow:0 18px 40px rgba(0,0,0,0.5)">
{img("crisis", 712, 666, "GRID FALL game concept: five glowing power buildings on hexagonal bases", radius=12)}</div>"""
slide("lessons", inner, tag="")

# ------------------------------------------------------------------ 10 GMI Clouders
def stat(big, small, w):
    return (f'<div style="box-sizing:border-box;width:{w}px;background:{CARD};border:1px solid {EDGE};border-radius:14px;padding:16px 20px">'
            f'<p style="{FG};font-size:46px;font-weight:700;line-height:1;color:{LIME}">{big}</p>'
            f'<p style="font-size:20px;line-height:1.25;color:{MUTED};padding-top:6px">{small}</p></div>')


def track(title, big, per, text):
    return card(f'<p style="{FG};font-size:36px;font-weight:700;line-height:1.1;color:{TXT}">{title}</p>'
                f'<p style="padding:8px 0 6px"><span style="{FG};font-size:56px;font-weight:700;color:{LIME}">{big}</span> '
                f'<span style="{MONO};font-size:20px;color:{MUTED}">{per}</span></p>'
                f'<p style="font-size:22px;line-height:1.3;color:{MUTED}">{text}</p>', pad="22px 26px", extra="flex:1")


def reward(t, d):
    return card(f'<p style="{FG};font-size:28px;font-weight:700;line-height:1.1;color:{LIME}">{t}</p>'
                f'<p style="font-size:21px;line-height:1.3;color:{TXT};padding-top:8px">{d}</p>', pad="18px 22px")


def qrcard(qr, title, url, pos, sub=None, h=500):
    s = f'<p style="font-size:20px;line-height:1.3;color:#333;padding-top:4px">{sub}</p>' if sub else ""
    return (f'<div style="box-sizing:border-box;position:absolute;{pos}width:440px;height:{h}px;background:#fff;border-radius:20px;padding:26px;display:flex;flex-direction:column;align-items:center;gap:10px;box-shadow:0 18px 40px rgba(0,0,0,0.5)">'
            f'{img(qr, 300, 300, "QR code: " + url, fit="contain", extra="image-rendering:pixelated")}'
            f'<p style="{FG};font-size:42px;font-weight:700;color:#000;line-height:1.1">{title}</p>'
            f'<p style="{MONO};font-size:16px;font-weight:500;color:#000;text-align:center">{url}</p>{s}</div>')


inner = f"""{abs_img("dither", "", "right:0;top:0;width:720px;height:1080px")}
<div style="position:relative;width:1216px;display:flex;flex-direction:column">
{eyebrow("GMI Clouders · ambassador program")}
<div style="padding-top:8px">{lead("Become a", "GMI Clouder.", 76)}</div>
<div style="display:flex;flex-direction:row;gap:16px;padding-top:24px">
{stat("50+", "Clouders", 292)}{stat("17", "countries and regions", 292)}{stat("$300", "max monthly cash reward", 292)}{stat("2", "tracks to pick from", 292)}
</div>
<p style="{MONO};font-size:18px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{MUTED};padding:24px 0 10px">Pick your track</p>
<div style="display:flex;flex-direction:row;gap:16px">
{track("Content Creator", "2 projects", "/ month", "Build with GMI tools and show it working in public: a post with a demo, and a repo.")}
{track("Community Builder", "1 event", "/ quarter", "Bring builders in your city together around GMI. Event credits and resources included.")}
</div>
<p style="{MONO};font-size:18px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{MUTED};padding:24px 0 10px">What you get</p>
<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px">
{reward("Up to $300 / month", "Cash rewards for the tutorials, integrations and posts you make.")}
{reward("Monthly credits", "$100 on acceptance, then fresh GMI credits every month.")}
{reward("Featured", "Best builds go on the GMI demos page, credited to you.")}
{reward("Amplified", "Your best work shared on GMI's social accounts.")}
{reward("Office hours", "Regular sessions with the GMI devrel team.")}
{reward("Early access", "New products first, and credit grants for big ideas.")}
</div></div>
{qrcard("qr_gmi", "Apply now", "gmicloud.ai/company/ambassador-program", "left:1384px;top:268px;", "Pick a track, ship your first build in weeks 2 to 4.", 500)}
{abs_img("trophy", "GMI gold trophy mascot", "left:1650px;top:52px;width:190px")}
<p style="position:absolute;left:1384px;top:790px;width:440px;{MONO};font-size:15px;line-height:1.4;color:{DIM}">Cash rewards are not available in every country. Source: gmicloud.ai/company/ambassador-program, 10 Nov 2026.</p>"""
slide("clouder", inner, tag="", pad="124px 96px 120px", notes=(
    "About 1 minute, shown at 10:20 when the session moves to the ambassador programmes. "
    "GMI Clouders is GMI Cloud's ambassador program. There are two tracks. A Content Creator ships two projects a month: a public post with a working demo and a repo. A Community Builder hosts one event a quarter, with event credits and resources behind them. You pick one, you do not have to do both. "
    "The rewards: cash of up to 300 dollars a month, $100 of credits when you are accepted and fresh credits every month, a feature on the GMI demos page, amplification on GMI's social accounts, office hours with the devrel team, early access to new products and credit grants for big ideas. "
    "Numbers on the slide (50+ Clouders, 17 countries and regions, $300 maximum monthly cash, 2 tracks) are from gmicloud.ai/company/ambassador-program as read on 10 November 2026, so re-check the page just before you present. Cash rewards are not available in some countries, including Taiwan, Japan, South Korea and Southeast Asia. "
    "Mention that Aditya is a Clouder too and that anyone who stays to the end gets free GMI Cloud inference and Factory credits (per the event page). "
    "The QR and the footer on every slide point to the same page."))

# ------------------------------------------------------------------ 11 Factory Guild
def tier(n, name, sub, perks, hot=False):
    bg, bd = (LIME, LIME) if hot else (CARD, EDGE)
    c = "#000" if hot else TXT
    m = "#2B3000" if hot else MUTED
    ac = "#000" if hot else LIME
    pl = "".join(f'<p style="font-size:23px;line-height:1.3;color:{c};padding:3px 0 3px 20px;position:relative"><span style="position:absolute;left:0;top:12px;width:7px;height:7px;border-radius:2px;background:{ac}"></span>{p}</p>' for p in perks)
    return card(f'<p style="{MONO};font-size:17px;font-weight:500;color:{ac}">TIER {n}</p>'
                f'<h3 style="{FG};font-size:42px;font-weight:700;line-height:1.1;color:{c};padding:6px 0 4px">{name}</h3>'
                f'<p style="font-size:20px;color:{m};padding-bottom:12px">{sub}</p>{pl}', bg=bg, border=bd, pad="22px 26px", extra="flex:1")


inner = f"""{abs_img("dither", "", "right:0;top:0;width:720px;height:1080px")}
<div style="position:relative;width:1216px;display:flex;flex-direction:column">
{eyebrow("Factory · the Guild")}
<div style="padding-top:8px">{lead("Join the", "Factory Guild.", 76)}</div>
<div style="display:flex;flex-direction:row;gap:16px;padding-top:24px">
{stat("3", "ranks, Apprentice to Artisan", 394)}{stat("Unlimited", "Droid credits at the top rank", 394)}{stat("Vetted", "every member reviewed by the Council", 394)}
</div>
<p style="{MONO};font-size:18px;font-weight:500;letter-spacing:2px;text-transform:uppercase;color:{MUTED};padding:24px 0 10px">Climb the ranks</p>
<div style="display:flex;flex-direction:row;gap:16px;height:416px">
{tier(1, "Apprentice", "Entry rank · day one", ["Full Max plan credits", "Guild Slack access", "Early feature access", "Welcome kit", "Group mentorship", "Resume and portfolio review"])}
{tier(2, "Craftsman", "Points + review", ["Full Ultra plan credits", "Premium kit", "1:1 monthly mentorship", "Coaching session", "Factory events access"])}
{tier(3, "Artisan", "Highest rank", ["Unlimited credits", "Elite kit", "Hiring fast-track", "Conference travel stipend", "Roadmap previews under NDA", "Co-author Factory blog posts"], hot=True)}
</div>
<div style="margin-top:20px;background:{CARD};border:1px solid {EDGE};border-radius:14px;padding:16px 26px">
<p style="{FG};font-size:28px;font-weight:600;color:{TXT}">Just build cool stuff with Droid, and show it to the world.</p></div>
</div>
{qrcard("qr_factory", "Join the Guild", "factory.com/ambassador", "left:1384px;top:268px;", "Contribute, climb the ranks, get recognized.", 500)}
{abs_img("trophy_skull", "GMI skull mascot in a gold trophy", "left:1640px;top:30px;width:200px")}"""
slide("guild", inner, tag="", pad="124px 96px 120px", notes=(
    "About 1 minute. The Factory Guild is Factory's community of builders who ship with Droid, share their work in public and climb three ranks. "
    "Apprentice is where everyone starts on day one: full Max plan credits, the Guild Slack, early feature access, a welcome kit, group mentorship and a resume and portfolio review. Craftsman adds full Ultra plan credits, a premium kit, monthly 1:1 mentorship, a coaching session and access to Factory events. Artisan, the highest rank, gets unlimited credits, the elite kit, a hiring fast-track, a conference travel stipend, roadmap previews under NDA and the chance to co-author Factory blog posts. "
    "The message: just build cool stuff with Droid, and show it to the world. Every member is reviewed by the Council. "
    "All of this is from factory.com/ambassador as read on 10 November 2026; re-check it just before you present. Aditya's deck has the same programme slide, so keep this one short and point to the QR."))

# ------------------------------------------------------------------ 12 close
def qrmini(qr, title, url):
    return (f'<div style="box-sizing:border-box;width:268px;background:#fff;border-radius:18px;padding:18px;display:flex;flex-direction:column;align-items:center;gap:8px;box-shadow:0 18px 40px rgba(0,0,0,0.5)">'
            f'{img(qr, 210, 210, "QR code: " + url, fit="contain", extra="image-rendering:pixelated")}'
            f'<p style="{FG};font-size:26px;font-weight:700;color:#000;line-height:1.1;text-align:center">{title}</p>'
            f'<p style="{MONO};font-size:13px;font-weight:500;color:#000;text-align:center">{url}</p></div>')


inner = f"""{abs_img("concept", "GRID FALL concept art: a calm city block on the left and a blackout crisis on the right", "left:0;top:0;width:1920px;height:1080px;object-fit:cover;opacity:0.5")}
<div style="position:absolute;left:0;top:0;width:1920px;height:1080px;background:linear-gradient(90deg, rgba(0,0,0,0.96) 0%, rgba(0,0,0,0.85) 45%, rgba(0,0,0,0.4) 100%)"></div>
{abs_img("glow", "GMI skull mascot", "right:0;top:60px;height:520px")}
<div style="position:relative;display:flex;flex-direction:column;flex:1;justify-content:center;gap:34px;width:900px">
{eyebrow("Thank you")}
<h1 style="{FG};font-size:150px;line-height:1.02;font-weight:700;color:{TXT}"><span style="color:{LIME};font-weight:300">Thank you.</span><br>Questions?</h1>
{lockup(52, 38)}
<p style="font-size:28px;line-height:1.4;color:{MUTED}"><b style="color:{TXT}">Kunal Siyag</b> · GMI Cloud Ambassador · Factory Guild member<br><span style="{MONO};font-size:22px;color:{LIME}">@kunal_twts · github.com/KunalSiyag/gridfall</span></p>
<p style="font-size:22px;line-height:1.4;color:{DIM}">Also built with Godot, Blender, Claude, Microsoft Rocketbox, Quaternius, Kenney, Poly Haven and ACE-Step.</p>
</div>
<div style="position:absolute;left:1000px;top:600px;display:flex;flex-direction:row;gap:22px">
{qrmini("qr_gmi", "GMI Clouders", "gmicloud.ai/company/ambassador-program")}
{qrmini("qr_factory", "Factory Guild", "factory.com/ambassador")}
{qrmini("qr_github", "GridFall", "github.com/KunalSiyag/gridfall")}
</div>"""
slide("close", inner, tag="GridFall", pad="128px 96px 120px")

# ------------------------------------------------------------------ index
order = ["cover", "whatis", "cast", "arch", "story", "droidkit", "people", "demo", "lessons", "clouder", "guild", "close"]
deck = {
    "v": 4, "createdOnFiles": {"v": 1, "at": "2026-11-02T19:45:00Z"}, "lists": "css",
    "title": "GridFall: building multi-model agents with Droid (GMI Cloud x Factory)",
    "order": order,
    "sections": {
        "s1": {"description": "What GridFall is: a city run by five AI mayors, and the 14 GMI models behind it.", "start": "cover"},
        "s2": {"description": "How it was built with Factory Droid, Blender and GMI's image model.", "start": "story"},
        "s3": {"description": "Live demo and lessons.", "start": "demo"},
        "s4": {"description": "Join GMI Clouders or the Factory Guild, then questions.", "start": "clouder"},
    },
    "faces": {
        "figtree": {"family": "Figtree", "href": "https://fonts.googleapis.com/css2?family=Figtree:wght@300;400;600;700&display=swap"},
        "geist-mono": {"family": "Geist Mono", "href": "https://fonts.googleapis.com/css2?family=Geist+Mono:wght@500&display=swap"},
    },
    "designSystems": [],
}
with open(os.path.join(ROOT, "project", "deck.json"), "w") as f:
    json.dump(deck, f, indent=2, ensure_ascii=False)
print("ok", len(order), "slides")

# ------------------------------------------------------------------ local preview (headless Chrome)
if "--preview" in sys.argv:
    S = os.environ["SCRATCH"]
    AF = S + "/artifact-files/96d9413f-7fc3-4f19-992b-0e4cd4e434cf/"
    local = {v: AF + v + ".jpg" for v in ID.values()}
    up = {ID[k]: S + f"/up3/{f}.png" for k, f in [
        ("skull_headphones", "skull_headphones"), ("skull_question", "skull_question"), ("skull_sunglasses", "skull_sunglasses"),
        ("skull_star_l", "skull_star_l"), ("skull_star_r", "skull_star_r"), ("trophy", "trophy"), ("skull_heart", "skull_heart"),
        ("trophy_skull", "trophy_skull"), ("ufo", "ufo_skull"), ("glow", "skull_glow"), ("dither", "dither_right"),
        ("dither_dark", "dither_right_dark"), ("dither_bottom", "dither_bottom_lime"), ("qr_gmi", "qr_gmi"),
        ("qr_factory", "qr_factory"), ("qr_github", "qr_github")]}
    local.update(up)
    r2 = ROOT + "/../deck-v2/img/"
    local.update({ID["robot"]: r2 + "robot.jpg", ID["hero"]: r2 + "hero_crop.jpg", ID["argon"]: r2 + "portraits/argon.jpg",
                  ID["deepseek"]: r2 + "portraits/deepseek.jpg", ID["kimi"]: r2 + "portraits/kimi.jpg",
                  ID["qwen"]: r2 + "portraits/qwen.jpg", ID["grok"]: r2 + "portraits/grok.jpg"})
    os.makedirs(ROOT + "/prev", exist_ok=True)
    for sid in order:
        t = open(f"{OUT}/{sid}.html").read()
        t = re.sub(r"/_blob/([0-9a-f]{32})", lambda m: "file://" + local.get(m.group(1), "/nonexistent"), t)
        t = re.sub(r"<aside>[\s\S]*?</aside>", "", t)
        t = t.replace('style="background', 'style="width:1920px;height:1080px;box-sizing:border-box;position:relative;overflow:hidden;background', 1)
        open(f"{ROOT}/prev/{sid}.html", "w").write(
            '<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Figtree:wght@300;400;600;700&family=Geist+Mono:wght@500&display=swap">'
            '<style>html,body{margin:0;padding:0;background:#000}p,h1,h2,h3{margin:0}</style></head><body>' + t + "</body></html>")
    print("preview ok")
