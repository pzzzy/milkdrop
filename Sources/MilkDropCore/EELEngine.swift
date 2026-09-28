import Foundation

/// Portable interpreter for the NS-EEL subset used by MilkDrop preset init/frame programs.
/// It deliberately avoids the original x86 JIT, which emits x86-64 machine code on any LP64 target.
public struct EELEngine: Sendable {
    private var statements: [Statement]

    public init(source: String) throws {
        var parser = Parser(source)
        statements = try parser.program()
    }

    public func execute(variables: inout [String: Double]) throws {
        variables["pi"] = .pi
        variables["e"] = M_E
        for statement in statements { try statement.execute(&variables) }
    }

    public var isEmpty: Bool { statements.isEmpty }
}

private enum Statement: Sendable {
    case assignment(String, AssignOp, Expression)
    case expression(Expression)


    func execute(_ variables: inout [String: Double]) throws {
        switch self {
        case let .assignment(name, op, expression):
            let rhs = try expression.evaluate(&variables)
            let lhs = variables[name] ?? 0
            switch op {
            case .set: variables[name] = rhs
            case .add: variables[name] = lhs + rhs
            case .subtract: variables[name] = lhs - rhs
            case .multiply: variables[name] = lhs * rhs
            case .divide: variables[name] = abs(rhs) < 1e-20 ? 0 : lhs / rhs
            case .modulo: variables[name] = abs(rhs) < 1e-20 ? 0 : lhs.truncatingRemainder(dividingBy: rhs)
            }
        case let .expression(expression): _ = try expression.evaluate(&variables)
        }
    }
}

