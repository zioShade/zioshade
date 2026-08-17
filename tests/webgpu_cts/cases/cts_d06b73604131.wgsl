
@compute @workgroup_size(1)
fn main() {
    const r = vec4(2147483647u) << vec4(1u);
}
    
