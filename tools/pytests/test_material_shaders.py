"""The ground and paved surfaces keep the material parameters that make them read as different stuff.

Materials unit G2: the owner saw "so many smooth surfaces" (grass, cement, sand all alike). These pin
what the shaders now say, in the source (the headless Godot test tools/tests/fp_materials_test.gd
pins what a loaded material carries): per-surface roughness constants in the ranges real materials
have, low specular on grass, rain darkening and glossing every paved surface, the surface switch off
by default, no instance uniforms, and no per-pixel hash noise on the grass.
"""
from __future__ import annotations

import re
from pathlib import Path

SHADERS = Path(__file__).parents[2] / "shaders"
ROAD = (SHADERS / "road_fp.gdshader").read_text()
GROUND = (SHADERS / "ground_detail.gdshader").read_text()


def _branch(source: str, head: str, tail: str) -> str:
    start = source.index(head)
    return source[start : source.index(tail, start)]


def _floats(pattern: str, text: str) -> list[float]:
    return [float(x) for x in re.findall(pattern, text)]


def _groups(pattern: str, text: str) -> list[float]:
    """The capture groups of the first match, as floats ([] when nothing matches)."""
    found = re.search(pattern, text)
    return [float(x) for x in found.groups()] if found else []


def test_no_instance_uniforms() -> None:
    """A mesh drawn with a shader that declares one takes a slot of Compatibility's 4096."""
    for text in (ROAD, GROUND):
        assert not re.search(r"^\s*instance\s+uniform\b", text, re.M)


def test_road_shader_switches_and_defaults() -> None:
    assert re.search(r"uniform float surface = 0\.0;", ROAD), "a fresh material is asphalt"
    assert re.search(r"uniform float wetness = 0\.0;", ROAD) and re.search(r"uniform float wetness = 0\.0;", GROUND)
    assert "rough_tex" not in ROAD, "the scanned roughness map is gone (near flat)"


def test_paved_surface_roughness() -> None:
    """Dry asphalt about 0.78, pavement and concrete about 0.84 and 0.82 (matte), kerb 0.7, paint 0.8."""
    asphalt = _branch(ROAD, "if (kind == 0) {", "} else if (kind == 1) {")
    pavement = _branch(ROAD, "} else if (kind == 1) {", "} else if (kind == 2) {")
    kerb = _branch(ROAD, "} else if (kind == 2) {", "} else if (kind == 3) {")
    concrete = _branch(ROAD, "} else if (kind == 3) {", "} else {")
    paint = ROAD[ROAD.index("// Lane paint") :]
    expect = {"asphalt": (asphalt, 0.78), "pavement": (pavement, 0.84), "kerb": (kerb, 0.70), "concrete": (concrete, 0.82), "paint": (paint, 0.80)}
    for name, (text, want) in expect.items():
        base = float(re.search(r"rough = ([\d.]+)", text).group(1))
        assert base == want, f"{name} roughness {base}"


def test_asphalt_is_mildly_glossy_wet_and_the_rest_darken() -> None:
    assert re.search(r"ROUGHNESS = mix\(rough, 0\.22, wetness \* 0\.8\);", ROAD)
    for factor in _floats(r"mix\(1\.0, ([\d.]+), wetness\)", ROAD):
        assert factor <= 0.75, f"rain darkens a paved surface to {factor} at most"
    assert len(_floats(r"mix\(1\.0, ([\d.]+), wetness\)", ROAD)) == 5, "every surface kind darkens in rain"
    dry, wet = re.search(r"SPECULAR = mix\(kind == 0 \? ([\d.]+) : [\d.]+, ([\d.]+), wetness\);", ROAD).groups()
    assert float(dry) <= 0.2 and float(wet) >= 0.5, "matte dry (a rough sky reflection washes it pale), glossy wet"


