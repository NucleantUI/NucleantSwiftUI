//
//  ShaderLibrary.swift
//  NucleantSwiftUI
//
//  A set of ready-made shaders, the counterpart of TouchBay's `Shaders` target.
//  Most are ports of the sources in `research/TouchBay-UI-SDK/Sources/Shaders`,
//  themselves ShaderToy pieces under their authors' licences (noted per entry).
//
//  Porting a ShaderToy body here usually means only:
//    * dropping its `vec2 fragCoord = TexCoord * iResolution;` preamble — the
//      wrapper already provides `uv`, `fragCoord`, `time`, `resolution` and
//      `mouse`, plus the `iTime` / `iResolution` / `iMouse` spellings;
//    * assigning `fragColor` rather than `FragColor`;
//    * moving helper functions into `functions:`, since GLSL has no nested
//      function definitions.
//

public enum ShaderLibrary {

    /// Every bundled shader, in a sensible demo order.
    @MainActor
    public static var all: [(name: String, blurb: String, function: ShaderFunction)] {
        [
            ("Plasma", "TouchBay's PlasmaShader, ported", plasma),
            ("Motion blur", "helper functions at file scope", motionBlur),
            ("Tunnel", "loop-heavy, written for this demo", tunnel),
            ("Fractal pyramid", "64-step raymarch, folded space", fractalPyramid),
            ("Cyber Fuji", "SDF landscape, CC BY 3.0 Jan Mróz", cyberFuji),
            ("Bokeh parallax", "five rotating bokeh layers", bokehParallax),
            ("Frosted glass", "blurred SDF circles", frostedGlass),
            ("ShaderToy form", "unmodified mainImage(), via shaderToy:", shaderToyExample),
        ]
    }

    /// Effects for `.shader(_:)` — each reads the view it is applied to
    /// through `layer(uv)` and writes what replaces it. Half of them never
    /// read the clock, and so are dispatched only when the view repaints.
    @MainActor
    public static var effects: [(name: String, blurb: String, function: ShaderFunction)] {
        [
            ("Identity", "layer(uv), pixel for pixel", identity),
            ("CRT", "static — dispatched once", crt),
            ("Wave", "a moving sine distortion", wave),
            ("Pixelate", "8-pixel cells, static", pixelate),
            ("Chromatic", "split around the pointer", chromatic),
            ("Blur", "13-tap gaussian", blur),
            ("Ripple", "rings from the centre", ripple),
            ("ShaderToy post", "mainImage() reads iChannel0", shaderToyPost),
        ]
    }

    /// Not a port — written in ShaderToy's own form to show that
    /// `ShaderFunction(shaderToy:)` takes a `mainImage` unchanged. Paste any
    /// texture-free ShaderToy shader in exactly this shape and it runs.
    public static let shaderToyExample = ShaderFunction(shaderToy: """
        float band(float x, float w) {
            return smoothstep(w, 0.0, abs(x));
        }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = (2.0 * fragCoord - iResolution.xy) / iResolution.y;

            float t = iTime * 0.7;
            float wave = 0.0;
            for (int i = 0; i < 5; i++) {
                float fi = float(i);
                wave += band(uv.y + 0.35 * sin(uv.x * (1.5 + fi * 0.6) + t + fi), 0.06);
            }

            vec3 col = vec3(0.10, 0.16, 0.30);
            col += wave * vec3(0.35, 0.75, 1.0);
            col += 0.25 * wave * wave * vec3(1.0, 0.45, 0.75);
            fragColor = vec4(col, 1.0);
        }
    """)

    // MARK: - Ports

    /// TouchBay `Shaders/PlasmaShader.swift`, near-verbatim.
    public static let plasma = ShaderFunction("""
        float t = time;
        float v = 0.0;
        v += sin(uv.x * 10.0 + t);
        v += sin((uv.y * 10.0 + t) * 0.5);
        v += sin((uv.x * 10.0 + uv.y * 10.0 + t) * 0.5);

        vec2 c = uv * 10.0 - vec2(5.0);
        v += sin(sqrt(c.x * c.x + c.y * c.y + 1.0) + t);
        v *= 0.5;

        vec3 col = vec3(
            sin(PI * v),
            sin(PI * v + 2.094395102),
            sin(PI * v + 4.188790205)
        );
        fragColor = vec4(col * 0.5 + 0.5, 1.0);
    """)

