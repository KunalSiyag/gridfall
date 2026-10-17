"""Vehicle library: cars, service vehicles, boats and aircraft.

Scale: road vehicles use real dimensions x1.2 (VS) so they read from the game camera while staying
in proportion with the buildings (a 4.7 m sedan is 0.28 units long, a 12 m bus 0.72). Boats, the
plane and the helicopter are modelled at tile scale too (1 unit = 20 m, the plane at 0.9x).
Front faces Blender -Y (Godot +Z). Wheels touch z=0; boats float with the waterline at z=0; the
plane origin is on the fuselage axis (gear touches z=-0.118), the helicopter origin is under its skids.

Scripted parts: Siren_<n> light-bar halves (emergency vehicles), Rotor (main rotor, spins about
Godot Y with its origin at the hub) and RotorTail (spins about Godot X)."""

import math

import bpy
from mathutils import Matrix, Vector

import core
from core import MB, M
from services import part
import indkit  # noqa: F401  (registers Container_* materials)

VS = 1.2 * M

core.MATS.update({
    "Wheel_Rim": ("flat", (0.55, 0.56, 0.58), 0.25, 1.0, {}),
    "Shutter_Alu": ("tex", "painted_metal_shutter", 0.8, (0.86, 0.87, 0.9)),
    "Paint_garbage": ("flat", (0.10, 0.36, 0.15), 0.32, 0.1, {"coat": 0.6}),
    "Paint_fire": ("flat", (0.62, 0.03, 0.02), 0.28, 0.1, {"coat": 1.0}),
    "Sign_Taxi": ("flat", (0.95, 0.85, 0.25), 0.3, 0.0, {"emission": (1.0, 0.8, 0.25), "strength": 0.8}),
    "Sign_Dest": ("flat", (0.9, 0.55, 0.05), 0.3, 0.0, {"emission": (1.0, 0.6, 0.05), "strength": 1.2}),
    "Hull_Red": ("flat", (0.33, 0.045, 0.035), 0.6, 0.0, {}),
    "Hull_White": ("flat", (0.86, 0.87, 0.87), 0.25, 0.0, {"coat": 0.6}),
    "Hull_Black": ("flat", (0.025, 0.025, 0.03), 0.4, 0.0, {}),
    "Hull_Navy": ("flat", (0.02, 0.06, 0.18), 0.35, 0.0, {"coat": 0.4}),
    "Deck_Teak": ("tex", "wood_planks", 0.8, (0.78, 0.62, 0.46)),
    "Deck_Grey": ("tex", "concrete_floor_02", 2.0, (0.45, 0.47, 0.46)),
    "Plane_White": ("flat", (0.86, 0.87, 0.89), 0.3, 0.05, {"coat": 0.5}),
    "Plane_Grey": ("flat", (0.52, 0.54, 0.57), 0.35, 0.6, {}),
    "Plane_Blue": ("flat", (0.04, 0.16, 0.48), 0.3, 0.1, {"coat": 0.5}),
    "Plane_Window": ("flat", (0.015, 0.02, 0.025), 0.1, 0.5, {}),
    "Nav_Green": ("flat", (0.05, 0.8, 0.2), 0.2, 0.0, {"emission": (0.05, 1.0, 0.2), "strength": 2.0}),
})
core.LITE.update({"Deck_Grey"})

RX90 = Matrix.Rotation(-math.pi / 2, 4, "X")  # local Z -> +Y
RY90 = Matrix.Rotation(math.pi / 2, 4, "Y")  # local Z -> +X


def bx(mb, x0, y0, z0, x1, y1, z1, mat, s=VS, **kw):
    mb.box2(x0 * s, y0 * s, z0 * s, x1 * s, y1 * s, z1 * s, mat, **kw)


def finish(c, name, angle=38):
    """Build the main mesh now so it can be shaded smooth-by-angle (crisp panel edges, soft curves)."""
    ob = c.mb.build(name)
    c.mb = MB()
    if ob is None:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))
    except Exception:
        pass
    return ob


# ----------------------------------------------------------------------------- body lofts

def body_loft(mb, stations, tags, W, mats, s=VS, crown=None):
    """Loft a car body through cross-section stations (front -> rear, metres):
    (y, sill_z, belt_z, glass_top_z, width_frac, roof_width_frac[, roof_band]).
    tags[k] classifies the segment after station k: X end, H hood, W windscreen, G side glass,
    P pillar/panel, B rear window, T trunk."""
    rings = []
    for st in stations:
        y, z0, zb, zr, wf, wrf = st[:6]
        band = st[6] if len(st) > 6 else 0.015
        hw, hr = W / 2 * wf, W / 2 * wrf
        zt = zr + band
        cr = crown if crown is not None else (0.035 if zr - zb > 0.25 else 0.012)
        zm = z0 + 0.45 * (zb - z0)
        pts = [(-hw * .94, z0), (-hw, zm), (-hw * .985, zb), (-hr, zr), (-hr * .995, zt), (-hr * .7, zt + cr),
               (hr * .7, zt + cr), (hr * .995, zt), (hr, zr), (hw * .985, zb), (hw, zm), (hw * .94, z0)]
        rings.append([(x * s, y * s, z * s) for x, z in pts])
    body = mats["body"]

    def matfn(k, i):
        t = tags[k]
        if i == 11:
            return mats.get("under", "Plastic_Black")
        if i in (0, 10):
            return mats.get("lower", body)
        if i in (1, 9):
            return body
        if i in (2, 8):
            return "Glass_Car" if t == "G" else mats.get("pillar", body)
        if i in (3, 7):
            if "band" in mats and t in "GPWB":
                return mats["band"]
            return "Glass_Car" if t in "WB" else (mats.get("roof", body) if t in "GP" else body)
        return "Glass_Car" if t in "WB" else (mats.get("roof", body) if t in "GP" else body)

    mb.loft(rings, matfn, smooth=False, cap_mat=mats.get("cap", body))


def ring_loft(mb, profiles, mat, s=VS, cap_mat=None, matfn=None, caps=(True, True)):
    """profiles: [(y, [(x, z), ...]), ...] closed rings ordered up the left side, over the top, down the right."""
    rings = [[(x * s, y * s, z * s) for x, z in pts] for y, pts in profiles]
    mb.loft(rings, matfn or (lambda k, i: mat), smooth=False, cap_start=caps[0], cap_end=caps[1],
            cap_mat=cap_mat or mat)


def rbox(hw, zb, zt, r=0.25):
    """Rounded-top box section (x, z)."""
    return [(-hw, zb), (-hw, zt - r), (-hw * 0.93, zt - r * 0.3), (-hw * 0.75, zt), (hw * 0.75, zt),
            (hw * 0.93, zt - r * 0.3), (hw, zt - r), (hw, zb)]


