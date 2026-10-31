"""The sky shader's sRGB night stays a night-only, Compatibility-only change.

Compatibility decodes a sky shader's COLOR as sRGB (its sky.glsl), which blacks the night out;
SkyDirector turns `srgb_sky` on there and the shader encodes the night to match. The day, dusk and
all of Forward+ must stay byte-identical: the encode lives inside the `night` block, behind the
flag, and nothing runs after it but the exposure. The encode is evaluated here as the shader
spells it, against the standard sRGB curve; the rest of the night block is pinned statement by
statement, as Forward+ has always drawn it.
"""
import math
import re
from pathlib import Path

SOURCE = (Path(__file__).parents[2] / "shaders" / "sky_blend.gdshader").read_text()
CODE = re.sub(r"//[^\n]*", "", SOURCE)

# The night block's statements with the flag off, which is every Forward+ night frame.
FORWARD_NIGHT = [
    "vec3 n = mix(vec3(0.020, 0.024, 0.040), vec3(0.003, 0.006, 0.018), smoothstep(0.0, 0.6, up))",
    "n += vec3(0.06, 0.035, 0.015) * pow(1.0 - abs(up), 8.0) * (1.0 + grey)",
    "float star = step(0.9982, hash3(floor(EYEDIR * 420.0))) * smoothstep(0.05, 0.35, up) * (1.0 - grey)",
    "n += vec3(0.9, 0.92, 1.0) * star * 1.5",
    "col = mix(col, n, night)",
]


def _block(source: str, header: str) -> str:
    """The text between the braces of the first `header {`, braces matched."""
    start = source.index(header) + len(header)
    depth = 1
    for i in range(start, len(source)):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        if depth == 0:
            return source[start:i]
    raise AssertionError(f"unbalanced braces after {header!r}")


def _glsl(expr: str, names: dict) -> float:
    """A scalar GLSL expression, evaluated: vec3(x) is x, the shader's own functions are `names`."""
    scope = {
        "mix": lambda a, b, t: a * (1.0 - t) + b * t,
        "step": lambda edge, x: 0.0 if x < edge else 1.0,
        "pow": math.pow,
        "min": min,
        "max": max,
    }
    scope.update(names)
    return float(eval(re.sub(r"\bvec3\(", "(", expr), {"__builtins__": {}}, scope))  # noqa: S307


def _srgb(c: float) -> float:
    """The standard sRGB transfer function (IEC 61966-2-1)."""
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1.0 / 2.4) - 0.055


def _curve(c: float) -> float:
    """The shader's own linear_to_srgb(), evaluated."""
    body = _block(CODE, "vec3 linear_to_srgb(vec3 c) {")
    return _glsl(re.search(r"return (.*);", body, re.S).group(1), {"c": c})


def _lift() -> float:
    return float(re.search(r"SRGB_SKY_LIFT = ([\d.]+);", CODE).group(1))


def test_encode_runs_only_in_the_night_block_behind_the_flag() -> None:
    night = _block(CODE, "if (night > 0.001) {")
    flagged = _block(night, "if (srgb_sky > 0.0) {")
    assert "linear_to_srgb(col" in flagged
    assert CODE.count("linear_to_srgb(col") == 1, "the encode must not run anywhere else"
    assert CODE.count("SRGB_SKY_LIFT") == 2, "the lift is declared once and used once"
    assert re.search(r"uniform float srgb_sky[^;]*= 0\.0;", CODE), "Forward+ must default to off"
    sky = _block(CODE, "void sky() {")
    header = "if (night > 0.001) {"
    after = sky[sky.index(header) + len(header) + len(night) + 1 :]
    assert " ".join(after.split()) == "COLOR = col * exposure;", "nothing follows the night block"


def test_sky_encode_is_the_srgb_curve_lifted_and_faded_in_with_the_night() -> None:
    # The curve the shader spells, against the standard one, over the range of the night's colours.
    for c in (0.0, 0.0005, 0.002, 0.0031308, 0.01, 0.04, 0.1, 0.5, 1.0):
        assert abs(_curve(c) - _srgb(c)) < 1e-6, f"linear_to_srgb({c}) is not sRGB"
    flagged = _block(_block(CODE, "if (night > 0.001) {"), "if (srgb_sky > 0.0) {")
    statement = re.fullmatch(r"\s*col = (.*);\s*", flagged, re.S)
    assert statement, f"the flag guards one assignment to col, not {flagged!r}"
    lift = _lift()
    assert 0.002 <= lift <= 0.006, f"night sky lift {lift} is outside the measured 0.002..0.006"
    for col in (0.0, 0.003, 0.02, 0.1, 0.8):
        for night in (0.0, 0.25, 1.0):
            for flag in (0.0, 1.0):
                names = {
                    "col": col,
                    "night": night,
                    "srgb_sky": flag,
                    "SRGB_SKY_LIFT": lift,
                    "linear_to_srgb": _curve,
                }
                fade = flag * night
                want = col * (1.0 - fade) + _srgb(col + lift) * fade
                got = _glsl(statement.group(1), names)
                assert abs(got - want) < 1e-9, f"col {col}, night {night}, srgb_sky {flag}: {got}"


def test_the_forward_night_is_what_it_always_was() -> None:
    night = _block(CODE, "if (night > 0.001) {")
    flag = "if (srgb_sky > 0.0) {"
    head = night[: night.index(flag)]
    tail = night[night.index(flag) + len(flag) + len(_block(night, flag)) + 1 :]
    statements = [" ".join(s.split()) for s in (head + tail).split(";") if s.strip()]
    assert statements == FORWARD_NIGHT, "the flag-off night block is not Forward+'s own"
