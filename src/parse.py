import unittest
import lex
import ast
from ast import Type
from enum import Enum, unique

class ParseError(Exception):
    pass

def parse(buf: str):
    lexer = lex.Lexer(buf)
    parser = Parser(lexer)
    return parser.parse()

class Precedence(Enum):
    LOWEST = 0
    EQUALITY = 1
    LESSGREATER = 2
    SUM = 3
    PRODUCT = 4
    PREFIX = 5
    CALL = 6

PRECEDENCE_MAP = {
    lex.Token.PLUS: Precedence.SUM,
    lex.Token.MINUS: Precedence.SUM,
    lex.Token.ASTERISK: Precedence.PRODUCT,
    lex.Token.SOLIDUS: Precedence.PRODUCT,
    lex.Token.LESS: Precedence.LESSGREATER,
    lex.Token.GREATER: Precedence.LESSGREATER,
}

NULL_DENOTATIONS = {
    lex.Token.INTEGER: "parse_integer",
    lex.Token.LPAREN: "parse_group",
    lex.Token.EOF: "parse_eof",
}

LEFT_DENOTATIONS = {
    lex.Token.ASTERISK: "parse_infix_product",
    lex.Token.PLUS: "parse_infix_sum",
    lex.Token.SOLIDUS: "parse_infix_division",
}

class Parser:
    cur_token = None

    def __init__(self, lexer: lex.Lexer):
        self.lexer = lexer

    def __advance(self):
        self.cur_token = self.lexer.next()

    def __consume(self, op):
        tok = self.cur_token
        if self.cur_token[0] == op:
            self.__advance()
        else:
            raise ParseError("expected: " + repr(op), self.cur_token)
        return tok

    def __cur_type(self):
        return self.cur_token[0]

    def parse_eof(self):
        _ = self.__consume(lex.Token.EOF)
        return None

    def parse_group(self):
        _ = self.__consume(lex.Token.LPAREN)
        val = self.parse_expression(Precedence.LOWEST)
        _ = self.__consume(lex.Token.RPAREN)
        return ast.Group(val)

    def parse_integer(self):
        tok = self.__consume(lex.Token.INTEGER)
        return ast.Literal(Type.INTEGER, int(tok[3]))

    def parse_infix_division(self, left):
        tok = self.__consume(lex.Token.SOLIDUS)
        precedence = PRECEDENCE_MAP[tok[0]]
        right = self.parse_expression(precedence)
        # TODO: rename
        return ast.InfixMethod("division", left, right)

    def parse_infix_product(self, left):
        tok = self.__consume(lex.Token.ASTERISK)
        precedence = PRECEDENCE_MAP[tok[0]]
        right = self.parse_expression(precedence)
        return ast.InfixMethod("product", left, right)

    def parse_infix_sum(self, left):
        tok = self.__consume(lex.Token.PLUS)
        precedence = PRECEDENCE_MAP[tok[0]]
        right = self.parse_expression(precedence)
        return ast.InfixMethod("sum", left, right)

    def parse_expression(self, precedence):
        nud = NULL_DENOTATIONS.get(self.__cur_type())
        # in the future we could continue parsing
        # and reveal additional errors in source
        if nud == None:
            raise ParseError(self.cur_token)
        left = getattr(self, nud)()
        while self.cur_token and precedence.value < PRECEDENCE_MAP.get(self.__cur_type(), Precedence.LOWEST).value:
            led = LEFT_DENOTATIONS[self.__cur_type()]
            if led == None:
                raise ParseError(self.cur_token)
            fn = getattr(self, led)
            left = fn(left)
        return left

    def parse(self):
        arr = []
        while True:
            self.__advance()
            res = self.parse_expression(Precedence.LOWEST)
            if res == None:
                break
            arr.append(res)
        return arr

class TestParser(unittest.TestCase):
    maxDiff = None
    def setUp(self):
        self.one = ast.Literal(Type.INTEGER, 1)
        self.two = ast.Literal(Type.INTEGER, 2)
        self.three = ast.Literal(Type.INTEGER, 3)

    def test_infix_sum(self):
        val = parse('1 + 2')
        self.assertEqual(val, [ast.InfixMethod('sum', self.one, self.two)])

    def test_infix_product(self):
        val = parse('1 + 2 * 3')
        self.assertEqual(val, [ast.InfixMethod('sum', self.one, ast.InfixMethod('product', self.two, self.three))])

    def test_infix_division(self):
        val = parse('2 + 2 / 2')
        self.assertEqual(val, [ast.InfixMethod('sum', self.two, ast.InfixMethod('division', self.two, self.two))])

    def test_group(self):
        val = parse('(2 + 2) / 2')
        self.assertEqual(val, [
            ast.InfixMethod('division',
                ast.Group(
                    ast.InfixMethod('sum', self.two, self.two)
                ),
                self.two
                )])

if __name__ == '__main__':
    unittest.main()