def wheel(mb, x, y, r, w, s=VS, n=14, rim="Wheel_Rim"):
    R, Wd = r * s, w * s
    c = (x * s, y * s, r * s)
    prof = [(R * .6, -Wd * .42), (R * .6, -Wd / 2), (R * .9, -Wd / 2), (R, -Wd * .3), (R, Wd * .3),
            (R * .9, Wd / 2), (R * .6, Wd / 2), (R * .6, Wd * .42)]
    mb.lathe(prof, "Rubber", n=n, c=c, axis=RY90, smooth=True)
    mb.push(Matrix.Translation(Vector(c)) @ RY90)
    for sd in (-1, 1):
        pts = [(R * .6 * math.cos(2 * math.pi * k / n), R * .6 * math.sin(2 * math.pi * k / n), sd * Wd * .42)
               for k in range(n)]
        mb.poly(pts if sd > 0 else list(reversed(pts)), rim)
        hub = [(R * .2 * math.cos(2 * math.pi * k / 6), R * .2 * math.sin(2 * math.pi * k / 6), sd * Wd * .45)
               for k in range(6)]
        mb.poly(hub if sd > 0 else list(reversed(hub)), "Metal_Dark")
    mb.pop()


def arch(mb, x, y, r, s=VS, n=9, mat="Plastic_Black"):
    """Dark wheel-arch shadow on the body side behind a wheel (x = body side, sign = outward)."""
    sd = 1 if x > 0 else -1
    R = r + 0.06
    pts = [(x * s, (y + R * math.cos(math.pi * k / n)) * s, (r + R * math.sin(math.pi * k / n)) * s)
           for k in range(n + 1)]
    pts += [(x * s, (y - R) * s, max(0.0, r - 0.12) * s), (x * s, (y + R) * s, max(0.0, r - 0.12) * s)]
    mb.polyo(pts, mat, (sd, 0, 0))


def axle(mb, y, r, w, W, s=VS, dual=False, inset=0.0):
    x = W / 2 - w / 2 + 0.02 - inset
    for sd in (-1, 1):
        arch(mb, sd * (W / 2 + 0.004), y, r, s)
        wheel(mb, sd * x, y, r, w, s)
        if dual:
            wheel(mb, sd * (x - w - 0.02), y, r, w, s)


def siren(name, x, y, z, sx, sy, sz, mat, s=VS):
    return part(name, (x * s, y * s, z * s),
                lambda mb: mb.box((0, 0, sz * s / 2), (sx * s, sy * s, sz * s), mat))


def light_bar(x, y, z, w=1.2, n0=0, mats=("Siren_Red", "Siren_Blue"), s=VS):
    """Roof light bar: dark base in the body, two lens halves as Siren_<n> objects."""
    return [siren("Siren_%d" % (n0 + k), (k - 0.5) * w * 0.5, y, z, w * 0.48, 0.24, 0.12, mats[k], s)
            for k in range(2)]


def front_lights(mb, yf, hw, z, h=0.12, xin=0.45, w=0.3, mat="Light_Head", d=0.12):
    for sd in (-1, 1):
        bx(mb, sd * (hw - xin * 0 - w) if sd > 0 else -hw, yf - 0.01, z, sd * hw if sd > 0 else -hw + w,
           yf + d, z + h, mat)


def lamp_pair(mb, y0, y1, x0, x1, z0, z1, mat):
    for sd in (-1, 1):
        bx(mb, min(sd * x0, sd * x1), y0, z0, max(sd * x0, sd * x1), y1, z1, mat)


# ----------------------------------------------------------------------------- cars

CAR_SHAPES = {
    "sedan": dict(L=4.7, W=1.82, r=0.33, axles=(-1.42, 1.38), tags="XHWGPGBTX", st=[
        (-2.35, .34, .66, .70, .86, .78), (-2.22, .26, .78, .81, .97, .90), (-1.15, .24, .88, .92, 1.0, .92),
        (-0.30, .24, .92, 1.42, 1.0, .80), (0.10, .24, .93, 1.45, 1.0, .80), (0.22, .24, .93, 1.45, 1.0, .80),
        (0.85, .24, .94, 1.41, 1.0, .80), (1.62, .25, .97, 1.00, 1.0, .92), (2.22, .30, .96, .99, .97, .90),
        (2.35, .40, .84, .87, .88, .80)]),
    "hatchback": dict(L=4.1, W=1.76, r=0.31, axles=(-1.3, 1.25), tags="XHWGPGPBX", st=[
        (-2.05, .34, .64, .68, .86, .78), (-1.93, .26, .76, .79, .97, .90), (-1.05, .24, .88, .92, 1.0, .92),
        (-0.25, .24, .92, 1.44, 1.0, .80), (0.12, .24, .93, 1.47, 1.0, .80), (0.24, .24, .93, 1.47, 1.0, .80),
        (1.20, .25, .95, 1.44, 1.0, .80), (1.55, .26, .96, 1.40, 1.0, .79), (1.93, .30, .97, 1.02, .98, .90),
        (2.05, .40, .88, .91, .90, .82)]),
    "suv": dict(L=4.8, W=1.95, r=0.38, axles=(-1.45, 1.42), tags="XHWGPGPGBX", st=[
        (-2.40, .45, .86, .90, .88, .80), (-2.27, .38, .98, 1.01, .97, .90), (-1.35, .36, 1.08, 1.12, 1.0, .92),
        (-0.55, .36, 1.12, 1.76, 1.0, .84), (-0.05, .36, 1.13, 1.78, 1.0, .84), (0.07, .36, 1.13, 1.78, 1.0, .84),
        (1.25, .36, 1.14, 1.78, 1.0, .84), (1.45, .36, 1.14, 1.78, 1.0, .84), (2.15, .38, 1.14, 1.74, 1.0, .83),
        (2.30, .40, 1.10, 1.14, .98, .90), (2.40, .48, 1.00, 1.04, .92, .82)]),
    "coupe": dict(L=4.5, W=1.86, r=0.33, axles=(-1.38, 1.32), tags="XHWGBTX", st=[
        (-2.25, .32, .60, .64, .86, .78), (-2.12, .24, .72, .75, .97, .90), (-0.95, .22, .84, .88, 1.0, .92),
        (-0.15, .22, .88, 1.28, 1.0, .76), (0.45, .22, .90, 1.30, 1.0, .76), (1.65, .24, .95, 1.00, 1.0, .90),
        (2.15, .30, .94, .97, .97, .90), (2.25, .40, .82, .85, .88, .80)]),
    "van": dict(L=5.3, W=2.0, r=0.35, axles=(-1.75, 1.75), tags="XHWGPX", st=[
        (-2.65, .40, .80, .84, .88, .80), (-2.50, .34, .95, .98, .97, .90), (-1.85, .33, 1.10, 1.14, 1.0, .92),
        (-1.05, .33, 1.15, 2.02, 1.0, .90, .05), (-0.45, .33, 1.15, 2.05, 1.0, .90, .05),
        (2.55, .33, 1.15, 2.05, 1.0, .90, .05), (2.65, .40, 1.10, 1.99, .97, .88, .05)]),
    "minibus": dict(L=5.3, W=2.0, r=0.35, axles=(-1.75, 1.75), tags="XHWGPGX", st=[
        (-2.65, .40, .80, .84, .88, .80), (-2.50, .34, .95, .98, .97, .90), (-1.85, .33, 1.10, 1.14, 1.0, .92),
        (-1.05, .33, 1.15, 2.02, 1.0, .90, .05), (-0.25, .33, 1.15, 2.05, 1.0, .90, .05),
        (-0.1, .33, 1.15, 2.05, 1.0, .90, .05), (2.55, .33, 1.15, 2.05, 1.0, .90, .05),
        (2.65, .40, 1.10, 1.99, .97, .88, .05)]),
    "pickup": dict(L=5.4, W=1.95, r=0.38, axles=(-1.7, 1.6), tags="XHWGPGB", st=[
        (-2.70, .45, .86, .90, .88, .80), (-2.57, .38, 1.00, 1.03, .97, .90), (-1.40, .36, 1.10, 1.14, 1.0, .92),
        (-0.65, .36, 1.13, 1.82, 1.0, .85), (-0.12, .36, 1.14, 1.85, 1.0, .85), (0.0, .36, 1.14, 1.85, 1.0, .85),
        (0.52, .36, 1.14, 1.83, 1.0, .85), (0.62, .36, 1.14, 1.18, 1.0, .92)]),
}


