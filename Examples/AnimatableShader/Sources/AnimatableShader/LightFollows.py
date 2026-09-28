# Decompiled from SPIR-V (glslang 8) by spirv2py.
#
# The glow sat in the middle of the view; here it sits at `light`, a
# ShaderArgument the app animates — in pixels from the view's top left,
# the way a tap reports it, and flipped here into y-up shader space.
from pyshader import *


def mainImage(fragColor: float4, fragCoord: float2, resolution: float2, light: float2) -> float4:
    centre = float2(light.x, resolution.y - light.y)
    pos = (centre - fragCoord) / resolution.x
    dist = 1.0 / length(pos)
    dist *= 0.1
    dist = pow(dist, 0.8)
    col = float3(1.0, 0.5, 0.25) * dist
    col = 1.0 - exp(-col)
    return float4(col, 1.0)


def main(frag_coord: float2, resolution: float2, light: float2) -> float4:
    return mainImage(float4(0.0), frag_coord, resolution, light)
