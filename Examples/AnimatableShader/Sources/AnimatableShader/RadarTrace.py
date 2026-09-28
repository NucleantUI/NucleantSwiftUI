# https://www.shadertoy.com/view/lltyWS

# Decompiled from SPIR-V (glslang 8) by spirv2py.
#
# ShaderToy's clock (`time`) is replaced by `playhead`, a ShaderArgument the
# app animates. The scope is centred on the view rather than placed for a
# 16:9 frame, and two no-op expression statements left by the decompile
# are gone.
from pyshader import *


def gradations(a: float, gradNum: float, outRad: float, tickLen: float, tickWidth: float, r: float, move: float) -> float:
    return 1.0 - step(step(0.0, cos((a + move) * gradNum) - tickWidth) * tickLen + (outRad - tickLen), r) * 1.0 - step(r, outRad - tickLen)


def plot(st: float2, pct: float, width: float) -> float:
    return smoothstep(pct - width, pct, st.y) - smoothstep(pct, pct + width, st.y)


def drawPolygon(polygonCenter: float2, N: int, radius: float, pos: float2) -> float:
    pos -= polygonCenter
    d = 0.0
    a = atan2(pos.x, pos.y)
    r = 6.2831855 / float(N)
    d = cos(floor(0.5 + a / r) * r - a) * length(pos)
    return 1.0 - smoothstep(radius, radius + radius / 10.0, d)


def mainImage(fragColor: float4, fragCoord: float2, playhead: float, resolution: float2) -> float4:
    pos = (fragCoord - resolution * 0.5) / resolution.y
    mapcol = float4(0.0, 0.85, 0.0, 1.0)
    color = float3(0.0)
    r = length(pos) * 2.0
    a = atan2(pos.y, pos.x)
    an = 3.1415927 - mod(playhead / 1.0, 6.2831855)
    blipSpd = 3.0
    translate1 = float2(cos(playhead / blipSpd), sin(playhead / blipSpd))
    translate2 = float2(sin(playhead / blipSpd), cos(playhead / blipSpd))
    left1 = translate1 * 0.35
    right1 = -translate1 * 0.3
    left2 = translate2 * 0.15
    right2 = -translate2 * 0.25
    sn = step(1.5707964, an) * step(-1.5707964, a + an) * step(r, 0.95) * (1.0 - 0.55 * (a + 6.2831855 - an))
    sw = step(an, a) * step(r, 0.95)
    s_blade = sw * (1.0 - (a - an) * 20.0)
    s = sw * (1.0 - 0.55 * (a - an))
    s = max(sn, s)
    s1 = smoothstep(0.95, 0.96, r) * smoothstep(0.97, 0.96, r)
    s0 = 1.0 - smoothstep(0.005, 0.01, length(pos))
    smb = (1.0 - smoothstep(0.2, 0.21, length(pos))) * (1.0 - smoothstep(0.21, 0.2, length(pos)))
    smr = (1.0 - smoothstep(0.3, 0.31, length(pos))) * (1.0 - smoothstep(0.31, 0.3, length(pos)))
    gradNum = 120.0
    tickWidth = 0.9
    outRad = 0.95
    move = 0.0
    sm = 0.75 * gradations(a, gradNum, outRad, 0.04, tickWidth, r, move)
    gradNum = 36.0
    tickWidth = 0.95
    outRad = 0.6
    move = sin(playhead / 10.0)
    smr += 0.5 * gradations(a, gradNum, outRad, 0.04, tickWidth, r, move)
    outRad = 0.4
    move = cos(playhead / 10.0)
    smb += 0.5 * gradations(a, gradNum, outRad, 0.04, tickWidth, r, move)
    sr = plot(pos, pos.x, 0.003) * step(r, 0.89)
    sr += plot(float2(0.0), pos.x, 0.002) * step(r, 0.89)
    sr += plot(float2(0.0), pos.y, 0.003) * step(r, 0.89)
    sr += plot(-pos, pos.x, 0.003) * step(r, 0.89)
    sr *= 0.75
    st_trace1 = left2
    s_trace1 = s * (1.0 - smoothstep(0.0025, 0.025, length(pos - st_trace1)))
    s_trace1 += s * (1.0 - smoothstep(0.0025, 0.025, length(pos - st_trace1 + 0.05)))
    s_trace1 += s * (1.0 - smoothstep(0.0025, 0.025, length(pos - st_trace1 + 0.1)))
    s_trace2 = s * (1.0 - smoothstep(0.0025, 0.025, length(pos - right1)))
    st_trace3 = left1
    st1 = s * drawPolygon(st_trace3, 3, 0.015, pos)
    st1 += s * drawPolygon(st_trace3 + -0.05, 3, 0.015, pos)
    st1 += s * drawPolygon(st_trace3 + float2(0.05, -0.05), 3, 0.015, pos)
    st2 = s * drawPolygon(right2, 3, 0.015, pos)
    s_grn = max(s * mapcol.y, s_blade)
    s_grn = max(s_grn, s0 + sr + sm)
    s_grn += s1 / 1.5 + smb + smr
    s_red = st1 * 2.0 + st2 * 2.0 + smr
    s_blue = max(s_trace1 + s_trace2, s_blade) + smb
    if s_trace1 > 0.0 or s_trace2 > 0.0:
        s_blue = max(s, s_blue)
        s_grn = max(s_grn, s_blue)
    color += float3(s_red, s_grn, s_blue)
    return float4(color, 1.0)


def main(frag_coord: float2, playhead: float, resolution: float2) -> float4:
    return mainImage(float4(0.0), frag_coord, playhead, resolution)