    /// TouchBay `Shaders/CirclesMotionBlurShader.swift`. Kept because it is the
    /// clearest case for `functions:` — its body calls two helpers.
    public static let motionBlur = ShaderFunction(
        functions: """
        vec4 circleAt(vec2 p, vec2 center, float r) {
            return mix(vec4(1.0), vec4(1.0, 0.2, 0.3, 1.0),
                       smoothstep(r + 0.005, r - 0.005, length(p - center)));
        }

        vec4 circleScene(vec2 p, float t) {
            return circleAt(p, vec2(0.0, sin(t * 16.0) * (sin(t) * 0.5 + 0.5) * 0.5), 0.2);
        }
        """,
        """
        vec2 cell = resolution / vec2(3.0, 1.0);
        vec2 local = mod(fragCoord, cell);
        float view = floor(fragCoord.x / cell.x);

        vec2 p = local / cell * 2.0 - vec2(1.0);
        p.x *= cell.x / cell.y;

        float frametime = 60.0 / (view + 1.0);
        float t = floor((time + 3.0) * frametime) / frametime;

        vec4 blurred = vec4(0.0);
        for (int i = 0; i < 24; i++) {
            blurred += circleScene(p, t - float(i) * (1.0 / 15.0 / 24.0));
        }
        blurred /= 24.0;

        fragColor = view < 1.0 ? circleScene(p, t) : blurred;
        """
    )

    /// Written for this framework rather than ported.
    public static let tunnel = ShaderFunction(
        functions: """
        float ringDist(vec2 p, float r) { return abs(length(p) - r); }
        """,
        """
        vec2 p = (fragCoord * 2.0 - resolution) / min(resolution.x, resolution.y);
        float a = atan(p.y, p.x);
        float r = length(p);

        float depth = 1.0 / (r + 0.12) + time * 0.6;
        float bands = sin(depth * 6.0) * 0.5 + 0.5;
        float spokes = sin(a * 8.0 + depth * 2.0) * 0.5 + 0.5;

        vec3 col = vec3(0.15, 0.35, 0.75) * bands
                 + vec3(0.65, 0.20, 0.45) * spokes * bands;
        col *= smoothstep(1.35, 0.15, r);
        col += 0.35 * exp(-24.0 * ringDist(p, 0.28 + 0.05 * sin(time * 2.0)));

        fragColor = vec4(col, 1.0);
        """
    )

    /// TouchBay `Shaders/FractalPyramid.swift`. The raymarch loop is bounded by
    /// a fixed step count, so it costs the same everywhere on screen.
    public static let fractalPyramid = ShaderFunction(
        functions: """
        vec3 fpPalette(float d) {
            return mix(vec3(0.2, 0.7, 0.9), vec3(1.0, 0.0, 1.0), d);
        }

        vec2 fpRotate(vec2 p, float a) {
            float c = cos(a);
            float s = sin(a);
            return p * mat2(c, s, -s, c);
        }

        float fpMap(vec3 p) {
            for (int i = 0; i < 8; ++i) {
                float t = time * 0.2;
                p.xz = fpRotate(p.xz, t);
                p.xy = fpRotate(p.xy, t * 1.89);
                p.xz = abs(p.xz);
                p.xz -= 0.5;
            }
            return dot(sign(p), p) / 5.0;
        }

        vec4 fpMarch(vec3 ro, vec3 rd) {
            float t = 0.0;
            vec3 col = vec3(0.0);
            float d;
            for (float i = 0.0; i < 64.0; i++) {
                vec3 p = ro + rd * t;
                d = fpMap(p) * 0.5;
                if (d < 0.02) { break; }
                if (d > 100.0) { break; }
                col += fpPalette(length(p) * 0.1) / (400.0 * d);
                t += d;
            }
            return vec4(col, 1.0);
        }
        """,
        """
        vec2 p = (fragCoord - resolution * 0.5) / resolution.x;

        vec3 ro = vec3(0.0, 0.0, -50.0);
        ro.xz = fpRotate(ro.xz, time);

        vec3 cf = normalize(-ro);
        vec3 cs = normalize(cross(cf, vec3(0.0, 1.0, 0.0)));
        vec3 cu = normalize(cross(cf, cs));

        vec3 target = ro + cf * 3.0 + p.x * cs + p.y * cu;
        fragColor = fpMarch(ro, normalize(target - ro));
        """
    )

