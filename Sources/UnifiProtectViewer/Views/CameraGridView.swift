import SwiftUI

/// Displays the cameras of the current view in a responsive grid based on the
/// view's `GridLayout`.
struct CameraGridView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { geo in
            let view = appState.currentView
            let cams = appState.camerasForView(view)

            if cams.isEmpty {
                emptyState
            } else {
                let columns = columnCount(for: view?.layout ?? .auto, count: cams.count)
                let spacing: CGFloat = 6
                let rows = Int(ceil(Double(cams.count) / Double(columns)))
                // Exact cell width so tiles never overflow the trailing edge:
                // total horizontal spacing = leading + trailing + (cols-1) gaps.
                let cellWidth = max(80, (geo.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns))
                let aspectHeight = cellWidth * 9.0 / 16.0
                // Also try to fit all rows vertically without scrolling.
                let fitHeight = (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(max(rows, 1))
                let tileHeight = max(110, min(aspectHeight, fitHeight))
                let gridItems = Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns)

                ScrollView {
                    LazyVGrid(columns: gridItems, spacing: spacing) {
                        ForEach(cams) { cam in
                            CameraTileView(camera: cam, view: view) {
                                appState.showFullscreen(cameraID: cam.id)
                            }
                            .frame(width: cellWidth, height: tileHeight)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(spacing)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No cameras in this view")
                .font(.headline)
            Text("Edit this view to add cameras, or connect to your controller.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnCount(for layout: GridLayout, count: Int) -> Int {
        if let fixed = layout.fixedColumns { return max(1, fixed) }
        // Auto: roughly square grid.
        switch count {
        case 0, 1: return 1
        case 2: return 2
        case 3, 4: return 2
        case 5, 6: return 3
        case 7...9: return 3
        case 10...16: return 4
        default: return 5
        }
    }
}
