import unittest
import io
from enum import Enum, unique

@unique
class Token(Enum):
    EOF = 0
    LPAREN = 4
    RPAREN = 5
    SYMBOL = 6
    STRING = 7
    COLON = 8
    COMMA = 9
    PLUS = 10
    MINUS = 11
    ASTERISK = 12
    SOLIDUS = 13
    LESS = 14
    GREATER = 15
    EQUAL = 16
    BANG = 17
    LSBRACKET = 18
    RSBRACKET = 19
    LCBRACKET = 20
    RCBRACKET = 21
    INTEGER = 22

class LexError(Exception):
    pass

class EOFException(Exception):
    pass

class Lexer:
    curr = 0
    line = 1 # 1 indexed, latent increment
    col = 0 # 1 indexed, immediate increment
    indent = 0 # 0 indexed, immediate increment

    def __init__(self, buf: str):
        self.buf = buf
    def __peek(self):
        if self.curr == len(self.buf):
            raise EOFException
        return self.buf[self.curr]
    def __prior(self):
        if self.curr > 0:
            return self.buf[self.curr - 1]
        else:
            return ''
    def __take(self):
        val = self.__peek()
        if self.__prior() == '\n':
            self.line += 1
            self.col = 0
        else:
            self.col += 1
        self.curr += 1
        return val
    # needle must be a single char
    def __take_string(self) -> str:
        val = io.StringIO()
        while self.__peek() != '"' or self.__prior() == '\\':
            val.write(self.__take())
        self.__take() # throwaway terminal quote
        return val.getvalue()
    def __take_indents(self):
        self.indent = 0
        while self.__peek() == '\t':
            self.indent += 1
            self.__take() # throwaway indents

    def __location(self) -> (int, int):
        return (self.indent, self.line, self.col)

    def next(self):
        try:
            val = self.__take()
            if val == '(':
                return (Token.LPAREN, self.__location())
            elif val == ')':
                return (Token.RPAREN, self.__location())
            elif val == ' ':
                return self.next()
            elif val == '\t':
                return self.next()
            elif val == '\n':
                self.__take_indents()
                return self.next()
            elif val == ':':
                return (Token.COLON, self.__location())
            elif val == ',':
                return (Token.COMMA, self.__location())
            elif val == '+':
                return (Token.PLUS, self.__location())
            elif val == '-':
                return (Token.MINUS, self.__location())
            elif val == '*':
                return (Token.ASTERISK, self.__location())
            elif val == '/':
                return (Token.SOLIDUS, self.__location())
            elif val == '<':
                return (Token.LESS, self.__location())
            elif val == '>':
                return (Token.GREATER, self.__location())
            elif val == '=':
                return (Token.EQUAL, self.__location())
            elif val == '!':
                return (Token.BANG, self.__location())
            elif val == '[':
                return (Token.LSBRACKET, self.__location())
            elif val == ']':
                return (Token.RSBRACKET, self.__location())
            elif val == '{':
                return (Token.LCBRACKET, self.__location())
            elif val == '}':
                return (Token.RCBRACKET, self.__location())
            elif val == '"':
                begin = self.__location()
                string = self.__take_string()
                return (Token.STRING, begin, self.__location(), string)
            elif val >= 'A' and val <= 'z':
                begin = self.__location()
                ret_val = io.StringIO()
                ret_val.write(val)
                next_val = val
                while next_val >= 'A' and next_val <= 'z':
                    ret_val.write(self.__take())
                    try:
                        next_val = self.__peek()
                    except EOFException:
                        break
                return (Token.SYMBOL, begin, self.__location(), ret_val.getvalue())
            elif val >= '0' and val <= '9':
                begin = self.__location()
                ret_val = io.StringIO()
                ret_val.write(val)
                try:
                    while self.__peek() >= '0' and self.__peek() <= '9':
                        ret_val.write(self.__take())
                except EOFException:
                    pass
                return (Token.INTEGER, begin, self.__location(), ret_val.getvalue())
            else:
                raise LexError
        except EOFException:
            return (Token.EOF, self.__location())

