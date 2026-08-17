
@compute @workgroup_size(1)
fn main() {
    const r = vec4(-1073741824i) << vec4(1u);
}
    
