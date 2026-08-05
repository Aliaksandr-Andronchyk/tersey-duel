// cube.s — фейковое 3D на честном ARM64-ассемблере.
// Вращение и проекция 8 вершин куба (±1,±1,±1):
//   поворот вокруг Y, затем вокруг X, затем фейковая перспектива 1/(z·0.25+2.5).
// Вход: d0=sinY d1=cosY d2=sinX d3=cosX, x0 → буфер на 16 double (x,y × 8 вершин).
// Собирается clang'ом, зовётся из Swift через @_silgen_name("cube_rotpro").

.section __TEXT,__text
.globl _cube_rotpro
.p2align 2
_cube_rotpro:
    mov     x9, #0              // счётчик вершин
Lloop:
    fmov    d4, #1.0
    fmov    d5, #-1.0
    tst     x9, #1
    fcsel   d16, d4, d5, ne     // x = бит0 ? +1 : -1
    tst     x9, #2
    fcsel   d17, d4, d5, ne     // y = бит1 ? +1 : -1
    tst     x9, #4
    fcsel   d18, d4, d5, ne     // z = бит2 ? +1 : -1

    // поворот вокруг Y:  x' = x·cosY + z·sinY ;  z1 = z·cosY − x·sinY
    fmul    d19, d16, d1
    fmadd   d19, d18, d0, d19
    fmul    d20, d18, d1
    fmsub   d20, d16, d0, d20

    // поворот вокруг X:  y' = y·cosX − z1·sinX ;  z' = y·sinX + z1·cosX
    fmul    d21, d17, d3
    fmsub   d21, d20, d2, d21
    fmul    d22, d17, d2
    fmadd   d22, d20, d3, d22

    // фейковая перспектива:  s = 1 / (z'·0.25 + 2.5)
    fmov    d23, #0.25
    fmov    d24, #2.5
    fmadd   d23, d22, d23, d24
    fmov    d24, #1.0
    fdiv    d23, d24, d23
    fmul    d19, d19, d23       // экранный x
    fmul    d21, d21, d23       // экранный y

    stp     d19, d21, [x0], #16
    add     x9, x9, #1
    cmp     x9, #8
    b.lt    Lloop
    ret
