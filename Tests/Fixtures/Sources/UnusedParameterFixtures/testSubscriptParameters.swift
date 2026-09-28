struct Grid {
    subscript(row: Int, column: Int) -> Int {
        row
    }

    subscript(index: Int) -> Int {
        get { 0 }
        set {}
    }
}
