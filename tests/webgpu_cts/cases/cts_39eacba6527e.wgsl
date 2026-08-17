
@compute @workgroup_size(1)
fn main() {
    const r = vec3(1073741824u) << vec3(1u);
}
    