    /// TouchBay `Shaders/CyberFuji2020.swift` — Shader License CC BY 3.0,
    /// author Jan Mróz (jaszunio15). The helpers read `time` directly, which is
    /// why the wrapper keeps it as a file-scope global.
    public static let cyberFuji = ShaderFunction(
        functions: """
        float cfSun(vec2 p, float battery) {
            float val = smoothstep(0.3, 0.29, length(p));
            float bloom = smoothstep(0.7, 0.0, length(p));
            float cut = 3.0 * sin((p.y + time * 0.2 * (battery + 0.02)) * 100.0)
                      + clamp(p.y * 14.0 + 1.0, -6.0, 6.0);
            cut = clamp(cut, 0.0, 1.0);
            return clamp(val * cut, 0.0, 1.0) + bloom * 0.6;
        }

        float cfGrid(vec2 p, float battery) {
            vec2 size = vec2(p.y, p.y * p.y * 0.2) * 0.01;
            p += vec2(0.0, time * 4.0 * (battery + 0.05));
            p = abs(fract(p) - 0.5);
            vec2 lines = smoothstep(size, vec2(0.0), p);
            lines += smoothstep(size * 5.0, vec2(0.0), p) * 0.4 * battery;
            return clamp(lines.x + lines.y, 0.0, 3.0);
        }

        float cfDot2(vec2 v) { return dot(v, v); }

        float cfTrapezoid(vec2 p, float r1, float r2, float he) {
            vec2 k1 = vec2(r2, he);
            vec2 k2 = vec2(r2 - r1, 2.0 * he);
            p.x = abs(p.x);
            vec2 ca = vec2(p.x - min(p.x, (p.y < 0.0) ? r1 : r2), abs(p.y) - he);
            vec2 cb = p - k1 + k2 * clamp(dot(k1 - p, k2) / cfDot2(k2), 0.0, 1.0);
            float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
            return s * sqrt(min(cfDot2(ca), cfDot2(cb)));
        }

        float cfLine(vec2 p, vec2 a, vec2 b) {
            vec2 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h);
        }

        float cfBox(vec2 p, vec2 b) {
            vec2 d = abs(p) - b;
            return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
        }

        float cfSmoothUnion(float d1, float d2, float k) {
            float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
            return mix(d2, d1, h) - k * h * (1.0 - h);
        }

        float cfCloud(vec2 p, vec2 a1, vec2 b1, vec2 a2, vec2 b2, float w) {
            float lineVal1 = cfLine(p, a1, b1);
            float lineVal2 = cfLine(p, a2, b2);
            vec2 ww = vec2(w * 1.5, 0.0);
            vec2 left = max(a1 + ww, a2 + ww);
            vec2 right = min(b1 - ww, b2 - ww);
            float boxH = abs(a2.y - a1.y) * 0.5;
            float boxVal = cfBox(p - (left + right) * 0.5, vec2(0.04, boxH)) + w;
            return min(cfSmoothUnion(lineVal1, boxVal, 0.05),
                       cfSmoothUnion(lineVal2, boxVal, 0.05));
        }
        """,
        """
        vec2 p = (2.0 * fragCoord - resolution) / resolution.y;
        float battery = 1.0;

        float fog = smoothstep(0.1, -0.02, abs(p.y + 0.2));
        vec3 col = vec3(0.0, 0.1, 0.2);

        if (p.y < -0.2) {
            p.y = 3.0 / (abs(p.y + 0.2) + 0.05);
            p.x *= p.y;
            col = mix(col, vec3(1.0, 0.5, 1.0), cfGrid(p, battery));
        } else {
            float fujiD = min(p.y * 4.5 - 0.5, 1.0);
            p.y -= battery * 1.1 - 0.51;

            vec2 sunUV = p + vec2(0.75, 0.2);
            col = vec3(1.0, 0.2, 1.0);
            float sunVal = cfSun(sunUV, battery);
            col = mix(col, vec3(1.0, 0.4, 0.1), sunUV.y * 2.0 + 0.2);
            col = mix(vec3(0.0), col, sunVal);

            float fujiVal = cfTrapezoid(p + vec2(-0.75, 0.5),
                                        1.75 + pow(p.y * p.y, 2.1), 0.2, 0.5);
            float waveVal = p.y + sin(p.x * 20.0 + time * 2.0) * 0.05 + 0.2;
            float waveWidth = smoothstep(0.0, 0.01, waveVal);

            col = mix(col, mix(vec3(0.0, 0.0, 0.25), vec3(1.0, 0.0, 0.5), fujiD),
                      step(fujiVal, 0.0));
            col = mix(col, vec3(1.0, 0.5, 1.0), waveWidth * step(fujiVal, 0.0));
            col = mix(col, vec3(1.0, 0.5, 1.0), 1.0 - smoothstep(0.0, 0.01, abs(fujiVal)));
            col += mix(col, mix(vec3(1.0, 0.12, 0.8), vec3(0.0, 0.0, 0.2),
                                clamp(p.y * 3.5 + 3.0, 0.0, 1.0)), step(0.0, fujiVal));

            vec2 cloudUV = p;
            cloudUV.x = mod(cloudUV.x + time * 0.1, 4.0) - 2.0;
            float ct = time * 0.5;
            float cloudY = -0.5;
            float cloud1 = cfCloud(cloudUV,
                vec2(0.1 + sin(ct + 140.5) * 0.1, cloudY),
                vec2(1.05 + cos(ct * 0.9 - 36.56) * 0.1, cloudY),
                vec2(0.2 + cos(ct * 0.867 + 387.165) * 0.1, 0.25 + cloudY),
                vec2(0.5 + cos(ct * 0.9675 - 15.162) * 0.09, 0.25 + cloudY), 0.075);
            cloudY = -0.6;
            float cloud2 = cfCloud(cloudUV,
                vec2(-0.9 + cos(ct * 1.02 + 541.75) * 0.1, cloudY),
                vec2(-0.5 + sin(ct * 0.9 - 316.56) * 0.1, cloudY),
                vec2(-1.5 + cos(ct * 0.867 + 37.165) * 0.1, 0.25 + cloudY),
                vec2(-0.6 + sin(ct * 0.9675 + 665.162) * 0.09, 0.25 + cloudY), 0.075);
            float cloudVal = min(cloud1, cloud2);

            col = mix(col, vec3(0.0, 0.0, 0.2),
                      1.0 - smoothstep(0.075 - 0.0001, 0.075, cloudVal));
            col += vec3(1.0) * (1.0 - smoothstep(0.0, 0.01, abs(cloudVal - 0.075)));
        }

        col += fog * fog * fog;
        col = mix(vec3(col.r) * 0.5, col, battery * 0.7);
        fragColor = vec4(col, 1.0);
        """
    )