private enum AssignOp: Sendable { case set, add, subtract, multiply, divide, modulo }
private indirect enum Expression: Sendable {
    case number(Double), variable(String), unary(String, Expression), binary(String, Expression, Expression), call(String, [Expression])
    case sequence([Expression])
    case assignment(Expression, AssignOp, Expression)


    func value(_ v: [String: Double]) throws -> Double {
        switch self {
        case let .number(x): return x
        case let .variable(name): return v[name] ?? 0
        case let .unary(op, x):
            let a = try x.value(v)
            if op == "-" { return -a }
            if op == "!" { return truth(a) ? 0 : 1 }
            return a
        case let .binary(op, l, r):
            if op == "&&" {
                let left = try l.value(v)
                if !truth(left) { return 0 }
                return truth(try r.value(v)) ? 1 : 0
            }
            if op == "||" {
                let left = try l.value(v)
                if truth(left) { return 1 }
                return truth(try r.value(v)) ? 1 : 0
            }
            let a = try l.value(v), b = try r.value(v)
            return try binaryValue(op, a, b)
        case let .call(name, args):
            // Preserve NS-EEL's conditional behavior for the common if/select forms.
            if name == "if", args.count == 3 { return truth(try args[0].value(v)) ? try args[1].value(v) : try args[2].value(v) }
            return try withUnsafeTemporaryAllocation(of: Double.self, capacity: args.count) { a in
                for index in args.indices { a[index] = try args[index].value(v) }
                switch name {
            case "sin": return sin(arg(a, 0)); case "cos": return cos(arg(a, 0)); case "tan": return tan(arg(a, 0))
            case "asin": return asin(clamp(arg(a, 0), -1, 1)); case "acos": return acos(clamp(arg(a, 0), -1, 1)); case "atan": return atan(arg(a, 0)); case "atan2": return atan2(arg(a, 0), arg(a, 1))
            case "sqrt": return sqrt(max(0, arg(a, 0))); case "sqr": return arg(a, 0) * arg(a, 0)
            case "abs": return abs(arg(a, 0)); case "sign": return arg(a, 0) < 0 ? -1 : (arg(a, 0) > 0 ? 1 : 0)
            case "log": return log(max(arg(a, 0), 1e-20)); case "log10": return log10(max(arg(a, 0), 1e-20)); case "exp": return exp(arg(a, 0)); case "pow": return pow(arg(a, 0), arg(a, 1))
            case "floor": return floor(arg(a, 0)); case "ceil": return ceil(arg(a, 0)); case "int": return Double(Int(arg(a, 0)))
            case "min": return min(arg(a, 0), arg(a, 1)); case "max": return max(arg(a, 0), arg(a, 1)); case "clamp": return clamp(arg(a, 0), arg(a, 1), arg(a, 2))
            case "above": return arg(a, 0) > arg(a, 1) ? 1 : 0; case "below": return arg(a, 0) < arg(a, 1) ? 1 : 0; case "equal": return abs(arg(a, 0) - arg(a, 1)) < 1e-5 ? 1 : 0
            case "bnot": return truth(arg(a, 0)) ? 0 : 1
            case "band": return arg(a, 0) >= arg(a, 1) && arg(a, 0) <= arg(a, 2) ? 1 : 0
            case "sigmoid": return 1 / (1 + exp(-arg(a, 0) * arg(a, 1)))
            case "rand": let limit = max(Int(abs(arg(a, 0))), 1); return Double.random(in: 0..<Double(limit))
            case "bor": return Double(Int64(arg(a, 0)) | Int64(arg(a, 1))); case "bandor": return Double(Int64(arg(a, 0)) & Int64(arg(a, 1)))
            default: throw EELError.unsupportedFunction(name)
            }
            }
        case let .sequence(expressions):
            var result = 0.0
            for expression in expressions { result = try expression.value(v) }
            return result
        case .assignment: throw EELError.expected("mutable assignment context")
        }
    }

    func evaluate(_ variables: inout [String: Double]) throws -> Double {
        switch self {
        case let .assignment(target, op, rhs):
            let value = try rhs.evaluate(&variables)
            let key: String
            if case let .variable(name) = target { key = name }
            else if case let .call(name, args) = target, (name == "gmegabuf" || name == "megabuf") {
                key = "\(name)[\(Int(try args[0].evaluate(&variables)))]"
            } else { throw EELError.expected("assignable EEL lvalue") }
            let old = variables[key] ?? 0
            let result: Double
            switch op {
            case .set: result = value
            case .add: result = old + value
            case .subtract: result = old - value
            case .multiply: result = old * value
            case .divide: result = abs(value) < 1e-20 ? 0 : old / value
            case .modulo: result = abs(value) < 1e-20 ? 0 : old.truncatingRemainder(dividingBy: value)
            }
            variables[key] = result
            return result
        case let .variable(name): return variables[name] ?? 0
        case let .call(name, args) where name == "gmegabuf" || name == "megabuf":
            return variables["\(name)[\(Int(try args[0].evaluate(&variables)))]"] ?? 0
        case let .call(name, args) where name == "bnot":
            return truth(try args[0].evaluate(&variables)) ? 0 : 1
        case let .call(name, args) where name == "loop" && args.count == 2:
            let count = max(0, min(Int(try args[0].evaluate(&variables)), 100_000))
            var result = 0.0
            for _ in 0..<count { result = try args[1].evaluate(&variables) }
            return result
        case let .call(name, args) where name == "while" && args.count == 2:
            var result = 0.0
            var iterations = 0
            while truth(try args[0].evaluate(&variables)) && iterations < 100_000 {
                result = try args[1].evaluate(&variables)
                iterations += 1
            }
            return result
        case let .call(name, args) where name == "if" && args.count == 3:
            return truth(try args[0].evaluate(&variables)) ? try args[1].evaluate(&variables) : try args[2].evaluate(&variables)
        case let .call(name, args) where name == "exec2" || name == "exec3":
            var result = 0.0
            for argument in args { result = try argument.evaluate(&variables) }
            return result
        case let .sequence(expressions):
            var result = 0.0
            for expression in expressions { result = try expression.evaluate(&variables) }
            return result
        case let .unary(op, expression):
            let value = try expression.evaluate(&variables)
            return op == "-" ? -value : (op == "!" ? (truth(value) ? 0 : 1) : value)
        case let .binary(op, left, right):
            let a = try left.evaluate(&variables), b = try right.evaluate(&variables)
            return try binaryValue(op, a, b)
        default: return try value(variables)
        }
    }
}

private func binaryValue(_ op: String, _ a: Double, _ b: Double) throws -> Double {
    switch op {
    case "+": return a + b
    case "-": return a - b
    case "*": return a * b
    case "/": return abs(b) < 1e-20 ? 0 : a / b
    case "%": return abs(b) < 1e-20 ? 0 : a.truncatingRemainder(dividingBy: b)
    case "^": return pow(a, b)
    case "<": return a < b ? 1 : 0
    case ">": return a > b ? 1 : 0
    case "<=": return a <= b ? 1 : 0
    case ">=": return a >= b ? 1 : 0
    case "==": return abs(a - b) < 1e-5 ? 1 : 0
    case "!=": return abs(a - b) >= 1e-5 ? 1 : 0
    case "&&": return truth(a) && truth(b) ? 1 : 0
    case "||": return truth(a) || truth(b) ? 1 : 0
    default: throw EELError.unsupportedOperator(op)
    }
}

private func arg<C: RandomAccessCollection>(_ values: C, _ index: Int) -> Double where C.Element == Double {
    index < values.count ? values[values.index(values.startIndex, offsetBy: index)] : 0
}
private func truth(_ x: Double) -> Bool { abs(x) > 1e-5 }
private func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double { min(max(x, low), high) }

