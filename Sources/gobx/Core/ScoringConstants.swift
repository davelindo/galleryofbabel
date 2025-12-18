enum ScoringConstants {
    static let targetAlpha: Double = 3.0
    static let alphaFitRMin: Int = 2
    static let alphaFitRMaxFrac: Double = 0.90

    static let peakinessRMinFrac: Double = 0.15
    static let peakinessRMaxFrac: Double = 0.95
    static let lambdaPeakiness: Double = 0.6

    static let flatnessRMinFrac: Double = 0.15
    static let flatnessRMaxFrac: Double = 0.95
    static let flatnessMax: Double = 0.15
    static let flatnessWeight: Double = 8.0

    static let neighborCorrMin: Double = 0.4
    static let neighborCorrWeight: Double = 5.0

    static let eps: Double = 1e-12

    enum Float32 {
        static let targetAlpha: Float = Float(ScoringConstants.targetAlpha)
        static let alphaFitRMaxFrac: Float = Float(ScoringConstants.alphaFitRMaxFrac)

        static let peakinessRMinFrac: Float = Float(ScoringConstants.peakinessRMinFrac)
        static let peakinessRMaxFrac: Float = Float(ScoringConstants.peakinessRMaxFrac)
        static let lambdaPeakiness: Float = Float(ScoringConstants.lambdaPeakiness)

        static let flatnessRMinFrac: Float = Float(ScoringConstants.flatnessRMinFrac)
        static let flatnessRMaxFrac: Float = Float(ScoringConstants.flatnessRMaxFrac)
        static let flatnessMax: Float = Float(ScoringConstants.flatnessMax)
        static let flatnessWeight: Float = Float(ScoringConstants.flatnessWeight)

        static let neighborCorrMin: Float = Float(ScoringConstants.neighborCorrMin)
        static let neighborCorrWeight: Float = Float(ScoringConstants.neighborCorrWeight)

        static let eps: Float = Float(ScoringConstants.eps)
    }
}

