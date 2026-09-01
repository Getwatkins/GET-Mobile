import Foundation

/// Direct port of Communication/Simos18/Logging/EquationEvaluator.cs -
/// same tiny recursive-descent grammar (+, -, *, /, parentheses, numbers,
/// "x" and named variables), so the same equation string ("x / 1024",
/// "((x / 10) * 0.1450777202) - 14", etc.) evaluates identically here as
/// it does in the Windows app.
enum EquationEvaluator {
    enum EquationError: Error { case malformed(String) }

    static func evaluate(_ equation: String, variables: [String: Double]) throws -> Double {
        let tokens = tokenize(equation)
        var pos = 0
        let result = try parseExpression(tokens, &pos, variables)
        guard pos == tokens.count else {
            throw EquationError.malformed("Unexpected token \"\(tokens[pos])\" in equation \"\(equation)\".")
        }
        return result
    }

    private static func parseExpression(_ tokens: [String], _ pos: inout Int, _ vars: [String: Double]) throws -> Double {
        var value = try parseTerm(tokens, &pos, vars)
        while pos < tokens.count, tokens[pos] == "+" || tokens[pos] == "-" {
            let op = tokens[pos]; pos += 1
            let rhs = try parseTerm(tokens, &pos, vars)
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private static func parseTerm(_ tokens: [String], _ pos: inout Int, _ vars: [String: Double]) throws -> Double {
        var value = try parseUnary(tokens, &pos, vars)
        while pos < tokens.count, tokens[pos] == "*" || tokens[pos] == "/" {
            let op = tokens[pos]; pos += 1
            let rhs = try parseUnary(tokens, &pos, vars)
            value = op == "*" ? value * rhs : value / rhs
        }
        return value
    }

    private static func parseUnary(_ tokens: [String], _ pos: inout Int, _ vars: [String: Double]) throws -> Double {
        if pos < tokens.count, tokens[pos] == "-" {
            pos += 1
            return -(try parseUnary(tokens, &pos, vars))
        }
        if pos < tokens.count, tokens[pos] == "+" {
            pos += 1
            return try parseUnary(tokens, &pos, vars)
        }
        return try parsePrimary(tokens, &pos, vars)
    }

    private static func parsePrimary(_ tokens: [String], _ pos: inout Int, _ vars: [String: Double]) throws -> Double {
        guard pos < tokens.count else { throw EquationError.malformed("Unexpected end of equation.") }
        let token = tokens[pos]

        if token == "(" {
            pos += 1
            let value = try parseExpression(tokens, &pos, vars)
            guard pos < tokens.count, tokens[pos] == ")" else {
                throw EquationError.malformed("Missing closing parenthesis in equation.")
            }
            pos += 1
            return value
        }

        if let numberValue = Double(token) {
            pos += 1
            return numberValue
        }

        // Identifier - "x" or a named variable. Unknown variables evaluate
        // to 0, matching the C# port's (and VW_Flash's own Python eval's)
        // fallback behavior.
        pos += 1
        return vars[token] ?? 0.0
    }

    private static func tokenize(_ equation: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(equation)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace { i += 1; continue }

            if "+-*/()".contains(c) {
                tokens.append(String(c)); i += 1; continue
            }

            if c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                tokens.append(String(chars[i..<j])); i = j; continue
            }

            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(String(chars[i..<j]).lowercased()); i = j; continue
            }

            i += 1 // unexpected character - skip rather than crash on a live gauge read
        }

        return tokens
    }
}
