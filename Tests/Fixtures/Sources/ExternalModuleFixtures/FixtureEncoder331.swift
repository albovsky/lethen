/// An encoding API from another module whose `Encodable` value is not its first argument.
public func fixtureEmit331(metadata: String, value: any Encodable) {
    print(metadata, value)
}
