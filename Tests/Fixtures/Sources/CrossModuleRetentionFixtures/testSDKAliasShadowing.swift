import Foundation

// RetentionFixtures declares its own CFloat. This file cannot see that module.
extension Float {
    init(fixtureSDK13 _: Int) { self = 0 }
    init(fixtureOther13 _: Int) { self = 0 }
    init(fixtureLive13 _: Int) { self = 0 }
}

// The compiled configuration declares its own CDouble. Windows uses the SDK alias.
#if !os(Windows)
    struct CDouble {}
#endif

extension Double {
    init(fixturePlatform13 _: Int) { self = 0 }
    init(fixturePlatformLive13 _: Int) { self = 0 }
}

// periphery:ignore
func fixtureSDKAlias13() {
    #if os(Windows)
        _ = CFloat(fixtureSDK13: 1)
        _ = CDouble(fixturePlatform13: 1)
    #else
        _ = Float(fixtureLive13: 2)
        _ = CDouble.self
        _ = Double(fixturePlatformLive13: 1)
    #endif
}
