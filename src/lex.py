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

class Lex:
    curr = 0

    def __init__(self, buf: str):
        self.buf = buf
    def __peek(self):
        if self.curr == len(self.buf):
            raise EOFException
        return self.buf[self.curr]
    def __peek(self):
        if self.curr == len(self.buf):
            raise EOFException
        return self.buf[self.curr]
    def __prior(self):
        return self.buf[self.curr - 1]
    def __take(self):
        val = self.__peek()
        self.curr += 1
        return val
    # needle must be a single char
    def __take_string(self) -> str:
        val = io.StringIO()
        while self.__peek() != '"' or self.__prior() == '\\':
            val.write(self.__take())
        return val.getvalue()

    def next(self):
        #if self.curr == len(self.string):

        try:
            val = self.__take()
            if val == '(':
                return (Token.LPAREN)
            elif val == ')':
                return (Token.RPAREN)
            elif val == ' ':
                return (Token.SPACE)
            elif val == '\t':
                return (Token.INDENT)
            elif val == '\n':
                return (Token.NEWLINE)
            elif val == ':':
                return (Token.COLON)
            elif val == '"':
                return (Token.STRING, self.__take_string())
            elif val >= 'A' and val <= 'z':
                ret_val = io.StringIO()
                ret_val.write(val)
                next_val = val
                while next_val >= 'A' and next_val <= 'z':
                    ret_val.write(self.__take())
                    try:
                        next_val = self.__peek()
                    except EOFException:
                        break
                return (Token.SYMBOL, ret_val.getvalue())
            else:
                raise LexError
        except EOFException:
            return (Token.EOF)

class TestLex(unittest.TestCase):
    def test__take(self):
        lexer = Lex("F")
        self.assertEqual(lexer.curr, 0)
        self.assertEqual(lexer._Lex__take(), 'F') # unmangling this will suck
        self.assertEqual(lexer.curr, 1)

    def test__peek(self):
        lexer = Lex("F")
        self.assertEqual(lexer.curr, 0)
        self.assertEqual(lexer._Lex__peek(), 'F')
        self.assertEqual(lexer.curr, 0)

    def test_parens(self):
        lexer = Lex("()")
        self.assertEqual(lexer.next(), (Token.LPAREN))
        self.assertEqual(lexer.next(), (Token.RPAREN))
        self.assertEqual(lexer.next(), (Token.EOF))

    def test_colon(self):
        lexer = Lex(":")
        self.assertEqual(lexer.next(), (Token.COLON))
        self.assertEqual(lexer.next(), (Token.EOF))

    def test_whitespace(self):
        lexer = Lex(" \t\n")
        self.assertEqual(lexer.next(), (Token.SPACE))
        self.assertEqual(lexer.next(), (Token.INDENT))
        self.assertEqual(lexer.next(), (Token.NEWLINE))
        self.assertEqual(lexer.next(), (Token.EOF))

    def test_symbol(self):
        lexer = Lex("thing ")
        self.assertEqual(lexer.next(), (Token.SYMBOL, 'thing'))
        self.assertEqual(lexer.next(), (Token.SPACE))
        self.assertEqual(lexer.next(), (Token.EOF))

    def test_symbol_terminal(self):
        lexer = Lex("thing")
        self.assertEqual(lexer.next(), (Token.SYMBOL, 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF))

    def test_string(self):
        lexer = Lex("\"thing\"")
        self.assertEqual(lexer.next(), (Token.STRING, 'thing'))
        self.assertEqual(lexer.next(), (Token.EOF))

if __name__ == '__main__':
    unittest.main()
