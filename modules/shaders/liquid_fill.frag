#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float radius;
    vec2 size;
    vec2 origin;
    float progress;
    float maxRadius;
    vec4 fromColor;
    vec4 toColor;
    vec4 highlightColor;
};

// Euclidean distance to rounded box boundary
float roundedBoxSDF(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 pixel = qt_TexCoord0 * size;
    vec2 halfSize = size * 0.5;
    vec2 p = pixel - halfSize;
    
    // 1. Precise sub-pixel anti-aliased rounded rectangle SDF clipping
    float dBox = roundedBoxSDF(p, halfSize, radius);
    float boxAlpha = smoothstep(0.5, -0.5, dBox);
    if (boxAlpha <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    // 2. Liquid wave expansion from click origin
    vec2 toPixel = pixel - origin;
    float dist = length(toPixel);
    
    // Base wavefront radius
    float waveR = progress * maxRadius;
    
    // Multi-harmonic fluid wobble (organic liquid surface tension)
    float angle = atan(toPixel.y, toPixel.x);
    float harmonic1 = sin(angle * 4.0 + progress * 5.0) * 3.5;
    float harmonic2 = sin(angle * 7.0 - progress * 3.0) * 1.5;
    float wobble = (harmonic1 + harmonic2) * sin(progress * 3.14159265);
    float curR = waveR + wobble;
    
    // 3. Fluid meniscus / wave front fill factor
    float waveEdge = curR - dist;
    float fill = smoothstep(-2.5, 3.5, waveEdge);
    
    // 4. Specular wave crest glint (luminous highlight at the edge of the liquid wave)
    float crestDist = abs(dist - curR);
    float crestEnvelope = smoothstep(0.02, 0.12, progress) * (1.0 - smoothstep(0.85, 1.0, progress));
    float crestGlint = exp(- (crestDist * crestDist) / 24.0) * crestEnvelope;
    
    // 5. Liquid caustic surface sheen behind the crest
    float depth = clamp((curR - dist) / max(curR, 1.0), 0.0, 1.0);
    float sheen = exp(-depth * 6.0) * fill * 0.25 * crestEnvelope;
    
    // 6. Base color blend and specular combination
    vec4 base = mix(fromColor, toColor, fill);
    vec4 crestColor = mix(highlightColor, toColor, 0.20);
    base += crestColor * (crestGlint * 0.85 + sheen);
    
    fragColor = base * boxAlpha * qt_Opacity;
}
