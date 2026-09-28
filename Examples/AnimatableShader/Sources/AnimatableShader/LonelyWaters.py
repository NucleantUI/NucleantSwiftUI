# https://www.shadertoy.com/view/NlKGWK

# Decompiled from SPIR-V (glslang 8) by spirv2py.
#
# ShaderToy's clock (`time`) is replaced by `playhead`, a ShaderArgument the
# app animates. The mouse orbit is gone: the pointer is always "pressed" as
# far as a shader here can tell, so the camera would follow it everywhere —
# the tab bar included. The dead anti-aliasing loop after `mainImage`'s early
# return is gone too.
from pyshader import *


scrollDir = float2(1.0)
sunrot = float2(-0.3, -0.25)
spec = 0.13


def wave(wavPos: float2, iters: int, t: float) -> float:
    wav = 0.0
    wavDir = float2(1.0, 0.0)
    wavWeight = 1.0
    wavPos += scrollDir * (t * 1.5)
    wavPos *= 1.1
    wavFreq = 0.6
    wavTime = 1.4 * t
    for i in range(iters):
        wavDir *= float2x2(float2(0.3530194, 0.935616), float2(-0.935616, 0.3530194))
        x = dot(wavDir, wavPos) * wavFreq + wavTime
        wave_1 = exp(sin(x) - 1.0) * wavWeight
        wav += wave_1
        wavFreq *= 1.2
        wavTime *= 1.095
        wavPos -= wavDir * wave_1 * 0.9 * cos(x)
        wavWeight *= 0.8
    return wav / (-(pow(0.8, float(iters)) - 1.0) * 2.5)


def map(p: float3, playhead: float) -> float:
    a = 0.0
    p.y -= wave(p.xz, 9, playhead)
    a = p.y
    return a


def pal(t: float, a: float3, b: float3, c: float3, d: float3) -> float3:
    return a + b * cos((c * t + d) * 6.2831855)


def spc(n: float, bright: float) -> float3:
    return pal(n, float3(bright), float3(0.5), float3(1.0), float3(0.0, 0.33, 0.67))


def sky(rd: float3, playhead: float, resolution: float2) -> float3:
    px = 1.5 / min(resolution.x, resolution.y)
    rdo = rd
    rad = 0.075
    col = float3(0.0)
    rd.yz *= float2x2(float2(cos(sunrot.y), sin(sunrot.y)), float2(-sin(sunrot.y), cos(sunrot.y)))
    rd.xz *= float2x2(float2(cos(sunrot.x), sin(sunrot.x)), float2(-sin(sunrot.x), cos(sunrot.x)))
    sFade = 2.5 / min(resolution.x, resolution.y)
    zFade = rd.z * 0.5 + 0.5
    sc = spc(spec - 0.1, 0.6) * 0.85
    a = length(rd.xy)
    sun = sc * smoothstep(a - px - sFade, a + px + sFade, rad) * zFade * 2.0
    col += sun
    col += sc * (rad / (rad + pow(a, 1.7))) * zFade
    col += mix(col, spc(spec + 0.1, 0.8), saturate(1.0 - length(col))) * 0.2
    e = 0.0
    p = rdo
    p.xz *= 0.4
    p.x += playhead * 0.007
    s = 200.0
    while s > 10.0:
        p.xz *= float2x2(float2(cos(s), sin(s)), float2(-sin(s), cos(s)))
        p += s
        e += abs(dot(sin(p * s + playhead * 0.02) / s, float3(1.65)))
        s *= 0.8
    e *= smoothstep(0.5, 0.4, e - 0.095)
    col += (1.0 - sun * 3.75) * (e * smoothstep(-0.02, 0.3, rdo.y) * 0.8) * mix(sc, float3(1.0), 0.4)
    return col


def wavedx(wavPos: float2, iters: int, t: float) -> float2:
    dx = float2(0.0)
    wavDir = float2(1.0, 0.0)
    wavWeight = 1.0
    wavPos += scrollDir * (t * 1.5)
    wavPos *= 1.1
    wavFreq = 0.6
    wavTime = 1.4 * t
    for i in range(iters):
        wavDir *= float2x2(float2(0.3530194, 0.935616), float2(-0.935616, 0.3530194))
        x = dot(wavDir, wavPos) * wavFreq + wavTime
        result = exp(sin(x) - 1.0) * cos(x)
        result *= wavWeight
        dx += wavDir * result / pow(wavWeight, 0.65)
        wavFreq *= 1.2
        wavTime *= 1.095
        wavPos -= wavDir * result * 0.9
        wavWeight *= 0.8
    return dx / pow(-(pow(0.8, float(iters)) - 1.0) * 2.5, 0.35)


def norm(p: float3, playhead: float) -> float3:
    wav = -wavedx(p.xz, 20, playhead)
    return normalize(float3(wav.x, 1.0, wav.y))


def render(fragCoord: float2, playhead: float, resolution: float2) -> float4:
    uv = (fragCoord - resolution * 0.5) / min(resolution.y, resolution.x)
    col = float3(0.0)
    ro = float3(0.0, 2.475, -3.3)
    f = normalize(float3(0.0, 2.0, 0.0) - ro)
    r = normalize(cross(float3(0.0, 1.0, 0.0), f))
    rd = normalize(f * 0.9 + r * uv.x + cross(f, r) * uv.y)
    dO = 0.0
    hit = False
    d = 0.0
    p = ro
    tPln = -(ro.y - 1.86) / rd.y
    if tPln > 0.0:
        dO += tPln
        i = 0.0
        while i < 80.0:
            p = ro + rd * dO
            d = map(p, playhead)
            dO += d
            if abs(d) < 0.005 or i > 78.0:
                hit = True
                break
            if dO > 35.0:
                dO = 35.0
                break
            i += 1.0
    skyrd = sky(rd, playhead, resolution)
    if hit:
        n = norm(p, playhead)
        rfl = reflect(rd, n)
        rfl.y = abs(rfl.y)
        rf = refract(rd, n, 0.7518797)
        fres = saturate(pow(1.0 - max(0.0, dot(-n, rd)), 5.0))
        sunDir = float3(0.0, 0.15, 1.0)
        sunDir.xz *= float2x2(float2(cos(-sunrot.x), sin(-sunrot.x)), float2(-sin(-sunrot.x), cos(-sunrot.x)))
        col += sky(rfl, playhead, resolution) * fres * 0.9
        subRefract = pow(max(0.0, dot(rf, sunDir)), 35.0)
        col += pow(spc(spec - 0.1, 0.5), float3(2.2)) * subRefract * 2.5
        rd2 = rd
        rd2.xz *= float2x2(float2(cos(sunrot.x), sin(sunrot.x)), float2(-sin(sunrot.x), cos(sunrot.x)))
        waterCol = saturate(spc(spec - 0.1, 0.4)) * (0.4 * pow(min(p.y * 0.7 + 0.9, 1.8), 4.0) * length(skyrd) * (rd2.z * 0.15 + 0.85))
        col += waterCol * 0.17
        col = mix(col, skyrd, dO / 35.0)
    else:
        col += skyrd
    col = saturate(col)
    col = pow(col, float3(0.87))
    col *= 1.0 - 0.8 * pow(length(uv * float2(0.8, 1.0)), 2.7)
    return float4(col, 1.0)


def main(frag_coord: float2, playhead: float, resolution: float2) -> float4:
    return render(frag_coord, playhead, resolution)
