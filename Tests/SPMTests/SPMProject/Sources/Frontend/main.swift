import Foundation
import SPMProjectKit

func main() {
    print(SPMProject().text)
    print(PublicCrossModuleReferenced.self)
}

// An unused global placed before top-level code must not claim that code's references.
let unusedGlobalBeforeTopLevelCode = "unused"
main()
