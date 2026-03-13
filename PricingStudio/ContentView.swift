import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var operatorVM = OperatorCollectionViewModel()
    @State private var pricingVM = PricingViewModel()

    var body: some View {
        NavigationSplitView {
            OperatorSidebarView(viewModel: operatorVM)
        } detail: {
            if let op = operatorVM.selectedOperator {
                PricingDetailView(op: op, viewModel: pricingVM)
            } else {
                EmptyStateView()
            }
        }
        .sheet(isPresented: $operatorVM.showingAddSheet) {
            AddOperatorSheet(viewModel: operatorVM)
        }
        .sheet(isPresented: $operatorVM.showingEditSheet) {
            if let op = operatorVM.operatorToEdit {
                EditOperatorSheet(viewModel: operatorVM, operator_: op)
            }
        }
        .sheet(item: $operatorVM.operatorForStats) { op in
            OperatorStatsSheet(
                operator_: op,
                stats: PreviewData.sampleOperatorStats
            )
        }
        .onChange(of: operatorVM.selectedOperator) { _, newOp in
            if newOp == nil {
                pricingVM.reset()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Operator.self, inMemory: true)
}
