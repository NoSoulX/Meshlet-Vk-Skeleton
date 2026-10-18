#version 450

layout(location = 0) in VertexOutput {
    vec4 color;
} In;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(In.color);
}