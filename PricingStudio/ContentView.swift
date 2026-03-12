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
