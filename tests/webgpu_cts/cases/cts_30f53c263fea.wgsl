
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupAnd(0u);
}