    /// TouchBay `Shaders/BokehParalax.swift`.
    public static let bokehParallax = ShaderFunction(
        functions: """
        vec2 bkRotate(vec2 p, float a) {
            return cos(a) * p + sin(a) * vec2(p.y, -p.x);
        }

        float bkCircle(vec2 p, float r) {
            return (length(p / r) - 1.0) * r;
        }

        float bkRand(vec2 c) {
            return fract(sin(dot(c.xy, vec2(12.9898, 78.233))) * 43758.5453);
        }

        vec3 bkLayer(vec3 color, vec2 p, vec3 c) {
            float wrap = 450.0;
            if (mod(floor(p.y / wrap + 0.5), 2.0) == 0.0) {
                p.x += wrap * 0.5;
            }

            vec2 p2 = mod(p + 0.5 * wrap, wrap) - 0.5 * wrap;
            vec2 cell = floor(p / wrap + 0.5);
            float cellR = bkRand(cell);

            c *= fract(cellR * 3.33 + 3.33);
            float radius = mix(30.0, 70.0, fract(cellR * 7.77 + 7.77));
            p2.x *= mix(0.9, 1.1, fract(cellR * 11.13 + 11.13));
            p2.y *= mix(0.9, 1.1, fract(cellR * 17.17 + 17.17));

            float sdf = bkCircle(p2, radius);
            float circle = 1.0 - smoothstep(0.0, 1.0, sdf * 0.04);
            float glow = exp(-sdf * 0.025) * 0.3 * (1.0 - circle);
            return color + c * (circle + glow);
        }
        """,
        """
        vec2 p = (2.0 * fragCoord - resolution) / resolution.x * 1000.0;

        vec3 color = mix(vec3(0.3, 0.1, 0.3), vec3(0.1, 0.4, 0.5),
                         dot(uv, vec2(0.2, 0.7)));

        float t = time - 15.0;
        p = bkRotate(p, 0.2 + t * 0.03);
        color = bkLayer(color, p + vec2(-50.0 * t +  0.0,   0.0), 3.0 * vec3(0.4, 0.1, 0.2));
        p = bkRotate(p, 0.3 - t * 0.05);
        color = bkLayer(color, p + vec2(-70.0 * t + 33.0, -33.0), 3.5 * vec3(0.6, 0.4, 0.2));
        p = bkRotate(p, 0.5 + t * 0.07);
        color = bkLayer(color, p + vec2(-60.0 * t + 55.0,  55.0), 3.0 * vec3(0.4, 0.3, 0.2));
        p = bkRotate(p, 0.9 - t * 0.03);
        color = bkLayer(color, p + vec2(-25.0 * t + 77.0,  77.0), 3.0 * vec3(0.4, 0.2, 0.1));
        p = bkRotate(p, 0.0 + t * 0.05);
        color = bkLayer(color, p + vec2(-15.0 * t + 99.0,  99.0), 3.0 * vec3(0.2, 0.0, 0.4));

        fragColor = vec4(color, 1.0);
        """
    )

