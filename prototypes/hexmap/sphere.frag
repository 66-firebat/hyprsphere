#version 310 es
precision highp float;

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D src;
uniform highp float sphereR;
uniform highp float hexScale;
uniform highp float d;
uniform highp float rotX;
uniform highp float rotY;
uniform highp float flatHalf;
uniform highp float viewportX;
uniform highp float viewportY;

void main() {
    highp float X = (qt_TexCoord0.x - 0.5) * 2.0 * viewportX;
    highp float Y = (qt_TexCoord0.y - 0.5) * 2.0 * viewportY;

    highp float a = sphereR;
    highp float D = d;
    highp float R2 = X*X + Y*Y;

    highp float Aq = R2/(D*D) + 1.0;
    highp float Bq = -2.0*D;
    highp float Cq = D*D - a*a;
    highp float disc = Bq*Bq - 4.0*Aq*Cq;
    if (disc < 0.0) { fragColor = vec4(0.0); return; }
    highp float sq = sqrt(disc);
    highp float t1 = (-Bq - sq)/(2.0*Aq);
    highp float t2 = (-Bq + sq)/(2.0*Aq);
    highp float t = ((D - t1)/a) > ((D - t2)/a) ? t1 : t2;
    highp vec3 r = vec3(X*t/(a*D), Y*t/(a*D), (D - t)/a);

    if (r.z <= 0.22) { fragColor = vec4(0.0); return; }

    highp float cb = cos(-rotY), sb = sin(-rotY);
    highp float x1 = r.x*cb - r.z*sb;
    highp float z1 = r.x*sb + r.z*cb;
    highp float y1 = r.y;
    highp float ca = cos(-rotX), sa = sin(-rotX);
    highp float y2 = y1*ca - z1*sa;
    highp float z2 = y1*sa + z1*ca;
    highp float x2 = x1;
    highp vec3 s = vec3(x2, y2, z2);

    highp float lat = asin(clamp(s.y, -1.0, 1.0));
    highp float lon = atan(s.x, s.z);
    highp float px = lon * sphereR / hexScale;
    highp float py = lat * sphereR / hexScale;

    highp float u = (px + flatHalf) / (2.0 * flatHalf);
    highp float v = (py + flatHalf) / (2.0 * flatHalf);
    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) { fragColor = vec4(0.0); return; }

    highp vec4 col = texture(src, vec2(u, v));

    highp float dist = length(vec2(px, py));
    highp float ring = dist / (hexScale * 1.5);
    highp float op = 1.0 - ring * 0.13;
    op = clamp(op, 0.12, 1.0);

    fragColor = vec4(col.rgb, col.a * op);
}
