import SwiftUI
import Combine
import Tagged

public struct One: EmptyInitializable, Equatable, Hashable, Codable {
  public init() {}
}

public protocol Application {
  associatedtype Action = Never
  associatedtype Environment = One
  typealias Effect = Uniflo.Effect<Action, Environment>
  typealias SubscriptionEffect = Uniflo.SubscriptionEffect<Action, Environment>
  var initialEffects: [Effect] { get }
  mutating func reduce(_ action: Action) -> [Effect]
  func subscriptions() -> [SubscriptionEffect]
}
public extension Application {
  var initialEffects: [Effect] {
    []
  }
  func reduce(_ action: Action) -> [Effect] {
    print("using default reduce implementation for application \(self), action: \(action)")
    return []
  }
  func subscriptions() -> [SubscriptionEffect] {
    []
  }
}
public extension Application where Environment: EmptyInitializable {
  var environment: Environment { .init() }
}
public protocol EmptyInitializable {
  init()
}

final class StateObject<State>: ObservableObject {
  init(state: State) { self.state = state }
  @Published var state: State
}

@dynamicMemberLookup public struct Store<State, Action>: DynamicProperty {
  @ObservedObject var stateObject: StateObject<State>
  public let dispatch: (Action) -> ()
  
  public static func application<Environment>(environment: Environment, initialState: State, initialEffects: [Effect<Action, Environment>] = [], reduce: @escaping (inout State, Action) -> [Effect<Action, Environment>] = {_,_ in []}, subscriptions: @escaping (State) -> [SubscriptionEffect<Action, Environment>] = { _ in [] }) -> Store {
    
    let program = ElmProgram<State, Action, Environment>(initialState: initialState, initialEffects: initialEffects, update: reduce, subscriptions: subscriptions, effects: environment)
    var store = Store(initialState: program.state, dispatch: program.dispatch, willChange: program.willChange.eraseToAnyPublisher())
    store.strongReferences.append(program)
    
    return store
  }
  
  public subscript<Subject>(dynamicMember keyPath: KeyPath<State, Subject>) -> Subject {
    stateObject.state[keyPath: keyPath]
  }
  public subscript<Subject>(dynamicMember keyPath: KeyPath<State, Subject>) -> (@escaping (Subject) -> Action) -> Binding<Subject> {
  { transform in
    Binding(get: { () -> Subject in
      self[dynamicMember: keyPath]
    }, set: { newValue in
        self.dispatch(transform(newValue))
    })
    }
  }
  
  private var strongReferences: [Any] = [] //used to retain Cancellables and Application, no need to track type of either
  
  //this generic version segfaults at callsite, we need to typeErase for now
  //    private init<P: Publisher>(initialState: State, dispatch: @escaping (Action) -> Void, willChange: P) where P.Output == State, P.Failure == Never { }
  
  init(initialState: State, dispatch: @escaping (Action) -> Void, willChange: AnyPublisher<State, Never>) {
    stateObject = StateObject(state: initialState)
    self.dispatch = dispatch
    strongReferences.append(willChange.assign(to: \.state, on: stateObject)
    )
  }
  
  public static func just(_ state: State) -> Store {
    self.init(initialState: state, dispatch: {
      print($0)
    }, willChange: Empty(completeImmediately: true).eraseToAnyPublisher())
  }
}

public extension Store where Action: EmptyInitializable {
  subscript(dynamicMember keyPath: WritableKeyPath<Action, Void?>) -> () -> Void {
    {
      var action = Action()
      action[keyPath: keyPath] = ()
      self.dispatch(action)
    }
  }
  public subscript<ActionParam>(dynamicMember keyPath: WritableKeyPath<Action, ActionParam?>) -> (ActionParam) -> Void {
      {
        var action = Action()
        action[keyPath: keyPath] = $0
        self.dispatch(action)
      }
  }
  public subscript<P1,P2>(dynamicMember keyPath: WritableKeyPath<Action, (P1, P2)?>) -> (P1, P2) -> Void {
      {
        var action = Action()
        action[keyPath: keyPath] = ($0, $1)
        self.dispatch(action)
      }
  }
}

