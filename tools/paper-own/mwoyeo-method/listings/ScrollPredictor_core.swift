    /// Content movement (points, positive = down) expected between `t0` (the frame the overlay was placed from) and `t1`.
    public func offset(from t0: Double, to t1: Double) -> Double {
        ratios.reduce(0) { $0 + $1.value * units($1.key, from: t0, to: t1) }
    }

    /// Frames at `t0` and `t1` showed the content moved by `shift` points: learn the ratio from it. A stop at the end
    /// of the page (events, no movement) or a scroll by other means (keys, scripts) says nothing and is ignored.
    public mutating func confirm(shift: Double, from t0: Double, to t1: Double) {
        let precise = units(true, from: t0, to: t1), lines = units(false, from: t0, to: t1)
        guard (abs(precise) >= 1) != (abs(lines) >= 1) else { return }
        let kind = abs(precise) >= 1, sample = shift / (kind ? precise : lines)
        if let r = ratios[kind] {
            guard sample / r > 0.33, sample / r < 3 else { return }
            ratios[kind] = r + 0.3 * (sample - r)
        } else if sample.isFinite, sample != 0 {
            ratios[kind] = sample
        }
    }

    /// Another app or page: forget what was learnt.
    public mutating func reset() {
        events = []
        ratios = [true: 1]
    }

    /// Wheel units of one kind that reached the screen between `t0` and `t1`.
    func units(_ precise: Bool, from t0: Double, to t1: Double) -> Double {
        events.reduce(0) { $1.precise == precise ? $0 + $1.delta * (shown($1, at: t1) - shown($1, at: t0)) : $0 }
    }

    /// How much of an event's movement is on screen at `t`.
    private func shown(_ e: Event, at t: Double) -> Double {
        let s = t - e.time - latency
        guard s > 0 else { return 0 }
        guard !e.precise else { return 1 }
        let u = min(1, s / stepDuration), rest = 1 - u
        return 1 - rest * rest * rest   // ease-out, like a smooth-scroll animation
    }
