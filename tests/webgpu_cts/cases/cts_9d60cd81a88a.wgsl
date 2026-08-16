
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : bool = subgroupAny(true);
}
