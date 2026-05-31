import Foundation

struct PlainTextToolCallParser {
    struct ParsedCall {
        let name: String
        var arguments: [String: Any]
    }

    private let supportedNames: [String]

    init(supportedNames: [String]) {
        self.supportedNames = supportedNames
    }

    func parse(response: String) -> ParsedCall? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        for name in supportedNames where trimmed.hasPrefix("\(name)(") && trimmed.hasSuffix(")") {
            let openParenIndex = trimmed.index(trimmed.startIndex, offsetBy: name.count)
            let argumentsStart = trimmed.index(after: openParenIndex)
            let argumentsEnd = trimmed.index(before: trimmed.endIndex)
            let rawArguments = String(trimmed[argumentsStart..<argumentsEnd])
            guard let arguments = Self.parseArguments(rawArguments) else {
                return nil
            }

            return ParsedCall(name: name, arguments: arguments)
        }

        return nil
    }

    static func parseArguments(_ rawArguments: String) -> [String: Any]? {
        var result: [String: Any] = [:]
        var index = rawArguments.startIndex

        func skipWhitespaceAndCommas() {
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isWhitespace || character == "," {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
        }

        func parseKey() -> String? {
            let start = index
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isLetter || character.isNumber || character == "_" {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
            guard start < index else { return nil }
            return String(rawArguments[start..<index])
        }

        func parseQuotedString(quote: Character) -> String? {
            index = rawArguments.index(after: index)
            var value = ""
            var isEscaping = false

            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                index = rawArguments.index(after: index)

                if isEscaping {
                    switch character {
                    case "n":
                        value.append("\n")
                    case "t":
                        value.append("\t")
                    case "r":
                        value.append("\r")
                    case "\\", "\"", "'":
                        value.append(character)
                    default:
                        value.append(character)
                    }
                    isEscaping = false
                    continue
                }

                if character == "\\" {
                    isEscaping = true
                    continue
                }

                if character == quote {
                    return value
                }

                value.append(character)
            }

            return nil
        }

        func parseBareValue() -> Any {
            let start = index
            while index < rawArguments.endIndex, rawArguments[index] != "," {
                index = rawArguments.index(after: index)
            }
            let value = String(rawArguments[start..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            case "none", "null":
                return NSNull()
            default:
                if let intValue = Int(value) {
                    return intValue
                }
                if let doubleValue = Double(value) {
                    return doubleValue
                }
                return value
            }
        }

        while index < rawArguments.endIndex {
            skipWhitespaceAndCommas()
            guard index < rawArguments.endIndex else { break }
            guard let key = parseKey() else { return nil }

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex, rawArguments[index] == "=" else {
                return nil
            }
            index = rawArguments.index(after: index)

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex else { return nil }

            let value: Any
            if rawArguments[index] == "\"" || rawArguments[index] == "'" {
                guard let stringValue = parseQuotedString(quote: rawArguments[index]) else {
                    return nil
                }
                value = stringValue
            } else {
                value = parseBareValue()
            }

            result[key] = value
        }

        return result.isEmpty ? nil : result
    }
}
