let handler: (Int, Int) -> Int = { used, unused in used }

class Holder {
    var onEvent: (String) -> Void = { _ in }
    let transform: (Int) -> Int = { value in value * 2 }
    let typed: (Int, Int) -> Int = { (first: Int, second: Int) in first }
}
