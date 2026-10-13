import Foundation

public struct MapRect: Sendable {
    public let index: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public enum TreemapLayout {
    // Balanced binary partition, bounded by the caller to a few dozen interactive tiles.
    public static func rectangles(weights: [Int64], width: Double, height: Double) -> [MapRect] {
        let items = weights.enumerated().filter { $0.element > 0 }.map { ($0.offset, Double($0.element)) }
        var output: [MapRect] = []
        func split(_ items: [(Int, Double)], _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            guard !items.isEmpty, w > 0, h > 0 else { return }
            if items.count == 1 {
                output.append(MapRect(index: items[0].0, x: x, y: y, width: w, height: h)); return
            }
            let total = items.reduce(0) { $0 + $1.1 }
            var cut = 1, running = items[0].1
            while cut < items.count - 1 && running + items[cut].1 <= total / 2 {
                running += items[cut].1; cut += 1
            }
            let ratio = running / total
            let first = Array(items[..<cut]), second = Array(items[cut...])
            if w >= h {
                split(first, x, y, w * ratio, h); split(second, x + w * ratio, y, w * (1 - ratio), h)
            } else {
                split(first, x, y, w, h * ratio); split(second, x, y + h * ratio, w, h * (1 - ratio))
            }
        }
        split(items, 0, 0, width, height)
        return output
    }
}