public extension Store where State: Application, State.Action == Action {
  public static func application(state : State, environment: State.Environment) -> Store {
    self.application(environment: environment, initialState: state, initialEffects: state.initialEffects, reduce: { $0.reduce($1) }, subscriptions: { $0.subscriptions() })
  }
}

fileprivate final class ElmProgram<State, Action, Environment>: EffectManager {
  private(set) lazy var dispatch: (Action) -> Void = {
    print($0)
    self._dispatch($0)
  }
  let willChange = PassthroughSubject<State, Never>()
  private var _dispatch: ((Action) -> Void)!
  private var draftState: State
  private(set) var state: State
  private var isIdle = true
  private var queue : [Action] = []
  private var subscriptions: [(subscription: SubscriptionEffect<Action, Environment>, cancellable: AnyCancellable)] = []//subscriptions we've already fired and may want to cancel
  
  func cancelEffect(id: EffectManager.EffectID) {
    let cancellable = effectCancellables[id]
    cancellable?.cancel() // call cancel just to be safe (it should get cancelled on dealloc anyway)
    effectCancellables[id] = nil
  }
  private var effectCancellables: [EffectManager.EffectID: AnyCancellable] = [:]
  init(initialState: State, initialEffects: [Effect<Action, Environment>], update: @escaping (inout State, Action) -> [Effect<Action, Environment>], subscriptions: @escaping (State) -> [SubscriptionEffect<Action, Environment>], effects: Environment) {
    draftState = initialState
    state = initialState
    let processEffects: ([Effect<Action, Environment>]) -> Void = { [unowned self] effs in
      effs.forEach {
        var cancellable: AnyCancellable?
        let uuid = $0.id
        var completedAlready = false
        cancellable = AnyCancellable($0.perform(self, effects)
          .sink(receiveCompletion: { [weak self] _ in
            // effectCancellables shouldnt grow indefinitely so we make sure we always remove it on completion
            self?.cancelEffect(id: uuid)
            completedAlready = true
            },receiveValue: self.dispatch))
        if !completedAlready { //only append it unless it completed synchronously (Afaik you cant tell from the cancellable if its still alive)
          self.effectCancellables[uuid] = cancellable
        }
      }
      
      let subs = subscriptions(self.state)
      // we cant do a collection.difference here, since that can produce .inserts and .removes for reordering
      // we dont care about order, just cancel and remove old ones and append new ones
      self.subscriptions.forEach { oldSub in
        if !subs.contains(oldSub.subscription) {
          oldSub.cancellable.cancel()
          // TODO: removeFirst(where:)
          self.subscriptions.removeAll { $0.subscription == oldSub.subscription }
        }
      }
      subs.forEach { newSub in
        if !self.subscriptions.contains(where: { $0.subscription == newSub }) {
          let cancellable = AnyCancellable(newSub.perform(effects).sink(receiveValue: self.dispatch))
          self.subscriptions.append((newSub, cancellable))
        }
      }
    }
    _dispatch = { [weak self] msg in
      let dispatchOnMainThread = { [weak self] in
        guard let self = self else { assertionFailure("if I properly managed all cancellables, a dispatch on a dead Program would never happen"); return }
        self.queue.append(msg)
        if self.isIdle { //only start the processing while-loop once. If not idle, then this is a recursive dispatch and we just need to enqueue it.
          self.isIdle = false
          defer { self.isIdle = true }
          
          while !self.queue.isEmpty {
            let currentMsg = self.queue.removeFirst()
            print(currentMsg)
            let effs = update(&self.draftState, currentMsg)
            processEffects(effs)
          }
          
          self.willChange.send(self.draftState)
          self.state = self.draftState
        }
      }
      if Thread.isMainThread {
        dispatchOnMainThread()
      } else {
        DispatchQueue.main.async {
          dispatchOnMainThread()
        }
      }
    }
    
    processEffects(initialEffects)
  }
}
