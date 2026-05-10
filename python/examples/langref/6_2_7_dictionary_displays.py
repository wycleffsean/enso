# Dictionary Displays
# https://docs.python.org/3/reference/expressions.html#dictionary-displays

empty = {}
x = { "a": 1, }
y = { "b": 2, "c": 3, **x }
c = {z : z for z in range(5)}
