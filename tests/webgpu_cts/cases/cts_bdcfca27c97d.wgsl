
      enable f16;

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat3x3(0h, 1h, 2h, 3h, 4h, 5h, 6h, 7h, 8h));
      }
