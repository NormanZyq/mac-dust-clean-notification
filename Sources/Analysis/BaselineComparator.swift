import Foundation

// MARK: - BaselineComparator
//
// Detects degraded cooling performance by comparing a recent window against
// the best stable cooling capacity observed in historical raw samples. The
// hard part is separating real degradation from
// two confounds the user explicitly cares about:
//
//   (a) Workload. A machine under sustained heavy load is legitimately hot
//       with fast fans — that is not degradation. We handle this by
//       STRATIFYING on load: we only ever compare samples at the same load
//       level (bucket) against each other.
//
//   (b) Ambient / room temperature. A hotter room raises every temperature
//       by roughly the same amount, baseline and recent alike, and a few
//       degrees of seasonal drift is right at the alert threshold. Comparing
//       absolute temperatures would fire on summer arriving. We handle this
//       WITHOUT needing an ambient sensor (most Macs, including desktops,
//       don't expose a usable one) by measuring the TEMPERATURE RISE ABOVE
//       IDLE:
//
//           chipTemp ≈ ambient + thermalResistance × power
//           rise(load) = temp(load) − temp(idle)
//                      ≈ thermalResistance × (power(load) − power(idle))
//
//       The ambient term cancels in the subtraction. If cooling degrades
//       (dust, dried paste), thermalResistance rises and so does `rise`. If
//       only the room got hotter, idle and loaded temps move together and
//       `rise` is unchanged. So we compare the DISTRIBUTION OF RISE in the
//       best historical reference to the distribution of rise in the recent
//       window.
//
// We run the same analysis independently for the CPU (bucketed by CPU load)
// and the GPU (bucketed by GPU load), and return whichever subsystem shows
// the most significant, ambient-corrected degradation. Fan RPM at the same
// bucket is carried as corroborating evidence.
//
// Statistics: per bucket we build rise samples, keep a robust lower slice of
// both historical and recent values as the best-observed cooling reference
// for each side, and compare those distributions with a Mann-Whitney U test
// (non-parametric — temperature is skewed). A single shifted bucket is not
// enough to recommend cleaning: the reference model must be mature and the
// signal must be corroborated across multiple recent days or load buckets.

struct ThermalFinding: Equatable {
    enum Subsystem: String, Equatable { case cpu = "CPU", gpu = "GPU" }

    let subsystem: Subsystem

    // The load bucket (0..loadBuckets-1) where degradation was strongest.
    let cpuPState: Int            // kept this name for UI/back-compat; it is the load bucket

    // Reference/recent chart values. When ambient correction is available
    // these are median rises over idle; otherwise they are absolute medians.
    let baselineMedian: Double
    let recentMedian: Double

    // Ambient-corrected signal: how much the rise-above-idle grew versus the
    // best-observed historical cooling reference.
    let baselineRise: Double      // median rise above idle, reference model
    let recentRise: Double        // median rise above idle, recent window
    let riseDelta: Double         // recentRise - baselineRise  (the headline number)
    let ambientCorrected: Bool    // false if no idle reference was available

    // `tempDelta` keeps its old meaning for existing UI bindings, but is now
    // the ambient-corrected riseDelta when correction was possible (falling
    // back to the raw median delta otherwise).
    let tempDelta: Double

    let fanBaselineMean: Double
    let fanRecentMean: Double
    let fanDelta: Double

    let pValue: Double
    let baselineCount: Int
    let recentCount: Int

    let referenceDayCount: Int
    let supportingRecentDayCount: Int
    let supportingBucketCount: Int
}

struct DustRiskAssessment: Equatable {
    enum Level: Equatable {
        case insufficientData
        case none
        case minor
        case elevated
        case needsCleaning
    }

    let level: Level
    let evidence: ThermalFinding?
    let baselineSampleCount: Int
    let recentSampleCount: Int
    let requiredSamplesPerWindow: Int
    let baselineCoverage: Double
    let recentCoverage: Double
    let referenceDayCount: Int
    let requiredReferenceDays: Int
}

struct CoolingCapacityPoint: Equatable, Identifiable {
    let date: Date
    let subsystem: ThermalFinding.Subsystem
    let coolingLossC: Double
    let fanDelta: Double
    let pValue: Double
    let sampleCount: Int
    let ambientCorrected: Bool

