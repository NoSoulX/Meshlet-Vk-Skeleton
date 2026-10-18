package meshlet_vulkan

Vertex :: struct {
    pos:[2]f32,
    _pad:[2]f32,
    color:[4]f32,
}

Quad_Data :: struct {
    vertices : [6]Vertex,
}