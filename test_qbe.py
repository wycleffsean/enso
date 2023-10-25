from subprocess import call, run, PIPE

def qbe_to_asm(str):
    res = run(['vendor/qbe/qbe', '-o', 'assertion.s'], input=str.encode('ascii'))
    return res.stdout

def build_assertion():
    call(["zig", "cc", "assertion.s", "-o", "assertion"])

def qbe_assertion(type, expected, actual):
    return """
    export function w $main() {{
    @start
            %a ={0} {2}
            %r ={0} ceq{0} {1}, %a
            jnz %r, @fail, @succ
    @succ
            ret 0
    @fail
            ret 1
    }}
    """.format(type, expected, actual)

def run_assertion():
    return call(['./assertion'])

def qbe_assert(type, expected, actual):
    qbe = qbe_assertion(type, expected, actual)
    asm = qbe_to_asm(qbe)
    build_assertion()
    return bool(run_assertion())

# negation is wrapping?
min_i32 = -2147483648
# min_i32 = -2147483647

print(qbe_assert('w', min_i32, 'neg -2147483648'))
