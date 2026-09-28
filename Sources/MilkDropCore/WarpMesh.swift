import Foundation

public struct WarpMeshVertex: Sendable, Equatable {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>
    public var originalUV: SIMD2<Float>
    public var radius: Float
    public var angle: Float

    public init(position: SIMD2<Float>, uv: SIMD2<Float>, originalUV: SIMD2<Float>, radius: Float, angle: Float) {
        self.position = position
        self.uv = uv
        self.originalUV = originalUV
        self.radius = radius
        self.angle = angle
    }
}

/// MilkDrop's default 48×36 warp grid, expressed as a Metal-ready triangle list.
/// The dimensions are intentionally configurable for later quality/performance tiers.
public struct WarpMesh: Sendable {
    public let gridX: Int
    public let gridY: Int
    public let textureWidth: Int
    public let textureHeight: Int
    public let vertices: [WarpMeshVertex]
    public let indices: [UInt32]

    public struct Motion: Sendable {
        public var zoom: Float = 1
        public var zoomExponent: Float = 1
        public var rotation: Float = 0
        public var center: SIMD2<Float> = SIMD2(0.5, 0.5)
        public var translation: SIMD2<Float> = .zero
        public var stretch: SIMD2<Float> = SIMD2(1, 1)
        public var warp: Float = 0
        public init() {}
    }

    public init(gridX: Int = 48, gridY: Int = 36, width: Int, height: Int) {
        self.gridX = max(gridX, 2)
        self.gridY = max(gridY, 2)
        self.textureWidth = max(width, 1)
        self.textureHeight = max(height, 1)

        let aspectX: Float = height > width ? Float(width) / Float(height) : 1
        let aspectY: Float = width > height ? Float(height) / Float(width) : 1
        let vertexWidth = self.gridX + 1
        var builtVertices: [WarpMeshVertex] = []
        builtVertices.reserveCapacity(vertexWidth * (self.gridY + 1))

        for y in 0...self.gridY {
            for x in 0...self.gridX {
                let px = 2 * Float(x) / Float(self.gridX) - 1
                let py = 2 * Float(y) / Float(self.gridY) - 1
                let uv = SIMD2(0.5 * px + 0.5 + 0.5 / Float(width),
                               -0.5 * py + 0.5 + 0.5 / Float(height))
                let correctedX = px * aspectX
                let correctedY = py * aspectY
                let radius = sqrt(correctedX * correctedX + correctedY * correctedY)
                let angle = radius < 0.000001 ? 0 : atan2(correctedY, correctedX)
                builtVertices.append(WarpMeshVertex(
                    position: SIMD2(px, py), uv: uv, originalUV: uv, radius: radius, angle: angle))
            }
        }
        self.vertices = builtVertices

        var builtIndices: [UInt32] = []
        builtIndices.reserveCapacity(self.gridX * self.gridY * 6)
        for y in 0..<self.gridY {
            for x in 0..<self.gridX {
                let topLeft = UInt32(y * vertexWidth + x)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((y + 1) * vertexWidth + x)
                let bottomRight = bottomLeft + 1
                builtIndices.append(contentsOf: [topLeft, topRight, bottomLeft,
                                                  bottomLeft, topRight, bottomRight])
            }
        }
        self.indices = builtIndices
    }

    /// Evaluates MilkDrop's per-pixel program once per mesh vertex and applies
    /// the portable built-in UV transform. The returned vertices retain the
    /// original positions and carry updated feedback UVs.
    public func evaluate(perPixel engine: EELEngine?, variables frameVariables: [String: Double], motion: Motion) throws -> [WarpMeshVertex] {
        var result = vertices
        for index in result.indices {
            var vars = frameVariables
            let vertex = vertices[index]
            vars["x"] = Double(0.5 * vertex.position.x * aspectX + 0.5)
            vars["y"] = Double(-0.5 * vertex.position.y * aspectY + 0.5)
            vars["rad"] = Double(vertex.radius)
            vars["ang"] = Double(vertex.angle)
            vars["zoom"] = Double(motion.zoom)
            vars["zoomexp"] = Double(motion.zoomExponent)
            vars["rot"] = Double(motion.rotation)
            vars["cx"] = Double(motion.center.x); vars["cy"] = Double(motion.center.y)
            vars["dx"] = Double(motion.translation.x); vars["dy"] = Double(motion.translation.y)
            vars["sx"] = Double(motion.stretch.x); vars["sy"] = Double(motion.stretch.y)
            vars["warp"] = Double(motion.warp)
            try engine?.execute(variables: &vars)
            let zoom = max(Float(vars["zoom"] ?? Double(motion.zoom)), 0.001)
            let zoomExp = max(Float(vars["zoomexp"] ?? Double(motion.zoomExponent)), 0.001)
            let radiusExponent = pow(zoomExp, 2 * vertex.radius - 1)
            let zoomInv = 1 / pow(zoom, radiusExponent)
            var u = 0.5 * vertex.position.x * aspectX * zoomInv + 0.5
            var v = -0.5 * vertex.position.y * aspectY * zoomInv + 0.5
            let cx = Float(vars["cx"] ?? Double(motion.center.x)); let cy = Float(vars["cy"] ?? Double(motion.center.y))
            let sx = max(Float(vars["sx"] ?? Double(motion.stretch.x)), 0.001); let sy = max(Float(vars["sy"] ?? Double(motion.stretch.y)), 0.001)
            u = (u - cx) / sx + cx; v = (v - cy) / sy + cy
            let angle = Float(vars["rot"] ?? Double(motion.rotation))
            let dx = u - cx, dy = v - cy
            let cs = cos(angle), sn = sin(angle)
            u = cs * dx - sn * dy + cx + Float(vars["dx"] ?? Double(motion.translation.x))
            v = sn * dx + cs * dy + cy + Float(vars["dy"] ?? Double(motion.translation.y))
            result[index].uv = SIMD2(u, v)
        }
        return result
    }

