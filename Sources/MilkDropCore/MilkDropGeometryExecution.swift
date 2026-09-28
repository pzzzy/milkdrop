public enum MilkDropGeometryExecution {
    public static func refresh(_ registered: [String: Double], in state: inout [String: Double]) {
        for (name, value) in registered { state[name] = value }
    }

    public static func instanceCount(_ authored: Int) -> Int {
        max(1, authored)
    }
}
