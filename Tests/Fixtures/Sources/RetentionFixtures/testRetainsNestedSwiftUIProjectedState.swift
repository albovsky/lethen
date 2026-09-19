#if canImport(SwiftUI)
import SwiftUI

public struct NestedProjectionPreviews: PreviewProvider {
    public static var previews: some View {
        FirstPreview()
        SecondPreview()
    }

    struct FirstPreview: View {
        @State private var firstSelection: Int? = 1
        var body: some View {
            ProjectionConsumer(selection: self.$firstSelection)
        }
    }

    struct SecondPreview: View {
        @State private var secondSelection: Int? = 2
        @State private var unusedSelection: Int? = nil
        var body: some View {
            ProjectionConsumer(selection: self.$secondSelection)
        }
    }
}

struct ProjectionConsumer: View {
    @Binding var selection: Int?
    var body: some View { Text(String(describing: selection)) }
}
#endif