def car(c, shape="sedan", paint="Paint_blue", lower=None, roof=None, taxi=False, police=False):
    mb = c.mb
    sp = CAR_SHAPES[shape]
    L, W, r = sp["L"], sp["W"], sp["r"]
    st = sp["st"]
    mats = {"body": paint}
    if lower:
        mats["lower"] = lower
    if roof:
        mats["roof"] = roof
    body_loft(mb, st, sp["tags"], W, mats)
    yf, yr = st[0][0], st[-1][0]
    hwf = W / 2 * st[0][4]
    zf0, zf1 = st[0][1], st[0][3]
    # front: grille, lamps, plate, bumper
    bx(mb, -hwf * .55, yf - .012, zf0 + .04, hwf * .55, yf + .1, zf0 + .04 + (zf1 - zf0) * .45, "Plastic_Black")
    for sd in (-1, 1):
        bx(mb, sd * hwf * .58, yf - .012, zf1 - .14, sd * hwf * .96, yf + .12, zf1 - .03, "Light_Head")
        mb.box((sd * hwf * 0.8 * VS, (yf + 0.05) * VS, (zf0 + 0.08) * VS), (0.2 * VS, 0.12 * VS, 0.06 * VS),
               "Light_Amber")
    bx(mb, -.26, yf - .02, zf0 + .02, .26, yf + .02, zf0 + .13, "Sign_White")
    # rear
    if shape != "pickup":
        hwr = W / 2 * st[-1][4]
        zr0, zr1 = st[-1][1], st[-1][3]
        for sd in (-1, 1):
            bx(mb, sd * hwr * .62, yr - .1, zr1 - .16, sd * hwr * .97, yr + .012, zr1 - .03, "Light_Tail")
        bx(mb, -.26, yr - .02, zr0 + .1, .26, yr + .015, zr0 + .21, "Sign_White")
        bx(mb, -hwr * .9, yr - .05, zr0 - .02, hwr * .9, yr + .03, zr0 + .08, "Plastic_Black")
    # mirrors at the windscreen base
    iw = sp["tags"].index("W")
    ym, zm = st[iw][0] + 0.25, st[iw][2] + 0.05
    for sd in (-1, 1):
        bx(mb, sd * W / 2 * 0.98, ym, zm, sd * (W / 2 + 0.14), ym + 0.1, zm + 0.12, paint)
    # door handles / shut lines suggestion: thin dark strip along the belt
    for sd in (-1, 1):
        x = sd * (W / 2 + 0.004)
        bx(mb, x - 0.004, st[2][0] + 0.2, st[3][2] - 0.04, x + 0.004, st[-2][0] - 0.25, st[3][2] - 0.02,
           "Chrome" if shape in ("sedan", "coupe") else "Plastic_Black")
    if shape == "pickup":
        yb0, yb1 = st[-1][0], L / 2
        hw = W / 2
        bx(mb, -hw, yb0, .36, hw, yb1, .62, paint)  # bed underbody
        bx(mb, -hw + .06, yb0, .62, hw - .06, yb1 - .06, .66, "Plastic_Black")  # bed liner
        for sd in (-1, 1):
            bx(mb, min(sd * hw, sd * (hw - .06)), yb0, .62, max(sd * hw, sd * (hw - .06)), yb1, 1.14, paint)
        bx(mb, -hw + .06, yb1 - .06, .62, hw - .06, yb1, 1.14, paint)
        bx(mb, -hw, yb0 + .02, 1.14, hw, yb0 + .08, 1.2, "Plastic_Black")
        for sd in (-1, 1):
            bx(mb, sd * hw * .62, yb1 - .01, .92, sd * hw * .96, yb1 + .012, 1.1, "Light_Tail")
        bx(mb, -hw * .95, yb1, .3, hw * .95, yb1 + .08, .45, "Chrome")
    if shape in ("van", "minibus"):
        hwr = W / 2 * st[-1][4]
        bx(mb, -hwr * .85, yr - .01, 1.35, -0.03, yr + .015, 1.85, "Glass_Car")
        bx(mb, 0.03, yr - .01, 1.35, hwr * .85, yr + .015, 1.85, "Glass_Car")
    for y in sp["axles"]:
        axle(mb, y, r, 0.24, W)
    zroof = max(s_[3] for s_ in st) + 0.05
    iroof = [s_[3] for s_ in st].index(max(s_[3] for s_ in st))
    yroof = st[iroof][0]
    if taxi:
        bx(mb, -.32, yroof - .12, zroof - .02, .32, yroof + .12, zroof + .04, "Plastic_Black")
        bx(mb, -.28, yroof - .09, zroof + .04, .28, yroof + .09, zroof + .24, "Sign_Taxi")
        for sd in (-1, 1):
            for k in range(8):
                y0 = st[2][0] + 0.25 + k * 0.28
                bx(mb, sd * (W / 2 + .003) - .006, y0, .6, sd * (W / 2 + .003) + .006, y0 + .14, .7,
                   "Plastic_Black" if k % 2 == 0 else "Sign_White")
    if police:
        bx(mb, -.6, yroof - .14, zroof - .02, .6, yroof + .14, zroof + .04, "Metal_Dark")
        light_bar(0, yroof, zroof + 0.04, w=1.2)
        for sd in (-1, 1):
            bx(mb, sd * (W / 2 + .003) - .006, st[2][0] + 0.3, .62, sd * (W / 2 + .003) + .006, st[-2][0] - .4, .72,
               "Sign_Blue")
    finish(c, shape)


# ----------------------------------------------------------------------------- heavy vehicles

