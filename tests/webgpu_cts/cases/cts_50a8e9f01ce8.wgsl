
      enable f16;

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat2x2(0h, 1h, 2h, 3h));
      }