    var id: Date { date }
}

enum BaselineComparator {

    // Load is bucketed into this many levels (0..N-1) by round(load*(N-1)).
    // Matches the synthetic generator and the Sampler's P-State derivation.
    private static let loadBuckets = 9      // 0..8
    private static let minSamplesPerBucket = 30
    private static let minDailyBucketSamples = 10
    private static let minWindowCoverage = 0.65
    private static let minReferenceDaysForCleaning = 7
    private static let minRecentDaysForCleaning = 3

    private struct WorkloadBucket: Hashable, Comparable {
        let primary: Int
        let secondary: Int

        static func < (lhs: WorkloadBucket, rhs: WorkloadBucket) -> Bool {
            if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
            return lhs.secondary < rhs.secondary
        }
    }

    private struct BucketedReading {
        let timestamp: Date
        let value: Double
    }

    /// Run the comparison and return the single most-significant finding
    /// (largest ambient-corrected rise delta) across CPU and GPU, or nil.
    static func run(database: Database, config: Config) throws -> ThermalFinding? {
        let assessment = try assessDustRisk(database: database, config: config)
        guard assessment.level == .needsCleaning else { return nil }
        return assessment.evidence
    }

    /// Return a dashboard-friendly risk assessment without changing the
    /// notification policy. Only `.needsCleaning` maps to an alertable finding;
    /// `.minor` is a significant but below-threshold shift shown as early
    /// warning context in the Overview tab.
    static func assessDustRisk(database: Database, config: Config) throws -> DustRiskAssessment {
        let now = Int64(Date().timeIntervalSince1970)
        let recentStart = now - Int64(config.compareDays) * 86400
        let recentEnd = now
        let referenceStart = config.coolingCalibrationStartedAt ?? 0
        let referenceEnd = recentStart - 1

        // RAW per-sample data only — the rollups have lost the load
        // dimension and the per-sample distribution the test needs.
        let reference = referenceEnd > referenceStart
            ? try database.fetchRawSamplesForAnalysis(from: referenceStart, to: referenceEnd)
            : []
        let recent = try database.fetchRawSamplesForAnalysis(from: recentStart, to: recentEnd)

        let required = minSamplesPerBucket * 2
        let referenceDayCount = distinctDayCount(reference)
        let referenceReadiness = modelReadiness(
            samples: reference,
            required: required,
            dayCount: referenceDayCount,
            requiredDays: minReferenceDaysForCleaning
        )
        let recentCoverage = windowCoverage(samples: recent, from: recentStart, to: recentEnd)
        guard reference.count >= required,
              recent.count >= required,
              recentCoverage >= minWindowCoverage else {
            return DustRiskAssessment(
                level: .insufficientData,
                evidence: nil,
                baselineSampleCount: reference.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: referenceReadiness,
                recentCoverage: recentCoverage,
                referenceDayCount: referenceDayCount,
                requiredReferenceDays: minReferenceDaysForCleaning
            )
        }

        let cpuCandidates = analyzeCandidates(
            subsystem: .cpu,
            baseline: reference, recent: recent, config: config,
            primaryLoad: { $0.cpuLoad },
            secondaryLoad: { $0.gpuLoad },
            temp: { $0.cpuTempC }
        )
        let gpuCandidates = analyzeCandidates(
            subsystem: .gpu,
            baseline: reference, recent: recent, config: config,
            primaryLoad: { $0.gpuLoad },
            secondaryLoad: { $0.cpuLoad },
            temp: { $0.gpuTempC }
        )
        let candidates = annotateSupport(cpuCandidates + gpuCandidates, config: config)

        guard !candidates.isEmpty else {
            return DustRiskAssessment(
                level: .insufficientData,
                evidence: nil,
                baselineSampleCount: reference.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: referenceReadiness,
                recentCoverage: recentCoverage,
                referenceDayCount: referenceDayCount,
                requiredReferenceDays: minReferenceDaysForCleaning
            )
        }

        let alertableCandidates = candidates.filter { isAlertable($0, config: config) }
        if referenceDayCount >= minReferenceDaysForCleaning,
           let alertable = alertableCandidates
            .filter({ isCleaningRecommendation($0, config: config) })
            .max(by: { $0.riseDelta < $1.riseDelta })
        {
            return DustRiskAssessment(
                level: .needsCleaning,
                evidence: alertable,
                baselineSampleCount: reference.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: referenceReadiness,
                recentCoverage: recentCoverage,
                referenceDayCount: referenceDayCount,
                requiredReferenceDays: minReferenceDaysForCleaning
            )
        }

        if let elevated = alertableCandidates.max(by: { $0.riseDelta < $1.riseDelta }) {
            return DustRiskAssessment(
                level: .elevated,
                evidence: elevated,
                baselineSampleCount: reference.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: referenceReadiness,
                recentCoverage: recentCoverage,
                referenceDayCount: referenceDayCount,
                requiredReferenceDays: minReferenceDaysForCleaning
            )
        }

        if let minor = candidates
            .filter({ isMinorRisk($0, config: config) })
            .max(by: { $0.riseDelta < $1.riseDelta })
        {
            return DustRiskAssessment(
                level: .minor,
                evidence: minor,
                baselineSampleCount: reference.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: referenceReadiness,
                recentCoverage: recentCoverage,
                referenceDayCount: referenceDayCount,
                requiredReferenceDays: minReferenceDaysForCleaning
            )
        }

        return DustRiskAssessment(
            level: .none,
            evidence: nil,
            baselineSampleCount: reference.count,
            recentSampleCount: recent.count,
            requiredSamplesPerWindow: required,
            baselineCoverage: referenceReadiness,
            recentCoverage: recentCoverage,
            referenceDayCount: referenceDayCount,
            requiredReferenceDays: minReferenceDaysForCleaning
        )
    }