public enum EELError: LocalizedError, Sendable {
    case unexpectedToken(String), expected(String), unsupportedOperator(String), unsupportedFunction(String)
    public var errorDescription: String? {
        switch self {
        case let .unexpectedToken(x): "Unexpected EEL token: \(x)"
        case let .expected(x): "Expected EEL token: \(x)"
        case let .unsupportedOperator(x): "Unsupported EEL operator: \(x)"
        case let .unsupportedFunction(x): "Unsupported EEL function: \(x)"
        }
    }
}

private enum Token: Equatable { case number(Double), identifier(String), symbol(String), end }
private struct Lexer {
    private let characters: [Character]; private var index = 0
    init(_ source: String) { characters = Array(source.replacingOccurrences(of: "\r", with: "\n")) }
    mutating func next() -> Token {
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" { while index < characters.count && characters[index] != "\n" { index += 1 }; continue }
            break
        }
        guard index < characters.count else { return .end }
        let c = characters[index]
        if c.isNumber || c == "." {
            let start = index; index += 1
            while index < characters.count && (characters[index].isNumber || ".eE+-".contains(characters[index])) {
                if (characters[index] == "+" || characters[index] == "-") && !"eE".contains(characters[index - 1]) { break }
                index += 1
            }
            return .number(Double(String(characters[start..<index])) ?? 0)
        }
        if c.isLetter || c == "_" {
            let start = index; index += 1
            while index < characters.count && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_") { index += 1 }
            return .identifier(String(characters[start..<index]).lowercased())
        }
        if index + 1 < characters.count {
            let pair = String(characters[index...index + 1])
            if ["+=","-=","*=","/=","%=","<=",">=","==","!=","&&","||"].contains(pair) { index += 2; return .symbol(pair) }
        }
        index += 1; return .symbol(String(c))
    }
}

private struct Parser {
    private var lexer: Lexer; private var current: Token
    init(_ source: String) { var l = Lexer(source); current = l.next(); lexer = l }
    mutating func program() throws -> [Statement] {
        var out: [Statement] = []
        while current != .end {
            if current == .symbol(";") { advance(); continue }
            out.append(try statement())
            if current == .symbol(";") { advance() }
        }
        return out
    }
    private mutating func statement() throws -> Statement {
        if case let .identifier(name) = current {
            var copy = self; copy.advance()
            if case let .symbol(op) = copy.current, ["=","+=","-=","*=","/=","%="].contains(op) {
                advance(); advance()
                return .assignment(name, assignOp(op), try expression(0))
            }
        }
        return .expression(try expression(0))
    }
    private mutating func expression(_ minimum: Int) throws -> Expression {
        var left = try prefix()
        if minimum == 0, case let .symbol(op) = current,
           ["=", "+=", "-=", "*=", "/=", "%="].contains(op) {
            advance()
            return .assignment(left, assignOp(op), try expression(0))
        }
        while case let .symbol(op) = current, let precedence = precedence(op), precedence >= minimum {
            advance(); let right = try expression(precedence + (op == "^" ? 0 : 1)); left = .binary(op, left, right)
        }
        return left
    }
    private mutating func argument() throws -> Expression {
        var expressions: [Expression] = [try expression(0)]
        while current == .symbol(";") {
            advance()
            if current == .symbol(")") || current == .symbol(",") { break }
            expressions.append(try expression(0))
        }
        return expressions.count == 1 ? expressions[0] : .sequence(expressions)
    }
    private mutating func prefix() throws -> Expression {
        switch current {
        case let .number(x): advance(); return .number(x)
        case let .identifier(name):
            advance()
            if current == .symbol("(") {
                advance(); var args: [Expression] = []
                if current != .symbol(")") {
                    while true {
                        args.append(try argument())
                        if current != .symbol(",") { break }
                        advance()
                    }
                }
                guard current == .symbol(")") else { throw EELError.expected(")") }; advance(); return .call(name, args)
            }
            return .variable(name)
        case let .symbol(op) where ["+","-","!"].contains(op): advance(); return .unary(op, try expression(8))
        case .symbol("("): advance(); let x = try expression(0); guard current == .symbol(")") else { throw EELError.expected(")") }; advance(); return x
        default: throw EELError.unexpectedToken("\(current)")
        }
    }
    private mutating func advance() { current = lexer.next() }
}
private func precedence(_ op: String) -> Int? { ["||":1,"&&":2,"==":3,"!=":3,"<":4,">":4,"<=":4,">=":4,"+":5,"-":5,"*":6,"/":6,"%":6,"^":7][op] }
private func assignOp(_ op: String) -> AssignOp { ["+=":.add,"-=":.subtract,"*=":.multiply,"/=":.divide,"%=":.modulo][op] ?? .set }
