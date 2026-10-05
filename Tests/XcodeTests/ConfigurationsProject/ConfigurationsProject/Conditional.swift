func calledOnlyInDebug() {}
func calledOnlyInRelease() {}

func conditionalEntry() {
    #if DEBUG
        calledOnlyInDebug()
    #else
        calledOnlyInRelease()
    #endif
}
func calledOnlyFromTests() {}
func calledOnlyFromReleaseTests() {}
