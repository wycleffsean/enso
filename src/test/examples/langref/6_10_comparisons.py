# Comparisons
# https://docs.python.org/3/reference/expressions.html#comparisons

## Value Comparisons
## <, >, ==, >=, <=, and !=

a = 1 < 2
b = 3 > 4
c = 5 == 6
d = 7 <= 8
e = 9 >= 10


## Membership Test
## in, not in
f = "" in "yo"
# TODO: there's an issue with precedence and deciding whether
# 'not' is a unary or infix operator in the parser.  We'll have to
# revisit this
# g = "yo" not in ""
