import Foundation

/// Command-line quoting for an argv editor. This never evaluates a shell,
/// expands variables, or treats shell operators as commands.
public enum ArgumentText {
    public static func parse(_ text: String) throws -> [String] {
        enum Quote { case none, single, double }
        let characters = Array(text)
        var quote = Quote.none, token = "", started = false, index = 0
        var result: [String] = []
        while index < characters.count {
            let character = characters[index]
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { token.append(character) }
            case .double:
                if character == "\"" { quote = .none }
                else if character == "\\", index + 1 < characters.count {
                    let next = characters[index + 1]
                    if ["\"", "\\", "$", "`", "\n"].contains(next) {
                        if next != "\n" { token.append(next) }
                        index += 1
                    } else { token.append(character) }
                } else { token.append(character) }
            case .none:
                if character.isWhitespace {
                    if started { result.append(token); token = ""; started = false }
                } else if character == "'" { quote = .single; started = true }
                else if character == "\"" { quote = .double; started = true }
                else if character == "\\" {
                    guard index + 1 < characters.count else { throw ChauffeurError("invalid_arguments", "Add a character after the final backslash, or remove it") }
                    index += 1
                    if characters[index] != "\n" { token.append(characters[index]); started = true }
                } else { token.append(character); started = true }
            }
            index += 1
        }
        guard quote == .none else { throw ChauffeurError("invalid_arguments", "Close the quoted value in Launch arguments") }
        if started { result.append(token) }
        return result
    }

    public static func format(_ arguments: [String]) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        return arguments.map { argument in
            if !argument.isEmpty && argument.unicodeScalars.allSatisfy(plain.contains) { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
