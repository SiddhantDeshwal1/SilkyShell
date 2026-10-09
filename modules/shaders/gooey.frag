#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 uv = qt_TexCoord0;
    
    // 1. Gather blurred alpha
    float blurRadius = 10.0;
    vec2 texelSize = 1.0 / itemSize;
    float alphaSum = 0.0;
    float weightSum = 0.0;
    
    // Simple 7x7 box-ish / gaussian-ish blur for alpha
    for(float x = -3.0; x <= 3.0; x++) {
        for(float y = -3.0; y <= 3.0; y++) {
            vec2 offset = vec2(x, y) * texelSize * (blurRadius / 3.0);
            float weight = exp(-(x*x + y*y) / 9.0); // simple gaussian weight
            alphaSum += texture(source, uv + offset).a * weight;
            weightSum += weight;
        }
    }
    float blurredAlpha = alphaSum / weightSum;
    
    // 2. Threshold the blurred alpha to create the blob
    // feColorMatrix: 18 * alpha - 9
    // threshold at 0.5
    float blobAlpha = smoothstep(0.45, 0.55, blurredAlpha);
    
    // 3. Get the original crisp color
    vec4 originalColor = texture(source, uv);
    
    // 4. Blend original OVER the blob. 
    // The blob should have the color of the background (e.g. #f5f5f5)
    vec3 blobColorRgb = vec3(0.96, 0.96, 0.96); // #f5f5f5
    vec4 blobColor = vec4(blobColorRgb * blobAlpha, blobAlpha);
    
    // Blend: out = src + dst * (1 - src.a)
    vec4 finalColor = originalColor + blobColor * (1.0 - originalColor.a);
    
    fragColor = finalColor * qt_Opacity;
}
