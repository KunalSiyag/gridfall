"""The wet-ground shaders sheen where water stands instead of mirroring the sky.

Regression guard for the plaza-band report: on the web GL build at grazing angles, the road
shader's pool mask (jagged fbm, wetness-gated) dropped ROUGHNESS to 0.03 with a 90%-flattened
normal, so each pool pixel sampled the sky — a pale jagged band winding along the carriageway
that flickered as the mask aliased. ground_detail had the same mirror in track ruts (0.05).
The pools must stay a sheen (>= 0.2): low enough to read as standing water against the
surrounding wet surface, never low enough to mirror.
"""
import re
from pathlib import Path

SHADERS = Path(__file__).parents[2] / "shaders"


def _pool_floor(source: str, pattern: str) -> float:
    m = re.search(pattern, source)
    assert m, "pool roughness line not found — the wet-pool feature moved; update this guard"
    return float(m.group(1))


def test_road_pools_sheen_not_mirror() -> None:
    src = (SHADERS / "road_fp.gdshader").read_text()
    floors = [float(x) for x in re.search(r"mix\(ROUGHNESS, mix\(([\d.]+), ([\d.]+), polish\), pool\)", src).groups()]
    for floor in floors:
        assert 0.2 <= floor <= 0.4, f"road pool roughness floor {floor}"
    flatten = _pool_floor(src, r"pool \* ([\d.]+)\)")
    assert flatten <= 0.6, f"road pool normal flatten {flatten} kills the asphalt detail"


def test_ground_rut_puddles_sheen_not_mirror() -> None:
    src = (SHADERS / "ground_detail.gdshader").read_text()
    floor = _pool_floor(src, r"mix\(rough, ([\d.]+), puddle \* wetness")
    assert 0.18 <= floor <= 0.4, f"ground rut puddle roughness floor {floor}"


SCRIPTS = Path(__file__).parents[2] / "scripts"


def test_water_on_foot_is_not_a_mirror() -> None:
    """The river read as a pale slab on the web: ROUGHNESS 0.04 with a SPECULAR 0.8 sky mirror
    drowned the body colour. On foot the water keeps a floor on both."""
    src = (SHADERS / "water.gdshader").read_text()
    m = re.search(r"ROUGHNESS = mix\(fp \? ([\d.]+) : ([\d.]+), ([\d.]+), foam\)", src)
    assert m, "water roughness line moved; update this guard"
    assert float(m.group(1)) >= 0.1, f"on-foot water roughness {m.group(1)}"
    spec = re.search(r"SPECULAR = fp \? ([\d.]+) : ([\d.]+);", src)
    assert spec and float(spec.group(1)) <= 0.6, "on-foot water specular"


def test_water_depth_read_knows_the_compatibility_renderer() -> None:
    """The web build renders with gl_compatibility: its depth texture is in [0, 1] and unprojects
    with the screen uv remapped as well. The Forward+ formula there made t_depth 0 and foam 1
    everywhere (an all-foam pale slab)."""
    src = (SHADERS / "water.gdshader").read_text()
    assert "uniform bool compat" in src
    assert "compat ? vec3(SCREEN_UV, z) * 2.0 - 1.0 : vec3(SCREEN_UV * 2.0 - 1.0, z)" in src
    view = (SCRIPTS / "world" / "city_view.gd").read_text()
    # The view asks the renderer and sets the uniform from WATER.is_compat; the decision itself is
    # pinned by fp_water_test (through the render_method_override), the wiring is checked here.
    assert "RenderingServer.get_current_rendering_method()" in view
    assert re.search(r'set_shader_parameter\("compat", WATER\.is_compat\(\w+\)\)', view)
    surf = (SCRIPTS / "world" / "water_surface.gd").read_text()
    assert re.search(r'func is_compat\(\w+: String\) -> bool:\s+return \w+ == "gl_compatibility"', surf)


def test_flood_sheet_shortens_the_depth_scale() -> None:
    """A flood plane is millimetres deep over paving: it reads white vertex colour (no mesh colours)
    and the shader shrinks its depth scale, foam and silt, or it stays a pale low-contrast sheet
    (luminance spread about 2 of 255, the old slab's signature)."""
    src = (SHADERS / "water.gdshader").read_text()
    assert "varying float sheet;" in src
    assert re.search(r"sheet = COLOR\.b > 0\.5 \? 1\.0 : 0\.0;", src)
    assert re.search(r"float dfade = mix\(depth_fade, depth_fade \* 0\.[0-9]+, sheet\);", src)
    assert "smoothstep(0.0, dfade, depth)" in src


def test_water_ripple_slots_match_the_shader() -> None:
    src = (SHADERS / "water.gdshader").read_text()
    n = int(re.search(r"uniform vec4 ripples\[(\d+)\]", src).group(1))
    surf = (SCRIPTS / "world" / "water_surface.gd").read_text()
    assert int(re.search(r"const SLOTS := (\d+)", surf).group(1)) == n
    assert f"for (int i = 0; i < {n}; i++)" in src
    life = float(re.search(r"const LIFE := ([\d.]+)", surf).group(1))
    assert f"r.z / {life}" in src, "the shader fades a ring over the ripple life"


def test_shore_shader_constants_match_shore_gd() -> None:
    """The shader rebuilds the band from the tile code with literals; they must equal shore.gd."""
    shore = (SCRIPTS / "world" / "shore.gd").read_text()
    sh = (SHADERS / "ground_detail.gdshader").read_text()
    width = float(re.search(r"const SHORE_W := ([\d.]+)", shore).group(1))
    assert f"smoothstep(0.0, {width}, dist)" in sh
    assert re.search(rf"smoothstep\(0\.0, {width / 3:.2f}, dist( - [^)]*)?\)", sh)
    assert float(re.search(r"const TILE_MARK := ([\d.]+)", shore).group(1)) == 0.5
    assert float(re.search(r"const BED_MARK := ([\d.]+)", shore).group(1)) == 0.25
    assert "abs(shore_v.a - 0.5) < 0.05" in sh and "abs(shore_v.a - 0.25) < 0.05" in sh
