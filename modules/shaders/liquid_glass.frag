#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float radius;
    vec2 size;
    vec4 baseColor;
    vec4 highlightColor;
    float specularScale;
    float blurDiffusion;
    float time;
    float padding;
};

// ── 2D Simplex Noise (Ashima Arts / Stefan Gustavson) ───────────────────
vec3 permute(vec3 x) {
    return mod(((x * 34.0) + 1.0) * x, 289.0);
}

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187,  // (3.0-sqrt(3.0))/6.0
                        0.366025403784439,  // 0.5*(sqrt(3.0)-1.0)
                       -0.577350269189626,  // -1.0 + 2.0 * C.x
                        0.024390243902439); // 1.0 / 41.0
    vec2 i  = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod(i, 289.0);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
                   + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    vec3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// ── Static Procedural Liquid Caustics (No movement, calm & elegant) ─────
float getLiquidHeight(vec2 pt) {
    // Fixed seed coords matching feTurbulence baseFrequency 0.001 0.005
    vec2 st = pt * vec2(0.0012, 0.0040) + vec2(17.3, 42.7);
    float n1 = snoise(st);
    float n2 = snoise(st * 2.1 + vec2(3.1, 1.7)) * 0.4;
    float n = n1 + n2;
    float norm = clamp(n * 0.5 + 0.5, 0.0, 1.0);
    return pow(norm, 2.2);
}

// ── Analytical Exact Signed Distance for Rounded Box ────────────────────
float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - (b - vec2(r));
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    vec2 boxCenter = size * 0.5;
    vec2 boxHalf = size * 0.5;
    float cornerR = clamp(radius, 0.0, min(boxHalf.x, boxHalf.y));

    // Analytical distance to rounded box boundary
    float dist = sdRoundedBox(p - boxCenter, boxHalf, cornerR);

    // Butter-smooth sub-pixel boundary anti-aliasing
    float edgeWidth = clamp(fwidth(dist), 0.75, 1.5);
    float shapeAlpha = 1.0 - smoothstep(-edgeWidth * 0.5, edgeWidth * 0.5, dist);
    if (shapeAlpha <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    // ── 1. Soft, Silky Liquid Glass Caustic Reflections ─────────────────
    // Gentle surface scale (6.0 instead of 32.0) matching feSpecularLighting surfaceScale="5"
    float eps = 2.5;
    float hC = getLiquidHeight(p);
    float hR = getLiquidHeight(p + vec2(eps, 0.0));
    float hU = getLiquidHeight(p + vec2(0.0, eps));
    vec2 gradH = vec2(hR - hC, hU - hC) / eps;
    vec3 normal = normalize(vec3(-gradH * 6.0 * specularScale, 1.0));

    // Ambient elevated light source
    vec3 lightPos = vec3(-150.0, -150.0, 300.0);
    vec3 pixelPos = vec3(p, 0.0);
    vec3 lightDir = normalize(lightPos - pixelPos);
    vec3 viewDir = vec3(0.0, 0.0, 1.0);
    vec3 halfDir = normalize(lightDir + viewDir);

    float specDot = max(dot(normal, halfDir), 0.0);
    // Soft, delicate gloss highlights (zero harsh glare)
    float spec = pow(specDot, 55.0) * 0.35 * specularScale;
    float softSheen = pow(specDot, 12.0) * 0.10 * specularScale;

    // ── 2. Clean, Pure Glass Color & Premultiplied Alpha Blending ───────
    // Base glass frost: premultiplied RGB
    vec3 baseRgbPremul = baseColor.rgb * baseColor.a;
    // Glossy specular highlight added smoothly on top
    vec3 specHighlight = highlightColor.rgb * (spec + softSheen);
    vec3 totalRgb = baseRgbPremul + specHighlight;

    // Uniform glass transmission alpha (leaves compositor blur clean & accurate)
    float totalAlpha = clamp(baseColor.a + (spec * 0.12), 0.0, 1.0);
    totalAlpha *= shapeAlpha * qt_Opacity;

    // Output premultiplied alpha for Qt Quick SceneGraph & Wayland compositor
    fragColor = vec4(totalRgb * shapeAlpha * qt_Opacity, totalAlpha);
}