def test_asphalt_has_its_wear() -> None:
    """The things the owner's list asks of asphalt: speckle, cracks, tar, oil at junctions, worn tracks."""
    asphalt = _branch(ROAD, "if (kind == 0) {", "} else if (kind == 1) {")
    for part in ("hash12(floor(r1 / 0.006))", "float crack", "float tar", "lane_axis < 6.5", "float track", "float oil"):
        assert part in asphalt, part
    assert "textureLod(albedo_tex, vec2(0.5), 10.0)" in asphalt, "the scan's contrast is stretched about its mean"


def test_pavement_has_joints_and_tone_per_paver() -> None:
    pavement = _branch(ROAD, "} else if (kind == 1) {", "} else if (kind == 2) {")
    for part in ("hash12(cell)", "float jl", "t.x * 3.0", "t.y * 6.0", "st = nz("):
        assert part in pavement, part


def test_grass_is_matte_with_low_specular() -> None:
    rough = float(re.search(r"float rough = mix\(([\d.]+) \+", GROUND).group(1))
    assert 0.85 <= rough <= 0.95, f"grass roughness {rough}"
    spec = re.search(r"float spec = mix\(([\d.]+), ([\d.]+), earth\);", GROUND)
    grass_spec, earth_spec = float(spec.group(1)), float(spec.group(2))
    assert grass_spec <= 0.25, f"grass specular {grass_spec}"
    assert grass_spec < earth_spec <= 0.4
    assert "SPECULAR = 0.35;" not in GROUND, "one specular for every ground class is how it all looked alike"
    assert "uniform sampler2D grass_rough" not in GROUND


def test_grass_has_clumps_dry_patches_and_clover() -> None:
    for part in ("float c1 = (nz(", "float dry = smoothstep", "float clover = smoothstep", "float worn = smoothstep(0.82"):
        assert part in GROUND, part


def test_grass_path_has_no_hashed_fbm() -> None:
    """The macro and patch layers read the noise texture (a fetch) instead of 24 to 48 hashes a pixel;
    the hashed fbm is left to the track code (gravel, dirt, trails), which runs on a few tiles."""
    before_tracks = GROUND[: GROUND.index("if (track) {")]
    calls = re.findall(r"\bfbm\(", before_tracks)
    assert len(calls) == 1, "only fbm's own definition may appear before the track branch"


def test_sand_has_grain_and_stays_in_step_with_the_shore_band() -> None:
    sand = _branch(GROUND, "if (shore.x > 0.004) {", "float puddle")
    assert "hash12(floor(wm / 0.005))" in sand, "sand grains"
    assert "float crest = sin(" in sand and "spec = mix(spec, 0.35, cover)" in sand


def test_kerb_face_is_not_a_black_line() -> None:
    """Review of G2: the kerb face (lit by blue sky ambient only) came out near-black, 38/43/51 in the
    darkest 3% against 63/70/73 before. The stone is lighter, and warm on the face to cancel the sky."""
    kerb = _branch(ROAD, "} else if (kind == 2) {", "} else if (kind == 3) {")
    base = _groups(r"alb = vec3\(([\d.]+), ([\d.]+), ([\d.]+)\) \* tint", kerb)
    assert len(base) == 3 and min(base) >= 0.5, f"kerb stone albedo {base}"
    warm = _groups(r"mix\(vec3\(1\.0\), vec3\(([\d.]+), ([\d.]+), ([\d.]+)\), 1\.0 - top\)", kerb)
    assert len(warm) == 3 and warm[0] > warm[2], "the face leans warm"
    foot = float(re.search(r"alb \*= 1\.0 - ([\d.]+) \* foot", kerb).group(1))
    assert foot <= 0.35, f"grime at the foot of the kerb {foot}"


def test_wheel_tracks_are_patchy_not_rules_to_the_horizon() -> None:
    """Review of G2: five or six long dark parallel stripes fanned to the vanishing point. The tracks and
    drips now fade in and out along the lane, and the two amplitudes are near what they were before."""
    asphalt = _branch(ROAD, "if (kind == 0) {", "} else if (kind == 1) {")
    assert re.search(r"float along_wear = [\d.]+ \+ [\d.]+ \* smoothstep\([^;]*nz\(m / 1\d\.0", asphalt)
    assert re.search(r"oil = [^;]*\* along_wear;", asphalt) and re.search(r"track = [^;]*\* along_wear;", asphalt)
    oil = float(re.search(r"alb \*= 1\.0 - ([\d.]+) \* clamp\(oil", asphalt).group(1))
    track = float(re.search(r"alb \*= 1\.0 - ([\d.]+) \* track", asphalt).group(1))
    assert oil <= 0.30 and track <= 0.13, f"oil {oil}, track {track}"
    assert float(re.search(r"alb \*= mix\(([\d.]+), 1\.08, age\)", asphalt).group(1)) >= 0.84, "the road is not darker than before"


