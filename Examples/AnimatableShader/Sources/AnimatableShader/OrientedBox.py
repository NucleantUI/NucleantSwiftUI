# https://www.shadertoy.com/view/stcfzn$0

# Decompiled from SPIR-V (glslang 8) by spirv2py.
#
# ShaderToy's clock (`time`) is replaced by `playhead`, a ShaderArgument the
# app animates: the shader never reads the real clock, so the box only moves
# when the app moves the playhead.
from pyshader import *


def sdOrientedBox(p: float2, a: float2, b: float2, th: float) -> float:
    l = length(b - a)
    d = (b - a) / l
    q = p - (a + b) * 0.5
    q = float2x2(float2(d.x, -d.y), float2(d.y, d.x)) * q
    q = abs(q) - float2(l * 0.5, th)
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0)


def mainImage(fragColor: float4, fragCoord: float2, playhead: float, resolution: float2, mouse: float2, mouse_click: float2) -> float4:
    p = (fragCoord * 2.0 - resolution) / resolution.y
    m = (float4(mouse, mouse_click).xy * 2.0 - resolution) / resolution.y
    px = 2.0 / resolution.y
    v1 = float2(1.0, 0.6) * cos(playhead * 0.5 + float2(0.0, 1.0) + 0.0)
    v2 = float2(1.0, 0.6) * cos(playhead * 0.5 + float2(0.0, 3.0) + 1.5)
    th = 0.3 * (0.5 + 0.5 * cos(playhead * 1.1 + 1.0))
    d = sdOrientedBox(p, v1, v2, th)
    col = float3(0.9, 0.6, 0.3) if d > 0.0 else float3(0.65, 0.85, 1.0)
    col *= 1.0 - exp2(-12.0 * abs(d))
    col *= 0.8 + 0.2 * cos(120.0 * d)
    col = mix(col, float3(1.0), smoothstep(1.5 * px, 0.0, abs(d) - 0.002))
    if float4(mouse, mouse_click).z > 0.001:
        d = sdOrientedBox(m, v1, v2, th)
        col = mix(col, float3(1.0, 1.0, 0.0), smoothstep(1.5 * px, 0.0, min(abs(length(p - m) - abs(d)) - 0.0025, length(p - m) - 0.015)))
    return float4(col, 1.0)


def main(frag_coord: float2, playhead: float, resolution: float2, mouse: float2, mouse_click: float2) -> float4:
    return mainImage(float4(0.0), frag_coord, playhead, resolution, mouse, mouse_click)
