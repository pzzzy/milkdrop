public struct MilkDropLaunchPolicy: Sendable, Equatable {
    public let activatesApplication: Bool
    public let entersFullscreen: Bool
    public let makesWindowKey: Bool

    public init(backgroundTest: Bool) {
        activatesApplication = !backgroundTest
        entersFullscreen = !backgroundTest
        makesWindowKey = !backgroundTest
    }
}
