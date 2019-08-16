import SwiftUI

@dynamicMemberLookup public protocol StoreView: View {
    associatedtype State
    associatedtype Action
    var store: Store<State, Action> { get set }
}

public extension StoreView {
    subscript<Subject>(dynamicMember keyPath: KeyPath<State, Subject>) -> Subject {
        store[dynamicMember: keyPath]
    }
    
    subscript<Subject>(dynamicMember keyPath: KeyPath<State, Subject>) -> (@escaping (Subject) -> Action) -> Binding<Subject> {
        store[dynamicMember: keyPath]
    }
}

public extension StoreView where Action: EmptyInitializable {
  subscript(dynamicMember keyPath: WritableKeyPath<Action, Void?>) -> () -> Void {
    self.store[dynamicMember: keyPath]
  }
  subscript<ActionParam>(dynamicMember keyPath: WritableKeyPath<Action, ActionParam?>) -> (ActionParam) -> Void {
          self.store[dynamicMember: keyPath]
  }
  subscript<P1,P2>(dynamicMember keyPath: WritableKeyPath<Action, (P1, P2)?>) -> (P1, P2) -> Void {
          self.store[dynamicMember: keyPath]
  }
}
