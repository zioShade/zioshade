
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadBroadcast(i32(0), 0);
}
