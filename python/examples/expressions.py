# compile.c compiler_visit_expr1

# named expression
# https://peps.python.org/pep-0572/
(named_expression := 1)

# bool ops
True and False

# binary ops
# TODO: python folds all of this into a literal value
#   in the future we can cheat by wrapping this in a closure
#   or something
x = 1 + 2 - 3 * 4 / 5 // 6 % 7 << 8 >> 9 ** 10

# matrix multiply
c = a @ b
# TODO: fix - the following fails parsing
# c = a@b

# unary operators

positive = +1
negative = -1
logical_not = not 0
bitwise_invert = ~16