def cab_over(mb, y0, W, Lc, paint, roof=2.6, belt=1.32, z0=0.5, crew=False, mats=None):
    if crew:
        st = [(y0, z0 + .05, belt - .07, belt - .02, .96, .9, .02), (y0 + .16, z0, belt, roof, .99, .95, .14),
              (y0 + .95, z0, belt, roof, 1, .95, .14), (y0 + 1.1, z0, belt, roof, 1, .95, .14),
              (y0 + Lc - .25, z0, belt, roof, 1, .95, .14), (y0 + Lc, z0, belt, roof, 1, .95, .14)]
        tags = "WGPGP"
    else:
        st = [(y0, z0 + .05, belt - .07, belt - .02, .96, .9, .02), (y0 + .16, z0, belt, roof, .99, .95, .14),
              (y0 + Lc * .55, z0, belt, roof, 1, .95, .14), (y0 + Lc, z0, belt, roof, 1, .95, .14)]
        tags = "WGP"
    m = {"body": paint}
    m.update(mats or {})
    body_loft(mb, st, tags, W, m, crown=0.05)
    hw = W / 2 * .96
    bx(mb, -hw * .7, y0 - .015, z0 + .25, hw * .7, y0 + .1, belt - .15, "Plastic_Black")
    for sd in (-1, 1):
        bx(mb, sd * hw * .72, y0 - .015, z0 + .3, sd * hw * .97, y0 + .1, z0 + .48, "Light_Head")
        bx(mb, sd * hw * .76, y0 - .015, z0 + .52, sd * hw * .97, y0 + .1, z0 + .62, "Light_Amber")
        bx(mb, sd * W / 2, y0 + .45, belt + .1, sd * (W / 2 + .22), y0 + .55, belt + .6, "Metal_Dark")
    bx(mb, -W / 2, y0 - .06, z0 - .15, W / 2, y0 + .12, z0 + .12, "Metal_Dark")
    return st


def chassis(mb, y0, y1, W, z=0.55):
    bx(mb, -W * .3, y0, z - .12, W * .3, y1, z + .12, "Metal_Dark")


def truck(c, box="Metal_White", paint="Paint_white", stripe="Sign_Blue"):
    mb = c.mb
    L, W = 8.0, 2.5
    y0 = -L / 2
    cab_over(mb, y0, W, 2.0, paint)
    chassis(mb, y0 + .5, L / 2 - .2, W)
    yb = y0 + 2.15
    bx(mb, -W / 2, yb, 1.0, W / 2, L / 2, 3.6, box, mats={"-y": "Metal_White"})
    bx(mb, -W / 2 - .01, yb + .3, 2.6, -W / 2, L / 2 - .3, 3.0, stripe)
    bx(mb, W / 2, yb + .3, 2.6, W / 2 + .01, L / 2 - .3, 3.0, stripe)
    for sd in (-1, 1):
        bx(mb, sd * W / 2 * .55 - .5, L / 2, 1.1, sd * W / 2 * .55 + .5, L / 2 + .02, 3.5, "Metal_White")
        bx(mb, sd * W / 2 * .8, L / 2 - .05, .7, sd * W / 2 * .95, L / 2 + .03, .9, "Light_Tail")
        mb.cyl((sd * W * .34 * VS, (y0 + 2.6) * VS, .55 * VS), .3 * VS, .9 * VS, "Chrome", n=10, axis=RX90)
        bx(mb, sd * W / 2 * .96, y0 + 3.4, .55, sd * W / 2 * .99, L / 2 - 2.3, .65, "Metal_Galv")
    bx(mb, -W / 2 + .05, L / 2 - .05, .45, W / 2 - .05, L / 2 + .05, .6, "Metal_Dark")
    axle(mb, y0 + 1.05, .5, .32, W)
    axle(mb, L / 2 - 1.7, .5, .32, W, dual=True)
    finish(c, "truck")


def garbage_truck(c):
    mb = c.mb
    L, W = 9.0, 2.5
    y0 = -L / 2
    cab_over(mb, y0, W, 2.0, "Paint_white", mats={"lower": "Paint_garbage"})
    chassis(mb, y0 + .5, L / 2 - .5, W)
    yb, ye = y0 + 2.15, L / 2 - 1.4
    hw = W / 2
    ring_loft(mb, [(yb, rbox(hw, 1.0, 3.3, .45)), (ye, rbox(hw, 1.0, 3.3, .45))], "Paint_garbage")
    ring_loft(mb, [(ye, rbox(hw, 0.85, 3.25, .5)), (L / 2, rbox(hw, 0.7, 2.3, .4))], "Paint_garbage",
              cap_mat="Metal_Dark")
    for sd in (-1, 1):
        bx(mb, sd * hw - .01 if sd < 0 else hw, yb + .2, 1.5, sd * hw if sd < 0 else hw + .01, ye - .2, 1.7,
           "Reflective_White")
        bx(mb, sd * hw * .75, L / 2, .8, sd * hw * .95, L / 2 + .05, 1.0, "Light_Tail")
        bx(mb, sd * hw * .5 - .08, ye + .6, 3.2, sd * hw * .5 + .08, ye + .9, 3.5, "Light_Amber")
    bx(mb, -hw * .8, L / 2 - .1, .9, hw * .8, L / 2 + .25, 1.3, "Metal_Galv")  # bin lifter
    bx(mb, -hw * .8, L / 2 + .2, .5, hw * .8, L / 2 + .3, .95, "Metal_Dark")
    axle(mb, y0 + 1.05, .5, .32, W)
    axle(mb, L / 2 - 2.3, .5, .32, W, dual=True)
    finish(c, "garbage_truck")


def firetruck(c):
    mb = c.mb
    L, W = 9.6, 2.5
    y0 = -L / 2
    cab_over(mb, y0, W, 2.7, "Paint_fire", roof=2.7, crew=True, mats={"roof": "Paint_white"})
    chassis(mb, y0 + .5, L / 2 - .2, W)
    yb = y0 + 2.8
    hw = W / 2
    bx(mb, -hw, yb, .7, hw, L / 2, 2.75, "Paint_fire", mats={"+z": "Steel_White"})
    # equipment lockers (roller shutters) and a reflective stripe
    for sd in (-1, 1):
        x = sd * hw
        for k in range(3):
            ya = yb + .25 + k * 1.95
            bx(mb, min(x, x + sd * .02), ya, 1.05, max(x, x + sd * .02), ya + 1.7, 2.6, "Shutter_Alu")
        bx(mb, min(x, x + sd * .025), yb, .8, max(x, x + sd * .025), L / 2, .95, "Reflective_White")
        bx(mb, min(sd * (hw + .01), sd * (hw + .025)), y0 + .2, .62, max(sd * (hw + .01), sd * (hw + .025)),
           y0 + 2.7, .74, "Reflective_White")
        bx(mb, sd * hw * .75, L / 2, .9, sd * hw * .95, L / 2 + .04, 1.15, "Light_Tail")
    # ladder on the roof, turntable at the rear
    zl = 3.0
    for sd in (-1, 1):
        bx(mb, sd * .5 - .05, y0 + .4, zl, sd * .5 + .05, L / 2 - .4, zl + .16, "Metal_Galv")
        bx(mb, sd * .7 - .06, L / 2 - 1.6, 2.75, sd * .7 + .06, L / 2 - 1.3, zl + .05, "Metal_Galv")
        bx(mb, sd * .6 - .05, y0 + .6, 2.7, sd * .6 + .05, y0 + .8, zl + .02, "Metal_Galv")
    n = 22
    for k in range(n):
        yy = y0 + .6 + k * (L - 1.2) / (n - 1)
        bx(mb, -.45, yy - .03, zl + .05, .45, yy + .03, zl + .1, "Metal_Galv")
    mb.cyl((0, (L / 2 - 1.45) * VS, 2.75 * VS), .75 * VS, .2 * VS, "Metal_Dark", n=14)
    axle(mb, y0 + 1.3, .52, .34, W)
    axle(mb, L / 2 - 1.9, .52, .34, W, dual=True)
    light_bar(0, y0 + .5, 2.7 + .16, w=1.6, mats=("Siren_Red", "Siren_Red"))
    for k, sd in enumerate((-1, 1)):
        siren("Siren_%d" % (2 + k), sd * (hw - .2), L / 2 - .25, 2.75, .25, .25, .2,
              "Siren_Blue" if k else "Siren_Red")
    finish(c, "firetruck")


