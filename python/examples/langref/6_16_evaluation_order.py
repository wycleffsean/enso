# Evaluation Order
# https://docs.python.org/3.12/reference/expressions.html#evaluation-order

def mark(value):
    print(value)
    return value

mark(1) + mark(2)
