        if proseWords > 0 {
            let rest = letters - proseLetters
            let one = proseWords == 1 && relation && rest >= 2 * proseLetters
            let two = proseWords == 2 && relation && callSeen && proseRuns == [0, 1] && 2 * rest >= 3 * proseLetters
            if !(one || two) { return false }
        }
        if sign { return true }
        if onlyAtoms && (digitLetter || (capsCluster && !digit)) { return true }
