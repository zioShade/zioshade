
enable subgroups;
@compute @workgroup_size(16)
fn main() {
  _ = subgroupMin(0);
}