def ambulance(c):
    mb = c.mb
    W, Wb = 2.05, 2.3
    st = [(-3.1, .40, .80, .84, .88, .80), (-2.95, .34, .95, .98, .97, .90), (-2.3, .33, 1.10, 1.14, 1.0, .92),
          (-1.55, .33, 1.15, 2.0, 1.0, .90, .05), (-0.9, .33, 1.15, 2.02, 1.0, .90, .05)]
    body_loft(mb, st, "XHWG", W, {"body": "Paint_white"})
    yf, hwf = -3.1, W / 2 * .88
    bx(mb, -hwf * .55, yf - .012, .44, hwf * .55, yf + .1, .62, "Plastic_Black")
    for sd in (-1, 1):
        bx(mb, sd * hwf * .58, yf - .012, .66, sd * hwf * .96, yf + .12, .8, "Light_Head")
        bx(mb, sd * W / 2 * .98, -2.1, 1.2, sd * (W / 2 + .16), -2.0, 1.36, "Paint_white")
    bx(mb, -.26, yf - .02, .42, .26, yf + .02, .53, "Sign_White")
    hb = Wb / 2
    yb0, yb1 = -1.0, 3.1
    ring_loft(mb, [(yb0, rbox(hb, .45, 2.85, .12)), (yb1, rbox(hb, .45, 2.85, .12))], "Paint_white")
    for sd in (-1, 1):
        x = sd * hb
        bx(mb, min(x, x + sd * .015), yb0, 1.0, max(x, x + sd * .015), yb1, 1.3, "Sign_Red")
        bx(mb, min(x, x + sd * .015), yb0, 1.3, max(x, x + sd * .015), yb1, 1.42, "Paint_yellow")
        bx(mb, min(x, x + sd * .012), .2, 1.6, max(x, x + sd * .012), 1.4, 2.3, "Glass_Car")
        bx(mb, sd * hb * .6, yb1, .7, sd * hb * .9, yb1 + .03, 1.0, "Light_Tail")
        bx(mb, sd * .05, yb1, 1.6, sd * hb * .8, yb1 + .02, 2.4, "Glass_Car")
    bx(mb, -hb, yb1, 1.0, hb, yb1 + .016, 1.3, "Sign_Red")
    for y in (-2.0, 2.0):
        axle(mb, y, .36, .26, W)
    light_bar(0, -1.25, 2.12, w=1.4)
    for k, sd in enumerate((-1, 1)):
        siren("Siren_%d" % (2 + k), sd * (hb - .15), yb1 - .2, 2.85, .2, .2, .14,
              "Siren_Red" if k else "Siren_Blue")
    finish(c, "ambulance")


def bus(c, paint="Paint_red", band="Paint_white"):
    mb = c.mb
    L, W = 12.0, 2.55
    y0 = -L / 2
    st = [(y0, .40, .95, 1.0, .97, .95, .05), (y0 + .16, .32, 1.0, 2.62, 1, .985, .4),
          (L / 2 - .25, .32, 1.0, 2.62, 1, .985, .4), (L / 2, .38, 1.0, 2.55, .98, .965, .4)]
    body_loft(mb, st, "WGP", W, {"body": paint, "band": band, "roof": band, "cap": paint}, crown=0.06)
    hw = W / 2
    # window pillars, kerb-side doors (-X), destination sign, lights
    for sd in (-1, 1):
        x = sd * hw * .995
        for k in range(9):
            yy = y0 + 1.4 + k * 1.3
            if sd < 0 and (abs(yy - (y0 + .9)) < .8 or abs(yy - .2) < .8):
                continue
            bx(mb, min(x, x + sd * .03), yy - .05, 1.0, max(x, x + sd * .03), yy + .05, 2.62, "Plastic_Black")
    for yd in (y0 + .9, 0.2):
        bx(mb, -hw - .02, yd - .65, .35, -hw + .02, yd + .65, 2.6, "Glass_Car")
        bx(mb, -hw - .03, yd - .02, .35, -hw + .02, yd + .02, 2.6, "Metal_Dark")
    bx(mb, -hw * .8, y0 - .05, 2.62, hw * .8, y0 + .12, 2.92, "Sign_Dest")
    for sd in (-1, 1):
        bx(mb, sd * hw * .65, y0 - .015, .5, sd * hw * .95, y0 + .1, .68, "Light_Head")
        bx(mb, sd * hw * .7, L / 2 - .05, .6, sd * hw * .95, L / 2 + .015, 1.0, "Light_Tail")
        bx(mb, sd * hw, y0 + .3, 2.0, sd * (hw + .25), y0 + .4, 2.5, "Metal_Dark")
    bx(mb, -hw * .6, y0 - .015, .45, hw * .6, y0 + .1, .85, "Metal_Dark")
    bx(mb, -hw * .8, L / 2 - 2.2, 3.06, hw * .8, L / 2 - .3, 3.3, band)  # roof HVAC / engine pod
    axle(mb, y0 + 2.6, .5, .3, W)
    axle(mb, L / 2 - 3.3, .5, .3, W, dual=True)
    finish(c, "bus")


# ----------------------------------------------------------------------------- boats (tile scale, M)

