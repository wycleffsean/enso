from enum import Enum, unique
from collections import namedtuple

@unique
class Type(Enum):
    INTEGER = 0
    PLUS = 1

Group = namedtuple("Group", "expr")
InfixMethod = namedtuple("InfixMethod", "name left right")
Literal = namedtuple("Literal", "type value")
