class Larimar::Parser
  module AST
    abstract class Node
      include JSON::Serializable

      getter parent : Node?

      macro inherited
        getter node : String = {{ @type.name.stringify.split("::").last }}
      end
    end

    class Nop < Node
      def initialize(@parent)
      end
    end

    class Expressions < Node
      getter children : Array(Node)?

      def initialize(@parent, @children)
      end
    end

    class NilLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class BoolLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class NumberLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class CharLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class StringLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class SymbolLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class ArrayLiteral < Node
      getter left_bracket : Token
      getter elements : Array(Tuple(Node, Token))?
      getter last_element : Node?
      getter right_bracket : Token
      getter of : Token?
      getter type : Node

      def initialize(
        @parent, @left_bracket, @elements, @last_element, @right_bracket,
        @of, @type
      )
      end
    end

    class RangeLiteral < Node
      getter from : Node
      getter dots : Token
      getter to : Node

      def initialize(@parent, @from, @dots, @to)
      end
    end

    class RegexLiteral < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class SpecialVar < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class Var < Node
      getter token : String

      def initialize(@parent, @token)
      end
    end

    class Path < Node
      getter start_colon : Token?
      getter names : Array(Token)

      def initialize(@parent, @start_colon, @names)
      end
    end

    class ClassDef < Node
      getter class_keyword : Token
      getter name : Node
      getter super_arrow : Token
      getter super_name : Node
      getter body : Node

      def initialize(
        @parent, @class_keyword, @name, @super_arrow, @super_name, @body
      )
      end
    end

    class Self < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end

    class Or < Node
      getter left : Node
      getter operator : Token
      getter right : Node

      def initialize(@parent, @left, @operator, @right)
      end
    end

    class And < Node
      getter left : Node
      getter operator : Token
      getter right : Node

      def initialize(@parent, @left, @operator, @right)
      end
    end

    class Call < Node
      getter obj : Node
      getter dot : Token?
      getter name : Token
      getter lparen : Token?
      getter args : Array(Node)
      getter rparen : Token?

      def initialize(@parent, @obj, @dot, @name, @lparen, @args, @rparen)
      end

      def self.new(parent : Node?, obj : Node, name : Token, arg : Node)
        new(parent, obj, nil, name, nil, [arg] of Node, nil)
      end

      def self.new(parent : Node?, obj : Node, name : Token)
        new(parent, obj, nil, name, nil, [] of Node, nil)
      end
    end

    class Not < Node
      getter mark : Token
      getter expression : Node

      def initialize(@parent, @expression, @mark)
      end
    end

    class Error < Node
      getter token : Token

      def initialize(@parent, @token)
      end
    end
  end
end