def hull(mb, stations, mats, s=M):
    """Hull lofted bow -> stern. stations: (y, half_beam, draft, deck_z). Waterline at z=0."""
    rings = []
    for y, hb, d, dz in stations:
        pts = [(0.0, -d), (-hb * .55, -d * .8), (-hb * .93, -0.02), (-hb * .96, 0.12), (-hb, dz), (hb, dz),
               (hb * .96, 0.12), (hb * .93, -0.02), (hb * .55, -d * .8)]
        rings.append([(x * s, y * s, z * s) for x, z in pts])
    seg = {0: "anti", 1: "anti", 2: "boot", 3: "hull", 4: "deck", 5: "hull", 6: "boot", 7: "anti", 8: "anti"}

    def matfn(k, i):
        return mats[seg[i]]
    mb.loft(rings, matfn, smooth=False, cap_start=True, cap_end=True, cap_mat=mats.get("transom", mats["hull"]))


def rail(mb, pts, z, h=0.9, mat="Metal_White", s=M, step=1.2):
    for (a, b) in zip(pts[:-1], pts[1:]):
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(1, int(L / step))
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        mb.box(((a[0] + b[0]) / 2 * s, (a[1] + b[1]) / 2 * s, (z + h) * s), (L * s, .06 * s, .06 * s), mat, rz=ang)
        for k in range(n + 1):
            t = k / n
            mb.box(((a[0] + (b[0] - a[0]) * t) * s, (a[1] + (b[1] - a[1]) * t) * s, (z + h / 2) * s),
                   (.05 * s, .05 * s, h * s), mat)


def boat_fishing(c):
    mb = c.mb
    s = M
    st = [(-7.0, .12, .4, 3.0), (-6.4, 1.0, 1.0, 2.8), (-5.0, 1.9, 1.5, 2.5), (-2.5, 2.3, 1.7, 2.2),
          (2.0, 2.35, 1.7, 2.0), (5.5, 2.2, 1.4, 2.0), (7.0, 1.95, 1.0, 2.0)]
    hull(mb, st, {"anti": "Hull_Red", "boot": "Hull_White", "hull": "Hull_Navy", "deck": "Deck_Grey"})
    # bulwark
    for sd in (-1, 1):
        mb.box((sd * 2.28 * s, 1.5 * s, 2.45 * s), (.1 * s, 11.0 * s, .9 * s), "Hull_Navy")
    # wheelhouse
    bx(mb, -1.6, -3.6, 2.4, 1.6, -0.2, 4.5, "Hull_White", s=s)
    bx(mb, -1.65, -3.65, 3.6, 1.65, -0.15, 4.4, "Glass_Car", s=s, skip=("+z", "-z"))
    bx(mb, -1.8, -3.9, 4.5, 1.8, 0.1, 4.7, "Hull_White", s=s)
    bx(mb, -1.2, -1.2, 2.2, 1.2, 1.4, 3.6, "Hull_White", s=s)
    # mast with radar, gantry and net drum at the stern
    mb.cyl((0, -2.0 * s, 4.7 * s), .1 * s, 4.0 * s, "Metal_White", n=8)
    bx(mb, -.9, -2.1, 7.0, .9, -1.9, 7.15, "Metal_Dark", s=s)
    bx(mb, -.6, -2.6, 5.4, .6, -2.3, 5.6, "Metal_White", s=s)
    for sd in (-1, 1):
        mb.box((sd * 2.0 * s, 6.3 * s, 4.0 * s), (.25 * s, .25 * s, 4.0 * s), "Plastic_Orange")
    bx(mb, -2.1, 6.2, 5.9, 2.1, 6.45, 6.2, "Plastic_Orange", s=s)
    mb.cyl((-1.2 * s, 4.2 * s, 3.2 * s), .9 * s, 2.4 * s, "Fabric_Green", n=12, axis=RY90)
    mb.cyl((-1.3 * s, 4.2 * s, 3.2 * s), 1.1 * s, .1 * s, "Metal_Dark", n=12, axis=RY90)
    mb.cyl((1.2 * s, 4.2 * s, 3.2 * s), 1.1 * s, .1 * s, "Metal_Dark", n=12, axis=RY90)
    for k in range(3):
        bx(mb, -1.4 + k * 1.0, 1.8, 2.0, -0.6 + k * 1.0, 2.6, 2.6, ("Container_Blue", "Container_Orange",
                                                                     "Container_Blue")[k], s=s)
    rail(mb, [(-1.5, -6.0), (0, -6.8), (1.5, -6.0)], 2.9, h=.8)
    finish(c, "boat_fishing")


def boat_tug(c):
    mb = c.mb
    s = M
    st = [(-6.2, .4, .6, 2.6), (-5.6, 1.7, 1.3, 2.4), (-4.0, 2.5, 1.9, 2.1), (-1.0, 2.7, 2.1, 1.8),
          (3.0, 2.7, 2.0, 1.6), (5.3, 2.4, 1.6, 1.6), (6.2, 1.8, 1.0, 1.6)]
    hull(mb, st, {"anti": "Hull_Red", "boot": "Hull_White", "hull": "Hull_Black", "deck": "Deck_Grey"})
    # tyre fenders along the sheer and a bow pudding fender
    for sd in (-1, 1):
        for k in range(6):
            y = -3.8 + k * 1.6
            mb.cyl((sd * 2.72 * s, y * s, 0.9 * s), .45 * s, .35 * s, "Rubber", n=10,
                   axis=Matrix.Rotation(sd * math.pi / 2, 4, "Y") @ Matrix.Translation(Vector((0, 0, -.17 * s))))
    mb.cyl((0, -6.0 * s, 1.6 * s), .55 * s, 2.0 * s, "Rubber", n=10, axis=RY90 @ Matrix.Translation(
        Vector((0, 0, -1.0 * s))))
    # two-tier superstructure, wheelhouse with all-round glazing, funnel, mast
    bx(mb, -2.0, -2.8, 1.8, 2.0, 2.4, 4.0, "Hull_White", s=s)
    bx(mb, -1.5, -2.6, 4.0, 1.5, 0.4, 6.0, "Hull_White", s=s)
    bx(mb, -1.55, -2.65, 4.9, 1.55, 0.45, 5.8, "Glass_Car", s=s, skip=("+z", "-z"))
    bx(mb, -1.8, -2.9, 6.0, 1.8, 0.7, 6.2, "Hull_White", s=s)
    bx(mb, -2.05, -2.85, 3.0, 2.05, 2.45, 3.3, "Glass_Car", s=s, skip=("+z", "-z"))
    mb.cyl((0, 1.6 * s, 4.0 * s), .65 * s, 2.6 * s, "Metal_Yellow", n=12)
    mb.cyl((0, 1.6 * s, 6.6 * s), .66 * s, .5 * s, "Hull_Black", n=12)
    mb.cyl((0, -1.0 * s, 6.2 * s), .1 * s, 3.0 * s, "Metal_White", n=8)
    bx(mb, -1.0, -1.1, 8.4, 1.0, -.9, 8.55, "Metal_Dark", s=s)
    # towing hook / bitts on the after deck
    for x in (-.8, .8):
        mb.cyl((x * s, 4.5 * s, 1.6 * s), .25 * s, .8 * s, "Metal_Dark", n=8)
    rail(mb, [(-2.5, 2.6), (-2.5, 5.8), (2.5, 5.8), (2.5, 2.6)], 1.6, h=.7)
    finish(c, "boat_tug")


