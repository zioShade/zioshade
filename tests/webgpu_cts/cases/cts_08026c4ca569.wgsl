
enable subgroups;
@compute @workgroup_size(16)
fn main() {
  _ = quadBroadcast(0, 0);
}
