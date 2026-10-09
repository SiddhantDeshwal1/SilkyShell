#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 color = texture(source, qt_TexCoord0);
    // Smooth thresholding for the blob effect
    float newAlpha = smoothstep(0.4, 0.5, color.a);
    fragColor = vec4(color.rgb, newAlpha) * qt_Opacity;
}
