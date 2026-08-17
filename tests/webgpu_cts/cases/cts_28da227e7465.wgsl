
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadBroadcast(vec2(0, 0), 0);
}