    /// TouchBay `Shaders/SupahFrostedGlass.swift`.
    public static let frostedGlass = ShaderFunction(
        functions: """
        float fgCircle(vec2 p, float r, bool blur) {
            float a = blur ? 0.01 : 0.0;
            float b = blur ? 0.13 : 5.0 / resolution.y;
            return smoothstep(a, b, length(p) - r);
        }
        """,
        """
        vec2 p = (fragCoord - 0.5 * resolution) / resolution.y;
        vec2 t = vec2(sin(time * 2.0), cos(time * 3.0 + cos(time * 0.5))) * 0.1;

        vec3 col0 = vec3(0.9);
        vec3 col1 = vec3(0.1 + p.y * 2.0, 0.4 + p.x * -1.1, 0.8) * 0.828;
        vec3 col2 = vec3(0.86);

        float cir1 = fgCircle(p - t, 0.2, false);
        float cir2 = fgCircle(p + t, 0.2, false);
        float cir2B = fgCircle(p + t, 0.15, true);

        vec3 col = mix(col1 + vec3(0.3, 0.1, 0.0), col2, cir2B);
        col = mix(col, col0, cir1);
        col = mix(col, col1, clamp(cir1 - cir2, 0.0, 1.0));
        fragColor = vec4(col, 1.0);
        """
    )

    // MARK: - Effects

    /// The view unchanged. The one to apply when checking that a layer is
    /// pixel-exact — text, rounded corners and alpha should all survive.
    public static let identity = ShaderFunction("""
        fragColor = layer(uv);
    """)

    /// Barrel curvature, scanlines and a vignette. Reads neither the clock
    /// nor the pointer, so once drawn it costs nothing until the view under
    /// it changes.
    public static let crt = ShaderFunction("""
        vec2 p = uv * 2.0 - 1.0;
        p *= 1.0 + 0.08 * dot(p, p);
        vec2 curved = p * 0.5 + 0.5;
        float inside = step(0.0, curved.x) * step(curved.x, 1.0)
                     * step(0.0, curved.y) * step(curved.y, 1.0);

        vec4 c = layer(curved);
        float line = 0.85 + 0.15 * sin(curved.y * resolution.y * PI);
        float vignette = 1.0 - 0.35 * dot(p * 0.8, p * 0.8);
        c.rgb *= line * vignette;
        fragColor = vec4(c.rgb, c.a * inside);
    """)

