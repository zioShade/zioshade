
enable subgroups;
@compute @workgroup_size(1)
fn main() {
  _ = quadBroadcast(0, 0);
}
