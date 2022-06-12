import ast
import os
import sys
import io
import unittest

#Group = namedtuple("Group", "expr")
#InfixMethod = namedtuple("InfixMethod", "name left right")
#Literal = namedtuple("Literal", "type value")

class CodeGenerator:
    def __init__(self, ast):
        self.ast = ast
        self.buf = io.StringIO()

    def __call__(self, file = sys.stdout):
        self.__generate()
        file.write(self.buf.getvalue())

    def __generate(self):
        print(self.ast)
        self.__main()

    def __main(self, body):
        self.buf.write("""
        const std = @import("std");

        pub fn main() anyerror!void {
        """)
        body()
        self.buf.write("""
        }
        """)

class TestCodeGenerator(unittest.TestCase):
    def test__take(self):
        pass

if __name__ == '__main__':
    unittest.main()
