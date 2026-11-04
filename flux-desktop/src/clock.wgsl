struct Uniforms { screen: vec4f, digits: vec4f };
@group(0) @binding(0) var<uniform> u: Uniforms;
@vertex fn vs(@builtin(vertex_index) id: u32) -> @builtin(position) vec4f {
    let positions = array<vec2f, 3>(vec2f(-1., -1.), vec2f(3., -1.), vec2f(-1., 3.));
    return vec4f(positions[id], 0., 1.);
}
fn box_distance(p: vec2f, center: vec2f, half_size: vec2f) -> f32 {
    let q = abs(p - center) - half_size;
    return length(max(q, vec2f(0.))) + min(max(q.x, q.y), 0.) - 0.018;
}
fn digit(p: vec2f, number: u32) -> f32 {
    let masks = array<u32,10>(63u,6u,91u,79u,102u,109u,125u,7u,127u,111u);
    let centers = array<vec2f,7>(vec2f(.30,.05),vec2f(.58,.30),vec2f(.58,.80),vec2f(.30,1.05),vec2f(.02,.80),vec2f(.02,.30),vec2f(.30,.55));
    var distance = 10.;
    for (var i=0u; i<7u; i++) {
        if ((masks[number] & (1u << i)) != 0u) {
            let horizontal = i == 0u || i == 3u || i == 6u;
            let size = select(vec2f(.025,.19),vec2f(.22,.025),horizontal);
            distance = min(distance, box_distance(p, centers[i], size));
        }
    }
    return distance;
}
@fragment fn fs(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let unit = min(46. * u.screen.z, min(u.screen.x / 5., u.screen.y / 5.));
    let origin = vec2f(u.screen.x * .5 - 1.59 * unit, min(48. * u.screen.z, u.screen.y * .10));
    let p = (position.xy - origin) / unit;
    // Skip segment calculations outside the small clock area.
    if (p.x < -.15 || p.x > 3.35 || p.y < -.15 || p.y > 1.2) { discard; }
    var d = min(digit(p,u32(u.digits.x)), digit(p-vec2f(.8,0.),u32(u.digits.y)));
    d = min(d, digit(p-vec2f(1.8,0.),u32(u.digits.z)));
    d = min(d, digit(p-vec2f(2.6,0.),u32(u.digits.w)));
    d = min(d, length(p-vec2f(1.59,.32))-.035);
    d = min(d, length(p-vec2f(1.59,.78))-.035);
    let aa = 1. / unit;
    let text_alpha = 1. - smoothstep(-aa, aa, d);
    let shadow = (1. - smoothstep(0., .075, d)) * .6;
    let alpha = max(text_alpha, shadow);
    if (alpha < .001) { discard; }
    return vec4f(vec3f(text_alpha), alpha);
}
