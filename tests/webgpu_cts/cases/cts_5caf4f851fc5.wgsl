
      enable f16;

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat4x4(0h, 1h, 2h, 3h, 4h, 5h, 6h, 7h, 8h, 9h, 10h, 11h, 12h, 13h, 14h, 15h));
      }