def test_pavement_tone_and_stain_stay_moderate() -> None:
    """Review of G2: per-paver tone 0.84 to 1.14 and large stains made a patchwork at graze and range."""
    pavement = _branch(ROAD, "} else if (kind == 1) {", "} else if (kind == 2) {")
    lo, spread = _groups(r"alb \*= ([\d.]+) \+ ([\d.]+) \* hb;", pavement)
    assert spread / lo <= 0.25, f"paver tone {lo} .. {lo + spread}"
    stain = float(re.search(r"alb \*= 1\.0 - ([\d.]+) \* smoothstep\(0\.62, 0\.95, st\)", pavement).group(1))
    assert stain <= 0.15, f"stain {stain}"


def test_lawn_clumps_use_three_incommensurate_periods() -> None:
    """Review of G2: two clump layers of 1.3 and 1.9 m showed a faint lattice of dark blobs."""
    line = re.search(r"float c1 = ([^;]*);", GROUND).group(1)
    periods = _floats(r"/ ([\d.]+) \+", line)
    assert len(periods) == 3 and len(set(periods)) == 3, periods
    clover = float(re.search(r"clover \* ([\d.]+)\);", GROUND).group(1))
    assert clover <= 0.6, f"clover strength {clover}"


def test_sand_edge_wanders_and_has_coarse_grit() -> None:
    """Review of G2: the sand band met grass and water along a ruler-straight edge and read as a flat grey slab."""
    sand = _branch(GROUND, "if (shore.x > 0.004) {", "float puddle")
    assert re.search(r"float sx = shore\.x \* \(", sand), "the band's outer edge is scaled by noise"
    assert re.search(r"shore\.y = clamp\(shore\.y \* \(", sand), "so is the wet strip"
    assert "hash12(floor(wm / 0.02)" in sand and "float grit" in sand, "2 cm grit and shell"
    warm = _groups(r"vec3\(lum\) \* vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)", sand)
    assert warm[0] > warm[1] > warm[2] and warm[0] / warm[2] >= 1.6, f"sand is warm, not grey {warm}"


def test_lawn_patches_are_warped_so_no_grid_shows() -> None:
    """Review of G2: the 5.5 m dry-patch and 5.3 m / 7.9 m clover layers are single repeating tiles, a regular
    grid of dark blobs on a lawn. Their lookups go through coordinates warped by the 40 m macro noise
    (no extra fetch: m1 and m2 are read already)."""
    assert re.search(r"vec2 ww = wm \+ \(vec2\(m2, m1\) - 0\.5\) \* [\d.]+;", GROUND)
    for lookup in ("nz(ww / 5.5", "nz(wwr / 5.3", "nz(ww / 7.9"):
        assert lookup in GROUND, lookup
    for raw in ("nz(wm / 5.5", "nz(wr / 5.3", "nz(wm / 7.9"):
        assert raw not in GROUND, f"{raw} would repeat on a regular grid"


def test_grass_scan_is_stretched_in_its_detail_only() -> None:
    """Review of G2: stretching the grass scan about its mean amplified the 3 m blotches of the tile itself
    into a visible lattice. Only what is finer than its own blur (a low mip) is stretched."""
    assert not re.search(r"g = max\(g \+ \(g - textureLod\(grass_albedo, vec2\(0\.5\)", GROUND)
    assert re.search(r"vec3 gl = mix\(textureLod\(grass_albedo, p \+ oa, [2-6]\.0\)", GROUND)
    assert "g = max(g + (g - gl) *" in GROUND
