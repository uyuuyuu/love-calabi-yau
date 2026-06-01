#ifdef VERTEX
uniform mat4 projectionMatrix;
uniform mat4 viewMatrix;
uniform mat4 modelMatrix;
uniform bool isCanvas;

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 pos = projectionMatrix * viewMatrix * modelMatrix * vertex_position;
    if (isCanvas) {
        pos.y = -pos.y;
    }
    return pos;
}
#endif

#ifdef PIXEL
uniform float colorShift;
uniform float vignetteAmount;
uniform float chromaticAmount;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Basic texture sampling (for post-processing pass)
    // If rendering the model directly, vertex colors are used
    
    vec3 c;
    if (chromaticAmount > 0.0) {
        // Chromatic Aberration
        float r = Texel(tex, tc + vec2(chromaticAmount, 0.0)).r;
        float g = Texel(tex, tc).g;
        float b = Texel(tex, tc - vec2(chromaticAmount, 0.0)).b;
        c = vec3(r, g, b);
    } else {
        c = Texel(tex, tc).rgb * color.rgb;
    }

    // If not sampling a texture (main render stage), use the incoming color directly
    if (tc.x == 0.0 && tc.y == 0.0) {
        c = color.rgb;
        // Color cycling logic
        float hue = colorShift * 0.5;
        c.r += 0.1 * cos(6.28 * (hue));
        c.g += 0.1 * cos(6.28 * (hue + 0.33));
        c.b += 0.1 * cos(6.28 * (hue + 0.66));
    }

    // Vignette
    if (vignetteAmount > 0.0) {
        vec2 dist = (tc - 0.5) * 1.5;
        float v = smoothstep(0.8, 0.4, length(dist));
        c *= mix(1.0, v, vignetteAmount);
    }

    // Brightness pulse
    c *= 1.15 + 0.08 * sin(sc.y * 0.008 + sc.x * 0.001);
    
    return vec4(c, 1.0);
}
#endif