    public func evaluateConcurrent(perPixel engine: EELEngine?, variables frameVariables: [String: Double], motion: Motion) throws -> [WarpMeshVertex] {
        guard engine != nil, vertices.count >= 256 else {
            return try evaluate(perPixel: engine, variables: frameVariables, motion: motion)
        }
        var result = vertices
        let workerCount = min(ProcessInfo.processInfo.activeProcessorCount, vertices.count)
        let chunkSize = (vertices.count + workerCount - 1) / workerCount
        let lock = NSLock()
        var firstError: Error?
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let start = worker * chunkSize
            let end = min(start + chunkSize, vertices.count)
            guard start < end else { return }
            var local: [(Int, WarpMeshVertex)] = []
            local.reserveCapacity(end - start)
            do {
                for index in start..<end {
                    let vertex = vertices[index]
                    var vars = frameVariables
                    vars["x"] = Double(0.5 * vertex.position.x * aspectX + 0.5)
                    vars["y"] = Double(-0.5 * vertex.position.y * aspectY + 0.5)
                    vars["rad"] = Double(vertex.radius); vars["ang"] = Double(vertex.angle)
                    vars["zoom"] = Double(motion.zoom); vars["zoomexp"] = Double(motion.zoomExponent)
                    vars["rot"] = Double(motion.rotation)
                    vars["cx"] = Double(motion.center.x); vars["cy"] = Double(motion.center.y)
                    vars["dx"] = Double(motion.translation.x); vars["dy"] = Double(motion.translation.y)
                    vars["sx"] = Double(motion.stretch.x); vars["sy"] = Double(motion.stretch.y)
                    vars["warp"] = Double(motion.warp)
                    try engine?.execute(variables: &vars)
                    let zoom = max(Float(vars["zoom"] ?? Double(motion.zoom)), 0.001)
                    let zoomExp = max(Float(vars["zoomexp"] ?? Double(motion.zoomExponent)), 0.001)
                    let zoomInv = 1 / pow(zoom, pow(zoomExp, 2 * vertex.radius - 1))
                    var u = 0.5 * vertex.position.x * aspectX * zoomInv + 0.5
                    var v = -0.5 * vertex.position.y * aspectY * zoomInv + 0.5
                    let cx = Float(vars["cx"] ?? Double(motion.center.x)), cy = Float(vars["cy"] ?? Double(motion.center.y))
                    let sx = max(Float(vars["sx"] ?? Double(motion.stretch.x)), 0.001)
                    let sy = max(Float(vars["sy"] ?? Double(motion.stretch.y)), 0.001)
                    u = (u - cx) / sx + cx; v = (v - cy) / sy + cy
                    let angle = Float(vars["rot"] ?? Double(motion.rotation)), dx = u - cx, dy = v - cy
                    let cs = cos(angle), sn = sin(angle)
                    u = cs * dx - sn * dy + cx + Float(vars["dx"] ?? Double(motion.translation.x))
                    v = sn * dx + cs * dy + cy + Float(vars["dy"] ?? Double(motion.translation.y))
                    var output = vertex; output.uv = SIMD2(u, v)
                    local.append((index, output))
                }
            } catch {
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
                return
            }
            lock.lock(); for (index, vertex) in local { result[index] = vertex }; lock.unlock()
        }
        if let firstError { throw firstError }
        return result
    }

    private var aspectX: Float { textureHeight > textureWidth ? Float(textureWidth) / Float(textureHeight) : 1 }
    private var aspectY: Float { textureWidth > textureHeight ? Float(textureHeight) / Float(textureWidth) : 1 }
}
