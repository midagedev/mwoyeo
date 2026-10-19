    static func verdict(_ members: [Info]) -> Reason? {
        let tinted = members.contains { $0.tinted }
        let f = features(of: members.flatMap(\.lines), tinted: tinted)
        let container = tinted || (members.count > 1 && members.allSatisfy { $0.indented || $0.gutter })
        let weak = f.all - f.strong
        let keeps = (tinted && (f.strong >= 1 || weak >= 2))
            || (container && f.strong >= 1)
            || (members.count > 1 && f.strong >= 1 && f.all >= 2)
            || f.prompt
            || f.strong >= 2
        guard keeps, hasDensity(members, tinted: tinted) else { return nil }
        if f.prompt { return .terminal }
        if f.diff { return .diff }
        if f.log { return .log }
        if f.assignment && !f.keyword && !f.lineEnd { return .config }
        return .code
    }