    /// Daily trend of cooling loss versus the best available cooling
    /// reference. Each point compares a trailing `compareDays` window ending
    /// on that local day against a fixed historical reference before the
    /// chart's final recent window.
    static func coolingLossTrend(database: Database, config: Config,
                                 from fromSec: Int64, to toSec: Int64) throws -> [CoolingCapacityPoint] {
        let compareSeconds = Int64(max(1, config.compareDays)) * 86400
        let referenceStart = config.coolingCalibrationStartedAt ?? 0
        let referenceEnd = toSec - compareSeconds - 1
        guard referenceEnd > referenceStart, fromSec < toSec else { return [] }

        let reference = try database.fetchRawSamplesForAnalysis(
            from: referenceStart,
            to: referenceEnd
        )
        let required = minSamplesPerBucket * 2
        guard reference.count >= required else { return [] }

        let trendSamples = try database.fetchRawSamplesForAnalysis(
            from: max(0, fromSec - compareSeconds),
            to: toSec
        )
        guard !trendSamples.isEmpty else { return [] }

        let cpuBaseBuckets = bucketByLoad(
            reference,
            primaryLoad: { $0.cpuLoad },
            secondaryLoad: { $0.gpuLoad },
            temp: { $0.cpuTempC }
        )
        let gpuBaseBuckets = bucketByLoad(
            reference,
            primaryLoad: { $0.gpuLoad },
            secondaryLoad: { $0.cpuLoad },
            temp: { $0.gpuTempC }
        )
        let calendar = Calendar.current
        let rangeEnd = Date(timeIntervalSince1970: TimeInterval(toSec))
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(fromSec)))
        let totalDays = max(1, calendar.dateComponents([.day], from: day, to: rangeEnd).day ?? 1)
        let strideDays = max(1, Int(ceil(Double(totalDays) / 366.0)))
        var dayIndex = 0
        var points: [CoolingCapacityPoint] = []

        while day < rangeEnd {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(86400)
            defer {
                day = nextDay
                dayIndex += 1
            }
            guard dayIndex % strideDays == 0 || nextDay >= rangeEnd else {
                continue
            }
            let dayEnd = min(nextDay, rangeEnd)
            let dayEndSec = Int64(dayEnd.timeIntervalSince1970)
            let recentStart = dayEndSec - compareSeconds
            let recent = sliceSamples(trendSamples, from: recentStart, to: dayEndSec)
            guard recent.count >= required,
                  windowCoverage(samples: recent, from: recentStart, to: dayEndSec) >= minWindowCoverage else {
                continue
            }

            let cpuPoint = coolingLossPoint(
                subsystem: .cpu,
                date: day,
                baselineBuckets: cpuBaseBuckets,
                recent: recent,
                primaryLoad: { $0.cpuLoad },
                secondaryLoad: { $0.gpuLoad },
                temp: { $0.cpuTempC }
            )
            let gpuPoint = coolingLossPoint(
                subsystem: .gpu,
                date: day,
                baselineBuckets: gpuBaseBuckets,
                recent: recent,
                primaryLoad: { $0.gpuLoad },
                secondaryLoad: { $0.cpuLoad },
                temp: { $0.gpuTempC }
            )

            if let best = [cpuPoint, gpuPoint].compactMap({ $0 })
                .max(by: { $0.coolingLossC < $1.coolingLossC }) {
                points.append(best)
            }
        }

        return points
    }

    private static func coolingLossPoint(
        subsystem: ThermalFinding.Subsystem,
        date: Date,
        baselineBuckets: [WorkloadBucket: [BucketedReading]],
        recent: [Sample],
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?,
        temp: (Sample) -> Double?
    ) -> CoolingCapacityPoint? {
        let recBuckets = bucketByLoad(
            recent,
            primaryLoad: primaryLoad,
            secondaryLoad: secondaryLoad,
            temp: temp
        )
        guard let idleBucket = lowestSharedBucket(baselineBuckets, recBuckets) else {
            return nil
        }

        let baseIdleMed = median(values(baselineBuckets[idleBucket] ?? []))
        let recIdleMed = median(values(recBuckets[idleBucket] ?? []))
        let sharedBuckets = Set(baselineBuckets.keys).intersection(recBuckets.keys)
            .filter { $0.primary > idleBucket.primary }
            .sorted()

        var bestLoss: (loss: Double, sampleCount: Int)?
        for bucket in sharedBuckets {
            let baseTemps = baselineBuckets[bucket] ?? []
            let recTemps = recBuckets[bucket] ?? []
            guard baseTemps.count >= minSamplesPerBucket,
                  recTemps.count >= minSamplesPerBucket else { continue }

            let baseRise = bestObservedValues(values(baseTemps).map { $0 - baseIdleMed })
            let recRise = bestObservedValues(values(recTemps).map { $0 - recIdleMed })
            guard baseRise.count >= minSamplesPerBucket,
                  recRise.count >= minSamplesPerBucket else { continue }

            let loss = median(recRise) - median(baseRise)
            let candidate = (loss: max(0, loss), sampleCount: recRise.count)
            if bestLoss == nil || candidate.loss > bestLoss!.loss {
                bestLoss = candidate
            }
        }

        guard let bestLoss else { return nil }
        return CoolingCapacityPoint(
            date: date,
            subsystem: subsystem,
            coolingLossC: bestLoss.loss,
            fanDelta: 0,
            pValue: 1,
            sampleCount: bestLoss.sampleCount,
            ambientCorrected: true
        )
    }

    // MARK: - Core analysis for one subsystem

    private static func analyzeCandidates(
        subsystem: ThermalFinding.Subsystem,
        baseline: [Sample], recent: [Sample], config: Config,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?,
        temp: (Sample) -> Double?
    ) -> [ThermalFinding] {

        let baseBuckets = bucketByLoad(
            baseline, primaryLoad: primaryLoad, secondaryLoad: secondaryLoad, temp: temp)
        let recBuckets  = bucketByLoad(
            recent, primaryLoad: primaryLoad, secondaryLoad: secondaryLoad, temp: temp)
        return analyzeCandidates(
            subsystem: subsystem,
            baseBuckets: baseBuckets,
            recBuckets: recBuckets,
            baseline: baseline,
            recent: recent,
            config: config,
            primaryLoad: primaryLoad,
            secondaryLoad: secondaryLoad
        )
    }

    private static func analyzeCandidates(
        subsystem: ThermalFinding.Subsystem,
        baseBuckets: [WorkloadBucket: [BucketedReading]],
        recBuckets: [WorkloadBucket: [BucketedReading]],
        baseline: [Sample], recent: [Sample], config: Config,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?
    ) -> [ThermalFinding] {
        // Idle reference = the lowest populated bucket present in BOTH
        // sets. Its median temperature stands in for "ambient + idle
        // power" and is subtracted from the samples before choosing the
        // best historical cooling slice.
        guard let idleBucket = lowestSharedBucket(baseBuckets, recBuckets) else {
            // No common idle reference → cannot ambient-correct. Fall back to
            // an absolute-temperature comparison at the worst shared bucket.
            return absoluteFallbackCandidates(
                subsystem: subsystem,
                baseBuckets: baseBuckets, recBuckets: recBuckets,
                baseline: baseline, recent: recent, config: config,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad
            )
        }

        let baseIdleMed = median(values(baseBuckets[idleBucket] ?? []))
        let recIdleMed  = median(values(recBuckets[idleBucket] ?? []))

        var candidates: [ThermalFinding] = []

        // Compare every loaded bucket (above idle) shared by both sets.
        // Reference values are the lower, stable slice of historical rise
        // samples, so one hot historical period cannot redefine "normal".
        let sharedBuckets = Set(baseBuckets.keys).intersection(recBuckets.keys)
            .filter { $0.primary > idleBucket.primary }
            .sorted()

        for b in sharedBuckets {
            let baseTemps = baseBuckets[b] ?? []
            let recTemps  = recBuckets[b]  ?? []
            guard baseTemps.count >= minSamplesPerBucket,
                  recTemps.count  >= minSamplesPerBucket else { continue }

            let baseValues = values(baseTemps)
            let recValues = values(recTemps)

            // Rise above idle (cancels much of the ambient term). Both sides
            // use their lower stable slice so we compare cooling capacity,
            // not heat left over after a recent workload spike.
            let baseRiseAll = baseValues.map { $0 - baseIdleMed }
            let recRiseAll = recValues.map { $0 - recIdleMed }
            let baseRise = bestObservedValues(baseRiseAll)
            let recRise = bestObservedValues(recRiseAll)
            guard baseRise.count >= minSamplesPerBucket,
                  recRise.count >= minSamplesPerBucket else { continue }

            let baseRiseMed = median(baseRise)
            let recRiseMed  = median(recRise)
            let riseDelta   = recRiseMed - baseRiseMed

            // Significance of the shift in the rise distribution.
            let u = mannWhitneyU(baseRise, recRise)
            let p = mannWhitneyPValue(U: u, n1: baseRise.count, n2: recRise.count)

            // Fan evidence at this bucket.
            let (fanBase, fanRec, fanDelta) = fanStats(
                baseline: baseline, recent: recent, bucket: b,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad)

            let candidate = ThermalFinding(
                subsystem: subsystem,
                cpuPState: b.primary,
                baselineMedian: baseRiseMed,
                recentMedian:   recRiseMed,
                baselineRise:   baseRiseMed,
                recentRise:     recRiseMed,
                riseDelta:      riseDelta,
                ambientCorrected: true,
                tempDelta:      riseDelta,
                fanBaselineMean: fanBase,
                fanRecentMean:   fanRec,
                fanDelta:        fanDelta,
                pValue:          p,
                baselineCount:   baseRise.count,
                recentCount:     recRise.count,
                referenceDayCount: distinctDayCount(baseTemps),
                supportingRecentDayCount: supportingRecentDayCount(
                    readings: recTemps,
                    idleMedian: recIdleMed,
                    referenceMedian: baseRiseMed,
                    threshold: config.tempThresholdC
                ),
                supportingBucketCount: 1
            )
            candidates.append(candidate)
        }
        return candidates
    }

    // MARK: - Absolute-temperature fallback
    //
    // Used only when there is no shared idle bucket to anchor the rise (e.g.
    // a machine that is never idle in one of the windows). We compare
    // absolute temperatures at shared buckets and flag the finding as NOT
    // ambient-corrected so the UI/alert can soften the wording.

    private static func absoluteFallbackCandidates(
        subsystem: ThermalFinding.Subsystem,
        baseBuckets: [WorkloadBucket: [BucketedReading]],
        recBuckets: [WorkloadBucket: [BucketedReading]],
        baseline: [Sample], recent: [Sample], config: Config,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?
    ) -> [ThermalFinding] {
        let shared = Set(baseBuckets.keys).intersection(recBuckets.keys).sorted()
        var candidates: [ThermalFinding] = []
        for b in shared {
            let baseTemps = baseBuckets[b] ?? []
            let recTemps  = recBuckets[b]  ?? []
            guard baseTemps.count >= minSamplesPerBucket,
                  recTemps.count  >= minSamplesPerBucket else { continue }

            let baseValues = values(baseTemps)
            let recValues = values(recTemps)
            let bestBaseTemps = bestObservedValues(baseValues)
            let bestRecTemps = bestObservedValues(recValues)
            guard bestBaseTemps.count >= minSamplesPerBucket,
                  bestRecTemps.count >= minSamplesPerBucket else { continue }

            let baseMed = median(bestBaseTemps)
            let recMed  = median(bestRecTemps)
            let delta   = recMed - baseMed
            let u = mannWhitneyU(bestBaseTemps, bestRecTemps)
            let p = mannWhitneyPValue(U: u, n1: bestBaseTemps.count, n2: bestRecTemps.count)
            let (fanBase, fanRec, fanDelta) = fanStats(
                baseline: baseline, recent: recent, bucket: b,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad)

            let candidate = ThermalFinding(
                subsystem: subsystem,
                cpuPState: b.primary,
                baselineMedian: baseMed,
                recentMedian:   recMed,
                baselineRise:   0,
                recentRise:     0,
                riseDelta:      delta,
                ambientCorrected: false,
                tempDelta:      delta,
                fanBaselineMean: fanBase,
                fanRecentMean:   fanRec,
                fanDelta:        fanDelta,
                pValue:          p,
                baselineCount:   bestBaseTemps.count,
                recentCount:     bestRecTemps.count,
                referenceDayCount: distinctDayCount(baseTemps),
                supportingRecentDayCount: supportingRecentDayCount(
                    readings: recTemps,
                    idleMedian: nil,
                    referenceMedian: baseMed,
                    threshold: config.tempThresholdC
                ),
                supportingBucketCount: 1
            )
            candidates.append(candidate)
        }
        return candidates
    }

    private static func isAlertable(_ finding: ThermalFinding, config: Config) -> Bool {
        let tempTriggered = finding.pValue < 0.05 && finding.tempDelta >= config.tempThresholdC
        let fanTriggered = finding.pValue < 0.05 && finding.fanDelta >= Double(config.fanThresholdRPM)
        return tempTriggered || fanTriggered
    }

    private static func isCleaningRecommendation(_ finding: ThermalFinding, config: Config) -> Bool {
        guard finding.ambientCorrected else { return false }
        guard isAlertable(finding, config: config) else { return false }
        return finding.supportingBucketCount >= 2
            || finding.supportingRecentDayCount >= minRecentDaysForCleaning
    }

    private static func isMinorRisk(_ finding: ThermalFinding, config: Config) -> Bool {
        let tempFloor = max(1.0, config.tempThresholdC * 0.5)
        let fanFloor = max(150.0, Double(config.fanThresholdRPM) * 0.5)
        let tempShift = finding.tempDelta >= tempFloor
        let fanShift = finding.fanDelta >= fanFloor
        return finding.pValue < 0.05 && (tempShift || fanShift)
    }

    private static func annotateSupport(_ candidates: [ThermalFinding], config: Config) -> [ThermalFinding] {
        let strongBySubsystem = Dictionary(grouping: candidates.filter {
            isAlertable($0, config: config)
        }, by: \.subsystem)
        return candidates.map { finding in
            let supportingBucketCount = strongBySubsystem[finding.subsystem]?.count ?? 0
            return ThermalFinding(
                subsystem: finding.subsystem,
                cpuPState: finding.cpuPState,
                baselineMedian: finding.baselineMedian,
                recentMedian: finding.recentMedian,
                baselineRise: finding.baselineRise,
                recentRise: finding.recentRise,
                riseDelta: finding.riseDelta,
                ambientCorrected: finding.ambientCorrected,
                tempDelta: finding.tempDelta,
                fanBaselineMean: finding.fanBaselineMean,
                fanRecentMean: finding.fanRecentMean,
                fanDelta: finding.fanDelta,
                pValue: finding.pValue,
                baselineCount: finding.baselineCount,
                recentCount: finding.recentCount,
                referenceDayCount: finding.referenceDayCount,
                supportingRecentDayCount: finding.supportingRecentDayCount,
                supportingBucketCount: supportingBucketCount
            )
        }
    }

    // MARK: - Bucketing helpers

    /// Group temperatures by the subsystem's own load and the other major
    /// subsystem's load. This keeps GPU-heavy game sessions from being
    /// compared against CPU-only baseline samples in the same CPU bucket.
    private static func bucketByLoad(
        _ samples: [Sample],
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?,
        temp: (Sample) -> Double?
    ) -> [WorkloadBucket: [BucketedReading]] {
        var out: [WorkloadBucket: [BucketedReading]] = [:]
        for s in samples {
            guard let primary = primaryLoad(s), let t = temp(s) else { continue }
            let secondary = secondaryLoad(s) ?? 0
            let bucket = WorkloadBucket(
                primary: loadBucket(primary),
                secondary: loadBucket(secondary)
            )
            out[bucket, default: []].append(BucketedReading(timestamp: s.timestamp, value: t))
        }
        return out
    }

    private static func loadBucket(_ load: Double) -> Int {
        let clamped = max(0.0, min(1.0, load))
        return Int((clamped * Double(loadBuckets - 1)).rounded())
    }

    private static func values(_ readings: [BucketedReading]) -> [Double] {
        readings.map(\.value)
    }

    /// A robust "best observed cooling" slice. We intentionally do not use a
    /// single minimum point; the reference must include enough samples to be a
    /// stable capability estimate. Taking the lower fraction captures periods
    /// where the cooling system performed best while ignoring later degraded
    /// history in the same load bucket.
    private static func bestObservedValues(_ values: [Double]) -> [Double] {
        guard values.count >= minSamplesPerBucket else { return [] }
        let sorted = values.sorted()
        let fractionCount = Int((Double(sorted.count) * 0.35).rounded(.up))
        let count = min(sorted.count, max(minSamplesPerBucket, fractionCount))
        return Array(sorted.prefix(count))
    }

    private static func supportingRecentDayCount(
        readings: [BucketedReading],
        idleMedian: Double?,
        referenceMedian: Double,
        threshold: Double
    ) -> Int {
        let calendar = Calendar.current
        var byDay: [Date: [Double]] = [:]
        for reading in readings {
            let day = calendar.startOfDay(for: reading.timestamp)
            let value = idleMedian.map { reading.value - $0 } ?? reading.value
            byDay[day, default: []].append(value)
        }
        return byDay.values.filter { dayValues in
            guard dayValues.count >= minDailyBucketSamples else { return false }
            return median(dayValues) - referenceMedian >= threshold
        }.count
    }

    private static func distinctDayCount(_ samples: [Sample]) -> Int {
        let calendar = Calendar.current
        return Set(samples.map { calendar.startOfDay(for: $0.timestamp) }).count
    }

    private static func distinctDayCount(_ readings: [BucketedReading]) -> Int {
        let calendar = Calendar.current
        return Set(readings.map { calendar.startOfDay(for: $0.timestamp) }).count
    }

    /// Lowest bucket index present in both sets with enough samples to be
    /// a stable idle reference.
    private static func lowestSharedBucket(
        _ a: [WorkloadBucket: [BucketedReading]],
        _ b: [WorkloadBucket: [BucketedReading]]
    ) -> WorkloadBucket? {
        Set(a.keys).intersection(b.keys)
            .filter { (a[$0]?.count ?? 0) >= minSamplesPerBucket
                   && (b[$0]?.count ?? 0) >= minSamplesPerBucket }
            .min()
    }

    /// Mean fan RPM at a given load bucket in each window, and the delta.
    private static func fanStats(
        baseline: [Sample], recent: [Sample],
        bucket: WorkloadBucket,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?
    ) -> (base: Double, rec: Double, delta: Double) {
        func meanFan(_ samples: [Sample]) -> Double {
            let fans = samples.compactMap { s -> Int? in
                guard let primary = primaryLoad(s) else { return nil }
                let secondary = secondaryLoad(s) ?? 0
                let sampleBucket = WorkloadBucket(
                    primary: loadBucket(primary),
                    secondary: loadBucket(secondary)
                )
                guard sampleBucket == bucket else { return nil }
                guard let f = s.maxFanRPM, f > 0 else { return nil }
                return f
            }
            return fans.isEmpty ? 0 : Double(fans.reduce(0, +)) / Double(fans.count)
        }
        let base = meanFan(baseline)
        let rec  = meanFan(recent)
        return (base, rec, rec - base)
    }

    private static func windowCoverage(samples: [Sample], from start: Int64, to end: Int64) -> Double {
        guard let first = samples.first?.timestamp.timeIntervalSince1970,
              let last = samples.last?.timestamp.timeIntervalSince1970,
              end > start else {
            return 0
        }
        return max(0, min(1, (last - first) / Double(end - start)))
    }

    private static func sliceSamples(_ samples: [Sample], from start: Int64, to end: Int64) -> [Sample] {
        guard start <= end, !samples.isEmpty else { return [] }
        let lower = lowerBound(samples, seconds: start)
        let upper = lowerBound(samples, seconds: end + 1)
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }

    private static func lowerBound(_ samples: [Sample], seconds: Int64) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            let value = Int64(samples[mid].timestamp.timeIntervalSince1970)
            if value < seconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func modelReadiness(
        samples: [Sample],
        required: Int,
        dayCount: Int,
        requiredDays: Int
    ) -> Double {
        guard required > 0, requiredDays > 0 else { return 0 }
        let sampleReadiness = Double(samples.count) / Double(required)
        let dayReadiness = Double(dayCount) / Double(requiredDays)
        return min(1, sampleReadiness, dayReadiness)
    }

    // MARK: - Math helpers

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    // MARK: - Mann-Whitney U test
    //
    // U with the normal approximation and tie-corrected average ranks. Good
    // enough for alert triggering at n ≥ 30; a permutation test would be
    // overkill for a once-a-minute sampler.

    private static func mannWhitneyU(_ a: [Double], _ b: [Double]) -> Double {
        let combined: [(Double, Int)] = a.map { ($0, 0) } + b.map { ($0, 1) }
        let sorted = combined.sorted { $0.0 < $1.0 }
        var ranks = Array(repeating: 0.0, count: sorted.count)
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].0 == sorted[i].0 { j += 1 }
            let avg = Double(i + j) / 2.0 + 1   // average rank for ties
            for k in i...j { ranks[k] = avg }
            i = j + 1
        }
        var r1: Double = 0
        for (idx, item) in sorted.enumerated() where item.1 == 0 { r1 += ranks[idx] }
        let n1 = Double(a.count)
        let u1 = r1 - n1 * (n1 + 1) / 2
        return u1
    }

    private static func mannWhitneyPValue(U: Double, n1: Int, n2: Int) -> Double {
        let mu = Double(n1 * n2) / 2.0
        let n1d = Double(n1)
        let n2d = Double(n2)
        let sigma = (n1d * n2d * (n1d + n2d + 1) / 12.0).squareRoot()
        guard sigma > 0 else { return 1.0 }
        let z = (U - mu).magnitude - 0.5    // continuity correction
        return 2.0 * (1.0 - normalCdf(z / sigma))
    }

    /// Standard normal CDF via the Abramowitz & Stegun erf approximation.
    private static func normalCdf(_ z: Double) -> Double {
        let a1 =  0.254829592
        let a2 = -0.284496736
        let a3 =  1.421413741
        let a4 = -1.453152027
        let a5 =  1.061405429
        let p  =  0.3275911
        let sign = z < 0 ? -1.0 : 1.0
        let x = z.magnitude / sqrt(2.0)
        let t = 1.0 / (1.0 + p * x)
        let y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x)
        return 0.5 * (1.0 + sign * y)
    }
}
