# The continue Statement
# https://docs.python.org/3.12/reference/simple_stmts.html#the-continue-statement

count = 0

while count < 3:
    count += 1
    if count < 3:
        continue
    print(count)
