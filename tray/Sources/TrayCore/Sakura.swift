import Foundation

/// O logo do Kubo (flor de cerejeira), com o mesmo desenho do `<symbol id="sakura">` do agent-studio
/// (`docker/agent-studio/agent_studio/static/lucide.svg`; o `tests/oute-tray.test.sh` confere que os dois batem).
/// Caixa de 100 × 100, com o eixo y para baixo, como no SVG. Aqui fica só a geometria; quem desenha é o app (#563).
public enum Sakura {
    public struct Point: Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Segment: Equatable {
        case move(Point)
        case line(Point)
        case curve(control1: Point, control2: Point, to: Point)
        case close
    }

    public static let box: Double = 100
    public static let center = Point(x: 50, y: 50)

    /// Uma pétala; as cinco são esta, girada em volta do centro.
    public static let petalPath = "M50,50 C38,43 33,27 39,15 C42,8 47,10 50,17 C53,10 58,8 61,15 C67,27 62,43 50,50 Z"
    public static let petalAngles: [Double] = [0, 72, 144, 216, 288]
    public static let petalStroke: Double = 6

    /// Um estame, com o ponto na ponta; ficam entre as pétalas.
    public static let stamenPath = "M50,50 L50,34"
    public static let stamenAngles: [Double] = [36, 108, 180, 252, 324]
    public static let stamenStroke: Double = 3.3
    public static let stamenDot = Point(x: 50, y: 33)
    public static let stamenDotRadius: Double = 3
    public static let heartRadius: Double = 5.4

    /// Lê um caminho SVG só com `M`, `L`, `C` e `Z` absolutos (o que o logo usa). Outro comando ou número que
    /// falta = `nil`: o tray não desenha pela metade.
    public static func segments(_ path: String) -> [Segment]? {
        var tokens: [String] = []
        var number = ""
        for character in path {
            if character.isLetter || character == "," || character == " " {
                if !number.isEmpty { tokens.append(number); number = "" }
                if character.isLetter { tokens.append(String(character)) }
            } else {
                number.append(character)
            }
        }
        if !number.isEmpty { tokens.append(number) }

        var segments: [Segment] = []
        var index = 0
        func points(_ count: Int) -> [Point]? {
            guard index + count * 2 <= tokens.count else { return nil }
            let values = tokens[index..<index + count * 2].compactMap(Double.init)
            guard values.count == count * 2 else { return nil }
            index += count * 2
            return (0..<count).map { Point(x: values[$0 * 2], y: values[$0 * 2 + 1]) }
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                guard let found = points(1) else { return nil }
                segments.append(.move(found[0]))
            case "L":
                guard let found = points(1) else { return nil }
                segments.append(.line(found[0]))
            case "C":
                guard let found = points(3) else { return nil }
                segments.append(.curve(control1: found[0], control2: found[1], to: found[2]))
            case "Z":
                segments.append(.close)
            default:
                return nil
            }
        }
        return segments
    }
}
