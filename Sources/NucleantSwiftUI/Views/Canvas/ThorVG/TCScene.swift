public final class TCScene: ThorScene {
    public var base: Tvg_Paint
    
    init(base: Tvg_Paint = tvg_shape_new()) {
        self.base = base
    }
}