def boat_speed(c):
    mb = c.mb
    s = M
    st = [(-5.5, .1, .3, 1.7), (-5.0, .7, .6, 1.55), (-3.5, 1.35, .75, 1.35), (-1.0, 1.6, .7, 1.2),
          (3.0, 1.6, .55, 1.1), (5.5, 1.5, .4, 1.1)]
    hull(mb, st, {"anti": "Hull_White", "boot": "Hull_Navy", "hull": "Hull_White", "deck": "Hull_White",
                  "transom": "Hull_White"})
    # cockpit tub, windscreen, seats, teak sun deck, outboards
    bx(mb, -1.2, -0.6, 1.0, 1.2, 3.6, 1.18, "Deck_Teak", s=s)
    mb.push(Matrix.Translation(Vector((0, -1.2 * s, 1.2 * s))) @ Matrix.Rotation(math.radians(-35), 4, "X"))
    mb.box((0, 0, .35 * s), (2.6 * s, .05 * s, .7 * s), "Glass_Car")
    mb.pop()
    for x in (-.6, .6):
        bx(mb, x - .4, .2, 1.18, x + .4, .9, 1.6, "Fabric_Cream", s=s)
        bx(mb, x - .4, .8, 1.6, x + .4, .95, 2.1, "Fabric_Cream", s=s)
    bx(mb, -1.3, 2.2, 1.18, 1.3, 3.4, 1.55, "Fabric_Cream", s=s)
    for x in (-.5, .5):
        bx(mb, x - .3, 5.5, 0.4, x + .3, 6.1, 1.6, "Plastic_Black", s=s)
        bx(mb, x - .08, 5.6, -0.6, x + .08, 5.9, 0.4, "Metal_Dark", s=s)
    rail(mb, [(-1.3, -2.0), (-.6, -4.4), (0, -5.0), (.6, -4.4), (1.3, -2.0)], 1.4, h=.45, mat="Chrome", step=2.5)
    finish(c, "boat_speed")


# ----------------------------------------------------------------------------- aircraft

def _airfoil(x, y_le, c, z, t=0.11):
    """Section ring in the YZ plane (TE -> top -> LE -> bottom), for lofting along +X."""
    return [(x, y_le + c, z), (x, y_le + c * .6, z + c * t * .55), (x, y_le + c * .25, z + c * t * .5),
            (x, y_le + c * .05, z + c * t * .25), (x, y_le, z), (x, y_le + c * .08, z - c * t * .2),
            (x, y_le + c * .35, z - c * t * .25), (x, y_le + c * .7, z - c * t * .12)]


def _fin_sec(z, y_le, c, t=0.1):
    """Section ring in the XY plane (LE -> right -> TE -> left), for lofting along +Z."""
    return [(0, y_le, z), (c * t * .5, y_le + c * .3, z), (c * t * .25, y_le + c * .75, z), (0, y_le + c, z),
            (-c * t * .25, y_le + c * .75, z), (-c * t * .5, y_le + c * .3, z)]


def _scaled(rings, s):
    return [[(p[0] * s, p[1] * s, p[2] * s) for p in r] for r in rings]


def wing_pair(mb, x0, x1, y_root, c_root, y_tip, c_tip, z0, z1, mat, s, t=0.11):
    for sd in (-1, 1):
        a = _airfoil(sd * x0, y_root, c_root, z0, t)
        b = _airfoil(sd * x1, y_tip, c_tip, z1, t)
        rings = [a, b] if sd > 0 else [b, a]
        mb.loft(_scaled(rings, s), lambda k, i: mat, smooth=False)


def plane(c):
    mb = c.mb
    s = 0.9 * M
    R = 1.5
    prof = [(0.0, -15.0), (0.55, -14.75), (0.95, -14.2), (1.25, -13.4), (1.42, -12.4), (1.5, -11.0),
            (1.5, 7.0), (1.38, 9.5), (1.05, 12.0), (0.6, 14.0), (0.25, 15.2), (0.0, 15.4)]
    mb.lathe([(r * s, y * s) for r, y in prof], "Plane_White", n=20, axis=RX90, smooth=True)
    # cockpit visor: a slightly proud band over the upper nose (angles about local Z, top = -90 deg)
    vis = [(r * 1.012 * s, y * s) for r, y in prof[2:5]]
    mb.lathe(vis, "Plane_Window", n=8, axis=RX90, a0=math.radians(-150), a1=math.radians(-30), smooth=True)
    # cabin windows
    for sd in (-1, 1):
        for k in range(24):
            y = -10.2 + k * 0.78
            mb.box((sd * R * 0.985 * s, y * s, 0.4 * s), (0.05 * s, 0.32 * s, 0.4 * s), "Plane_Window")
        mb.box((sd * R * 0.99 * s, -11.6 * s, 0.0), (0.04 * s, 0.85 * s, 1.7 * s), "Plane_Grey")
    # belly fairing, wings, engines, tail
    mb.sphere((0, 0.5 * s, -1.05 * s), 1.0 * s, "Plane_White", n=12, rings=6, scale=(1.5, 5.0, 0.6))
    wing_pair(mb, 1.2, 13.0, -2.4, 5.8, 3.6, 1.6, -0.9, -0.1, "Plane_Grey", s, t=0.12)
    for sd in (-1, 1):
        mb.box((sd * 13.05 * s, 4.3 * s, 0.1 * s), (0.15 * s, 0.6 * s, 2.0 * s), "Plane_Blue")
        mb.sphere((sd * 13.05 * s, 3.9 * s, -0.1 * s), 0.12 * s, "Light_Tail" if sd < 0 else "Nav_Green", n=6, rings=4)
        ex = sd * 4.6
        eng = [(0.0, -5.0), (0.78, -4.95), (0.92, -4.6), (0.95, -3.4), (0.85, -1.8), (0.6, -1.2), (0.3, -0.9)]
        mb.lathe([(r * s, y * s) for r, y in eng], "Plane_White", n=14, c=(ex * s, 0, -1.65 * s), axis=RX90)
        mb.cyl((ex * s, -4.93 * s, -1.65 * s), 0.74 * s, 0.05 * s, "Metal_Dark", n=14, axis=RX90)
        mb.box((ex * s, -2.0 * s, -1.0 * s), (0.25 * s, 2.6 * s, 0.9 * s), "Plane_Grey")
    for sd in (-1, 1):
        a = _airfoil(sd * 0.4, 11.6, 2.8, 0.6, 0.1)
        b = _airfoil(sd * 5.0, 13.6, 1.2, 1.0, 0.1)
        mb.loft(_scaled([a, b] if sd > 0 else [b, a], s), lambda k, i: "Plane_White", smooth=False)
    fin = [_fin_sec(0.8, 9.6, 5.2, 0.12), _fin_sec(6.8, 13.4, 2.2, 0.12)]
    mb.loft(_scaled(fin, s), lambda k, i: "Plane_Blue", smooth=False)
    mb.sphere((0, 14.4 * s, 6.85 * s), 0.12 * s, "Beacon_Red", n=6, rings=4)
    mb.box((0, -8.0 * s, 1.5 * s), (1.2 * s, 2.6 * s, 0.06 * s), "Plane_Blue")
    # landing gear (wheels touch z = -2.62 m)
    zg = -2.62
    gears = [(0.0, -11.5, 0.38), (-2.4, 1.0, 0.55), (2.4, 1.0, 0.55)]
    for gx, gy, gr in gears:
        mb.cyl((gx * s, gy * s, (zg + gr) * s), 0.08 * s, (-1.2 - zg - gr) * s, "Metal_Galv", n=6)
        for dx in (-0.25, 0.25):
            mb.cyl(((gx + dx - 0.11) * s, gy * s, (zg + gr) * s), gr * s, 0.22 * s, "Rubber", n=10, axis=RY90)
    finish(c, "plane", angle=40)