class TestLexer(unittest.TestCase):
    def test__take(self):
        lexer = Lexer("F")
        self.assertEqual(lexer.curr, 0)
        self.assertEqual(lexer._Lexer__take(), 'F') # unmangling this will suck
        self.assertEqual(lexer.curr, 1)

    def test__peek(self):
        lexer = Lexer("F")
        self.assertEqual(lexer.curr, 0)
        self.assertEqual(lexer._Lexer__peek(), 'F')
        self.assertEqual(lexer.curr, 0)

    def test_parens(self):
        lexer = Lexer("()")
        self.assertEqual(lexer.next(), (Token.LPAREN, (0, 1, 1)))
        self.assertEqual(lexer.next(), (Token.RPAREN, (0, 1, 2)))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 2)))

    def test_operators(self):
        lexer = Lexer(":,+-*/<>=![]{}")
        self.assertEqual(lexer.next(), (Token.COLON, (0, 1, 1)))
        self.assertEqual(lexer.next(), (Token.COMMA, (0, 1, 2)))
        self.assertEqual(lexer.next(), (Token.PLUS, (0, 1, 3)))
        self.assertEqual(lexer.next(), (Token.MINUS, (0, 1, 4)))
        self.assertEqual(lexer.next(), (Token.ASTERISK, (0, 1, 5)))
        self.assertEqual(lexer.next(), (Token.SOLIDUS, (0, 1, 6)))
        self.assertEqual(lexer.next(), (Token.LESS, (0, 1, 7)))
        self.assertEqual(lexer.next(), (Token.GREATER, (0, 1, 8)))
        self.assertEqual(lexer.next(), (Token.EQUAL, (0, 1, 9)))
        self.assertEqual(lexer.next(), (Token.BANG, (0, 1, 10)))
        self.assertEqual(lexer.next(), (Token.LSBRACKET, (0, 1, 11)))
        self.assertEqual(lexer.next(), (Token.RSBRACKET, (0, 1, 12)))
        self.assertEqual(lexer.next(), (Token.LCBRACKET, (0, 1, 13)))
        self.assertEqual(lexer.next(), (Token.RCBRACKET, (0, 1, 14)))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 14)))

    def test_whitespace_ignored(self):
        lexer = Lexer(" \t\n")
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 3)))

    def test_indents(self):
        lexer = Lexer("\t+\n\t\t+\n\t\t\t+\n")
        # TODO: a bit wrong :/
        self.assertEqual(lexer.next(), (Token.PLUS, (0, 1, 2)))
        self.assertEqual(lexer.next(), (Token.PLUS, (2, 2, 2)))
        self.assertEqual(lexer.next(), (Token.PLUS, (3, 3, 3)))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 3, 4)))

    def test_symbol(self):
        lexer = Lexer("thing ")
        self.assertEqual(lexer.next(), (Token.SYMBOL, (0, 1, 1), (0, 1, 5), 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 6)))

    def test_expression(self):
        lexer = Lexer("1 + 2")
        self.assertEqual(lexer.next(), (Token.INTEGER, (0, 1, 1), (0, 1, 1), '1'))
        self.assertEqual(lexer.next(), (Token.PLUS, (0, 1, 3)))
        self.assertEqual(lexer.next(), (Token.INTEGER, (0, 1, 5), (0, 1, 5), '2'))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 5)))

    def test_symbol_terminal(self):
        lexer = Lexer("thing")
        self.assertEqual(lexer.next(), (Token.SYMBOL, (0, 1, 1), (0, 1, 5), 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 5)))

    def test_integer_terminal(self):
        lexer = Lexer("100")
        self.assertEqual(lexer.next(), (Token.INTEGER, (0, 1, 1), (0, 1, 3), '100'))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 3)))

    def test_string(self):
        lexer = Lexer("\"thing\"")
        self.assertEqual(lexer.next(), (Token.STRING, (0, 1, 1), (0, 1, 7), 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF, (0, 1, 7)))

if __name__ == '__main__':
    unittest.main()
