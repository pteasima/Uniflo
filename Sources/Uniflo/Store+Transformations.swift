import Combine

public extension Store {
  public func filterMap<Substate>(initialState: Substate, transform: @escaping (State) -> Substate?) -> Store<Substate, Action> {
    Store<Substate, Action>(initialState: initialState, dispatch: dispatch, willChange: self.stateObject.objectWillChange.map { _ in self.stateObject.state }.compactMap(transform).eraseToAnyPublisher())
  }
  public func pullback<SubAction>(actionTransform: @escaping (SubAction) -> Action) -> Store<State, SubAction> {
    Store<State, SubAction>(initialState: self.stateObject.state, dispatch: { self.dispatch(actionTransform($0)) }, willChange: self.stateObject.objectWillChange.map { _ in self.stateObject.state }.eraseToAnyPublisher())
  }

}