    /// A sine wave running down the view, moving with time.
    public static let wave = ShaderFunction("""
        float dx = sin(uv.y * 30.0 + time * 3.0) * 0.012;
        float dy = cos(uv.x * 20.0 + time * 2.0) * 0.006;
        fragColor = layer(uv + vec2(dx, dy));
    """)

    /// 8-pixel cells: every pixel in a cell reads the cell's centre.
    public static let pixelate = ShaderFunction("""
        vec2 cells = resolution / 8.0;
        vec2 cell = (floor(uv * cells) + 0.5) / cells;
        fragColor = layer(cell);
    """)

    /// Red and blue pulled apart, more so the further from the pointer — or
    /// from the centre, until the pointer has been over the view.
    public static let chromatic = ShaderFunction("""
        vec2 focus = mouse.x > 0.0 && mouse.y > 0.0 ? mouse / resolution : vec2(0.5);
        vec2 away = uv - focus;
        vec2 shift = away * 0.03;
        float r = layer(uv + shift).r;
        vec4 g = layer(uv);
        float b = layer(uv - shift).b;
        fragColor = vec4(r, g.g, b, g.a);
    """)

    /// A separable-looking 13-tap gaussian done in one pass. Colours are
    /// weighted by alpha so the transparent surround does not darken edges —
    /// the view is straight-alpha, like the canvas it came from.
    public static let blur = ShaderFunction(
        functions: """
        vec4 blurTap(vec2 p, vec2 offset, float weight) {
            vec4 c = layer(p + offset);
            return vec4(c.rgb * c.a, c.a) * weight;
        }
        """,
        """
        vec2 texel = 1.5 / resolution;
        vec4 acc = blurTap(uv, vec2(0.0), 0.16);
        float w[3] = float[3](0.13, 0.07, 0.03);
        for (int i = 1; i <= 3; i++) {
            vec2 d = texel * float(i);
            acc += blurTap(uv, vec2( d.x, 0.0), w[i - 1]);
            acc += blurTap(uv, vec2(-d.x, 0.0), w[i - 1]);
            acc += blurTap(uv, vec2(0.0,  d.y), w[i - 1]);
            acc += blurTap(uv, vec2(0.0, -d.y), w[i - 1]);
        }
        acc /= 0.16 + 4.0 * (0.13 + 0.07 + 0.03);
        fragColor = acc.a > 0.0 ? vec4(acc.rgb / acc.a, acc.a) : vec4(0.0);
        """
    )

    /// Rings spreading from the centre, displacing what they pass over.
    public static let ripple = ShaderFunction("""
        vec2 p = uv - 0.5;
        p.x *= resolution.x / resolution.y;
        float d = length(p);
        float ring = sin(d * 40.0 - time * 5.0) * 0.006 * smoothstep(0.6, 0.0, d);
        vec2 dir = d > 0.0 ? p / d : vec2(0.0);
        dir.x *= resolution.y / resolution.x;
        fragColor = layer(uv + dir * ring);
    """)

    /// A post-process in ShaderToy's own form: the view is `iChannel0`, read
    /// with the same `texture(iChannel0, uv)` a ShaderToy image pass uses.
    public static let shaderToyPost = ShaderFunction(shaderToy: """
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
        }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            vec4 c = texture(iChannel0, uv);

            // Film grain, new every frame, and a slow brightness breathe.
            float grain = hash(fragCoord + fract(iTime) * 100.0) - 0.5;
            float breathe = 0.9 + 0.1 * sin(iTime * 1.5);
            vec3 col = c.rgb * breathe + grain * 0.06;

            // Warm the highlights, cool the shadows.
            float l = dot(col, vec3(0.299, 0.587, 0.114));
            col = mix(col * vec3(0.9, 0.95, 1.1), col * vec3(1.1, 1.0, 0.85), l);

            fragColor = vec4(col, c.a);
        }
    """)
}
