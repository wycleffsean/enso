from parse import parse
import gen
import os
import sys

def compile(path):
    with open(path) as f:
        ast = parse(f.read())
        generator = gen.CodeGenerator(ast)
        generator()

if __name__ == '__main__':
    print(sys.argv)
    compile(sys.argv[1])
    #os.chdir(os.path.dirname(__file__))
    #os.system("zig build run")
