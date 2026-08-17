
@compute @workgroup_size(1)
fn main() {
    const r = vec3(2147483647u) << vec3(1u);
}
    
