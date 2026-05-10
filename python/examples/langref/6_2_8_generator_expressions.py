# Generator Expressions
# https://docs.python.org/3/reference/expressions.html#generator-expressions

y = (x*y for x in range(10) for y in range(x, x+10))