def helicopter(c):
    mb = c.mb
    s = M

    def sec(y, hw, zc, hh, n=12):
        return (y, [(math.cos(math.radians(270 - 360 * k / n)) * hw, zc + math.sin(math.radians(270 - 360 * k / n)) * hh)
                    for k in range(n)])
    pod = [sec(-3.6, .25, 1.35, .25), sec(-3.3, .6, 1.4, .55), sec(-2.6, .78, 1.45, .75), sec(-1.6, .8, 1.5, .8),
           sec(-0.2, .78, 1.55, .8), sec(0.8, .6, 1.65, .65), sec(1.6, .35, 1.85, .38)]
    canopy = {0, 1, 2}

    def podmat(k, i):
        ang = 270 - 360 * (i + 0.5) / 12
        up = math.sin(math.radians(ang))
        if k in canopy and up > -0.15:
            return "Glass_Car"
        if k == 3 and up > 0.2 and abs(math.cos(math.radians(ang))) > 0.3:
            return "Glass_Car"
        return "Paint_red" if up < 0.25 else "Paint_white"
    rings = [[(x * s, y * s, z * s) for x, z in pts] for y, pts in pod]
    mb.loft(rings, podmat, smooth=False, cap_mat="Paint_red")
    boom = [sec(1.5, .32, 1.95, .32, 8), sec(6.0, .14, 2.05, .16, 8)]
    ring_loft(mb, boom, "Paint_red", s=s)
    bx(mb, -.5, -1.4, 2.05, .5, 1.2, 2.55, "Paint_white", s=s)  # engine cowling
    mb.cyl((0, -0.2 * s, 2.5 * s), .18 * s, .55 * s, "Metal_Dark", n=8)  # mast
    # fin, stabiliser, skids
    mb.loft(_scaled([_fin_sec(1.9, 5.4, 1.1, .14), _fin_sec(3.2, 6.0, 0.7, .14)], s), lambda k, i: "Paint_red",
            smooth=False)
    a = _airfoil(-1.0, 4.9, .6, 2.05, .1)
    b = _airfoil(1.0, 4.9, .6, 2.05, .1)
    mb.loft(_scaled([a, b], s), lambda k, i: "Paint_white", smooth=False)
    for sd in (-1, 1):
        mb.cyl((sd * .95 * s, -3.0 * s, .06 * s), .06 * s, 5.0 * s, "Metal_Galv", n=6, axis=RX90)
        for y in (-1.9, 0.4):
            mb.cyl((sd * .95 * s, y * s, .06 * s), .05 * s, .8 * s, "Metal_Galv", n=6,
                   axis=Matrix.Rotation(sd * math.radians(-30), 4, "Y"))
    mb.sphere((0, -3.55 * s, 0.95 * s), .1 * s, "Lamp_Glow", n=6, rings=4)
    mb.sphere((0, 1.2 * s, 2.6 * s), .1 * s, "Beacon_Red", n=6, rings=4)

    def rotor(m):
        m.cyl((0, 0, 0), .3 * s, .2 * s, "Metal_Dark", n=10)
        for k in range(4):
            a = k * math.pi / 2
            m.box((math.cos(a) * 2.55 * s, math.sin(a) * 2.55 * s, .12 * s), (4.9 * s, .32 * s, .05 * s),
                  "Plastic_Black", rz=a)
    part("Rotor", (0, -0.2 * s, 3.05 * s), rotor)

    def tail_rotor(m):
        m.cyl((-.05 * s, 0, 0), .1 * s, .25 * s, "Metal_Dark", n=8, axis=RY90)
        for k in range(2):
            a = k * math.pi
            m.box((.1 * s, math.cos(a) * .4 * s, math.sin(a) * .4 * s), (.04 * s, .14 * s, .8 * s), "Plastic_Black")
    part("RotorTail", (0.22 * s, 6.0 * s, 2.35 * s), tail_rotor)
    finish(c, "helicopter")


# ----------------------------------------------------------------------------- registry

def _car(shape, paint, **kw):
    return (car, dict(shape=shape, paint=paint, **kw))


REGISTRY = {
    "vehicles/sedan_blue": _car("sedan", "Paint_blue"),
    "vehicles/sedan_silver": _car("sedan", "Paint_silver"),
    "vehicles/sedan_red": _car("sedan", "Paint_darkred"),
    "vehicles/sedan_white": _car("sedan", "Paint_white"),
    "vehicles/hatchback_red": _car("hatchback", "Paint_red"),
    "vehicles/hatchback_white": _car("hatchback", "Paint_white", roof="Paint_black"),
    "vehicles/hatchback_green": _car("hatchback", "Paint_green"),
    "vehicles/suv_black": _car("suv", "Paint_black"),
    "vehicles/suv_grey": _car("suv", "Paint_grey"),
    "vehicles/suv_beige": _car("suv", "Paint_beige"),
    "vehicles/coupe_yellow": _car("coupe", "Paint_yellow"),
    "vehicles/coupe_navy": _car("coupe", "Paint_navy"),
    "vehicles/taxi": _car("sedan", "Paint_yellow", taxi=True),
    "vehicles/van_white": _car("van", "Paint_white"),
    "vehicles/van_minibus": _car("minibus", "Paint_silver"),
    "vehicles/pickup_red": _car("pickup", "Paint_red"),
    "vehicles/pickup_grey": _car("pickup", "Paint_grey"),
    "vehicles/police": _car("sedan", "Paint_white", lower="Paint_navy", police=True),
    "vehicles/bus": (bus, {}),
    "vehicles/truck": (truck, {}),
    "vehicles/garbage_truck": (garbage_truck, {}),
    "vehicles/firetruck": (firetruck, {}),
    "vehicles/ambulance": (ambulance, {}),
    "vehicles/boat_fishing": (boat_fishing, {}),
    "vehicles/boat_tug": (boat_tug, {}),
    "vehicles/boat_speed": (boat_speed, {}),
    "vehicles/plane": (plane, {}),
    "vehicles/helicopter": (helicopter, {}),
}
