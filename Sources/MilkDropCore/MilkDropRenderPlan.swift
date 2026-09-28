public enum MilkDropRenderPlan {
    public static func needsNativeInjection(hasPixelEngine: Bool, hasTranslatedWarp: Bool) -> Bool {
        hasPixelEngine && !hasTranslatedWarp
    }
}
