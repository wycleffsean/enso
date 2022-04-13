import unittest
import io
from enum import Enum, unique

@unique
class Token(Enum):
    EOF = 0
    SPACE = 1
    INDENT = 2
    NEWLINE = 3
    LPAREN = 4
    RPAREN = 5
    COLON = 6
    SYMBOL = 7
    STRING = 8

class LexError(Exception):
    pass

class EOFException(Exception):
    pass

class Lexer:
    curr = 0
    line = 1 # 1 indexed, latent increment
    col = 0 # 1 indexed, immediate increment

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
    def __location(self) -> (int, int):
        return (self.line, self.col)

    def next(self):
        try:
            val = self.__take()
            if val == '(':
                return (Token.LPAREN, self.__location())
            elif val == ')':
                return (Token.RPAREN, self.__location())
            elif val == ' ':
                return (Token.SPACE, self.__location())
            elif val == '\t':
                return (Token.INDENT, self.__location())
            elif val == '\n':
                return (Token.NEWLINE, self.__location())
            elif val == ':':
                return (Token.COLON, self.__location())
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
        self.assertEqual(lexer.next(), (Token.LPAREN, (1, 1)))
        self.assertEqual(lexer.next(), (Token.RPAREN, (1, 2)))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 2)))

    def test_colon(self):
        lexer = Lexer(":")
        self.assertEqual(lexer.next(), (Token.COLON, (1, 1)))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 1)))

    def test_whitespace(self):
        lexer = Lexer(" \t\n")
        self.assertEqual(lexer.next(), (Token.SPACE, (1, 1)))
        self.assertEqual(lexer.next(), (Token.INDENT, (1, 2)))
        self.assertEqual(lexer.next(), (Token.NEWLINE, (1, 3)))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 3)))

    def test_symbol(self):
        lexer = Lexer("thing ")
        self.assertEqual(lexer.next(), (Token.SYMBOL, (1, 1), (1, 5), 'thing'))
        self.assertEqual(lexer.next(), (Token.SPACE, (1, 6)))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 6)))

    def test_symbol_terminal(self):
        lexer = Lexer("thing")
        self.assertEqual(lexer.next(), (Token.SYMBOL, (1, 1), (1, 5), 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 5)))

    def test_string(self):
        lexer = Lexer("\"thing\"")
        self.assertEqual(lexer.next(), (Token.STRING, (1, 1), (1, 7), 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF, (1, 7)))

if __name__ == '__main__':
    unittest.main()
