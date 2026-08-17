
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadBroadcast(vec2(0u, 0u), 0);
}
