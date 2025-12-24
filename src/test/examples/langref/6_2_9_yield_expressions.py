# Yield Expressions
# https://docs.python.org/3/reference/expressions.html#yield-expressions

def foo():
    yield 10

def bar(a):
    yield 10, *a

def baz(a):
    yield from a
