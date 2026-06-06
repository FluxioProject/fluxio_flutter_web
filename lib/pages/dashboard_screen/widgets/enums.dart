enum BlockType { math, compare, timer, io }

enum MathOp {
  add, // 0
  sub, // 1
  mul, // 2
  div, // 3
}

enum IOType { ai, di, ao, doo }

enum CompareOp {
  gt, // >
  lt, // <
  eq, // ==
  gte, // >=
  lte, // <=
}

enum InputKind {
  constant, // 0
  block, // 1
}

enum InputSourceType { block, constant }
